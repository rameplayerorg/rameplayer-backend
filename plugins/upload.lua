local RAME = require 'rame.rame'
local Item = require 'rame.item'

local BUFFER_SIZE = 64*1024

-- returns true if upload file is valid
local function is_valid(filename, mimetype)
	return mimetype == "video/mp4"
end

local UPLOAD = {}

-- reads content in chunks from body
function UPLOAD.POST(ctx, reply)
	local id = ctx.paths[ctx.path_pos]
	local item = Item.find(id, true, true)
	if item == nil then return 404 end
	local path = RAME.resolve_uri(item.uri)
	local filename = ctx.headers["upload-filename"]
	local file = path .. filename
	RAME.log.debug(("user uploading file to %s (%d bytes)"):format(file, ctx.headers["content-length"]))
	local mimetype = ctx.headers["content-type"]
	local valid = is_valid(filename, mimetype)

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
	if not valid then
		return 400, { error = "Invalid file type" }
	end
	return 200, {}
end

local Plugin = {}

function Plugin.init()
	RAME.rest.upload = function(ctx, reply) return ctx:route(reply, UPLOAD) end
end

return Plugin
