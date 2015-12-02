#!/usr/bin/dbus-run-session lua5.3

-- package.path = "/path/to/lua-cqueues-pushy/?.lua;"..package.path
local posix = require 'posix'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plutils = require 'pl.utils'
local cqueues = require 'cqueues'
local httpd = require 'cqp.httpd'
local process = require 'cqp.process'
local RAME = require 'rame'

-- Clear framebuffer
os.execute([[
[ -e /.splash.ctrl ] && (echo quit > /.splash.ctrl ; rm /.splash.ctrl)
dd if=/dev/zero of=/dev/fb0 bs=1024 count=2700
]])

local function load_plugins(...)
	for _, path in ipairs(table.pack(...)) do
		if plpath.isdir(path) then
			local files = pldir.getfiles(path, "rame-*.lua")
			for _, f in pairs(files) do
				local ok, plugin = pcall(dofile, f)
				local act, err = true
				if ok then
					if plugin.active then
						act, err = plugin.active()
					end
				else
					act, err = false, "failed to load: " .. plugin
				end

				print(("Plugin %s: %s"):format(f, act and "loaded" or "not active: "..(err or "disabled")))
				if act then
					RAME.plugins[plpath.basename(f)] = plugin
				end
			end
		end
	end
end

local function start_player()
	load_plugins(
		"/usr/share/rameplayer-backend/",
		"/etc/rameplayer/",
		RAME.config.settings_path .. "/plugins/",
		"./")

	RAME:hook("early_init")
	httpd.new{
		local_addr = "0.0.0.0",
		port = 8000,
		uri = function(ctx, reply)
			reply.headers["Access-Control-Allow-Origin"] = "*"
			if ctx.method == "OPTIONS" then
				reply.headers["Access-Control-Allow-Methods"] = "POST,GET,OPTIONS"
				reply.headers["Access-Control-Allow-Headers"] = "Content-Type"
				reply.headers["Allow"] = "POST,GET,OPTIONS"
				return 200
			end
			reply.headers["Cache-Control"] = "no-cache"
			reply.headers["Pragma"] = "no-cache"
			return ctx:route(reply, RAME.rest, true)
		end
	}

	RAME:hook("init")
	for _, p in pairs(RAME.plugins) do
		if p.main then cqueues.running():wrap(p.main) end
	end
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
	while true do
		local socket = require "socket"
		local s = socket.udp()
		s:setpeername("8.8.8.8", 80)
		local ip, port = s:getsockname()
		s:close()
		RAME.system.ip((tostring(ip) ~= "0.0.0.0") and ip or "")
		cqueues.poll(15.0)
	end
end

local loop = cqueues.new()
loop:wrap(exit_handler)
loop:wrap(start_player)
loop:wrap(update_ip)
for e in loop:errors() do
	if not RAME.running then break end
	print(e)
end
process.killall(9)
