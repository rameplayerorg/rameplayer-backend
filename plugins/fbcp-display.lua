local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local process = require 'cqp.process'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local fbcputil = "/usr/bin/ramefbcp"
local Plugin = {}

local function get_localui_tz()
	local ts = os.time()
	local utcdate   = os.date("!*t", ts)
	local localdate = os.date( "*t", ts)
	localdate.isdst = false
	local tzoffset = os.difftime(os.time(localdate), os.time(utcdate))
	local tznfo = "UTC "
	if tzoffset ~= 0 then
		local h, m = math.modf(tzoffset / 3600)
		tznfo = ("UTC%+.4d "):format(h * 100 + m * 60)
	end
	--print(tznfo, localdate["hour"], localdate["min"], localdate["sec"], cqueues.monotime())
	--return ("%s %02d:%02d:%02d"):format(tznfo, localdate["hour"], localdate["min"], localdate["sec"])
	return tznfo
end

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
	RAME.cluster.controller:push_to(update)
	RAME.system.ip:push_to(update)
	RAME.system.reboot_required:push_to(update)
	RAME.system.hostname:push_to(update)
	RAME.system.headphone_volume:push_to(update)
	RAME.system.firmware_upgrade:push_to(update)
	RAME.system.rebooting_flag:push_to(update)
	RAME.version.short:push_to(update)
	RAME.localui.menu:push_to(update)
	RAME.localui.rotary_flag:push_to(update)
	RAME.remounter.rw_mount_count:push_to(update)

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
	local last_displayed_filename = ""
	local last_displayed_notifyinfo = ""
	local tznfo = 0
	local sched_update_tznfo_time = cqueues.monotime()
	local max_cond_wait = 60
	local tz_update_check_interval = 30*60

	-- using only one default color for each row, for now
	out:write("O1:FFFFFFFF\n") -- hostname
	out:write("O2:FFFFFFFF\n") -- IP
	out:write("O3:FF8899AA\n") -- clock
	out:write("O4:FF777777\n") -- version
	out:write("O5:FFFF8800\n") -- reboot req.
	out:write("O6:FFFFFFFF\n") -- filename (usually)
	out:write("O7:FFFFFFFF\n") -- play pos/len (usually)

	while true do
		local monotime = cqueues.monotime()
		pending = false

		local status = RAME.player.status()
		local reboot_required = RAME.system.reboot_required()
		local status_id = statmap[status] or 0
		local menu = RAME.localui.menu()
		local video_enabled = vidmap[status] or 0
		local turn_off_menu = false
		local showing_volume = false
		local item, filename
		local fw_upgrade, hostname
		local cluster_controller
		local notify1, notifysep, notify2
		local notifyinfo = ""

		if RAME.system.rebooting_flag() then
			out:write("O6:FFAA2200\nS:6\nV:0\n")
			out:write("X1:\nX2:\nX3:\nX4:\nX5:--- REBOOTING ---\nX6:Please wait...\nX7:\n")
			goto update_done -- skip normal update logic
		end

		if monotime >= sched_update_tznfo_time then
			tznfo = get_localui_tz()
			sched_update_tznfo_time = monotime + tz_update_check_interval
		end

		if menu then
			if video_enabled == 0 then
				-- In current placeholder implementation state, Rame menu
				-- button just blinks its led when video is not playing.
				turn_off_menu = true
			end

			video_enabled = 0
		end

		fw_upgrade = RAME.system.firmware_upgrade()
		if fw_upgrade ~= nil and type(fw_upgrade) == "number" then
			if fw_upgrade < 100 then
				status_id = statmap.buffering -- animated
			else
				status_id = statmap.stopped
			end
		end

		out:write(("S:%d\nV:%d\n"):format(status_id, video_enabled))

		hostname = RAME.system.hostname() or nil
		if hostname then
			out:write(("X1:%s\n"):format(hostname))
		end
		out:write(("X2:IP %s\n"):format(RAME.system.ip()))

		out:write(("C3:%s\n"):format(tznfo))

		out:write(("X4:%s\n"):format(RAME.version.short()))

		cluster_controller = RAME.cluster.controller()
		reboot_required = RAME.system.reboot_required()
		rw_mount_count = RAME.remounter.rw_mount_count()
		notify1 = cluster_controller and "In cluster controlled by "..cluster_controller or ""
		notifysep = ""
		notify2 = (rw_mount_count > 0) and "Writing files, do not turn off!" or ""
		if notify2:len() == 0 then
			notify2 = reboot_required and "Restart Pending..." or ""
		end
		if notify1:len() > 0 and notify2:len() > 0 then
			notifysep = " -- "
		elseif notify2:len() > 0 then
			notifysep = "‼ "
		end
		if notify1:len() > 0 or notify2:len() > 0 then
			notifyinfo = ("%s%s%s"):format(notify1, notifysep, notify2)
		end
		if notifyinfo ~= last_displayed_notifyinfo then
			out:write(("X5:%s\n"):format(notifyinfo))
			last_displayed_notifyinfo = notifyinfo
		end

		-- If rotary has just been turned, show Volume info
		if RAME.localui.rotary_flag() then
			local volume = RAME.system.headphone_volume()
			hold_volume_display_until_time = monotime + 1.5
			if RAME.config.omxplayer_audio_out ~= "hdmi" then
				out:write(("X7:Headp. volume: %d%%\n"):format(volume))
			else
				out:write("X7:Only HDMI audio!\n")
			end
			RAME.localui.rotary_flag(false)
		end
		if hold_volume_display_until_time ~= 0 then
			if monotime < hold_volume_display_until_time then
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
			last_displayed_filename = ""
			if not showing_volume then
				out:write(("X7:Firmware upg.: %d%%\n"):format(fw_upgrade))
			end
			goto update_done -- skip normal update logic
		end

		-- normal mode

		item = Item.find(RAME.player.cursor())
		if item and not item.scanned then
			-- meta is missing for item; scan items of current dir now
			local scanitem = item
			repeat
				-- loop&refresh through all until we come back to cursor item
				scanitem:refresh_meta()
				scanitem = scanitem:navigate(false)
			until scanitem == item
		end
		filename = item and (item.filename or item.uri) or ""

		if filename ~= last_displayed_filename then
			out:write(("X6:%s\n"):format(filename))
			last_displayed_filename = filename
		end

		if status_id == statmap.buffering then
			out:write("P:0\n")
			if not showing_volume then
				-- don't show time when we're still buffering
				out:write("X7:\n") -- empty last row
			end
		elseif status_id > 0 then
			-- Default status for 2 last rows: filename, status icon and play time info
			local position = RAME.player.position()
			local duration = RAME.player.duration()
			-- progress:
			if duration > 0 then
				out:write(("P:%.0f\n"):format(math.max(position, 0) / duration * 1000))
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

		if not pending then cond:wait(max_cond_wait) end
		-- Aggregate further changes before updating the screen
		cqueues.poll(0.02)
	end
end

return Plugin
