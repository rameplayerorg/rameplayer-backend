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
	reply.headers["Content-Type"] = "text/plain"

	return 200, data
end

function LOG.POST(ctx, reply)
	local args = ctx.args
	err, msg = RAME.check_fields(args, {
		time = {typeof="string"},
		level = {typeof="string", choices=log_levels},
		message = {typeof="string"},
	})
	if err then return err, msg end

	local str = ctx.ip..", "..args.time..", "..args.message.."\n"
	--print(str)
	syslog.syslog(log_levels[args.level],str)
	return 200
end

local Plugin = {}

function Plugin.init()
	syslog.openlog("WEBUI")
	RAME.rest.log = function(ctx, reply) return ctx:route(reply, LOG) end
end

return Plugin
