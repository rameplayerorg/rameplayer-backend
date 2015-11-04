local posix = require 'posix'
local cqueues = require 'cqueues'
local notify = require 'cqueues.notify'
local process = require 'cqp.process'

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

local Plugin = {}

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
				process.run("mount", "-o", "ro", dev, mountpoint)
			end
			RAME:hook("media_changed", mountpoint, name)
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
				RAME:hook("media_changed", mountpoint, name)
			elseif bit32.band(notify.DELETE, changes) == notify.DELETE then
				RAME:hook("media_changed", mountpoint, name)
				process.run("umount", "-l", mountpoint)
			end
		end
	end
end

return Plugin
