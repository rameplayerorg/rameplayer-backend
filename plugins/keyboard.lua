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
	[evdev.KEY_MENU] = "menu",
	[evdev.KEY_OK] = "ok",
}

local Plugin = { }
function Plugin.active()
	return plpath.exists(dev), "keyboard not present"
end

function Plugin.main()
	local kbd = evdev.Device(dev)
	local factory_reset_seconds_per_step = 1
	local factory_reset_seq_actions = { "menu", "stop", "ok" }
	local factory_reset_seq_pos = 1
	local factory_reset_seq_time = 0
	kbd:grab(true)
	while true do
		cqueues.poll(kbd)
		local timestamp, eventType, eventCode, value = kbd:read()
		if value ~= 0 and actions[eventCode] then
			local rerouted_key = false

			-- todo: refactor keyboard&rotary handling modes, maybe similar to
			--       how different controls are made for RAME.player.control
			if RAME.config.second_display and actions[eventCode] == "play" then
				if RAME.localui.state() == RAME.localui.states.FILE_BROWSER then
					RAME.localui.button_play(true)
					rerouted_key = true
				end
			end

			if not rerouted_key then
				RAME:action(actions[eventCode])
			end
		end

--		print("KBD: " .. timestamp .. " - " .. eventType .. "/" .. eventCode .. ", " .. value)

		-- local UI factory reset sequence hack
		if value ~= 0 and eventCode ~= 0 then
			if actions[eventCode] == factory_reset_seq_actions[1] then
				factory_reset_seq_time = timestamp
				factory_reset_seq_pos = 2
			elseif factory_reset_seq_pos <= #factory_reset_seq_actions
			   and actions[eventCode] == factory_reset_seq_actions[factory_reset_seq_pos]
			   and timestamp > factory_reset_seq_time + factory_reset_seconds_per_step then
				factory_reset_seq_pos = factory_reset_seq_pos + 1
				factory_reset_seq_time = timestamp
			else
				factory_reset_seq_pos = 1
				factory_reset_seq_time = 0
				--print("seq reset")
			end
			--print("seq pos: "..factory_reset_seq_pos.." time: " ..timestamp)
		elseif value == 0 and eventCode ~= 0 then
			-- require simultaneous presses of reset sequence
			factory_reset_seq_pos = 1
			factory_reset_seq_time = 0
			--print("seq reset")
		end

		if factory_reset_seq_pos > #factory_reset_seq_actions then
			RAME.system.firmware_upgrade(99)
			print("FACTORY RESET")
			RAME.factory_reset()
			RAME.reboot_device()
		end
	end
end

return Plugin
