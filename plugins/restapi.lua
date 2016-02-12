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
	if ctx.args.delay and RAME.player.status() ~= "stopped" then
		-- apply delay param only when not stopped
		return delayed(function()
			set_cursor(ctx)
		end, ctx.args.delay)
	else
		return set_cursor(ctx)
	end
end

function set_cursor(ctx)
	if RAME.player.status() ~= "stopped" then return 400 end
	local id = ctx.args.id
	local item = Item.find(id)
	if item == nil then return 404 end
	RAME.player.cursor(id)
	return 200
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
		player = #player > 0 and player or nil,
	}
end

-- REST API: /player/
local PLAYER = { GET = {}, POST = {} }

function PLAYER.GET.play(ctx, reply)
	return delayed(function()
		return RAME:action("play") and 200 or 400
	end, ctx.args.delay)
end

function PLAYER.GET.stop(ctx, reply)
	return delayed(function()
		return RAME:action("stop") and 200 or 400
	end, ctx.args.delay)
end

PLAYER.GET["step-forward"] = function(ctx, reply)
	return RAME:action("next", RAME.player.__autoplay) and 200 or 400
end

PLAYER.GET["step-backward"] = function(ctx, reply)
	return RAME:action("prev", RAME.player.__autoplay) and 200 or 400
end

function PLAYER.GET.pause(ctx, reply)
	return delayed(function()
		if not RAME.player.control or not RAME.player.control.pause then return 400 end
		return RAME.player.control.pause() and 200 or 400
	end, ctx.args.delay)
end

function PLAYER.GET.seek(ctx, reply)
	return delayed(function()
		if not RAME.player.control or not RAME.player.control.seek then return 400 end
		local pos = tonumber(ctx.paths[ctx.path_pos])
		if pos == nil then return 500 end
		return RAME.player.control.seek(pos) and 200 or 400
	end, ctx.args.delay)
end

function delayed(func, delay)
	if delay then
		cqueues.running():wrap(function()
			cqueues.sleep(delay)
			func()
		end)
		return 200
	else
		return func()
	end
end

function Plugin.early_init()
	RAME.rest.player = function(ctx, reply) return ctx:route(reply, PLAYER) end
	RAME.rest.cursor = function(ctx, reply) return ctx:route(reply, CURSOR) end
	RAME.rest.lists = function(ctx, reply) return ctx:route(reply, LISTS) end
end

return Plugin
