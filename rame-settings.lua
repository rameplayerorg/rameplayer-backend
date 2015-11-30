-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local plfile = require 'pl.file'
local process = require 'cqp.process'

-- forced resolutions on RPi
local rpi_resolutions = {
	rame_autodetect = "",
	rame_720p50 = "hdmi_mode=19",
	rame_720p60 = "hdmi_mode=4",
	rame_1080i50 = "hdmi_mode=20",
	rame_1080i60 = "hdmi_mode=5",
	rame_1080p50 = "hdmi_mode=31",
	rame_1080p60 = "hdmi_mode=16",
}

local rpi_audio_ports = {
	rame_analog_only = "hdmi_drive=1",
	rame_hdmi_only =  "hdmi_drive=2",
	rame_hdmi_and_analog = "hdmi_drive=2",
}

local omxplayer_audio_outs = {
	rame_analog_only = "local",
	rame_hdmi_only = "hdmi",
	rame_hdmi_and_analog = "both",
	-- needs specific ALSA build of omxplayer
	rame_alsa_only = "alsa",
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

	local rpi_audio_port = rpi_audio_ports[json_table.audio_port]
	if rpi_audio_port then
		usercfg = usercfg .. rpi_audio_port .. "\n"

		if json_table.audio_port == "rame_analog_only" and RAME.alsa_support then
			RAME.omxplayer_audio_out = omxplayer_audio_outs["rame_alsa_only"]
		--elseif json_data.audio_port == "rame_hdmi_and_analog"
				 --and RAME.alsa_support
			-- todo this case is not defined!!
		else
			RAME.omxplayer_audio_out = omxplayer_audio_outs[json_table.audio_port]
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
	return read_json(RAME.settings_path .. "version-rame.json")
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	RAME.rest.settings = function(ctx, reply)
		reply.headers["Content-Type"] = "application/json"
		return ctx:route(reply, Settings)
	end
	RAME.rest.version = function(ctx, reply)
		reply.headers["Content-Type"] = "application/json"
		return ctx:route(reply, Version)
	end
end

return Plugin
