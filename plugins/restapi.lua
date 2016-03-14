local cqueues = require 'cqueues'
local json = require 'cjson.safe'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local Plugin = {}

-- REST API: /lists/ID
local function rest_info(item)
	return {
		["type"] = item.type,
		id = item.id,
		duration = item.duration,
		editable = item.editable,
		modified = item.modified,
		name = item.filename or item.uri,
		refreshed = item.refreshed,
		size = item.size,
		title = item.title,
		uri = item.uri,
	}
end

local LISTS = {}

function LISTS.GET(ctx, reply)
	-- GET /lists/ID
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id, true, true)
	if item == nil then return 404 end
	if item.items == nil then return 400 end

	item:expand()

	local r = rest_info(item)
	r.items = setmetatable({}, json.array)
	for _, child in pairs(item.items) do
		child:refresh_meta()
		table.insert(r.items, rest_info(child))
	end

	return 200, r
end

function LISTS.POST(ctx, reply)
	local item
	if #ctx.paths == ctx.path_pos-1 then
		-- POST /lists/ -- add new list
		item = Item.new{["type"]='playlist', title = ctx.args.title, editable = true, items = {}}
		for _, c in pairs(ctx.args.items) do
			item:add(Item.new{title = c.title, uri = c.uri})
		end
		RAME.root:add(item)
	elseif #ctx.paths == ctx.path_pos+1 and ctx.paths[ctx.path_pos+1] == "items" then
		-- POST /lists/ID/items -- add new item
		local id = ctx.paths[ctx.path_pos]
		local list = Item.find(id)
		if list == nil then return 404 end
		if not (list.editable and list.items) then return 405 end
		if ctx.args.uri == nil then return 400 end

		item = Item.new { title = ctx.args.title, uri = ctx.args.uri, editable = true }
		if not item then return 400 end
		list:add(item)
	else
		return 404
	end

	return 200, rest_info(item)
end

function LISTS.PUT(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id)
	if item == nil then return 404 end
	if not item.editable then return 405 end

	if #ctx.paths == ctx.path_pos+2 and ctx.paths[ctx.path_pos+1] == "items" then
		local cid = ctx.paths[ctx.path_pos+2]
		local child = Item.find(cid)
		if child == nil then return 404 end
		if not child.editable then return 405 end
		child:move_after(ctx.args.afterId)
		return 200
	end

	return 404
end

function LISTS.DELETE(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id)
	if item == nil then return 404 end
	if not item.editable then return 405 end

	if #ctx.paths == ctx.path_pos then
		item:unlink()
	elseif #ctx.paths == ctx.path_pos+1 and ctx.paths[ctx.path_pos+1] == "items" then
		if not item.items then return 405 end
		while item.items[1] do
			item.items[1]:unlink()
		end
	elseif #ctx.paths == ctx.path_pos+2 then
		local id = ctx.paths[ctx.path_pos+2]
		local item = Item.find(id)
		if item == nil then return 404 end
		if not item.editable then return 405 end
		item:unlink()
	else
		return 404
	end

	return 200
end

-- REST API: /cursor/
local CURSOR = {}

function CURSOR.PUT(ctx, reply)
	return RAME:action("set_cursor", ctx.args.id)
end

-- REST API: /status/
function RAME.rest.status(ctx, reply)
	if ctx.method ~= "GET" and ctx.method ~= "POST" then return 405 end

	local lists = nil
	if ctx.args.lists then
		lists = setmetatable({}, json.object)
		for _, list_id in pairs(ctx.args.lists) do
			local list = Item.find(list_id)
			lists[list_id] = list and list.refreshed
		end
	end

	local item = Item.find(RAME.player.cursor())

	local player = {
		rebootRequired = RAME.system.reboot_required() and true or nil,
		updateAvailable = RAME.system.update_available() and true or nil,
		upgradeProgress = RAME.system.firmware_upgrade(),
	}

	return 200, {
		listsRefreshed = lists,
		state = RAME.player.status(),
		position = RAME.player.position(),
		duration = RAME.player.duration(),
		cursor = {
			id = item and item.id,
			name = item and (item.filename or item.uri),
			parentId = item and item.parent and item.parent.id,
		},
		player = next(player) and player,
	}
end

-- REST API: /player/
local PLAYER = { GET = {}, POST = {} }

function PLAYER.GET.play(ctx, reply)
	if ctx.args.id then
		RAME:action("set_cursor", ctx.args.id)
	end
	return RAME:action("play", nil, tonumber(ctx.args.pos))
end

function PLAYER.GET.stop(ctx, reply)
	return RAME:action("stop")
end

PLAYER.GET["step-forward"] = function(ctx, reply)
	return RAME:action("next")
end

PLAYER.GET["step-backward"] = function(ctx, reply)
	return RAME:action("prev")
end

function PLAYER.GET.pause(ctx, reply)
	return RAME:action("pause")
end

function PLAYER.GET.seek(ctx, reply)
	local pos = tonumber(ctx.paths[ctx.path_pos])
	if pos == nil then return 500 end
	return RAME:action("seek", nil, pos)
end

function Plugin.early_init()
	RAME.rest.player = function(ctx, reply) return ctx:route(reply, PLAYER) end
	RAME.rest.cursor = function(ctx, reply) return ctx:route(reply, CURSOR) end
	RAME.rest.lists = function(ctx, reply) return ctx:route(reply, LISTS) end
end

return Plugin
