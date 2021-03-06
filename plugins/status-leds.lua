local plfile = require 'pl.file'
local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local push = require 'cqp.push'
local RAME = require 'rame.rame'

local properties = {}
local mappings = {
	["rame:play"]	= function() local s = RAME.player.status() return s == "playing" or s == "buffering" end,
	["rame:pause"]	= function() local s = RAME.player.status() return s == "waiting" or s == "paused"  or s == "buffering" end,
	["rame:stop"]	= function() local s = RAME.player.status() return s == "waiting" or s == "stopped" end,
	["rame:rame"]	= function() return RAME.localui.state() ~= RAME.localui.states.DEFAULT end,
}

local Plugin = { }
function Plugin.init()
	for led, value in pairs(mappings) do
		local sysfsled = "/sys/class/leds/"..led
		if plpath.exists(sysfsled) then
			local prop = push.computed(value)
			table.insert(properties, prop)
			prop:push_to(function(val)
				plfile.write(sysfsled.."/brightness", val and "255" or "0")
			end)
		end
	end
end

return Plugin
