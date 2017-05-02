local RAME = require 'rame.rame'
local Item = require 'rame.item'

local BUFFER_SIZE = 64*1024

local accepted_mimetypes = {
	["video/mp4"] = 1,
	["video/mpeg"] = 1,
	["video/x-mpeg"] = 1,
	["video/quicktime"] = 1,
	["video/x-matroska"] = 1,
	["video/x-m4v"] = 1,
	["video/avi"] = 1,
	["video/vnd.avi"] = 1,
	["video/msvideo"] = 1,
	["video/x-msvideo"] = 1,
	["video/x-flv"] = 1,
	["audio/ogg"] = 1,
	["audio/m4a"] = 1,
	["audio/x-m4a"] = 1,
	["audio/aac"] = 1,
	["audio/flac"] = 1,
	["audio/mpeg"] = 1,
	["audio/x-mpeg"] = 1,
	["audio/mp3"] = 1,
	["audio/x-mp3"] = 1,
	["audio/mpeg3"] = 1,
	["audio/x-mpeg3"] = 1,
	["audio/wav"] = 1,
	["audio/x-wav"] = 1,
	["audio/wave"] = 1,
	["audio/x-wave"] = 1,
	["audio/vnd.wave"] = 1,
	["image/tiff"] = 1,
	["image/png"] = 1,
	["image/jpeg"] = 1,
	["image/gif"] = 1,
}

-- returns true if upload file is valid
local function is_valid(filename, mimetype)
	local validname = (filename:len() > 0) and (filename:len() <= 255)
		and (filename:find("/") == nil) and (filename:find("|") == nil)
		and (filename:find("?") == nil) and (filename:find("*") == nil)
		and (filename:find("<") == nil) and (filename:find(">") == nil)
		and (filename ~= ".") and (filename ~= "..")
	return validname and accepted_mimetypes[mimetype]
end

local UPLOAD = {}

-- reads content in chunks from body
function UPLOAD.POST(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id, true, true)
	if item == nil then return 404 end
	local path = RAME.resolve_uri(item.uri)
	local filename = ctx.headers["upload-filename"] or ""
	local file = path .. filename
	RAME.log.debug(("user uploading file to %s (%d bytes)"):format(file, ctx.headers["content-length"]))
	local mimetype = ctx.headers["content-type"] or ""
	local valid = is_valid(filename, mimetype)
	RAME.log.debug(("file name&type %s (MIME: %s)"):format(valid and "accepted" or "NOT ACCEPTED", mimetype))

	if valid then
		local mountpoint = RAME.get_mountpoint(file)
		RAME.remounter:wrap(mountpoint, function()
			local f = nil
			if valid then
				f, err, rc = io.open(file, "wb")
				if err ~= nil then
					RAME.log.error(("File write error (%d): %s"):format(rc, err))
				end
			end
			-- read upload file and write it to file
			ctx.read_file(function(buf)
				if f then
					f:write(buf)
				end
			end, BUFFER_SIZE)
			if f ~= nil then f:close() end
		end)
	else -- not valid:
		return 400, { error = "Invalid file type" }
	end
	return 200, {}
end

local Plugin = {}

function Plugin.init()
	RAME.rest.upload = function(ctx, reply) return ctx:route(reply, UPLOAD) end
end

return Plugin
