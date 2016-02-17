local posix = require 'posix'
local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local notify = require 'cqueues.notify'
local process = require 'cqp.process'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local function is_mount_point(path)
	local a = posix.stat(path)
	if a == nil then return false end
	local b = posix.stat(path.."/..") or {}
	return not (a.dev == b.dev and a.ino ~= b.ino)
end

local data_devices = {
	"sda1",
	"sdb1",
	"mmcblk0p2"
}

local items = {}

local function media_changed(name, mountpoint, mounted)
	if items[name] then
		items[name]:unlink()
		items[name] = nil
	end
	if mounted then
		local item = Item.new{
			["type"]="device",
			title=name,
			uri="file:///"..mountpoint,
		}
		items[name] = item
		RAME.root:add(item)
		if RAME.settings.autoplayUsb then
			item:expand()
			if #item.items > 0 then
				RAME:action("autoplay", item.items[1].id)
			end
		end
	end
end


local Plugin = {}

function Plugin.active()
	-- Root required for mounting/unmounting
	return posix.getuid() == 0, "not root"
end

function Plugin.init()
	local path = "/media/mmcblk0p1/media"
	if plpath.exists(path) then
		RAME.rame:add(Item.new({id="internal", title="Internal", uri="file:///"..path}))
	end
end

function Plugin.main()
	-- Mount existing nodes and setup notifications on them
	local n = notify.opendir("/dev/", 0)
	for _, name in ipairs(data_devices) do
		n:add(name)
		local dev = "/dev/"..name
		local mountpoint = "/media/"..name
		if posix.stat(dev) then
			if not is_mount_point(mountpoint) then
				posix.mkdir(mountpoint)
				process.run("mount", "-o", "iocharset=utf8,ro", dev, mountpoint)
			end
			media_changed(name, mountpoint, true)
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
				media_changed(name, mountpoint, true)
			elseif bit32.band(notify.DELETE, changes) == notify.DELETE then
				media_changed(name, mountpoint, false)
				process.run("umount", "-l", mountpoint)
			end
		end
	end
end

return Plugin
