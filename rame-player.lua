local json = require 'cjson'
local posix = require 'posix'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'

local cqueues = require 'cqueues'
local process = require 'cqp.process'
local httpd = require 'cqp.httpd'
local dbus = require 'cqp.dbus'

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

local function get_ip()
	local socket = require "socket"
	local s = socket.udp()
	s:setpeername("8.8.8.8", 80)
	local ip, port = s:getsockname()
	s:close()
	if tostring(ip) == "0.0.0.0" then return nil end
	return ip
end

local function map_uri(uri)
	local fn = uri:gsub("^rameplayer://", "")
	return fn
end

-- Player and playlist data
local player = {
	playlist = {},
	duration = nil,
	autoloop = true,
	autonext = true,

	__current = nil,
	__next_index = nil,
}

function player:next(id)
	if id then self.__next_index = (id ~= 0 and id or nil) end
	if self.proc then self.proc:kill() end
end

-- REST API: /player/
local REST = {
	GET  = { },
	POST = { },
}
function REST.GET.play(ctx, reply)
	local fn = table.concat(ctx.paths, "/", ctx.path_pos)
	print(fn)
	player:next(1)
	return 200
end

function REST.GET.pause(ctx, reply)
	RAME.OMX:Action(16)
end

function REST.GET.stop(ctx, reply)
	player:next(0)
	return 200
end

function REST.GET.next(ctx, reply)
	player:next()
	return 200
end

function REST.GET.seek(ctx, reply)
	local pos = tonumber(ctx.paths[ctx.path_pos])
	if pos == nil then return 500 end
	RAME.OMX:SetPosition("/", pos * 1000000)
	return 200
end

function REST.GET.status(ctx, reply)
	return 200, json.encode(OMX.status)
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
	local status = RAME.status
	local OMX = RAME.OMX
	while true do
		if player.__current then
			if not player.__current.duration then
				-- Cache duration
				player.__current.duration = OMX:Duration()
			end
			local pos = OMX:Position()
			if type(pos) ~= "number" or pos < 0 then pos = 0.0 end

			status.state = OMX:PlaybackStatus() == "Paused" and "paused" or "playing"
			status.position = pos / 1000000
			status.media.uri = player.__current.item.uri
			status.media.index = player.__current.index
			status.media.title = player.__current.item.title
			status.media.duration = (player.__current.duration or 0.0) / 1000000
		else
			status.state = 'stopped'
			status.position = 0
			status.media.uri = nil
			status.media.index = nil
			status.media.title = nil
			status.media.duration = 0
		end
		cqueues.poll(.2)
	end
end

function Plugin.main()
	cqueues.running():wrap(status_update)
	while true do
		local item = nil
		if player.__next_index then
			player.__next_index = (player.__next_index - 1) % #player.playlist.medias + 1
			item = player.playlist.medias[player.__next_index]
		end
		if item then
			player.__current = {
				index = player.__next_index,
				item = item,
			}
			player.__next_index = player.__next_index + 1
			player.proc = process.spawn("omxplayer", "--no-osd", "--no-keys", "--hdmiclocksync", "--adev", "hdmi", map_uri(item.uri))
		else
			player.__current = nil
			player.__next_index = nil
			player.proc = process.spawn("hellovg", get_ip() or "No Media")
		end
		player.proc:wait()
		player.proc = nil
	end
end

function Plugin.set_playlist(plist)
	player.playlist = plist or {}
	player:next(1)
end

return Plugin
