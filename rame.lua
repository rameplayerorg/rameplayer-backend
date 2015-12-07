local json = require 'cjson.safe'
local tablex = require 'pl.tablex'
local push = require 'cqp.push'
local condition = require 'cqueues.condition'

local RAME = {
	version = "undefined",
	running = true,
	start_time = os.time(),
	next_ticket = 1,
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
	scanner = {
		queue = {},
		cond  = condition.new(),
	},
	lists = {},
	rest = {},
	plugins = {},

	alsa_support = false,
	omxplayer_audio_out = "hdmi",
	path_rpi_config = "/media/mmcblk0p1/usercfg.txt",
	path_settings_system = "/media/mmcblk0p1/settings-system.json",
	path_settings_user = "/media/mmcblk0p1/settings-user.json",
}

function RAME:get_ticket()
	local ticket = self.next_ticket
	self.next_ticket = ticket + 1
	return ("%d.%d"):format(RAME.start_time, ticket)
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

function RAME:scanner_thread()
	while true do
		if self.scanner.queue.head then
			-- Dequeue item
			local item = self.scanner.queue.head
			if self.scanner.queue[item] then
				self.scanner.queue.head = self.scanner.queue[item]
			else
				self.scanner.queue.head = nil
				self.scanner.queue.tail = nil
			end
			-- Run the scan hook
			local space = item.space
			if space:scan_item(item) then
				local stamp = self:get_ticket()
				item.meta.refreshed = stamp
				local parent = self:get_item(item.parentId)
				if parent then
					parent.meta.refreshed = stamp
				end
			end
		else
			self.scanner.cond:wait()
		end
	end
end

function RAME:get_item(id, refresh_items, scan_item)
	if id == nil then return nil end

	local space_id, item_id = RAME:split_id(id)
	local space = self.lists[space_id]
	if space == nil then return nil end

	local item = space.items[item_id] or { space = space }
	if space.refresh_meta then space:refresh_meta(id, item) end
	if item.meta == nil then return nil end
	if scan_item and not item.scanned and space.scan_item then
		item.scanned = true
		-- Queue for scanning
		if self.scanner.queue.tail then
			self.scanner.queue[self.scanner.queue.tail] = item
		else
			self.scanner.queue.head = item
		end
		self.scanner.queue.tail = item
		self.scanner.cond:signal()
	end
	if refresh_items and space.refresh_items then space:refresh_items(id, item) end
	space.items[item_id] = item

	return item
end

function RAME:get_next_item(id)
	local wrapped = false
	local item = self:get_item(id)
	local parent = self:get_item(item.parentId)
	if parent == nil then return item, true end
	local ndx = tablex.find(parent.items, id)
	repeat
		ndx = ndx + 1
		if ndx > #parent.items then ndx, wrapped = 1, true end
		print("NEXT", id, ndx, parent.items[ndx])
		item = self:get_item(parent.items[ndx])
	until wrapped or item.uri

	return item, wrapped
end

-- REST API: /lists/ID
function RAME.rest.lists(ctx, reply)
	if ctx.method ~= "GET" then return 405 end

	local id = ctx.paths[ctx.path_pos]
	local list = RAME:get_item(id, true, true)
	if list == nil then return 404 end
	if list.items == nil then return 400 end

	local r = {
		id = id,
		info = list.meta,
		items = { },
	}

	for node_id, target_id in pairs(list.items) do
		local child = RAME:get_item(target_id, false, true)
		if child and child.meta then
			table.insert(r.items, {
				id = target_id, --("%s:%s"):format(id, node_id),
				targetId = child.items and target_id,
				info = child.meta
			})
		end
	end

	return 200, r
end

-- REST API: /status/
function RAME.rest.status(ctx, reply)
	if ctx.method ~= "GET" and ctx.method ~= "POST" then return 405 end

	local lists = nil
	if ctx.args.lists then
		lists = {}
		for _, list_id in pairs(ctx.args.lists) do
			local list = RAME:get_item(list_id)
			if list then
				lists[list_id] = list.meta.refreshed
			end
		end
	end

	local item = RAME:get_item(RAME.player.cursor())
	return 200, {
		listsRefreshed = lists,
		state = RAME.player.status(),
		position = RAME.player.position(),
		duration = RAME.player.duration(),
		cursor = {
			id = item and item.id,
			parentId = item and item.parentId,
		},
	}
end

-- REST API: /cursor/
function RAME.rest.cursor(ctx, reply)
	if ctx.method ~= "PUT" then return 405 end
	local id = ctx.args.id
	local item = RAME:get_item(id)
	if item == nil then return 404 end
	RAME:hook("set_cursor", id)
	return 200
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

function RAME.main()
	RAME:scanner_thread()
end

return RAME
