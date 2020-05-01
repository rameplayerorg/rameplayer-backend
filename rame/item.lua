local json = require 'cjson.safe'
local plfile = require 'pl.file'
local tablex = require 'pl.tablex'
local cqueues = require 'cqueues'
local stamp = require 'rame.stamp'
local UrlMatch = require 'rame.urlmatch'
local Queue = require 'rame.queue'

local Item = {
	__scanner = Queue.new(),
	__all_items = setmetatable({}, {__mode='v'}),
	__all_scheduled = setmetatable({}, {__mode='v'}),
	uri_helpers = UrlMatch.new(),
	uri_scanners = UrlMatch.new(),
}
Item.__index = Item

function Item.reschedule()
	RAME.log.debug("Item.reschedule")
end

function Item.scanner()
	while true do
		local item = Item.__scanner:dequeue()
		if not item.nuked then item:scan() end
	end
end

function Item.__eq(a, b)
	return a.type == b.type and a.uri == b.uri and a.id == b.id
end

function Item.__lt(a, b)
	if a.type == "directory" and b.type ~= "directory" then return true end
	if a.type ~= "directory" and b.type == "directory" then return false end
	if a.uri < b.uri then return true end
	if a.uri > b.uri then return false end
	return a.id < b.id
end

function Item:__le(a, b)
	if a.type == "directory" and b.type ~= "directory" then return true end
	if a.type ~= "directory" and b.type == "directory" then return false end
	if a.uri < b.uri then return true end
	if a.uri > b.uri then return false end
	return a.id <= b.id
end

function Item:refresh() end

function Item:expand()
	if type(self.items) == "function" then
		self:items()
	end
end

function Item:refresh_meta()
	if self.scanned or (self.type ~= "regular" and self.type ~= "chapter") then return end
	self.scanned = true
	self.scan = Item.uri_scanners:resolve(self.uri)
	if self.scan then
		Item.__scanner:enqueue(self)
	end
end

function Item:touch(rescan)
	self.refreshed = stamp.next()
	if self.container then self.container:queue_save() end
	if self.parent then
		self.parent.refreshed = self.refreshed
		if self.parent.container then
			self.parent.container:queue_save()
		end
	end
	if self.scheduled or Item.__all_scheduled[self.id] then
		Item.__all_scheduled[self.id] = self.scheduled and self or nil
		Item.reschedule()
	end
	if rescan and self.scanned == true then
		-- Wait for modifications to settle until
		-- re-scanning the file
		self.scanned = "Pending"
		cqueues.running():wrap(function()
			local ref
			repeat
				ref = self.refreshed
				cqueues.poll(4.0)
				if self.nuked then return end
			until ref == self.refreshed
			self.scanned = nil
			self:refresh_meta()
		end)
	end
	return self
end

function Item:add(item)
	if type(self.items) ~= "table" then return end
	if not item then return end
	if item.parent then item.parent:del(item) end
	table.insert(self.items, item)
	if self.shufflePlay then
		self:refresh_shuffle_order()
	end
	self:touch()
	item.parent = self
end

function Item:del(item)
	if type(self.items) ~= "table" then return end
	local idx = tablex.find(self.items, item)
	if idx then
		table.remove(self.items, idx)
		item.parent = nil
		if self.shufflePlay then
			self:refresh_shuffle_order()
		end
		self:touch()
	end
end

function Item:get_first_play_item_id()
	if not self.items or #self.items < 1 then return nil end
	if self.shufflePlay then
		return self.items[self.shuffle_order[1]].id
	end
	return self.items[1].id
end

function Item:refresh_shuffle_order()
	if type(self.items) ~= "table" then return end
	if not self.shufflePlay then return end
	self.shuffle_order = {}
	for a = 1, #self.items do
		self.shuffle_order[a] = a
	end
	for i = #self.shuffle_order, 2, -1 do
		local j = math.random(i)
		self.shuffle_order[i], self.shuffle_order[j] = self.shuffle_order[j], self.shuffle_order[i]
	end
end

function Item:move_after(id)
	local after
	if not self.parent then return end

	local pitems = self.parent.items
	local old_idx = tablex.find(pitems, self)
	if not old_idx then return end

	if id then
		after = Item.find(id)
		if not after or after.parent ~= self.parent then return end
	end

	table.remove(pitems, old_idx)
	table.insert(pitems, (after and tablex.find(pitems, after) or 0) + 1, self)
	self:touch()
end

function Item:unlink(forced)
	if self.pending_save then self:save_playlists() end

	self.nuked = true
	if self.parent then
		self.parent:del(self)
	end
	if self.container then
		self.container.playlists[self.title] = nil
		if not forced then self.container:queue_save() end
	end
	if type(self.items) == "table" then
		for _, child in ipairs(self.items) do
			child.parent = nil
			child:unlink()
		end
	end
	if type(self.playlists) == "table" then
		for _, item in pairs(self.playlists) do
			item.container = nil
			item:unlink()
		end
	end
	Item.__all_items[self.id] = nil
	if Item.__all_scheduled[self.id] then
		Item.__all_scheduled[self.id] = nil
		Item.reschedule()
	end
	if self.on_delete then self.on_delete() end
	if self.watcher then self.watcher:destroy() end
end

function Item:add_playlist(item)
	if item.type ~= "playlist" then return end
	if not self.playlists then return end
	if self.playlists[item.title] then
		self.playlists[item.title]:unlink()
	end
	self.playlists[item.title] = item
	item.container = self
	item:touch()
end

function Item:del_playlist(item)
	if item.type ~= "playlist" then return end
	if not self.playlists then return end
	if self.playlists[item.title] ~= item then return end
	self.playlists[item.title] = nil
	item:touch()
	item.container = nil
end

function Item:load_playlists(lists, save_func)
	self.pending_save = true
	for name, list in pairs(lists) do
		if type(name) == "string" then
			list = {
				title = name,
				items = list,
			}
		end
		local item = Item.new {
			["type"]='playlist',
			id = list.id,
			title = list.title or "unknown",
			["repeat"] = list["repeat"],
			autoPlayNext = list.autoPlayNext,
			shufflePlay = list.shufflePlay or false,
			editable = true,
			scheduled = list.scheduled or false,
			scheduledMonSun = list.scheduledMonSun or { false, false, false, false, false, false, false },
			scheduledTime = item.scheduledTime or 0,
			items = {}
		}
		for _, c in pairs(list.items or {}) do
			item:add(Item.new { id = c.id, title = c.title, uri = c.uri, editable = true })
		end
		if item.shufflePlay then
			item:refresh_shuffle_order()
		end
		self:add_playlist(item)
	end
	self.pending_save = false
	self.playlists_save = save_func
end

function Item:save_playlists()
	if not self.nuked and self.playlists_save then
		local data = setmetatable({}, json.array)
		for name, pitem in pairs(self.playlists) do
			local list = setmetatable({}, json.array)
			for _, item in ipairs(pitem.items) do
				table.insert(list, {
					id = item.id,
					uri = item.uri,
					title = item.title,
				})
			end
			table.insert(data, {
				id = pitem.id,
				title = pitem.title,
				["repeat"] = pitem["repeat"],
				autoPlayNext = pitem.autoPlayNext,
				shufflePlay = pitem.shufflePlay or false,
				scheduled = pitem.scheduled or false,
				scheduledMonSun = pitem.scheduledMonSun or { false, false, false, false, false, false, false },
				scheduledTime = pitem.scheduledTime or 0,
				items = list,
			})
		end
		self:playlists_save(data)
	end
	self.pending_save = nil
end

function Item:queue_save()
	if self.type ~= "device"
	   or not self.playlists or not self.playlistsfile
	   or self.pending_save or not self.playlists_save then
		return
	end
	self.pending_save = true
	cqueues.running():wrap(function()
		cqueues.poll(2)
		if self.pending_save then self:save_playlists() end
	end)
end

function Item:navigate(backwards, with_dirs)
	local wrapped = false
	local parent = self.parent
	if not parent then return self, true end

	local inc = backwards and -1 or 1
	local ndx = tablex.find(parent.items, self)
	if not ndx then return self, true end

	if parent.shufflePlay then
		-- make ndx index in the shuffle instead of actual list order
		ndx = tablex.find(parent.shuffle_order, ndx)
	end

	for i = 1, #parent.items do
		ndx = ndx + inc
		if ndx < 1 then ndx, wrapped = #parent.items, true
		elseif ndx > #parent.items then ndx, wrapped = 1, true end
		if parent.shufflePlay then
			item = parent.items[parent.shuffle_order[ndx]]
		else
			item = parent.items[ndx]
		end
		if with_dirs or (item.uri and (item.type == "regular" or item.type == "chapter")) then
			return item, wrapped
		end
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
	self.id = self.id or stamp.uuid()
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

function Item.search_all(fieldname, value)
	local result = {}
	for k,v in pairs(Item.__all_items) do
		if v and v[fieldname] and v[fieldname] == value then
			table.insert(result, v.id)
		end
	end
	return result
end

return Item
