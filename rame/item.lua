local tablex = require 'pl.tablex'
local stamp = require 'rame.stamp'
local UrlMatch = require 'rame.urlmatch'
local Queue = require 'rame.queue'

local Item = {
	__scanner = Queue.new(),
	__all_items = setmetatable({}, {__mode='v'}),
	uri_helpers = UrlMatch.new(),
	uri_scanners = UrlMatch.new(),
}
Item.__index = Item

function Item.scanner()
	while true do
		local item = Item.__scanner:dequeue()
		item:scan()
	end
end

function Item.__eq(a, b)
	return a.type == b.type and a.uri == b.uri
end

function Item.__lt(a, b)
	if a.type == "directory" and b.type ~= "directory" then return true end
	if a.type ~= "directory" and b.type == "directory" then return false end
	return a.uri < b.uri
end

function Item:__le(a, b)
	if a.type == "directory" and b.type ~= "directory" then return true end
	if a.type ~= "directory" and b.type == "directory" then return false end
	return a.uri <= b.uri
end

function Item:refresh() end

function Item:expand()
	if type(self.items) == "function" then
		self:items()
	end
end

function Item:refresh_meta()
	if self.scanned or self.type ~= "regular" then return end
	self.scanned = true
	self.scan = Item.uri_scanners:resolve(self.uri)
	if self.scan then
		Item.__scanner:enqueue(self)
	end
end

function Item:touch()
	self.refreshed = stamp.next()
	if self.parent then
		self.parent.refreshed = self.refreshed
	end
	return self
end

function Item:add(item)
	if type(self.items) ~= "table" then return end
	if self.items and item then
		table.insert(self.items, item)
		self:touch()
		item.parent = self
	end
end

function Item:del(item)
	if type(self.items) ~= "table" then return end
	local idx = tablex.find(self.items, item)
	if idx then
		table.remove(self.items, idx)
		item.parent = nil
		self:touch()
	end
end

function Item:unlink()
	if self.parent then
		self.parent:del(self)
	end
	if type(self.items) == "table" then
		for _, child in ipairs(self.items) do
			child.parent = nil
			child:unlink()
		end
	end
	Item.__all_items[self.id] = nil
	if self.on_delete then
		self.on_delete()
	end
end

function Item:navigate(backwards)
	local wrapped = false
	local parent = self.parent
	if not parent then return self, true end

	local inc = backwards and -1 or 1
	local ndx = tablex.find(parent.items, self)
	if not ndx then return self, true end

	for i = 1, #parent.items do
		ndx = ndx + inc
		if ndx < 1 then ndx, wrapped = #parent.items, true
		elseif ndx > #parent.items then ndx, wrapped = 1, true end
		item = parent.items[ndx]
		if item.uri then return item, wrapped end
	end

	return self, true
end

function Item.new(obj)
	obj = obj or {}
	local self = setmetatable(obj, Item)
	if obj.uri then
		local helper = Item.uri_helpers:resolve(obj.uri)
		if helper then helper(obj) end
	end
	if self.items then
		if type(self.items) == "table" then
			for _, child in ipairs(self.items) do
				child.parent = self
			end
		end
		self.type = self.type or "directory"
	else
		self.type = self.type or "regular"
	end
	self.id = self.id or tostring(stamp.next()) --fixme
	Item.__all_items[self.id] = self
	return self:touch()
end

function Item.new_list(obj)
	obj.items = obj.items or {}
	return Item.new(obj)
end

function Item.find(id)
	if type(id) ~= "string" then return nil end
	local item = Item.__all_items[id]
	if item then item:refresh() end
	return item
end

return Item
