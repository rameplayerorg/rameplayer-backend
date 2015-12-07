-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local plfile = require 'pl.file'
local process = require 'cqp.process'
local RAME = require 'rame'

-- forced resolutions on RPi
local rpi_resolutions = {
	rameAutodetect = "",
	rame720p50 = "hdmi_mode=19",
	rame720p60 = "hdmi_mode=4",
	rame1080i50 = "hdmi_mode=20",
	rame1080i60 = "hdmi_mode=5",
	rame1080p50 = "hdmi_mode=31",
	rame1080p60 = "hdmi_mode=16",
}

local rpi_audio_ports = {
	rameAnalogOnly = "hdmi_drive=1",
	rameHdmiOnly =  "hdmi_drive=2",
	rameHdmiAndAnalog = "hdmi_drive=2",
}

local omxplayer_audio_outs = {
	rameAnalogOnly = "local",
	rameHdmiOnly = "hdmi",
	rameHdmiAndAnalog = "both",
	-- needs specific ALSA build of omxplayer
	rameAlsaOnly = "alsa",
	-- tbd how to signal both alsa and HDMI
}

-- REST API: /settings/
local Settings = {
	GET  = { },
	POST = { },
}

function read_json(file)
	local data = plfile.read(file)
	return data and 200 or 500, data
end

function write_json(file, data)
	-- validating that data is JSON by encoding & decoding
	local json_table = json.decode(data)
	if not json_table then return 500, "json decode failed" end

	local body = json.encode(json_table)
	if not body then return 500, "json encode failed" end

	return write_file(file, data)
end

-- note errorhandling: if rw mount fails the file write fails so no need
-- check will the mount fails or not
function write_file(file, data)
	process.run("mount", "-o", "remount,rw", "/media/mmcblk0p1")
	local status = plfile.write(file, data)
	 process.run("mount", "-o", "remount,ro", "/media/mmcblk0p1")

	if not status then return 500, "file write failed" else return 200 end
end

function Settings.GET.user(ctx, reply)
	return read_json(RAME.path_settings_user)
end

function Settings.POST.user(ctx, reply)
	return write_json(RAME.path_settings_user, ctx.body)
end

function Settings.GET.system(ctx, reply)
	return read_json(RAME.path_settings_system)
end

-- todo add support for IP settings
-- these settings require reboot which is not implemented
function Settings.POST.system(ctx, reply)
	local usercfg = "hdmi_group=1" .. "\n"
	local json_table = json.decode(ctx.body)
	if not json_table then return 415, "malformed json" end

	local rpi_resolution = rpi_resolutions[json_table.resolution]
	if rpi_resolution then
		usercfg = usercfg .. rpi_resolution .. "\n"
	else return 422, "missing required json param: resolution" end

	local rpi_audio_port = rpi_audio_ports[json_table.audioPort]
	if rpi_audio_port then
		usercfg = usercfg .. rpi_audio_port .. "\n"

		if json_table.audioPort == "rame_analog_only" and RAME.alsa_support then
			RAME.omxplayer_audio_out = omxplayer_audio_outs["rame_alsa_only"]
		--elseif json_data.audio_port == "rame_hdmi_and_analog"
				 --and RAME.alsa_support
			-- todo this case is not defined!!
		else
			RAME.omxplayer_audio_out = omxplayer_audio_outs[json_table.audioPort]
		end
	else return 422, "missing required json param: audio_port" end

	if not write_file(RAME.path_rpi_config, usercfg)
		then return 500, "file write error" end

	local data = json.encode(json_table)
	if not data then return 500, "json encode failed" end

	if not write_file(RAME.path_settings_system, data)
		then return 500, "file write error" else return 200 end
end


-- REST API: /version/
local Version = {
	GET  = { },
}

function Version.GET(ctx, reply)
	local data = {}
	data["hw"] = plfile.read("/sys/firmware/devicetree/base/model")
	if not data["hw"] then return 500, "file read error" end

	-- last byte of hw ver data is special char that is left out
	data["hw"] = data["hw"]:sub(1, data["hw"]:len() - 1)
	data["backend"] = RAME.version

	return 200, data
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, Settings) end
	RAME.rest.version = function(ctx, reply) return ctx:route(reply, Version) end
end

return Plugin
