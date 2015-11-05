local json = require 'cjson'
local posix = require 'posix'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'

local cqueues = require 'cqueues'
local process = require 'cqp.process'
local httpd = require 'cqp.httpd'
local dbus = require 'cqp.dbus'

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
	local fn = uri:gsub("^rameplayer://", "/media/")
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
function REST.GET.play(hdr, args, path)
	local fn = table.concat(path, "/", 3)
	player:next(1)
	return 200
end

function REST.GET.play()
	return 500
end

function REST.GET.stop(hdr, args, path)
	player:next(0)
	return 200
end

function REST.GET.next(hdr, args, path)
	player:next()
	return 200
end

function REST.GET.seek(hdr, args, path)
	--dbus_omx:request("org.mpris.MediaPlayer2.Player", "Seek", nil, tonumber(path[3]))
	return 200
end

function REST.GET.status()
	local omx = RAME.dbus_omx
	local r
	if player.__current then
		if not player.__current.duration then
			-- Cache duration
			player.__current.duration = omx:request("org.freedesktop.DBus.Properties", "Duration")
		end
		local status = omx:request("org.freedesktop.DBus.Properties", "PlaybackStatus")
		local pos    = omx:request("org.freedesktop.DBus.Properties", "Position")
		r = {
			state = status == "Paused" and "paused" or "playing",
			position = (pos or 0.0) / 1000000,
			media = {
				uri = player.__current.item.uri,
				index = player.__current.index,
				title = player.__current.item.title,
				duration = (player.__current.duration or 0.0) / 1000000,
			}
		}
	else
		r = {
			state='stopped',
			position = 0,
			media = {
				duration = 0,
			}
		}
	end
	return 200, json.encode(r)
end

local Plugin = {}

function Plugin.init()
	RAME.dbus = dbus.get_bus()
	RAME.dbus_omx = RAME.dbus:get_proxy("org.mpris.MediaPlayer2.omxplayer", "/org/mpris/MediaPlayer2")
	RAME.rest.player = function(ctx, reply)
		reply.headers["Content-Type"] = "application/json"
		return ctx:route(reply, REST)
	end
end

function Plugin.active()
	return plpath.isfile("/usr/bin/omxplayer"), "omxplayer not found"
end

function Plugin.main()
	while true do
		local item = nil
		if player.__next_index then
			player.__next_index = (player.__next_index - 1) % #player.playlist + 1
			item = player.playlist[player.__next_index]
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
