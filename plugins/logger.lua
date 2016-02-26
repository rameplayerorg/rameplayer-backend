local RAME = require 'rame.rame'
local syslog = require "posix.syslog"

local LOG = {}

local log_levels = {
	INFO = 6, --LOG_INFO	6
	DEBUG = 7, --LOG_DEBUG 7
	WARNING = 4, --LOG_WARNING	4
	ERROR = 3, --LOG_ERR	3
}

function LOG.GET(ctx, reply)
	log_f = io.open("/var/log/messages", "r")
	if not log_f then
		return 500
	end
	local data = log_f:read("*a")

	log_f:close()
	--print(data)
	--print(#data)
	reply.headers["Content-Type"] = "text/plain"

	return 200, data
end

--todo implement check_fields() checking
function LOG.POST(ctx, reply)
	local str = ctx.ip..", "..ctx.args.time..", "..ctx.args.message.."\n"
	--print(str)
	syslog.syslog(log_levels[ctx.args.level],str)
	return 200
end

local Plugin = {}

function Plugin.init()
	syslog.openlog("RAME_WEBUI")
	RAME.rest.log = function(ctx, reply) return ctx:route(reply, LOG) end
end

return Plugin
