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
		--print("rotary", timestamp, eventType, eventCode, value)

		if eventType == evdev.EV_REL and eventCode == evdev.REL_X then

			if RAME.config.second_display and RAME.localui.state() == RAME.localui.states.FILE_BROWSER then
				-- todo: refactor keyboard&rotary handling modes, maybe similar to
				--       how different controls are made for RAME.player.control
				local rv = RAME.localui.rotary_delta() + value
				RAME.localui.rotary_delta(rv)

			elseif RAME.config.omxplayer_audio_out ~= "hdmi" then
				-- regular rotary handling
				local vol = RAME.system.headphone_volume() + 5 * value
				if vol <= 0 then vol = 0 end
				if vol >= 100 then vol = 100 end
				RAME.system.headphone_volume(vol)
			end

			RAME.localui.rotary_flag(true)
		end
	end
end

return Plugin
