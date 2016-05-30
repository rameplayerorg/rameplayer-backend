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
	RAME.system.rebooting_flag:push_to(update)
	RAME.system.firmware_upgrade:push_to(update)

	local lcd_width = 16
	local prev_filename = ""
	local scroll_time = 0
	local scroll_pos = 0
	local monotime = 0
	local prev_player_status = ""

	while true do
		pending = false

		local newtime = cqueues.monotime()
		if monotime == 0 then monotime = newtime end
		local deltatime = newtime - monotime
		monotime = newtime

		local player_status = RAME.player.status()
		local row1, row2 = "", ""
		local top_rotation = { RAME.system.ip() }
		local hostname = RAME.system.hostname() or nil
		local remaining_size
		local item, filename
		local fw_upgrade

		if RAME.system.rebooting_flag() then
			lcd:output("REBOOTING", "Please wait...")
			goto update_done -- skip normal update logic
		end

		if hostname then table.insert(top_rotation, hostname) end
		if RAME.system.reboot_required() then table.insert(top_rotation, "Reboot Required") end

		if #top_rotation > 0 then
			local delay = 3
			if #top_rotation > 2 then delay = 1.5 end
			local idx = tonumber(math.floor(math.abs(monotime / delay))) % #top_rotation
			row1 = top_rotation[idx + 1]
		end

		fw_upgrade = RAME.system.firmware_upgrade()
		if fw_upgrade ~= nil and type(fw_upgrade) == "number" then
			row2 = ("FW UPGRADE: %d%%"):format(fw_upgrade)
			lcd:output(row1, row2)
			goto update_done -- skip rest of normal update logic
		end

		if player_status ~= "stopped" then
			local pos = tonumber(math.floor(math.abs(RAME.player.position())))
			--print(pos)
			row2 = string.format("%02d:%02d ", pos // 60, pos % 60)
		end

		remaining_size = lcd_width - row2:len()

		item = Item.find(RAME.player.cursor())
		filename = item and (item.filename or item.uri) or ""
		if filename ~= prev_filename or prev_player_status ~= player_status then
			scroll_time = 0
			scroll_pos = 0
			prev_filename = filename
		end

		if filename:len() <= remaining_size then
			row2 = row2 .. filename
		else
			local speed = 1.5
			local scroll_len = (filename:len() - remaining_size + 1) * 2 + 1
			scroll_time = scroll_time + deltatime * speed
			scroll_pos = tonumber(math.floor(scroll_time)) % scroll_len
			if scroll_pos > scroll_len // 2 then scroll_pos = scroll_len + 1 - scroll_pos end
			row2 = row2 .. filename:sub(scroll_pos, scroll_pos + remaining_size)
		end
		lcd:output(row1, row2)

		::update_done::

		if not pending then cond:wait(0.1) end
		-- Aggregate further changes before updating the screen
		cqueues.poll(0.02)

		prev_player_status = player_status
	end
end

return Plugin
