local json = require 'cjson.safe'
local process = require 'cqp.process'
local Item = require 'rame.item'

local Plugin = {}

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

function Plugin.uri_scanner(self)
	RAME.log.info("Scanning", self.uri)

	local data = ffprobe_file(self.uri)
	if data == nil then return false end

	local ff = json.decode(data)
	if ff == nil then return false end

	local ff_fmt = ff.format or {}
	local ff_tags = ff_fmt.tags or {}

	self.duration = tonumber(ff_fmt.duration)
	self.title = ff_tags.title
	self:touch()

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

function Plugin.early_init()
	local schemes = {"http","https","file"}
	local exts = {
		"wav","mp3","flac","aac","m4a","ogg",
		"flv","avi","m4v","mkv","mov","mpg","mpeg","mpe","mp4",
	}
	Item.uri_scanners:register(schemes, exts, 10, Plugin.uri_scanner)
end

return Plugin
