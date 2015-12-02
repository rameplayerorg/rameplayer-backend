local json = require 'cjson.safe'
local tablex = require 'pl.tablex'
local push = require 'cqp.push'

local RAME = {
	running = true,
	next_ticket = os.time(),
	config = {
		settings_path = "/media/mmcblk0p1/",
	},
	system = {
		ip = push.property("", "Current IP-address"),
	},
	player = {
		status   = push.property("stopped", "Playback status"),
		position = push.property(0, "Active media play position"),
		duration = push.property(0, "Active media duration"),
		cursor   = push.property("", "Active media"),
	},
	lists = {},
	rest = {},
	plugins = {},
}

function RAME:get_ticket()
	local ticket = self.next_ticket
	self.next_ticket = ticket + 1
	return ticket
end

function RAME:hook(hook, ...)
	for _, p in pairs(self.plugins) do
		local f = p[hook]
		if f then f(...) end
	end
end

function RAME:split_id(id)
	local space_id, item_id = id:match("^([^:]+):(.*)$")
	if space_id == nil then space_id, item_id = id, "" end
	return space_id, item_id
end

function RAME:get_item(id, refresh_items)
	if id == nil then return nil end

	local space_id, item_id = RAME:split_id(id)
	local space = self.lists[space_id]
	if space == nil then return nil end

	local item = space.items[item_id] or {}
	if space.refresh_meta then space:refresh_meta(id, item) end
	if item.meta == nil then return nil end
	if refresh_items and space.refresh_items then space:refresh_items(id, item) end
	space.items[item_id] = item

	return item
end

function RAME:get_next_item_id(id)
	local wrapped = false
	local item = self:get_item(id)
	local parent = self:get_item(item.meta.parentId)
	if parent == nil then return id, true end

	local ndx = tablex.find(parent.items, id) + 1
	if ndx > #parent.items then ndx, wrapped = 1, true end
	print("NEXT", id, ndx, parent.items[ndx])
	return parent.items[ndx], wrapped
end

-- REST API: /lists/ID
function RAME.rest.lists(ctx, reply)
	if ctx.method ~= "GET" then return 405 end

	local id = ctx.paths[ctx.path_pos]
	local list = RAME:get_item(id, true)
	if list == nil then return 404 end
	if list.items == nil then return 400 end

	-- Deep copy meta data
	local r = { }
	for key, val in pairs(list.meta) do
		r[key] = val
	end
	-- Populate child items
	local items = { }
	for _, child_id in ipairs(list.items) do
		local child = RAME:get_item(child_id)
		if child and child.meta then
			table.insert(items, child.meta)
		end
	end
	r.items = items

	reply.headers["Content-Type"] = "application/json"
	return 200, json.encode(r)
end

-- REST API: /status/
function RAME.rest.status(ctx, reply)
	if ctx.method ~= "GET" then return 405 end
	reply.headers["Content-Type"] = "application/json"

	--[[
	local lists = {}
	for name, list in pairs(RAME.lists) do
		table.insert(lists, {id = list.id, modified = list.meta.refreshed})
	end
	--]]

	return 200, json.encode {
		state = RAME.player.status(),
		position = RAME.player.position(),
		duration = RAME.player.duration(),
		cursor = {
			id = RAME.player.cursor(),
		},
	}
end

local List = {}
List.__index = List
function List:touch() self.meta.refreshed = RAME:get_ticket() end
function List:add(item)
	table.insert(self.items, item)
	self:touch()
end
function List:del(item)
	local idx = tablex.find(self.items, item)
	if idx then
		table.remove(self.items, idx)
		self:touch()
	end
end
function List.new(id, title)
	return setmetatable({
		meta = {
			id = id,
			title = title,
			editable = false,
			refreshed = RAME:get_ticket(),
		},
		items = { },
	}, List)
end

local function ListMapping(list)
	return { items = { [""] = list } }
end

RAME.root = List.new('root', 'Root')
RAME.lists.root = ListMapping(RAME.root)

return RAME
