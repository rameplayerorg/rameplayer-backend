local plfile = require 'pl.file'
local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local push = require 'cqp.push'
local RAME = require 'rame.rame'
local evdev = require 'evdev'

local dev = "/dev/input/by-path/platform-soc:rame-keys-event"

local actions = {
	[evdev.KEY_UP] = "prev",
	[evdev.KEY_DOWN] = "next",
	[evdev.KEY_PAUSE] = "pause",
	[evdev.KEY_PLAY] = "play",
	[evdev.KEY_STOP] = "stop",
}

local Plugin = { }
function Plugin.active()
	return plpath.exists(dev), "keyboard not present"
end

function Plugin.main()
	local kbd = evdev.Device(dev)
	kbd:grab(true)
	while true do
		cqueues.poll(kbd)
		local timestamp, eventType, eventCode, value = kbd:read()
		if value ~= 0 and actions[eventCode] then
			RAME:hook(actions[eventCode])
		end
	end
end

return Plugin
