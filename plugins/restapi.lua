local json = require 'cjson.safe'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local Plugin = {}

-- REST API: /lists/ID
local function rest_info(item)
	return {
		id = item.id,
		targetId = item.items and item.id,
		info = {
			["type"] = item.type,
			editable = item.editable,
			duration = item.duration,
			filename = item.filename,
			id = item.id,
			modified = item.modified,
			refreshed = item.refreshed,
			size = item.size,
			title = item.title,
		}
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
	local id = ctx.paths[ctx.path_pos]

	if ctx.paths[ctx.path_pos+1] == "items" then
		-- POST /lists/ID/items -- add new item
		local list = Item.find(id)
		if list == nil then return 404 end
		if not list.editable then return 405 end
		if list.add == nil then return 400 end

		-- add existing item: {"id": "sda1:%2fSampleVideo_640x360_2mb_2%2emp4"}
		-- add streamed item: {"info": {"title": "My Live Stream", "uri": "http://www.example.com/stream.mp4"}}
		local item = ctx.args.info
		if ctx.args.id then
			item = Item.find(ctx.args.id)
		end
		if item == nil or item.uri == nil then return 400 end
		item = Item.new { title = item.title, uri = item.uri }
		list:add(item)
		return item and 200 or 400, r
	end

	return 404
end

-- REST API: /cursor/
local CURSOR = {}

function CURSOR.PUT(ctx, reply)
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
			parentId = item and item.parent and item.parent.id,
		},
		player = #player > 0 and player or nil,
	}
end

-- REST API: /player/
local PLAYER = { GET = {}, POST = {} }

function PLAYER.GET.play(ctx, reply)
	return RAME:action("play") and 200 or 400
end

function PLAYER.GET.stop(ctx, reply)
	return RAME:action("stop") and 200 or 400
end

PLAYER.GET["step-forward"] = function(ctx, reply)
	return RAME:action("next", RAME.player.__autoplay) and 200 or 400
end

PLAYER.GET["step-backward"] = function(ctx, reply)
	return RAME:action("prev", RAME.player.__autoplay) and 200 or 400
end

function PLAYER.GET.pause(ctx, reply)
	if not RAME.player.control or not RAME.player.control.pause then return 400 end
	return RAME.player.control.pause() and 200 or 400
end

function PLAYER.GET.seek(ctx, reply)
	if not RAME.player.control or not RAME.player.control.seek then return 400 end
	local pos = tonumber(ctx.paths[ctx.path_pos])
	if pos == nil then return 500 end
	return RAME.player.control.seek() and 200 or 400
end

function Plugin.early_init()
	RAME.rest.player = function(ctx, reply) return ctx:route(reply, PLAYER) end
	RAME.rest.cursor = function(ctx, reply) return ctx:route(reply, CURSOR) end
	RAME.rest.lists = function(ctx, reply) return ctx:route(reply, LISTS) end
end

return Plugin
