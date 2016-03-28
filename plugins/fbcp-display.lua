local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local process = require 'cqp.process'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local fbcputil = "/usr/bin/ramefbcp"
local Plugin = {}

function Plugin.active()
	if not plpath.isfile(fbcputil) then
		return nil, fbcputil.." not found"
	end
	if not plpath.exists("/dev/fb1") then
		return nil, "/dev/fb1 not found"
	end
	RAME.config.second_display = true
	return true
end

function Plugin.main()
	local pending = true
	local cond = condition.new()
	local update = function() pending=true cond:signal() end

	RAME.player.position:push_to(update)
	RAME.player.duration:push_to(update)
	RAME.player.status:push_to(update)
	RAME.player.cursor:push_to(update)
	RAME.system.ip:push_to(update)
	RAME.system.reboot_required:push_to(update)
	RAME.system.hostname:push_to(update)
	RAME.system.headphone_volume:push_to(update)
	RAME.system.firmware_upgrade:push_to(update)
	RAME.version.short:push_to(update)
	RAME.localui.menu:push_to(update)
	RAME.localui.rotary_flag:push_to(update)

	--S:0(no space), 1(empty), 2(play), 3(pause), 4(stopped), 5(buffering/waiting)
	--T:a,b
	--X[12]:text
	--P:0-1000 (progress)
	--V:0(disabled), 1(enabled) -- video cloning
	local statmap = {
		playing = 2,
		paused = 3,
		buffering = 5,
		waiting = 6,
	}
	local vidmap = {
		playing = 1,
		paused = 1,
		buffering = 0,
		waiting = 0,
	}
	local out = process.popenw(fbcputil)
	local hold_volume_display_until_time = 0

	while true do
		pending = false

		local status = RAME.player.status()
		local status_id = statmap[status] or 0
		local menu = RAME.localui.menu()
		local video_enabled = vidmap[status] or 0
		local item, filename

		local turn_off_menu = false
		if menu then
			if video_enabled == 0 then
				-- In current placeholder implementation state, Rame menu
				-- button just blinks its led when video is not playing.
				turn_off_menu = true
			end

			video_enabled = 0
		end

		local fw_upgrade = RAME.system.firmware_upgrade()
		if fw_upgrade ~= nil and type(fw_upgrade) == "number" then
			if fw_upgrade < 100 then
				status_id = 5 -- animated "buffering"
			else
				status_id = 4 -- stopped
			end
		end

		out:write(("S:%d\nV:%d\n"):format(status_id, video_enabled))

		local hostname = RAME.system.hostname() or nil
		if hostname then
			out:write(("X1:%s\n"):format(hostname))
		end
		out:write(("X2:IP %s\n"):format(RAME.system.ip()))

		out:write(("X4:%s\n"):format(RAME.version.short()))

		local reboot_required = RAME.system.reboot_required() and true or nil
		if reboot_required then
			out:write("X5:‼ Restart Pending...\n")
		end


		local showing_volume = false

		-- If rotary has just been turned, show Volume info
		if RAME.localui.rotary_flag() then
			local volume = RAME.system.headphone_volume()
			hold_volume_display_until_time = cqueues.monotime() + 1.5
			if RAME.config.omxplayer_audio_out ~= "hdmi" then
				out:write(("X7:Headp. volume: %d%%\n"):format(volume))
			else
				out:write("X7:Only HDMI audio!\n")
			end
			RAME.localui.rotary_flag(false)
		end
		if hold_volume_display_until_time ~= 0 then
			if cqueues.monotime() < hold_volume_display_until_time then
				pending = true
				showing_volume = true
			else
				hold_volume_display_until_time = 0
			end
		end


		if fw_upgrade ~= nil and type(fw_upgrade) == "number" then
			-- firmware upgrade mode
			out:write(("P:%d\n"):format(fw_upgrade * 10))
			if fw_upgrade < 100 then
				out:write("X6:--- DO NOT TURN OFF! ---\n")
			else
				out:write("X6:\n")
			end
			if not showing_volume then
				out:write(("X7:Firmware upg.: %d%%\n"):format(fw_upgrade))
			end
			goto update_done -- skip normal update logic
		end

		-- normal mode

		item = Item.find(RAME.player.cursor())
		filename = item and item.filename or ""

		out:write(("X6:%s\n"):format(filename))

		-- Default status for 2 last rows: filename, status icon and play time info
		if status_id > 0 then
			local position = math.abs(RAME.player.position())
			local duration = RAME.player.duration()
			-- progress:
			if duration > 0 then
				out:write(("P:%.0f\n"):format(position / duration * 1000))
			else
				out:write("P:0\n")
			end
			-- times (when not showing volume)
			if not showing_volume then
				if duration > 0 then
					out:write(("T:%.0f,%.0f\n"):format(position * 1000, duration * 1000))
				else
					out:write(("T:%.0f\n"):format(position * 1000))
				end
			end
		else
			-- stopped state, progress 0
			out:write("S:4\nP:0\n")
			if not showing_volume then
				out:write("X7:\n") -- empty last row
			end
		end

		::update_done::

		-- part of placeholder Rame menu button implementation:
		if turn_off_menu then
			cqueues.sleep(0.25)
			RAME.localui.menu(false)
		end

		if not pending then cond:wait() end
		-- Aggregate further changes before updating the screen
		cqueues.poll(0.02)
	end
end

return Plugin
