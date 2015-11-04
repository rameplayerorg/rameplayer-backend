#!/usr/bin/dbus-run-session lua5.2

local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local httpd = require 'cqp.httpd'
local dbus = require 'cqp.dbus'

RAME = {
	version = "0.1",
	plugins = {},
}

function RAME:hook(hook, ...)
	for _, p in ipairs(self.plugins) do
		local f = p[hook]
		if f then f(...) end
	end
end

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
				print(("Loading %s"):format(f))
				local plugin = dofile(f)
				table.insert(RAME.plugins, plugin)
			end
		end
	end
end

local function start_player()
	RAME.dbus = dbus.get_bus()
	RAME.rest = {}

	load_plugins("/usr/share/rameplayer-backend/", "/etc/rameplayer", ".")
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
	for _, p in ipairs(RAME.plugins) do
		if p.main then cqueues.running():wrap(p.main) end
	end
end

local loop = cqueues.new()
loop:wrap(start_player)
for e in loop:errors() do print(e) end
