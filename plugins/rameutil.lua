local plpath = require 'pl.path'
local stringx = require 'pl.stringx'
local url = require 'socket.url'
local process = require 'cqp.process'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local Plugin = {
	control = {}
}

local cmds = {
	["clock"] = "rameclock",
	["text"]  = "rametext",
	["status"] = function()
		Plugin.control.cleanup = RAME.system.ip:push_to(function()
			-- Refresh text if IP changes and not playing.
			-- Perhaps later rametext can be updated to get text
			-- updates via stdin or similar.
			Plugin.control.stop()
		end)
		local ip = RAME.system.ip()
		return "rametext", ip ~= "0.0.0.0" and ip or "No Media"
	end,
}

function Plugin.control.play(uri)
	local su = url.parse(uri)
	local cmd = cmds[su.host]
	if cmd == nil then return end

	if type(cmd) == "function" then
		Plugin.process = process.spawn(cmd(uri))
	else
		local args = {cmd}
		for _, s in ipairs{stringx.splitv(su.query or '', '&')} do
			local opt, _, val = stringx.partition(s, '=')
			table.insert(args, '--'..url.unescape(opt))
			table.insert(args, url.unescape(val))
		end
		if su.path then
			table.insert(args, url.unescape(su.path:sub(2)))
		end
		Plugin.process = process.spawn(table.unpack(args))
	end
	if RAME.player.status() == "buffering" then
		RAME.player.status("playing")
	end
	Plugin.process:wait()
	Plugin.process = nil
	if Plugin.control.cleanup then
		Plugin.control.cleanup()
		Plugin.control.cleanup = nil
	end
end

function Plugin.control.stop()
	if Plugin.process then
		Plugin.process:kill(9)
	end
end

function Plugin.active()
	return plpath.exists("/usr/bin/rametext"), "rametext not found"
end

function Plugin.early_init()
	RAME.players:register("rameutil", nil, 10, Plugin.control)
	if not RAME.config.second_display then
		RAME.idle_uri = "rameutil://status"
	end
	RAME.rame:add(Item.new{title="Clock (Analog)", uri="rameutil://clock/?display=analog"})
	RAME.rame:add(Item.new{title="Clock (Combined)", uri="rameutil://clock/?display=combined"})
	RAME.rame:add(Item.new{title="Clock (Digital)", uri="rameutil://clock/?display=digital"})
	RAME.rame:add(Item.new{title="Status", uri="rameutil://status"})
	RAME.rame:add(Item.new{title="Hello world", uri="rameutil://text/Hello world!"})
end

return Plugin
