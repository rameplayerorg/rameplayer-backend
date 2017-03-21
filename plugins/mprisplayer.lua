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
	Property = { interface = "org.freedesktop.DBus.Properties", method="Set", args = "ssd", returns = "d" },
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
				if not Plugin.live then
					duration = Plugin.mpris:Duration("Duration") or 0
				end
			else
				status = "buffering"
				position = 0
			end
		end
		RAME.player.status(status)
		local display_pos, display_dur = position / 1000000, duration / 1000000
		if Plugin.startpos and Plugin.endpos then
			-- normalize displayed position and duration to chapter
			display_pos = display_pos - Plugin.startpos
			display_dur = Plugin.endpos - Plugin.startpos
		end
		RAME.player.duration(display_dur)
		RAME.player.position(display_pos)
		if Plugin.endpos and position / 1000000 >= Plugin.endpos then
			-- simulate internally ending of normal playback when chapter ends
			Plugin.chapter_ended = true
			Plugin.control.stop()
		end
		cqueues.poll(.1)
	end
	Plugin.control.cond:signal()
end

function Plugin.control.omxplay(uri, itemrepeat, initpos, chstartpos, chendpos)
	local adev = RAME.config.omxplayer_audio_out

	-- FIXME: omxplayer does not support 'both' with alsa at the moment
	if adev == "local" and Plugin.use_alsa then adev = "alsa:default" end

	local cmd = {
		"omxplayer",
			"--no-osd",
			"--no-keys",
			"--nohdmiclocksync",
			"--adev", adev,
	}

	if uri:match("^rtmp:") then
		table.insert(cmd, "--live")
		Plugin.live = true
	end
	if itemrepeat then
		table.insert(cmd, "--loop")
	end
	if initpos then
		table.insert(cmd, "--pos")
		table.insert(cmd, tostring(initpos))
	end
	Plugin.chapter_ended = nil
	Plugin.startpos = chstartpos
	Plugin.endpos = chendpos
	if not Plugin.use_alsa then
		table.insert(cmd, "--vol")
		-- convert volume percentage to millibels
		local vol = math.log10(RAME.system.headphone_volume() / 100) * 2000
		table.insert(cmd, ("%d"):format(math.floor(vol)))
	end
	local filename, chapter_id = RAME.resolve_uri(uri)
	table.insert(cmd, filename)
	Plugin.process = process.spawn(table.unpack(cmd))
	cqueues.running():wrap(Plugin.control.status_update)
	local status = Plugin.process:wait()
	Plugin.process = nil
	Plugin.control.cond:wait()
	Plugin.live = nil
	local chapter_done = Plugin.chapter_ended
	Plugin.chapter_ended = nil
	return status == 0 or chapter_done
end

function Plugin.control.vlcplay(uri)
	Plugin.process = process.spawn(
		"vlc", "--control", "dbus", "--intf", "dummy",
		RAME.resolve_uri(uri))
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
	if Plugin.live then return false end
	if Plugin.startpos and Plugin.endpos then
		-- normalize position to chapter
		pos = pos + Plugin.startpos
	end
	Plugin.mpris:SetPosition("/", pos * 1000000)
	return true
end

function Plugin.control.pause()
	if Plugin.live then return false end
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
		"flv","avi","m4v","mkv","mov","mpg","mpeg","mpe","mp4",
	}
	local mprissvc, mprisapi

	Plugin.dbus = dbus.get_bus()
	if Plugin.omxplayer then
		Plugin.use_alsa = plpath.exists("/proc/asound/sndrpiwsp")
		if Plugin.use_alsa then
			RAME.system.headphone_volume:push_to(function(val)
				process.run("amixer", "-Dhw:sndrpiwsp", "--", "sset", "HPOUT1 Digital", ("%.2fdB"):format(64.0*val/100 - 64.0))
			end)
			RAME.system.lineout_volume:push_to(function(val)
				process.run("amixer", "-Dhw:sndrpiwsp", "--", "sset", "HPOUT2 Digital", ("%.2fdB"):format(64.0*val/100 - 64.0))
			end)
		end
		Plugin.control.play = Plugin.control.omxplay
		mprissvc = "org.mpris.MediaPlayer2.omxplayer"
		mprisapi = MprisPlayerDBusAPI_OMX
	else
		Plugin.control.play = Plugin.control.vlcplay
		mprissvc = "org.mpris.MediaPlayer2.vlc"
		mprisapi = MprisPlayerDBusAPI_VLC
	end
	Plugin.mpris = Plugin.dbus:get_object(mprissvc, "/org/mpris/MediaPlayer2", mprisapi)

	if Plugin.omxplayer and not Plugin.use_alsa then
		-- ALSA not available: use omxplayer interface for volume control
		RAME.log.info("Controlling headphone volume by omxplayer")
		RAME.system.headphone_volume:push_to(function(val)
			Plugin.mpris:Property("org.mpris.MediaPlayer2.Player", "Volume", val/100)
		end)
	end

	RAME.players:register("file",  exts, 10, Plugin.control)
	RAME.players:register(schemes, exts, 10, Plugin.control)
	RAME.players:register(schemes, "*", 20, Plugin.control)
end

return Plugin
