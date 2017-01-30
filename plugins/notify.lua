local posix = require 'posix'
local plpath = require 'pl.path'
local tablex = require 'pl.tablex'
local cqueues = require 'cqueues'
local notify = require 'cqueues.notify'
local RAME = require 'rame.rame'

local Watcher = {}
Watcher.__index = Watcher

function Watcher:has(file)
	return tablex.find(self.contents, file) ~= nil
end

function Watcher:is_excluded(file)
	return tablex.find(self.exclude, file) ~= nil
end

function Watcher:changed(changes, name)
	local fp = plpath.join(self.path, name)
	if bit32.band(notify.CREATE, changes) == notify.CREATE then
		for file in posix.files(self.path) do
			if file:sub(1, 1) ~= "." and not self:has(file) and not self:is_excluded(file) then
				local p = self:add(file)
				RAME.log.debug(("Notify: CREATED: %s"):format(p))
			end
		end
	elseif bit32.band(notify.DELETE, changes) == notify.DELETE then
		if name ~= "." then
			RAME.log.debug(("Notify: DELETED: %s"):format(fp))
			self:remove(name)
		end
	else
		if name ~= "." then
			RAME.log.debug(("Notify: MODIFY: %s"):format(fp))
		end
	end

end

function Watcher:add(file)
	local fp = plpath.join(self.path, file)
	local st = posix.stat(fp)
	if st == nil then return end
	self.n:add(file)
	is_dir = false
	if st.type == "directory" then
		self.watchers[file] = Watcher.new {
			path = fp
		}
		is_dir = true
	end
	table.insert(self.contents, file)
	return fp, is_dir
end

function Watcher:remove(file)
	local w = self.watchers[file]
	if w then
		w:destroy()
		self.watchers[file] = nil
	end

	-- remove from self.contents
	local idx = tablex.find(self.contents, file)
	if idx then
		table.remove(self.contents, idx)
	end
end

function Watcher:watch()
	self.n = notify.opendir(self.path, notify.CREATE | notify.MODIFY | notify.DELETE)

	-- setup notifications from existing files and directories
	for file in posix.files(self.path) do
		if file:sub(1, 1) ~= "." and not self:is_excluded(file) then
			self:add(file)
		end
	end

	-- start watching
	self.watching = true
	cqueues:running():wrap(function()
		while self.watching do
			-- trigger to changes and check flag 'self.watching' every hour
			for changes, name in self.n:changes(3600) do
				self:changed(changes, name)
			end
		end
		RAME.log.debug(("Notify: watching ended for %s"):format(self.path))
	end)
	return self
end

function Watcher:destroy()
	for f, w in pairs(self.watchers) do
		w:destroy()
	end
	-- stop watching
	self.watching = false
end

function Watcher.new(obj)
	obj = obj or {}
	local self = setmetatable(obj, Watcher)
	self.exclude = self.exclude or {}
	self.watchers = {}
	self.contents = {}
	return self:watch()
end

local exclude = {
	"mmcblk0p1"
}

local Plugin = {}

function Plugin.active()
	return true
end

function Plugin.main()
	Watcher.new {
		path = "/media",
		exclude = exclude,
	}
end

return Plugin
