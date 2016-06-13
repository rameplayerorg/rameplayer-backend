local posix = require 'posix'
local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local notify = require 'cqueues.notify'
local process = require 'cqp.process'
local stamp = require 'rame.stamp'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local function is_mount_point(path)
	local a = posix.stat(path)
	if a == nil then return false end
	local b = posix.stat(path.."/..") or {}
	return not (a.dev == b.dev and a.ino ~= b.ino)
end

local data_devices = {
	"sda", "sda1",
	"sdb", "sdb1",
	"sdc", "sdc1",
	"sdd", "sdd1",
	"mmcblk0p2"
}

local items = {}

local function media_changed(name, mounted)
	local devname = "/dev/"..name
	local mountpoint = "/media/"..name

	local item = items[name]
	if item then
		RAME.media[item.id] = nil
		item:unlink(true)
		items[name] = nil
	end

	if mounted then
		local blkid = process.popen("blkid", devname):read_all() or ""
		local label = blkid and blkid:match(' LABEL="(%S+)"') or "NONAME"
		local uuid  = blkid and blkid:match(' UUID="(%S+)"') or stamp.uuid()
		local ptype = blkid and blkid:match(' TYPE="(%S+)"')

		if not ptype then
			RAME.log.info(("Device %s: not a valid filesystem"):format(devname))
			return
		end

		RAME.log.info(("Device %s: mounting label=%s, uuid=%s"):format(devname, label, uuid))
		if not is_mount_point(mountpoint) then
			posix.mkdir(mountpoint)
			process.run("mount", "-o", "iocharset=utf8,ro", devname, mountpoint)
		end

		RAME.media[uuid] = mountpoint

		local item = Item.new{
			["type"]="device",
			title=label or name,
			mountpoint=mountpoint,
			playlists={},
			playlistsfile="/.rameplaylists.json",
			id=uuid,
			uri="file://"..uuid,
		}
		items[name] = item
		RAME.root:add(item)
		RAME.load_playlists(item)

		if RAME.user_settings.autoplayUsb then
			item:expand()
			if #item.items > 0 then
				for _,i in pairs(item.items or {}) do
					if i.type == "regular" then
						RAME:action("autoplay", i.id)
						break
					end
				end
			end
		elseif RAME.player.cursor() == "" then
			-- initialize cursor if it was empty
			item:expand()
			for _,i in pairs(item.items or {}) do
				if i.type == "regular" then
					RAME.player.cursor(i.id)
					break
				end
			end
		end
	else
		RAME.log.info(("Device '%s': umounting"):format(devname))
		process.run("umount", "-l", mountpoint)
		posix.rmdir(mountpoint)
	end
end


local Plugin = {}

function Plugin.active()
	-- Root required for mounting/unmounting
	return posix.getuid() == 0, "not root"
end

function Plugin.init()
	local id, path = "internal", "/media/mmcblk0p1/media"
	if plpath.exists(path) then
		RAME.media[id] = path
		RAME.rame:add(Item.new({id=id, title="Internal", uri="file://internal/"}))
	end
end

function Plugin.main()
	-- Mount existing nodes and setup notifications on them
	local n = notify.opendir("/dev/", 0)
	for _, name in ipairs(data_devices) do
		n:add(name)
		if posix.stat("/dev/"..name) then
			media_changed(name, true)
		end
	end

	-- Act on changes
	for changes, name in n:changes() do
		if name ~= "." then
			if bit32.band(notify.CREATE, changes) == notify.CREATE then
				media_changed(name, true)
			elseif bit32.band(notify.DELETE, changes) == notify.DELETE then
				media_changed(name, false)
			end
		end
	end
end

return Plugin
