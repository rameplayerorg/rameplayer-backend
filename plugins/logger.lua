--local json = require 'cjson.safe'
local RAME = require 'rame.rame'

local LOG = {}
local log_f

function LOG.GET(ctx, reply)
	log_f = io.open("rame_webui_log.txt", "r")
	if not log_f then
		return 404, "No log file created!"
	end
	local data = log_f:read("*a")

	log_f:close()
	--print(data)
	--print(#data)
	reply.headers["Content-Type"] = "text/plain"

	return 200, data
end

function LOG.POST(ctx, reply)
	log_f = io.open("rame_webui_log.txt", "a+")
	local str = ctx.ip..", "..ctx.args.time..", "..ctx.args.level..", "
				..ctx.args.message.."\n"
	print(str)
	log_f:write(str)
	log_f:close()

	return 200
end

local Plugin = {}

function Plugin.init()
	RAME.rest.log = function(ctx, reply) return ctx:route(reply, LOG) end
end

return Plugin
