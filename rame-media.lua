local url = require 'socket.url'
local json = require 'cjson.safe'
local posix = require 'posix'
local pldir = require 'pl.dir'
local plfile = require 'pl.file'
local plpath = require 'pl.path'
local process = require 'cqp.process'
local RAME = require 'rame'

-- Media scanning
local function ffprobe_file(fn)
	-- reference: https://ffmpeg.org/ffprobe.html
	local out = process.popen(
		"ffprobe",
			"-probesize", "1000",
			"-print_format", "json",
			"-show_entries", "format",
			"-show_chapters",
			fn)
	local res = out:read_all()
	out:close()
	return res
end

local supported_extension = {
	--[[
	-- Image formats
	jpg = true, jpeg = true, png = true,
	-- Audio formats
	wav = true, mp3 = true, flac = true, aac = true,
	m4a = true, ogg = true,
	--]]
	-- Video formats
	[".avi"] = true, [".m4v"] = true, [".mkv"] = true,
	[".mov"] = true, [".mpg"] = true, [".mpeg"] = true,
	[".mpe"] = true, [".mp4"] = true,
}

local FS = {}
FS.__index = FS

function FS:id_to_path(id)
	local space_id, item_id = RAME:split_id(id)
	local path = url.unescape(item_id)
	if path:match("/../") then return nil end
	return self.root..path
end

function FS:path_to_id(path)
	if path:sub(1, #self.root) ~= self.root then return nil end
	if path:match("/../") then return nil end
	return self.spaceId..':'..url.escape(path:sub(#self.root+1))
end

function FS:refresh_meta(id, item)
	if item.meta then return end
	local filename = self:id_to_path(id)
	local dirname  = plpath.dirname(filename)
	local basename = plpath.basename(filename)
	local ext      = plpath.extension(filename)
	local st = posix.stat(filename)
	if st == nil then return end

	item.id = id
	item.parentId = self:path_to_id(dirname)
	item.targetId = id
	item.meta = {
		["type"] = st.type,
		filename = basename,
		refreshed = RAME:get_ticket(),
		modified = st.mtime and st.mtime * 1000,
		size = st.size,
	}
	if st.type == "regular" and supported_extension[ext or ""] then
		item.uri = filename
	elseif st.type == "directory" then
		if id == self.rootId then
			item.parentId = 'root'
			item.meta.title = ("%s root"):format(basename)
		end
		item.items = true
	end
end

function FS:refresh_items(id, item)
	if type(item.items) == "table" then return end
	if item.meta.type ~= "directory" then return end

	local path = self:id_to_path(id)
	local items, i = {}, nil
	for file in posix.files(path) do
		if file:sub(1, 1) ~= "." then
			i = RAME:get_item(self:path_to_id(path..'/'..file))
			if i.uri or i.items then
				table.insert(items, i)
			end
		end
	end

	table.sort(items, function(a,b)
		if a.meta.type == "directory" and b.meta.type ~= "directory" then return true end
		if a.meta.type ~= "directory" and b.meta.type == "directory" then return false end
		return a.meta.filename < b.meta.filename
	end)

	item.items = {}
	for _, i in ipairs(items) do
		table.insert(item.items, i.id)
	end
end

function FS:scan_item(item)
	if not item.uri then return false end

	local data = ffprobe_file(item.uri)
	if data == nil then return false end

	local ff = json.decode(data)
	if ff == nil then return false end

	local ff_fmt = ff.format or {}
	local ff_tags = ff_fmt.tags or {}

	item.meta.duration = tonumber(ff_fmt.duration)
	item.meta.title = ff_tags.title
	return true

--[[
	-- expand out chapters separately (NB: flattened out to same level for now)
	-- TODO: support making of separate list of chapters
	for chidx, chff in pairs(ff.chapters or {}) do
		print(fn, chidx..": "..chff.tags.title)
		local starttime = tonumber(chff.start_time)
		local endtime = tonumber(chff.end_time)
		local m = {
			uri = out.uri,
			filename = out.filename,
			created = out.created,
			title = out.title and (chff.tags.title.." - "..out.title) or chff.tags.title,
			startTime = starttime,
			endTime = endtime,
			duration = endtime - starttime,
		}
		table.insert(medias, m)
	end
--]]
end

function FS.new_mapping(id, folder)
	local space = setmetatable({ spaceId = id, root = folder, items = {} }, FS)
	space.rootId = space:path_to_id(space.root)
	return space
end

-- Plugin Hooks
local Plugin = {}

function Plugin.media_changed(id, mountpoint, mounted)
	print("media_changed", id, mountpoint, mounted)
	if RAME.lists[id] then
		RAME.root:del(RAME.lists[id].rootId)
		RAME.lists[id] = nil
		print(id, RAME:split_id(RAME.player.cursor()))
		if RAME:split_id(RAME.player.cursor()) == id then
			RAME:hook("set_cursor", "stop")
		end
	end
	if mounted then
		local space = FS.new_mapping(id, mountpoint)
		RAME.lists[id] = space
		RAME.root:add(space.rootId)
		print("Adding to root", space.rootId)
		if RAME.player.status() == "stopped" then
			local r = RAME:get_item(space.rootId, true)
			if r and r.items and #r.items then
				local item, wrapped = RAME:get_item(r.items[1]), false
				if not item.uri then
					item, wrapped = RAME:get_next_item(item.id)
				end
				if not wrapped and item then
					print("USB hot plug, resetting cursor: ", r.items[1])
					RAME:hook("set_cursor", item.id)
				end
			end
		end
	end
end

return Plugin
