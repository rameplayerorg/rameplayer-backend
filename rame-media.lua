local json = require 'cjson'
local pldir = require 'pl.dir'
local plfile = require 'pl.file'
local plpath = require 'pl.path'
local process = require 'cqp.process'

-- Media Libaries
local medialib = {}

-- REST API: /lists/
local Lists = {}
function Lists.GET(ctx, reply)
	local r = { lists={} }
	for name, obj in pairs(medialib) do
		table.insert(r.lists, obj)
	end
	reply.headers["Content-Type"] = "application/json"
	return 200, json.encode(r)
end

-- Media scanning
local function ffprobe_file(fn)
	-- reference: https://ffmpeg.org/ffprobe.html
	local out = process.popen(
		"ffprobe",
			"-loglevel", "16",
			"-print_format", "json",
			"-show_entries", "format",
			"-show_chapters",
			fn)
	local res = out:read_all()
	out:close()
	return res
end

local function scan_file(fn, medias)
	local data = ffprobe_file(fn)
	if data == nil then return nil end

	local ff = json.decode(data)
	if ff == nil then return nil end

	local ff_fmt = ff.format
	local ff_tags = ff_fmt.tags or {}

	local out = {
		filename = plpath.basename(fn),
		created = plfile.modified_time(fn) * 1000,
		title = ff_tags.title,
		duration = tonumber(ff.format.duration),
		size = tonumber(ff.format.size),
	}
	table.insert(medias, out)

	-- expand out chapters separately (NB: flattened out to same level for now)
	-- TODO: support making of separate list of chapters
	for chidx, chff in pairs(ff.chapters or {}) do
		print(fn, chidx..": "..chff.tags.title)
		local starttime = tonumber(chff.start_time)
		local endtime = tonumber(chff.end_time)
		local m = {
			filename = out.filename,
			created = out.created,
			title = out.title and (chff.tags.title.." - "..out.title) or chff.tags.title,
			startTime = starttime,
			endTime = endtime,
			duration = endtime - starttime,
			--uri
		}
		table.insert(medias, m)
	end

	-- TODO field: name
	-- TODO field: shortName
	-- TODO field: mimeType
	-- TODO field: tags[]  (array of tags, multipurpose)
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

local function scan_folder(name, path)
	local m = {
		title = name,
		modified = os.time(),
		medias = {},
	}
	local files = pldir.getallfiles(path)
	table.sort(files)
	for _, f in pairs(files) do
		local ext = plpath.extension(f)
		if ext and supported_extension[ext] then
			scan_file(f, m.medias)
		end
	end

	medialib[name] = (#m.medias>0) and m or nil
	print(("%s: scanned %s, %d found"):format(name, path, #m.medias))
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	RAME.rest.lists = function(ctx, reply) return ctx:route(reply, Lists) end
end

function Plugin.media_changed(mountpoint, name)
	print("media_changed", mountpoint, name)
	scan_folder(name, mountpoint)
	if true then
		RAME:hook("set_playlist", medialib[name])
	end
end

return Plugin
