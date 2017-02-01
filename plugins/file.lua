local posix = require 'posix'
local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local notify = require 'cqueues.notify'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

-- returns given path without trailing slash
local function strip_slash(path)
	if path:sub(-1) == "/" then
		path = path:sub(1, -2)
	end
	return path
end

-- returns item with matching uri from given items,
-- or nil if not found
local function find_item(items, uri)
	for _, item in ipairs(items) do
		if uri == strip_slash(item.uri) then
			return item
		end
	end
	return nil
end

-- creates new item to given parent
local function create_item(parent, file)
	local i = Item.new { uri = parent.uri .. file }
	if i.type == "directory" or RAME.players:resolve(i.uri) then
		i.parent = parent
		table.insert(parent.items, i)
		-- start watching file
		parent.watcher:add(file)
	end
	return i
end

local Watcher = {}
Watcher.__index = Watcher

function Watcher:add(file)
	self.n:add(file)
end

function Watcher:remove(file)
	local uri = self.item.uri .. file
	local item = find_item(self.item.items, uri)
	if item ~= nil then
		item:unlink(true)
	end
end

-- scan directory and add new file and directory items
function Watcher:refresh_dir()
	for file in posix.files(self.path) do
		if file:sub(1, 1) ~= "." then
			local uri = self.item.uri .. file
			local item = find_item(self.item.items, uri)
			if item == nil then
				-- item not found: new item
				create_item(self.item, file)
			end
		end
	end
	table.sort(self.item.items)
	self.item:touch()
end

-- file item was modified, refresh its data
function Watcher:refresh_file(file)
	local uri = self.item.uri .. file
	local item = find_item(self.item.items, uri)
	if item ~= nil then
		local helper = Item.uri_helpers:resolve(item.uri)
		if helper then helper(item) end
		-- refresh also parent
		self.item:touch()
	end
end

-- switch functionality for change events
function Watcher:changed(changes, name)
	local fp = plpath.join(self.path, name)
	if bit32.band(notify.CREATE, changes) == notify.CREATE then
		-- file created to a directory
		if type(self.item.items) == "table" then
			-- child items already expanded, refresh them
			-- if not expanded, no need to do this
			self:refresh_dir()
		end

	elseif bit32.band(notify.DELETE, changes) == notify.DELETE then
		-- file/directory deleted from a directory
		if name ~= "." then
			-- RAME.log.debug(("Notify: DELETED: %s"):format(fp))
			self:remove(name)
		end
	else
		-- file modified
		if name ~= "." then
			-- RAME.log.debug(("Notify: MODIFY: %s"):format(fp))
			self:refresh_file(name)
		end
	end
end

function Watcher:watch()
	-- use cqueues notify to track file changes
	self.n = notify.opendir(self.path, notify.CREATE | notify.MODIFY | notify.DELETE)

	-- start watching
	self.watching = true
	cqueues:running():wrap(function()
		while self.watching do
			-- trigger to changes and check flag 'self.watching' every 10 secs
			for changes, name in self.n:changes(10) do
				self:changed(changes, name)
			end
		end
		RAME.log.debug(("watching ended for %s"):format(self.path))
	end)
	return self
end

function Watcher:destroy()
	-- stop watching
	self.watching = false
end

function Watcher.new(obj)
	obj = obj or {}
	local self = setmetatable(obj, Watcher)
	return self:watch()
end


local Plugin = {}

function Plugin.expand(self)
	local path = RAME.resolve_uri(self.uri)
	self.items = {}
	for file in posix.files(path) do
		if file:sub(1, 1) ~= "." then
			create_item(self, file)
		end
	end
	table.sort(self.items)
	self:touch()
end

function Plugin.uri_helper(self)
	local path = RAME.resolve_uri(self.uri)
	if not path then return end
	local st = posix.stat(path)
	if not st then return end

	self.type = self.type or st.type
	self.modified = st.mtime and st.mtime * 1000
	self.filename = plpath.basename(strip_slash(path))
	self.size = st.size
	if st.type == "directory" and not self.items then
		-- make sure uri is trailed by slash
		if self.uri:sub(-1) ~= "/" then
			self.uri = self.uri.."/"
		end
		self.watcher = Watcher.new { path = path, item = self }
		self.items = Plugin.expand
	end
end

function Plugin.early_init()
	Item.uri_helpers:register("file", nil, 10, Plugin.uri_helper)
end

return Plugin
