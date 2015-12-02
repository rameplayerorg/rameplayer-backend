local json = require 'cjson'
local posix = require 'posix'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'
local cqueues = require 'cqueues'
local process = require 'cqp.process'
local httpd = require 'cqp.httpd'
local dbus = require 'cqp.dbus'
local RAME = require 'rame'

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

local function map_uri(uri)
	local fn = uri:gsub("^rameplayer://", "")
	return fn
end

local function trigger_next(item_id)
	print("Player: requested to play: " .. item_id)
	RAME.player.__next_item_id = item_id
	if RAME.player.__proc then RAME.player.__proc:kill(9) end
end

-- REST API: /player/
local REST = {
	GET  = { },
	POST = { },
}
function REST.GET.play(ctx, reply)
	if RAME.player.status() ~= "paused" then
		trigger_next(RAME.player.cursor())
	else
		RAME.OMX:Action(16)
	end
	return 200
end

function REST.GET.pause(ctx, reply)
	RAME.OMX:Action(16)
	return 200
end

function REST.GET.stop(ctx, reply)
	trigger_next("stop")
	return 200
end

function REST.GET.next(ctx, reply)
	trigger_next()
	return 200
end

function REST.GET.seek(ctx, reply)
	local pos = tonumber(ctx.paths[ctx.path_pos])
	if pos == nil then return 500 end
	RAME.OMX:SetPosition("/", pos * 1000000)
	return 200
end

local Plugin = {}

function Plugin.init()
	RAME.dbus = dbus.get_bus()
	RAME.OMX = RAME.dbus:get_object("org.mpris.MediaPlayer2.omxplayer", "/org/mpris/MediaPlayer2", OMXPlayerDBusAPI)
	RAME.rest.player = function(ctx, reply)
		reply.headers["Content-Type"] = "application/json"
		return ctx:route(reply, REST)
	end
end

function Plugin.active()
	return plpath.isfile("/usr/bin/omxplayer"), "omxplayer not found"
end

local function status_update()
	local OMX = RAME.OMX
	while true do
		local status, position, duration = "stopped", 0, 0
		if RAME.player.__proc then
			status = OMX:PlaybackStatus() or "stopped"
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
	cqueues.running():wrap(status_update)
	while true do
		-- If cursor changed or play/stop requested
		local play_requested, wrapped = false, false
		local cursor_id  = RAME.player.cursor()
		local request_id = RAME.player.__next_item_id

		if request_id == "stop" or request_id == "" then
			play_requested = false
		elseif request_id then
			cursor_id = request_id
			play_requested = true
		elseif cursor_id and cursor_id ~= "" then
			cursor_id, wrapped = RAME:get_next_item_id(cursor_id)
			play_requested = true --list.autoPlayNext
			--[[
			if wrapped then
				play_requested = (list["repeat"] or 0) ~= 0 and play_requested
				if list["repeat"] >= 1 then
					list["repeat"] = list["repeat"] - 1
				end
			end
			--]]
		end

		-- Start process matching current state
		RAME.player.__next_item_id = nil
		RAME.player.cursor(cursor_id)
		RAME.player.position(0)
		RAME.player.duration(0)
		if play_requested then
			local item = RAME:get_item(cursor_id)
			RAME.player.status("buffering")
			RAME.player.__proc = process.spawn(
				"omxplayer",
					"--no-osd", "--no-keys",
					"--hdmiclocksync", "--adev", "hdmi",
					map_uri(item.uri))
		else
			RAME.player.status("stopped")
			RAME.player.__proc = process.spawn("hellovg", RAME.ip or "No Media")
		end
		RAME.player.__proc:wait()
		RAME.player.__proc = nil
	end
end

function Plugin.set_cursor(id)
	trigger_next(id)
end

return Plugin
