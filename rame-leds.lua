local plfile = require 'pl.file'
local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local push = require 'cqp.push'
local RAME = require 'rame'

local properties = {}
local mappings = {
	["rame:green:play"]	= function() local s = RAME.player.status() return s == "playing" or s == "buffering" end,
	["rame:yellow:pause"]	= function() local s = RAME.player.status() return s == "paused"  or s == "buffering" end,
	["rame:red:stop"]	= function() return RAME.player.status() == "stopped" end,
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
