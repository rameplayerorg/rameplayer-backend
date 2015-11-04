#!/usr/bin/dbus-run-session lua5.2

package.path = "/etc/cqpushy/?.lua;"..package.path
local json = require 'cjson'
local posix = require 'posix'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'

local cqueues = require 'cqueues'
local notify = require 'cqueues.notify'

local push = require 'cqp.push'
local process = require 'cqp.process'
local httpd = require 'cqp.httpd'
local dbus = require 'cqp.dbus'

-- Clear framebuffer
os.execute([[
[ -e /.splash.ctrl ] && (echo quit > /.splash.ctrl ; rm /.splash.ctrl)
dd if=/dev/zero of=/dev/fb0 bs=1024 count=2700
]])

local dbus_omx

local function is_mount_point(path)
	local a = posix.stat(path)
	if a == nil then return false end
	local b = posix.stat(path.."/..") or {}
	return not (a.dev == b.dev and a.ino ~= b.ino)
end

local function get_ip()
	local socket = require "socket"
	local s = socket.udp()
	s:setpeername("8.8.8.8",80)
	local ip, port = s:getsockname()
	s:close()
	if tostring(ip) == "0.0.0.0" then return nil end
	return ip
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

-- Media Libaries
local medialib = {
}
local function scan_media(name, mountpoint)
	local data = {
		uri = "rameplayer://"..name,
		title = dirname,
		medias = {}
	}
	local files = pldir.getfiles(mountpoint, "*.mp4")
	table.sort(files)
	for track, f in pairs(files) do
		local basename = plpath.basename(f)
		table.insert(data.medias, {
			uri = ("rameplayer://%s/%s"):format(name, basename),
			filename = basename,
			title = basename,
			duration = 0,
			created = plfile.modified_time(f) * 1000,
		})
	end
	medialib[name] = #data.medias and data or nil
	print(("Scanned %s, %d found"):format(name, #data.medias))

	-- Autoplay
	player.playlist = data.medias or {}
	player:next(1)
end

-- Auto-mounting
local data_devices = { "sda1", "sdb1", "mmcblk0p2" }
local function auto_mount()
	-- Mount existing nodes and setup notifications on them
	local n = notify.opendir("/dev/", 0)
	for _, name in ipairs(data_devices) do
		n:add(name)
		local dev = "/dev/"..name
		local mountpoint = "/media/"..name
		if posix.stat(dev) then
			if not is_mount_point(mountpoint) then
				posix.mkdir(mountpoint)
				process.run("mount", "-o", "ro", dev, mountpoint)
			end
			scan_media(name, mountpoint)
		end
	end

	-- Act on changes
	for changes, name in n:changes() do
		if name ~= "." then
			local dev = "/dev/"..name
			local mountpoint = "/media/"..name
			if bit32.band(notify.CREATE, changes) == notify.CREATE then
				posix.mkdir(mountpoint)
				process.run("mount", "-o", "ro", dev, mountpoint)
				scan_media(name, mountpoint)
			elseif bit32.band(notify.DELETE, changes) == notify.DELETE then
				medialib[name] = nil
				player.playlist = {}
				player:next()
				process.run("umount", "-l", mountpoint)
			end
		end
	end
end

-- omxplayer management & playlist handling
local function map_uri(uri)
	local fn = uri:gsub("^rameplayer://", "/media/")
	return fn
end

local function omxplayer_manager()
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

-- Media API
local hdrs_nocache = {
	"Access-Control-Allow-Origin: *",
	"Cache-Control: no-cache",
	"Pragma: no-cache",
}
local hdrs_json = {
	"Access-Control-Allow-Origin: *",
	"Content-Type: application/json",
	"Cache-Control: no-cache",
	"Pragma: no-cache",
}

local URI = {}
function URI.media(hdr, args)
	local libs = {}
	for name, obj in pairs(medialib) do table.insert(libs, obj) end
	return 200, "OK", hdrs_json, json.encode(libs)
end

URI.player = {}
function URI.player.play(hdr, args, path)
	local fn = table.concat(path, "/", 3)
	player:next(1)
	return 200, "OK", hdrs_json
end

function URI.player.stop(hdr, args, path)
	player:next(0)
	return 200, "OK", hdrs_nocache
end

function URI.player.next(hdr, args, path)
	player:next()
	return 200, "OK", hdrs_nocache
end

function URI.player.seek(hdr, args, path)
	--dbus_omx:request("org.mpris.MediaPlayer2.Player", "Seek", nil, tonumber(path[3]))
	return 200, "OK", hdrs_nocache
end

function URI.player.status()
	local r
	if player.__current then
		if not player.__current.duration then
			-- Cache duration
			player.__current.duration = dbus_omx:request("org.freedesktop.DBus.Properties", "Duration")
		end
		local status = dbus_omx:request("org.freedesktop.DBus.Properties", "PlaybackStatus")
		local pos    = dbus_omx:request("org.freedesktop.DBus.Properties", "Position")
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
	return 200, "OK", hdrs_json, json.encode(r)
end

local function setup()
	dbus_omx = dbus.get_bus():get_proxy("org.mpris.MediaPlayer2.omxplayer", "/org/mpris/MediaPlayer2")
	httpd.new{local_addr="0.0.0.0", port=8000, uri=URI}
end

local loop = cqueues.new()
loop:wrap(setup)
loop:wrap(omxplayer_manager)
loop:wrap(auto_mount)

for e in loop:errors() do
	print(e)
end
