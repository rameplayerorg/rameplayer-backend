#!/usr/bin/dbus-run-session lua5.3

-- package.path = "/path/to/lua-cqueues-pushy/?.lua;"..package.path
package.path = "/usr/share/rameplayer-backend/?.lua;"..package.path

local posix = require 'posix'
local socket = require 'socket'
local plutils = require 'pl.utils'
local cqueues = require 'cqueues'
local httpd = require 'cqp.httpd'
local process = require 'cqp.process'
local posixfd = require 'cqp.posixfd'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local function start_player()
	RAME:load_plugins(
		"/usr/share/rameplayer-backend/plugins/",
		RAME.config.settings_path .. "/plugins/",
		"./plugins/")

	RAME:hook("early_init")
	httpd.new{
		local_addr = "0.0.0.0",
		port = 8000,
		uri = function(ctx, reply)
			reply.headers["Access-Control-Allow-Origin"] = "*"
			if ctx.method == "OPTIONS" then
				local methods = "GET,OPTIONS,POST,PUT,DELETE"
				reply.headers["Allow"] = methods
				reply.headers["Access-Control-Allow-Methods"] = methods
				reply.headers["Access-Control-Allow-Headers"] = "Content-Type"
				reply.headers["Cache-Control"] = "public,max-age=600"
				return 200
			end
			reply.headers["Cache-Control"] = "no-cache"
			reply.headers["Pragma"] = "no-cache"
			return ctx:route(reply, RAME.rest, true)
		end
	}

	RAME:hook("init")
	--RAME.root:add(Item.new{id="movies", title="Movies", uri="file:///pub/movies"})

	for _, p in pairs(RAME.plugins) do
		if p.main then cqueues.running():wrap(p.main) end
	end
	cqueues.running():wrap(RAME.main)
end

local function exit_handler()
	local signal = require 'cqueues.signal'
	signal.block(signal.SIGKILL, signal.SIGTERM, signal.SIGHUP)
	local s = signal.listen(signal.SIGKILL, signal.SIGTERM, signal.SIGHUP)
	cqueues.poll(2)
	plutils.writefile('/var/run/cqpushy.pid', tostring(posix.getpid('pid')))
	s:wait()
	RAME.running = false
	error("exit")
end

local function update_ip()
	local nlfd, err = posix.socket(posix.AF_NETLINK, posix.SOCK_RAW, posix.NETLINK_ROUTE)
	posix.fcntl(nlfd, posix.F_SETFD, posix.FD_CLOEXEC)
	posix.fcntl(nlfd, posix.F_SETFL, posix.O_NONBLOCK)
	posix.bind(nlfd, {family=posix.AF_NETLINK, pid=posix.getpid("pid"), groups=0x440}) --groups=RTMGRP_IPV4_ROUTE|RTMGRP_IPV6_ROUTE
	local nlsock = posixfd.openfd(nlfd, 'r')
	local timeout = 0.05
	while true do
		if cqueues.poll(nlsock, timeout) == nlsock then
			-- Just read the netlink data. No real processing,
			-- instead just refresh the IP.
			nlsock:read(16*1024)
			timeout = 0.05
		else
			local s = socket.udp()
			s:setpeername("8.8.8.8", 80)
			local ip, port = s:getsockname()
			s:close()
			RAME.system.ip(tostring(ip))
			timeout = nil
		end
	end
end

-- Map local directory to be visible
local loop = cqueues.new()
loop:wrap(exit_handler)
loop:wrap(start_player)
loop:wrap(update_ip)
for e in loop:errors() do
	if not RAME.running then break end
	RAME.log.error(e)
end
process.killall(9)
