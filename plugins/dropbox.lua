local posix = require 'posix'
local plfile = require 'pl.file'
local plpath = require 'pl.path'
local json = require 'cjson.safe'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local notify = require 'cqueues.notify'
local process = require 'cqp.process'
local RAME = require 'rame.rame'
local Item = require 'rame.item'
local Stamp = require 'rame.stamp'
local DropboxClient = require 'rame.dropbox'

-- persistant storage for dropbox settings
local dropbox_json = "dropbox.json"
-- default conf
local dropbox_conf = {
	version = 1,
	-- random device id
	device = string.sub(Stamp.uuid(), 1, 8),
	mounts = {}
}

-- conf filename located in mounted medias, containing keys
local ext_fn = ".ramedropbox.json"

local data_devices = {
	"sda", "sda1",
	"sdb", "sdb1",
	"sdc", "sdc1",
	"sdd", "sdd1",
	"mmcblk0p2"
}

-- Dropbox sessions
local sessions = {}

-- Dropbox session
local Session = {
	mount_id = "",
	mountpoint = "",
	path = "",
	conf = {},
	running = false,
}

Session.__index = Session

function Session:start()
	-- sync in background
	local client = self.client
	cqueues.running():wrap(function()
		client:start_sync()
	end)

	self.running = true
	return self
end

function Session:stop()
	self.client:stop_sync()
	self.running = false
	return self
end

function Session.new(obj)
	obj = obj or {}
	local self = setmetatable(obj, Session)
	local path = RAME.resolve_uri(self.conf.uri)
	self.client = DropboxClient.new {
		access_token = self.conf.accessToken,
		dropbox_path = self.conf.dropboxPath,
		-- Dropbox client uses local path without trailing slash
		local_path   = path:sub(1, path:len() - 1),

		-- callbacks
		writing_start_callback = function()
			process.run("mount", "-o", "remount,rw", self.mountpoint)
			return true
		end;
		writing_end_callback = function()
			process.run("mount", "-o", "remount,ro", self.mountpoint)
			-- TODO: reload items
			return true
		end;
	}
	return self
end

-- adds new session and starts it
function Session.add(mount_id, mountpoint, conf)
	--local path = mountpoint .. conf.mountPath .. "/"
	local session = Session.new {
		mount_id = mount_id,
		mountpoint = mountpoint,
		--path = path,
		conf = conf,
	}
	sessions[conf.uri] = session
	return session:start()
end

-- stops session and removes it
function Session.remove(uri)
	local session = sessions[uri]
	if session ~= nil then
		session:stop()
	end
	sessions[uri] = nil
end

-- removes sessions by mountpoint
function Session.remove_mountpoints(mountpoint)
	for uri, session in pairs(sessions) do
		if session.mountpoint == mountpoint then
			Session.remove(uri)
		end
	end
end

-- returns true if string starts with given value
local function str_starts(str, start)
	return string.sub(str, 1, string.len(start)) == start
end

-- returns mountpoint used in path or nil if not any
local function find_mountpoint(path)
	for _, name in ipairs(data_devices) do
		local mountpoint = "/media/" .. name
		if str_starts(path, mountpoint .. "/") then
			return mountpoint
		end
	end
	return nil
end

-- adds given mount id to external conf in mount point
local function rewrite_ext(mountpoint, mount_id, add)
	-- read file
	local e_file = mountpoint .. "/" .. ext_fn
	local data, err = json.decode(plfile.read(e_file) or '{"version":1,"devices":{}}')

	-- modify content
	if data.devices[dropbox_conf.device] == nil then
		data.devices[dropbox_conf.device] = {
			mounts = {}
		}
	end

	if add then
		table.insert(data.devices[dropbox_conf.device].mounts, mount_id)
	else
		for i,m in ipairs(data.devices[dropbox_conf.device].mounts) do
			if m == mount_id then
				table.remove(data.devices[dropbox_conf.device].mounts, i)
				break
			end
		end
	end

	-- write file
	RAME.remount_rw_write(mountpoint, e_file, json.encode(data))
end

local function write_internal_conf()
	local saved_json, err = json.encode(dropbox_conf)
	if saved_json == nil or not RAME.write_settings_file(dropbox_json, saved_json) then
		RAME.log.error("Failed to write Dropbox cfg: " .. (err or "nil"))
	end
end

-- REST API: /dropbox/
local DROPBOX = { GET = {}, POST = {}, PUT = {}, DELETE = {} }

function DROPBOX.GET.auth(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id, true, true)
	if item == nil then return 404 end
	if item.items == nil then return 400 end

	local path = RAME.resolve_uri(item.uri)
	RAME.log.debug(("get Dropbox auth for %s"):format(path))

	local session = sessions[item.uri]
	if session == nil then
		return 200, {
			account = nil
		}
	end

	-- fetch account information from Dropbox
	local db_res = session.client:get_account(session.conf.accountId)
	local res = {
		account = db_res.data
	}
	if db_res.status ~= 200 then
		res.error = "Can't get account information"
	end
	return 200, res
end

-- called from Dropbox authentication broker site
function DROPBOX.POST.auth(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id, true, true)
	if item == nil then return 404 end
	if item.items == nil then return 400 end

	local path = RAME.resolve_uri(item.uri)
	RAME.log.debug(("Add Dropbox auth to %s"):format(path))

	--RAME.log.debug(("Dropbox access token: %s"):format(access_token))
	RAME.log.debug(("Dropbox account ID: %s"):format(ctx.args.accountId))

	-- get random mount id
	local mount_id = string.sub(Stamp.uuid(), 1, 8)
	local mountpoint = find_mountpoint(path)
	if mountpoint == nil then
		-- not a mountpoint
		return 500, {}
	end

	-- write mount id to external conf
	rewrite_ext(mountpoint, mount_id, true)

	--local rel_path = string.sub(path, string.len(mountpoint) + 1)
	-- strip trailing slash
	--rel_path = string.sub(rel_path, 1, rel_path:len() - 1)

	local conf = {
		accessToken = ctx.args.accessToken,
		accountId = ctx.args.accountId,
		-- in dropbox the root folder is specified as an empty string rather than as "/"
		dropboxPath = "",
		uri = item.uri,
		--mountPath = rel_path
	}

	-- add to internal conf and write it to disk
	dropbox_conf.mounts[mount_id] = conf
	write_internal_conf()

	RAME.log.debug(('Added authentication, device id: %s, mount id: %s'):format(dropbox_conf.device, mount_id))

	Session.add(mount_id, mountpoint, conf)

	return 200, { status = "ready" }
end

-- revoke Dropbox authentication
function DROPBOX.DELETE.auth(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id, true, true)
	if item == nil then return 404 end
	if item.items == nil then return 400 end
	--local path = RAME.resolve_uri(item.uri)
	RAME.log.debug(("Revoke Dropbox auth from %s"):format(item.uri))

	local session = sessions[item.uri]
	if session == nil then
		return 404
	end

	-- remove from internal conf and rewrite it to disk
	dropbox_conf.mounts[session.mount_id] = nil
	write_internal_conf()

	-- remove mount_id from external conf
	rewrite_ext(session.mountpoint, session.mount_id, false)

	Session.remove(item.uri)

	return 200, {}
end

-- returns conf by given device id and mount id or nil if not found
local function find_conf(device_id, mount_id)
	if device_id ~= dropbox_conf.device then return nil end
	return dropbox_conf.mounts[mount_id]
end

local function read_ext(mountpoint)
	-- read config keys from mounted media
	local e_file = mountpoint .. "/" .. ext_fn
	if not plpath.exists(e_file) then return end

	-- check if external conf has matching keys
	local content, err = plfile.read(e_file)
	if err == nil then
		local c = json.decode(content or "{}")
		for device_id, dev_conf in pairs(c.devices) do
			for _, mount_id in ipairs(dev_conf.mounts) do
				local conf = find_conf(device_id, mount_id)
				if conf ~= nil then
					-- matching conf found, create new session
					Session.add(mount_id, mountpoint, conf)
				else
					RAME.log.debug(("Dropbox: config not found for key %s:%s"):format(device_id, mount_id))
				end
			end
		end
	else
		RAME.log.error(("Error when reading external keyfile %s: %s"):format(e_file, err))
	end
end

local function media_changed(name, mounted)
	local mountpoint = "/media/"..name

	if mounted then
		-- sleep a little so fs is ready
		-- TODO: refactor to listen event from automount.lua
		cqueues.poll(0.3)
		read_ext(mountpoint)
	else
		-- device unmounted, stop session with this mountpoint
		RAME.log.info(("Dropbox: stop sessions with mountpoint: %s"):format(mountpoint))
		Session.remove_mountpoints(mountpoint)
	end
end

local Plugin = {}

Plugin.settings_changed = condition.new()

function Plugin.init()
	-- Read the stored values (or in case of 1st boot "")
	local conf = json.decode(RAME.read_settings_file(dropbox_json) or "")
	if conf ~= nil then
		dropbox_conf = conf
	else RAME.log.info("Dropbox: no config stored") end

	RAME.rest.dropbox = function(ctx, reply) return ctx:route(reply, DROPBOX) end
end

function Plugin.main()
	-- Setup notifications on mount points
	local n = notify.opendir("/media/", 0)
	for _, name in ipairs(data_devices) do
		n:add(name)
		if posix.stat("/media/"..name) then
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
