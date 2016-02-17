local posix = require 'posix'
local plpath = require 'pl.path'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local Plugin = {}

function Plugin.expand(self)
	local path = self.uri:gsub("^file://", "")
	local items = {}
	for file in posix.files(path) do
		if file:sub(1, 1) ~= "." then
			local i = Item.new { uri = self.uri .. file }
			if i.type == "directory" or RAME.players:resolve(i.uri) then
				i.parent = self
				table.insert(items, i)
			end
		end
	end
	table.sort(items)

	self.items = items
	self:touch()
end

function Plugin.uri_helper(self)
	local path = self.uri:gsub("^file://", "")
	local st = posix.stat(path)
	if not st then return end

	self.type = self.type or st.type
	self.modified = st.mtime and st.mtime * 1000
	self.filename = plpath.basename(path)
	self.size = st.size
	if st.type == "directory" and not self.items then
		if self.uri:sub(-1) ~= "/" then
			self.uri = self.uri.."/"
		end
		self.items = Plugin.expand
	end
end

function Plugin.early_init()
	Item.uri_helpers:register("file", nil, 10, Plugin.uri_helper)
end

return Plugin
