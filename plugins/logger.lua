local RAME = require 'rame.rame'

local LOG = {}


function LOG.GET(ctx, reply)
	log_f = io.open("/var/log/messages", "r")
	if not log_f then
		return 500
	end
	local data = log_f:read("*a")
	log_f:close()
	reply.headers["Content-Type"] = "text/plain"

	return 200, data
end

function LOG.POST(ctx, reply)
	local args = ctx.args
	err, msg = RAME.check_fields(args, {
		time = {typeof="number"},
		level = {typeof="string", choices=log_levels},
		message = {typeof="string"},
	})
	if err then return err, msg end

	local time_fmt = os.date("%Y-%m-%d %H:%M:%S", tonumber(math.floor(args.time / 1000)))
	local str = ctx.ip..", "..time_fmt..", "..args.message.."\n"
	local logfunc = RAME.log.level_func[args.level]
	if logfunc ~= nil then
		logfunc(str)
	end
	return 200, {}
end

local Plugin = {}

function Plugin.init()
	RAME.rest.log = function(ctx, reply) return ctx:route(reply, LOG) end
end

return Plugin
