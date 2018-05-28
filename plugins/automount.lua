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

local mount_statuses = {
	mounted = 1,
	removed = 2,
	manual_umount = 3,
}

local items = {}

local function unlink_items(name)
	local item = items[name]
	if item then
		RAME.media[item.id] = nil
		item:unlink(true)
		items[name] = nil
	end
end

local function media_changed(name, mount_status)
	local devname = "/dev/"..name
	local mountpoint = "/media/"..name

	if mount_status ~= mount_statuses.manual_umount then
		-- in case of manual umount, we do this only when it was successful
		unlink_items(name)
	end

	if mount_status == mount_statuses.mounted then
		local blkid = process.popen("blkid", devname):read_all() or ""
		local label = blkid and blkid:match(' LABEL="([^"]+)"') or "NONAME"
		local uuid  = blkid and blkid:match(' UUID="(%S+)"') or stamp.uuid()
		local ptype = blkid and blkid:match(' TYPE="(%S+)"')

		if not ptype then
			RAME.log.info(("Device %s: not a valid filesystem"):format(devname))
			return
		end

		RAME.log.info(("Device %s: mounting label=%s, uuid=%s"):format(devname, label, uuid))
		if not is_mount_point(mountpoint) then
			posix.mkdir(mountpoint)
			-- hack: exfat lacks proper low-level support for remount,
			--       so until it's fixed we have to always mount as rw
			--       first and then remount ro.
			process.run("mount", "-o", "iocharset=utf8,rw", devname, mountpoint)
			process.run("mount", "-o", "remount,ro", mountpoint)
		end

		RAME.media[uuid] = mountpoint

		RAME.mountpoint_fstype[mountpoint] = ptype

		local saferemove = (ptype == 'exfat' or ptype == 'ntfs')

		local item = Item.new{
			["type"]="device",
			title=label or name,
			mountpoint=mountpoint,
			playlists={},
			playlistsfile="/.rameplaylists.json",
			id=uuid,
			uri="file://"..uuid,
			saferemove=saferemove,
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
		RAME.system.media_mount({ mounted = true, mountpoint = mountpoint })
	elseif mount_status == mount_statuses.removed then
		RAME.log.info(("Device '%s': removed, umounting"):format(devname))
		RAME.mountpoint_fstype[mountpoint] = nil
		process.run("umount", "-l", mountpoint)
		posix.rmdir(mountpoint)
		RAME.system.media_mount({ mounted = false, mountpoint = mountpoint })
	elseif mount_status == mount_statuses.manual_umount then
		RAME.log.info(("Device '%s': manual umount"):format(devname))
		process.run("sync")
		local err = process.popen_err("umount", mountpoint):read_all() or ""
		if err ~= "" then
			RAME.log.error(("umounting %s failed: %s"):format(mountpoint, err))
			return err
		else
			unlink_items(name)
			RAME.mountpoint_fstype[mountpoint] = nil
			posix.rmdir(mountpoint)
			RAME.system.media_mount({ mounted = false, mountpoint = mountpoint })
			return nil
		end
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

function Plugin.umount(dev)
	return media_changed(dev, mount_statuses.manual_umount)
end

function Plugin.main()
	-- Mount existing nodes and setup notifications on them
	local n = notify.opendir("/dev/", 0)
	for _, name in ipairs(data_devices) do
		n:add(name)
		if posix.stat("/dev/"..name) then
			media_changed(name, mount_statuses.mounted)
		end
	end

	-- Act on changes
	for changes, name in n:changes() do
		if name ~= "." then
			if bit32.band(notify.CREATE, changes) == notify.CREATE then
				media_changed(name, mount_statuses.mounted)
			elseif bit32.band(notify.DELETE, changes) == notify.DELETE then
				media_changed(name, mount_statuses.removed)
			end
		end
	end
end

return Plugin
