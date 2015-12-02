local url = require 'socket.url'
local posix = require 'posix'
local pldir = require 'pl.dir'
local plfile = require 'pl.file'
local plpath = require 'pl.path'
local process = require 'cqp.process'
local RAME = require 'rame'

--[[
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

local function scan_file(fn, medias)
	local out = {
		--title = ff_tags.title,
		--duration = tonumber(ff.format.duration),
	}

	local data = ffprobe_file(fn)
	if data == nil then return nil end

	local ff = json.decode(data)
	if ff == nil then return nil end

	local ff_fmt = ff.format
	local ff_tags = ff_fmt.tags or {}

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

	-- TODO field: name
	-- TODO field: shortName
	-- TODO field: mimeType
	-- TODO field: tags[]  (array of tags, multipurpose)
end
--]]

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
	item.meta = {
		["type"] = st["type"],
		id = id,
		parentId = self:path_to_id(dirname),
		targetId = id,
		filename = basename,
		title = basename,
		refreshed = RAME:get_ticket(),
		modified = st.mtime and st.mtime * 1000,
		size = st.size,
	}
	if st["type"] == "regular" and ext and supported_extension[ext] then
		item.uri = filename
	end
end

function FS:refresh_items(id, item)
	if item.items then return end
	item.items = {}
	local path = self:id_to_path(id)
	local data = posix.dir(path)
	table.sort(data)
	for _, f in ipairs(data) do
		if f ~= "." and f ~= ".." then
			table.insert(item.items, self:path_to_id(path..'/'..f))
		end
	end
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
			RAME:hook("set_cursor", "")
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
					item, wrapped = RAME:get_next_item(item.meta.id)
				end
				if not wrapped and item then
					print("USB hot plug, resetting cursor: ", r.items[1])
					RAME:hook("set_cursor", item.meta.id)
				end
			end
		end
	end
end

return Plugin
