local tablex = require 'pl.tablex'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local plpath = require 'pl.path'
local posix = require 'posix'
local json = require 'cjson.safe'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local Plugin = {}

Plugin.cluster_cond = condition.new()

-- REST API: /lists/ID
local function rest_info(item)
	return {
		["type"] = item.type,
		["repeat"] = item["repeat"],
		id = item.id,
		duration = item.duration,
		editable = item.editable,
		modified = item.modified,
		name = item.filename or item.uri,
		chapterId = item.chapter_id,
		chapterParentId = item.chapter_parent_id,
		chapters = item.chapters,
		refreshed = item.refreshed,
		size = item.size,
		title = item.title,
		width = item.width,
		height = item.height,
		uri = item.uri,
		autoPlayNext = item.autoPlayNext,
		shufflePlay = item.shufflePlay or false,
		scheduled = item.scheduled or false,
		scheduledMonSun = item.scheduledMonSun or { false, false, false, false, false, false, false },
		scheduledTime = item.scheduledTime or 0,
		storage = item.container and item.container.id,
		saferemove = item.saferemove,
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
		local storage
		if ctx.args.storage then
			-- root item id to store the playlist in
			storage = Item.find(ctx.args.storage)
			if storage == nil then return 404 end
			if not storage.playlists then return 405 end
		end
		item = Item.new {
			["type"]='playlist',
			title = ctx.args.title,
			editable = true,
			["repeat"] = ctx.args["repeat"],
			autoPlayNext = ctx.args.autoPlayNext,
			shufflePlay = ctx.args.shufflePlay or false,
			scheduled = ctx.args.scheduled or false,
			scheduledMonSun = ctx.args.scheduledMonSun or { false, false, false, false, false, false, false },
			scheduledTime = ctx.args.scheduledTime or 0,
			items = {}
		}
		for _, c in pairs(ctx.args.items) do
			item:add(Item.new { title = c.title, uri = c.uri, editable = true })
		end
		if storage then storage:add_playlist(item) end
		RAME.root:add(item)
	elseif #ctx.paths == ctx.path_pos+1 and ctx.paths[ctx.path_pos+1] == "items" then
		-- POST /lists/ID/items -- add new item(s)
		local id = ctx.paths[ctx.path_pos]
		local list = Item.find(id)
		if list == nil then return 404 end
		if not (list.editable and list.items) then return 405 end

		local argItems = ctx.args
		if argItems[1] == nil then argItems = { argItems } end

		for _, argItem in ipairs(argItems) do
			if argItem == nil then return 400 end

			item = Item.new { title = argItem.title, uri = argItem.uri, editable = true }
			if not item then return 400 end
			list:add(item)

			local afterId = argItem.afterId
			if afterId == json.null then
				item:move_after(nil)
			elseif type(afterId) == "string" then
				item:move_after(afterId)
			end
		end
	else
		return 404
	end

	return 200, rest_info(item)
end

function LISTS.PUT(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id)
	if item == nil then return 404 end
	if item.type ~= "playlist" or not item.editable then return 405 end

	if #ctx.paths == ctx.path_pos then
		-- PUT /lists/ID -- Edit list
		local storage
		if ctx.args.storage then
			-- root item id to store the playlist in
			storage = Item.find(ctx.args.storage)
			if storage == nil then return 404 end
			if not storage.playlists then return 405 end
		end
		item["repeat"] = ctx.args["repeat"]
		item.autoPlayNext = ctx.args.autoPlayNext
		item.shufflePlay = ctx.args.shufflePlay or false
		item.scheduled = ctx.args.scheduled or false
		item.scheduledMonSun = ctx.args.scheduledMonSun or { false, false, false, false, false, false, false }
		item.scheduledTime = ctx.args.scheduledTime
		if item.title ~= ctx.args.title or item.container ~= storage then
			if item.container then item.container:del_playlist(item) end
			item.title = ctx.args.title
			if storage then storage:add_playlist(item) end
		else
			item:touch()
		end
	elseif #ctx.paths == ctx.path_pos+2 and ctx.paths[ctx.path_pos+1] == "items" then
		-- PUT /lists/listID/items/itemID -- Edit list item (move)
		local cid = ctx.paths[ctx.path_pos+2]
		local child = Item.find(cid)
		if child == nil then return 404 end
		if not child.editable then return 405 end
		local afterId = ctx.args.afterId
		if afterId == json.null then
			afterId = nil
		elseif type(afterId) ~= "string" then
			return 404
		end
		child:move_after(afterId)
		item = child
	else
		return 404
	end
	return 200, rest_info(item)
end

function LISTS.DELETE(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id)
	if item == nil then return 404 end
	if not item.editable then return 405 end

	-- DELETE /lists/targetID -- Delete list
	if #ctx.paths == ctx.path_pos then
		item:unlink()
	elseif #ctx.paths == ctx.path_pos+1 and ctx.paths[ctx.path_pos+1] == "items" then
		if not item.items then return 405 end
		while item.items[1] do
			item.items[1]:unlink()
		end
		item:touch()
	elseif #ctx.paths == ctx.path_pos+2 then
		local id = ctx.paths[ctx.path_pos+2]
		local pitem = Item.find(id)
		if pitem == nil or not tablex.find(item.items, pitem) then return 404 end
		if not pitem.editable then return 405 end
		pitem:unlink()
		item:touch()
	else
		return 404
	end

	return 200, {}
end

-- REST API: /cursor/
local CURSOR = {}

function CURSOR.PUT(ctx, reply)
	return RAME:action("set_cursor", ctx.args.id)
end

-- REST API: /disk/
local DISK = { PUT = {} }

-- used while recording:
local last_disk_space_time = 0
local last_disk_space = nil

-- REST API: /disk/status/
function DISK.PUT.status(ctx, reply)
	local dirname = plpath.dirname(ctx.args.path)
	local fstat = posix.stat(ctx.args.path)
	local dstat = posix.stat(dirname)
	local space = nil
	local statusline = nil
	local warn = nil
	local err = nil
	if RAME.recorder.enabled() then
		if RAME.recorder.running() then
			-- check disk space less often (while recording)
			local time = cqueues.monotime()
			if time > last_disk_space_time + 15 or last_disk_space == nil then
				last_disk_space_time = time
				last_disk_space = RAME.get_disk_space(dirname)
			end
			space = last_disk_space
		else
			space = RAME.get_disk_space(dirname)
		end
		statusline = RAME.recorder.last_statusline
		warn = RAME.recorder.last_warning
		err = RAME.recorder.last_error
	end
	return 200, {
		space=space,
		file=fstat,
		dir=dstat,
		info=statusline,
		warn=warn,
		error=err,
	}
end

-- REST API: /disk/umount/
function DISK.PUT.umount(ctx, reply)
	--local devname = "/dev/"..ctx.args.dev
	print("/disk/umount", ctx.args.dev)
	local res = RAME.plugins["automount.lua"].umount(ctx.args.dev)
	if res == nil then
		return 200, {}
	else
		return 500, { error = res }
	end
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

	if ctx.args.cluster then
		-- Start timer for auto clearing cluster controller status
		RAME.cluster.controllers[ctx.ip] = cqueues.monotime()
		Plugin.cluster_cond:signal()
	end

	local item = Item.find(RAME.player.cursor())

	local player = {
		rebootRequired = RAME.system.reboot_required() and true or nil,
		updateAvailable = RAME.system.update_available() and true or nil,
		upgradeProgress = RAME.system.firmware_upgrade(),
	}

	local recorder = {
		enabled = RAME.recorder.enabled() and true or nil,
		running = RAME.recorder.running() and true or nil,
		streaming = RAME.recorder.streaming() and true or nil,
		recording = RAME.recorder.recording() and true or nil,
	}

	local response = {
		listsRefreshed = lists,
		state = RAME.player.status(),
		position = RAME.player.position(),
		duration = RAME.player.duration(),
		["repeat"] = (RAME.player.command() == "repeatplay") and -1 or nil,
		cursor = {
			id = item and item.id,
			name = item and (item.filename or item.uri),
			parentId = item and item.parent and item.parent.id,
		},
		player = next(player) and player,
		recorder = next(recorder) and recorder,
	}
	if next(RAME.cluster.controllers) then
		local controllers = setmetatable({}, json.array)
		for ip, last_seen in pairs(RAME.cluster.controllers) do
			table.insert(controllers, ip)
		end
		table.sort(controllers)

		response.cluster = {
			controller = controllers,
		}
	end

	return 200, response
end

-- REST API: /player/
local PLAYER = { GET = {}, POST = {} }

function PLAYER.GET.play(ctx, reply)
	local cmd = "play"
	if ctx.args.id then
		RAME:action("set_cursor", ctx.args.id)
	end
	if tonumber(ctx.args["repeat"]) == -1 then
		cmd = "repeatplay"
	end
	return RAME:action(cmd, nil, tonumber(ctx.args.pos))
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
	RAME.rest.disk = function(ctx, reply) return ctx:route(reply, DISK) end
end

function Plugin.main()
	local timeout = nil
	while true do
		cqueues.poll(Plugin.cluster_cond, timeout)
		timeout = nil
		local items = {}
		local now = cqueues.monotime()
		for ip, last_seen in pairs(RAME.cluster.controllers) do
			local expires = last_seen + 3
			if now >= expires then
				RAME.log.info("Removing controller " .. ip)
				RAME.cluster.controllers[ip] = nil
			else
				table.insert(items, ip)
				if timeout == nil or timeout > expires - now then
					timeout = expires - now
				end
			end
		end
		if #items > 0 then
			table.sort(items)
			RAME.cluster.controller(table.concat(items, ","))
		else
			RAME.cluster.controller(false)
		end
	end
end

return Plugin
