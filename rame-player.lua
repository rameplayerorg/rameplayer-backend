local posix = require 'posix'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'
local cqueues = require 'cqueues'
local process = require 'cqp.process'
local httpd = require 'cqp.httpd'
local dbus = require 'cqp.dbus'
local RAME = require 'rame'

local use_alsa = plpath.exists("/proc/asound/sndrpiwsp")

local OMXPlayerDBusAPI = {
	-- Media Player interface
	SetPosition = { interface = "org.mpris.MediaPlayer2.Player", args = "ox" },
	Seek = { interface = "org.mpris.MediaPlayer2.Player", args = "x" },
	Action = { interface = "org.mpris.MediaPlayer2.Player", args = "i" },
	-- Properties interface
	PlaybackStatus = { interface = "org.freedesktop.DBus.Properties", returns = "s" },
	Duration = { interface = "org.freedesktop.DBus.Properties", returns = "t" },
	Position = { interface = "org.freedesktop.DBus.Properties", returns = "t" },
}

local function kill_proc()
	if RAME.player.__proc then RAME.player.__proc:kill(9) end
end

local function trigger(item_id, autoplay)
	print("Player: requested to play: " .. item_id)
	RAME.player.__next_item_id = item_id
	RAME.player.__autoplay = autoplay and true or false
	RAME.player.__trigger = -1
	kill_proc()
end

-- REST API: /player/
local PLAYER = { GET = {}, POST = {} }

function PLAYER.GET.play(ctx, reply)
	local status = RAME.player.status()
	if status == "paused" then
		RAME.OMX:Action(16)
	elseif status == "stopped" then
		trigger("play")
	else
		return 400
	end
	return 200
end

function PLAYER.GET.pause(ctx, reply)
	if not RAME.player.__playing then return 400 end
	RAME.OMX:Action(16)
	return 200
end

function PLAYER.GET.stop(ctx, reply)
	if not RAME.player.__playing then return 400 end
	trigger("stop")
	return 200
end

PLAYER.GET["step-forward"] = function(ctx, reply)
	trigger("next", RAME.player.__autoplay)
	return 200
end

PLAYER.GET["step-backward"] = function(ctx, reply)
	trigger("prev", RAME.player.__autoplay)
	return 200
end

function PLAYER.GET.seek(ctx, reply)
	if not RAME.player.__playing then return 400 end
	local pos = tonumber(ctx.paths[ctx.path_pos])
	if pos == nil then return 500 end
	RAME.OMX:SetPosition("/", pos * 1000000)
	return 200
end

-- REST API: /cursor/
local CURSOR = {}

function CURSOR.PUT(ctx, reply)
	if RAME.player.__playing then return 400 end
	local id = ctx.args.id
	local item = RAME:get_item(id)
	if item == nil then return 404 end
	trigger(id)
	return 200
end


local Plugin = {}

function Plugin.init()
	local dbus = require 'cqp.dbus'
	RAME.dbus = dbus.get_bus()
	RAME.OMX = RAME.dbus:get_object("org.mpris.MediaPlayer2.omxplayer", "/org/mpris/MediaPlayer2", OMXPlayerDBusAPI)
	RAME.rest.player = function(ctx, reply) return ctx:route(reply, PLAYER) end
	RAME.rest.cursor = function(ctx, reply) return ctx:route(reply, CURSOR) end
end

function Plugin.active()
	return plpath.isfile("/usr/bin/omxplayer"), "omxplayer not found"
end

local function status_update()
	local OMX = RAME.OMX
	while true do
		local status, position, duration = "stopped", 0, 0
		if RAME.player.__playing then
			status = OMX:PlaybackStatus() or "buffering"
			if status == 'Paused' or status == 'Playing' then
				position = OMX:Position() or 0
				if position >= 0 then
					status = status == "Paused" and "paused" or "playing"
					duration = OMX:Duration() or 0
				else
					status = "buffering"
					position = 0
				end
			end
		end
		RAME.player.status(status)
		RAME.player.duration(duration / 1000000)
		RAME.player.position(position / 1000000)
		cqueues.poll(.2)
	end
end

function Plugin.main()
	RAME.system.ip:push_to(function()
		-- Refresh text if IP changes and not playing.
		-- Perhaps later rametext can be updated to get text
		-- updates via stdin or similar.
		if not RAME.player.__playing then kill_proc() end
	end)
	cqueues.running():wrap(status_update)
	while true do
		-- If cursor changed or play/stop requested
		local play_requested, wrapped = false, false
		local cursor_id  = RAME.player.cursor()
		local request_id = RAME.player.__next_item_id or "next"
		local item

		if request_id == "next" or request_id == "prev" then
			item, wrapped = RAME:get_next_item(cursor_id, request_id == "prev")
			if item then
				cursor_id = item.id
				play_requested = RAME.player.__autoplay
			end
			if wrapped then
				play_requested = (RAME.player.__repeat or 0) ~= 0 and play_requested
				if RAME.player.__repeat >= 1 then
					RAME.player.__repeat = RAME.player.__repeat - 1
				end
			end
		elseif request_id == "stop" then
			play_requested = false
		elseif request_id == "play" then
			item = RAME:get_item(cursor_id)
			play_requested = true
		else
			cursor_id = request_id
			item = RAME:get_item(cursor_id)
			play_requested = RAME.player.__autoplay
		end

		-- Start process matching current state
		RAME.player.__next_item_id = nil
		RAME.player.cursor(cursor_id)
		RAME.player.position(0)
		RAME.player.duration(0)
		if (item and item.uri) or not play_requested then
			if play_requested then
				local adev = RAME.config.omxplayer_audio_out
				if adev == "local" and use_alsa then adev = "alsa" end
				RAME.player.status("buffering")
				RAME.player.__playing = true
				RAME.player.__proc = process.spawn(
					"omxplayer",
						"--no-osd", "--no-keys",
						"--hdmiclocksync", "--adev", adev,
						item.uri)
			else
				RAME.player.status("stopped")
				local ip = RAME.system.ip()
				RAME.player.__proc = process.spawn("rametext", ip ~= "0.0.0.0" and ip or "No Media")
			end
			RAME.player.__proc:wait()
			RAME.player.__proc = nil
			RAME.player.__playing = false
		end
	end
end

function Plugin.set_cursor(id)
	trigger(id, true)
end

return Plugin
