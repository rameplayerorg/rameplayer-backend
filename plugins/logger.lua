--local json = require 'cjson.safe'
local RAME = require 'rame.rame'

local LOG = {}

function LOG.GET(ctx, reply)
	--ip = ctx.ip
	local data = { time = "232320", level = "ERROR", message = "Hello Err!" }
	return 200, data
end

function LOG.POST(ctx, reply)
	print(ctx.ip, ctx.args.time, ctx.args.level, ctx.args.message)
	return 200
end

local Plugin = {}

function Plugin.init()
	RAME.rest.log = function(ctx, reply) return ctx:route(reply, LOG) end
end

return Plugin
