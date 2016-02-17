local posix = require 'posix'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local dbus = require 'cqp.dbus'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local MprisPlayerDBusAPI_OMX = {
	-- Media Player interface
	SetPosition = { interface = "org.mpris.MediaPlayer2.Player", args = "ox" },
	Seek = { interface = "org.mpris.MediaPlayer2.Player", args = "x" },
	PlayPause = { interface = "org.mpris.MediaPlayer2.Player" },
	-- Properties interface
	PlaybackStatus = { interface = "org.freedesktop.DBus.Properties", returns = "s" },
	Duration = { interface = "org.freedesktop.DBus.Properties", returns = "t" },
	Position = { interface = "org.freedesktop.DBus.Properties", returns = "t" },
}

local MprisPlayerDBusAPI_VLC = {
	-- Media Player interface
	SetPosition = { interface = "org.mpris.MediaPlayer2.Player", args = "ox" },
	Seek = { interface = "org.mpris.MediaPlayer2.Player", args = "x" },
	PlayPause = { interface = "org.mpris.MediaPlayer2.Player" },
	-- Properties interface
	PlaybackStatus = { interface = "org.mpris.MediaPlayer2.Player", property = "PlaybackStatus", datatype = "s" },
	Duration = { interface = "org.mpris.MediaPlayer2.Player", property = "Duration", datatype = "t" },
	Position = { interface = "org.mpris.MediaPlayer2.Player", property = "Position", datatype = "t" },
}

local Plugin = {
	control = {
		cond = condition.new(),
	}
}

function Plugin.control.status_update()
	while Plugin.process do
		local status, position, duration = "stopped", 0, 0
		status = Plugin.mpris:PlaybackStatus("PlaybackStatus") or "buffering"
		if status == 'Paused' or status == 'Playing' then
			position = Plugin.mpris:Position("Position") or 0
			if position >= 0 then
				status = status == "Paused" and "paused" or "playing"
				duration = Plugin.mpris:Duration("Duration") or 0
			else
				status = "buffering"
				position = 0
			end
		end
		RAME.player.status(status)
		RAME.player.duration(duration / 1000000)
		RAME.player.position(position / 1000000)
		cqueues.poll(.2)
	end
	Plugin.control.cond:signal()
end

function Plugin.control.omxplay(uri)
	local cmd = {
		"omxplayer",
			"--no-osd",
			"--no-keys",
			"--nohdmiclocksync",
			"--adev", RAME.config.omxplayer_audio_out,
	}
	if Plugin.use_alsa then
		table.insert(cmd, "-A")
		table.insert(cmd, "default")
	end
	table.insert(cmd, uri)
	Plugin.process = process.spawn(table.unpack(cmd))
	cqueues.running():wrap(Plugin.control.status_update)
	local status = Plugin.process:wait()
	Plugin.process = nil
	Plugin.control.cond:wait()
	return status == 0
end

function Plugin.control.vlcplay(uri)
	Plugin.process = process.spawn("vlc", "--control", "dbus", "--intf", "dummy", uri)
	cqueues.running():wrap(Plugin.control.status_update)
	local status = Plugin.process:wait()
	Plugin.process = nil
	Plugin.control.cond:wait()
	return status == 0
end

function Plugin.control.stop()
	if Plugin.process then
		Plugin.process:kill(9)
	end
end

function Plugin.control.seek(pos)
	Plugin.mpris:SetPosition("/", pos * 1000000)
	return true
end

function Plugin.control.pause()
	Plugin.mpris:PlayPause()
	return true
end

function Plugin.active()
	Plugin.omxplayer = plpath.isfile("/usr/bin/omxplayer")
	return Plugin.omxplayer or plpath.isfile("/usr/bin/vlc"), "omxplayer/vlc not found"
end

function Plugin.early_init()
	local schemes = {"http","https","rtmp"}
	local exts = {
		"wav","mp3","flac","aac","m4a","ogg",
		"flv","avi","m4v","mkv","mov","mpg","mpeg","mpe","mp4"
	}
	local mprissvc, mprisapi

	Plugin.dbus = dbus.get_bus()
	if Plugin.omxplayer then
		Plugin.use_alsa = plpath.exists("/proc/asound/sndrpiwsp")
		Plugin.control.play = Plugin.control.omxplay
		mprissvc = "org.mpris.MediaPlayer2.omxplayer"
		mprisapi = MprisPlayerDBusAPI_OMX
	else
		Plugin.control.play = Plugin.control.vlcplay
		mprissvc = "org.mpris.MediaPlayer2.vlc"
		mprisapi = MprisPlayerDBusAPI_VLC
	end
	Plugin.mpris = Plugin.dbus:get_object(mprissvc, "/org/mpris/MediaPlayer2", mprisapi)

	RAME.players:register("file",  exts, 10, Plugin.control)
	RAME.players:register(schemes, exts, 10, Plugin.control)
	RAME.players:register(schemes, "*", 20, Plugin.control)
end

return Plugin
