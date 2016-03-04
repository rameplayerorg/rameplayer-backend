local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local RAME = require 'rame.rame'
local evdev = require 'evdev'

local dev = "/dev/input/by-path/platform-soc:rame-rotary-event"

local Plugin = { }
function Plugin.active()
	return plpath.exists(dev), "rotary not present"
end

function Plugin.main()
	local input = evdev.Device(dev)
	input:grab(true)
	while true do
		cqueues.poll(input)
		local timestamp, eventType, eventCode, value = input:read()
		print("rotary", timestamp, eventType, eventCode, value)
		if eventType == evdev.EV_REL and eventCode == evdev.REL_X then
			local vol = RAME.system.headphone_volume() + 5 * value
			if vol <= 0 then vol = 0 end
			if vol >= 100 then vol = 100 end
			RAME.system.headphone_volume(vol)
			RAME.localui.rotary_flag(true)
		end
	end
end

return Plugin
