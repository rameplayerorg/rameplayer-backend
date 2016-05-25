local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local LCD = require 'cqp.display.lcd-hd44780'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local i2cdev = "/dev/i2c-1"
local Plugin = {}

function Plugin.active()
	if not plpath.exists("/sys/firmware/devicetree/base/rame/cid2") then
		return nil, "text display (cid2) not found"
	end
	RAME.config.second_display = true
	return true
end

function Plugin.main()
	local lcd  = LCD.new(i2cdev, LCD.DEFAULT_ADDRESS)
	local pending = true
	local cond = condition.new()
	local update = function() pending=true cond:signal() end

	RAME.player.status:push_to(update)
	RAME.player.position:push_to(update)
	RAME.player.cursor:push_to(update)
	RAME.system.ip:push_to(update)
	RAME.system.reboot_required:push_to(update)

	while true do
		pending = false

		local a, b = "", ""
		if RAME.system.reboot_required() then
			a = "Reboot Required"
		else
			a = RAME.system.ip()
		end
		if RAME.player.status() ~= "stopped" then
			local pos = tonumber(math.floor(math.abs(RAME.player.position())))
			print(pos)
			b = string.format("%02d:%02d|", pos // 60, pos % 60)
		end

		local item = Item.find(RAME.player.cursor())
		local filename = item and item.filename or ""
		b = b .. filename
		lcd:output(a, b)

		if not pending then cond:wait() end
		-- Aggregate further changes before updating the screen
		cqueues.poll(0.02)
	end
end

return Plugin
