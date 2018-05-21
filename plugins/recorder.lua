-- Must be safe version of cjson-lib for error handling
local json = require 'cjson.safe'
local plpath = require 'pl.path'
local plutils = require 'pl.utils'
local cqueues = require 'cqueues'
local posix = require 'posix'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

-- wait time in secs to check bmd-streamer is still running
local WAIT_PROCESS = 1
local BMD_STREAMER = "/usr/bin/bmd-streamer"
local SCRIPT_PATH = "/var/run/ramerecorder-ffmpeg.sh"
local FLAG_FILE = "/var/run/ramerecorder"
local FIRMWARE_PATH = "/media/mmcblk0p1/bmd-streamer"
local SETTINGS_FILE = "recorder.json"

local recorder_fields = {
	avgVideoBitrate  = { typeof="string"  },
	maxVideoBitrate  = { typeof="string"  },
	h264Profile      = { typeof="string"  },
	h264Level        = { typeof="string"  },
	h264BFrames      = { typeof="string"  },
	h264Cabac        = { typeof="string"  },
	fpsDivider       = { typeof="string"  },
	audioBitrate     = { typeof="string"  },
	input            = { typeof="string"  },
	recorderEnabled  = { typeof="boolean" },
	streamingEnabled = { typeof="boolean" },
	streamMode       = { typeof="string"  },
}

-- Plugin Hooks
local Plugin = {}

Plugin.settings = nil
Plugin.streaming = false
Plugin.recording = false

-- REST API: /recorder/
local RECORDER = { GET = {}, PUT = {} }

-- Generates ffmpeg script to be launched by bmd-stream
local function gen_script(cfg)
	local c = [[#!/bin/sh
# auto-generated by RamePlayer
exec /usr/bin/ffmpeg -fflags +genpts -i - ]]

	if cfg.recorderEnabled then
		c = c .. " \\\n\t-bsf:a aac_adtstoasc"
		c = c .. " \\\n\t-codec:a copy -codec:v copy"
		c = c .. " \\\n\t\"" .. cfg.recordingPath .. "\""
	end

	if cfg.streamingEnabled then
		if cfg.streamMode == "1" or cfg.streamMode == "extServer" then
			local server = "rtmp://localhost/rame/program"
			if cfg.streamMode == "extServer" then
				server = cfg.streamServer
			end
			c = c .. " \\\n\t-bsf:a aac_adtstoasc"
			c = c .. " \\\n\t-f flv -codec:a copy -codec:v copy"
			c = c .. " \\\n\t" .. server
		elseif cfg.streamMode == "2" then
			c = c .. " \\\n\t-bsf:a aac_adtstoasc"
			c = c .. " \\\n\t-f flv -codec:v copy -strict experimental -codec:a aac -b:a 256k -af \"pan=1c|c0=c0\" rtmp://localhost/rame/audio1"
			c = c .. " \\\n\t-f flv -codec:v copy -strict experimental -codec:a aac -b:a 256k -af \"pan=1c|c0=c1\" rtmp://localhost/rame/audio2"
		elseif cfg.streamMode == "custom" then
			c = c .. " \\\n\t" .. cfg.customParams
		end
	end
	return c .. "\n"
end

local function write_script(data)
	plutils.writefile(SCRIPT_PATH, data)
	posix.chmod(SCRIPT_PATH, "rwxrwxrwx")
end

-- Starts bmd-streamer
local function start_process(cfg)
	RAME.recorder.running(true)
	if cfg.recorderEnabled then
		Plugin.recording = true
		RAME.recorder.recording(true)
	end
	if cfg.streamingEnabled then
		Plugin.streaming = true
		RAME.recorder.streaming(true)
	end

	write_script(gen_script(cfg))

	cqueues.running():wrap(function()

		local function run()
			local cmd = {
				"/usr/bin/bmd-streamer",
				"-S", cfg.input,
				"--syslog",
				"--firmware-dir", FIRMWARE_PATH,
				"--exec", SCRIPT_PATH,
			}

			if cfg.avgVideoBitrate ~= "" then
				table.insert(cmd, "--video-kbps")
				table.insert(cmd, "" .. cfg.avgVideoBitrate)
			end

			if cfg.maxVideoBitrate ~= "" then
				table.insert(cmd, "--video-max-kbps")
				table.insert(cmd, "" .. cfg.maxVideoBitrate)
			end

			if cfg.audioBitrate ~= "" then
				RAME.log.debug(cfg.audioBitrate)
				table.insert(cmd, "--audio-kbps")
				table.insert(cmd, "" .. cfg.audioBitrate)
			end

			if cfg.h264Profile then
				table.insert(cmd, "--h264-profile")
				table.insert(cmd, cfg.h264Profile)
			end

			if cfg.h264Level ~= "" then
				table.insert(cmd, "--h264-level")
				table.insert(cmd, "" .. cfg.h264Level)
			end

			if cfg.h264BFrames == "enabled" then
				table.insert(cmd, "--h264-bframes")
			elseif cfg.h264BFrames == "disabled" then
				table.insert(cmd, "--h264-no-bframes")
			end

			if cfg.h264Cabac == "enabled" then
				table.insert(cmd, "--h264-cabac")
			elseif cfg.h264Cabac == "disabled" then
				table.insert(cmd, "--h264-no-cabac")
			end

			if cfg.fpsDivider ~= nil then
				table.insert(cmd, "--fps-divider")
				table.insert(cmd, "" .. cfg.fpsDivider)
			end

			RAME.log.debug('cmd:', table.unpack(cmd))
			Plugin.process = process.spawn(table.unpack(cmd))

			-- wait until process is terminated
			local status = Plugin.process:wait()
			RAME.log.info(('bmd-streamer terminated: %d'):format(status))
			RAME.recorder.running(false)
			RAME.recorder.recording(false)
			RAME.recorder.streaming(false)
			Plugin.recording = false
			Plugin.streaming = false
			Plugin.process = nil
		end

		if cfg.recorderEnabled then
			-- mountpoint needs to remounted rw before recording
			local mountpoint = RAME.get_mountpoint(cfg.recordingPath)
			-- make sure mountpoint is remounted ro after stopping recording
			RAME.remounter:wrap(mountpoint, run)
		else
			run()
		end
	end)

	-- wait to see if running flag has changed
	cqueues.poll(WAIT_PROCESS)
	return RAME.recorder.running()
end

-- udev script calls GET /recorder/enable when device is plugged in
function RECORDER.GET.enable()
	RAME.recorder.enabled(true)
	RAME.log.info('Recorder device connected')
	return 200, {}
end

-- udev script calls GET /recorder/disable when device is removed
function RECORDER.GET.disable()
	RAME.recorder.enabled(false)
	RAME.log.info('Recorder device disconnected')
	return 200, {}
end

function RECORDER.GET.config()
	return 200, Plugin.settings or {}
end

function RECORDER.PUT.start(ctx, reply)
	local cfg = ctx.args

	-- validate request
	err, msg = RAME.check_fields(cfg, recorder_fields)
	if err then return err, msg end

	if Plugin.streaming or Plugin.recording then
		return 503, { error = "bmd-streamer already running" }
	end

	-- validate recording path
	if cfg.recorderEnabled then
		local exists = cfg.recordingPath == "" or plpath.exists(cfg.recordingPath)
		if exists then
			return 500, { error="Recording file already exists"}
		end
	end

	if start_process(cfg) then
		Plugin.settings = cfg
		if not RAME.write_settings_file(SETTINGS_FILE, json.encode(cfg)) then
			RAME.log.error("File write error: "..SETTINGS_FILE)
			return 500, { error="File write error: "..SETTINGS_FILE }
		end
		return 200, {}
	else
		return 500, { error = "bmd-streamer not started" }
	end
end

function RECORDER.GET.stop(ctx, reply)
	if Plugin.process then
		RAME.log.debug('stop streaming/recording')
		Plugin.process:kill(15)
		return 200, {}
	end
	return 500, { error = "bmd-streamer was not running" }
end

function Plugin.init()
	-- check if flag file exists, created by udev script
	RAME.recorder.enabled(plpath.exists(FLAG_FILE))

	if RAME.recorder.enabled() then
		RAME.log.info('Recorder device detected')
	else
		RAME.log.info('Recorder device not detected')
	end

	local cfg = json.decode(RAME.read_settings_file(SETTINGS_FILE) or "")
	if cfg == nil then
		-- default values
		cfg = {}
		cfg.streamingEnabled = false
		cfg.recorderEnabled = false
		cfg.input = "sdi"
		cfg.avgVideoBitrate = "3000"
		cfg.maxVideoBitrate = "3100"
		cfg.h264Profile = "main"
		cfg.h264Level = "32"
		cfg.h264BFrames = "disabled"
		cfg.h264Cabac = "default"
		cfg.fpsDivider = ""
		cfg.audioBitrate = ""
		cfg.streamMode = "1"
		cfg.recordingPath = "/media/sda1/recording.mp4"
		cfg.streamServer = ""
		cfg.customParams = ""
	end
	if RAME.check_fields(cfg, recorder_fields) == nil then
		Plugin.settings = cfg
	end

	RAME.rest.recorder = function(ctx, reply) return ctx:route(reply, RECORDER) end
end

return Plugin
