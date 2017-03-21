local json = require 'cjson.safe'
local process = require 'cqp.process'
local RAME = require 'rame.rame'
local Item = require 'rame.item'
local url = require 'socket.url'

local Plugin = {}

-- Media scanning
local function ffprobe_file(fn)
	-- reference: https://ffmpeg.org/ffprobe.html
	if not fn then return nil end
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
	local extract_chapters = true
	local only_chapter_id = nil

	if self.parent and self.parent.editable then
		-- item added to editable playlist, chapter items shouldn't be extracted
		extract_chapters = false
	end

	local fn,chapter_id = RAME.resolve_uri(self.uri)

	if chapter_id ~= nil then
		-- Chapter videos (#id= fragment) are expected to be ffprobed only when
		-- added to a playlist, in which case it's assumed the original entry
		-- is already available (extracted when main video was ffprobed).
		-- We find that first & copy the data, and only continue to actual
		-- ffprobe if the original was not found for some reason.
		local matching_fn_items = Item.search_all("filename", self.filename)
		for _,id in ipairs(matching_fn_items) do
			local i = Item.find(id)
			if i and i.parent and not i.parent.editable and i.starttime and i.endtime then
				-- found "original" chapter entry, pick the already extracted metadata
				-- (no need to re-ffprobe it)
				self.type = "chapter"
				self.title = i.title
				self.starttime = i.starttime
				self.endtime = i.endtime
				self.duration = i.duration
				self:touch()
				return
			end
		end
		-- didn't find the "original", flag this chapter id to be searched for in ffprobe below
		only_chapter_id = chapter_id
	end

	local data = ffprobe_file(fn)
	if data == nil then return false end

	local ff = json.decode(data)
	if ff == nil then return false end

	local ff_fmt = ff.format or {}
	local ff_tags = ff_fmt.tags or {}

	self.duration = tonumber(ff_fmt.duration)
	self.title = ff_tags.title
	if ff.chapters and #ff.chapters > 0 then self.chapter_count = #ff.chapters end	

	local ch_item_pos_id = self.id

	-- read through chapter info
	-- (possible TODO: support making of separate folder of chapters?)
	for _, chff in pairs(ff.chapters or {}) do
		local start_t = tonumber(chff.start_time)
		local end_t = tonumber(chff.end_time)
		local chid = tostring(chff.id)
		if extract_chapters then
			-- extract chapter as a new list item
			local i = Item.new {
				type = "chapter",
				title = "#"..chid..": "..chff.tags.title, -- prefix chapter title with chapter index
				parent = self.parent,
				chapter_parent_id = self.id,
				filename = self.filename.." #"..chid, -- postfix filename with chapter index info
				uri = self.uri.."#id="..chid, -- add fragment id to uri containing chapter index
				starttime = start_t,
				endtime = end_t,
				duration = end_t - start_t,
				scanned = true
			}
			-- for now, chapter items are added flat to same level after original whole media item:
			self.parent:add(i)
			i:move_after(ch_item_pos_id)
			ch_item_pos_id = i.id
			i:touch()
		end

		if only_chapter_id ~= nil and chid == only_chapter_id then
			self.type = "chapter"
			self.title = "#"..chid..": "..chff.tags.title -- prefix chapter title with chapter index
			self.starttime = start_t
			self.endtime = end_t
			self.duration = end_t - start_t
			break -- no need to look at the rest
		end
	end

	self:touch()
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
