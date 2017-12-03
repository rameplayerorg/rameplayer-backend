local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local process = require 'cqp.process'
local RAME = require 'rame.rame'
local Item = require 'rame.item'

local fbcputil = "/usr/bin/ramefbcp"
local Plugin = {}

local INFODISPLAY_ROW_COUNT = 7

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

local file_browser_context = {
	parent_item = nil,       -- parent rame item of current folder
	first_item = nil,        -- cached first actual item of folder
	scroll_top_item = nil,   -- item of visible top row
	scroll_disabled = false, -- is view scrolling disabled? (less items than max rows)
	cursor_item = nil,       -- item of current cursor
	is_root = false,         -- is current folder the root level?
	prev_text = {},          -- previously set text for each row
	prev_color_fg = {},      -- previously set foreground color for each row
	prev_color_bg = {},      -- previously set background color for each row
	prev_icon = {},          -- previously set icon for each row
	hold_cursor_feedback_color_until_time = 0, -- used when cannot set cursor while playing
}


local function local_ui_state_change(out, prev_local_ui_state, local_ui_state)
	out:write("S:0\n") -- reset status icon
	out:write("X1:\nX2:\nX3:\nX4:\nX5:\nX6:\nX7:\n") -- clear rows
	if local_ui_state == RAME.localui.states.FILE_BROWSER then
		out:write("P0:0\n") -- disable progress bar
		--out:write("P8:1000,FF112233\n") -- progress bar bottom
		for r = 1,INFODISPLAY_ROW_COUNT do
			-- default gray color text & black bg & no icon for all rows
			file_browser_context.prev_text[r] = ""
			file_browser_context.prev_color_fg[r] = "FF999999"
			file_browser_context.prev_color_bg[r] = 0
			file_browser_context.prev_icon[r] = ""
			out:write(("O%d:%s\nS%d:0\n"):format(r, file_browser_context.prev_color_fg[r], r))
		end
	else
		-- info row colors
		out:write("O1:FFFFFFFF\n") -- hostname
		out:write("O2:FFFFFFFF\n") -- IP
		out:write("O3:FF8899AA\n") -- clock
		out:write("O4:FF777777\n") -- version
		out:write("O5:FFFF8800\n") -- reboot req.
		out:write("O6:FFFFFFFF\n") -- filename (usually)
		out:write("O7:FFFFFFFF\n") -- play pos/len (usually)
		-- reset icons
		out:write("S1:0\nS2:0\nS3:0\nS4:0\nS5:0\nS6:0\nS7:0\n")
	end
end

-- scan items of folder starting from a given item in it
local function scan_folder_items(item)
	if not item then return end
	local scanitem = item
	local wraps = 0
	repeat
		local wrapped
		-- loop&refresh through all until we come back to given item
		scanitem:refresh_meta()
		scanitem,wrapped = scanitem:navigate(false, true) --fwd w/dirs
		if wrapped then wraps = wraps + 1 end
		if wraps > 1 then break end -- failsafe
	until scanitem == item
end

local function file_browser_set_parent_folder(ctx, item, previous_sub_level)
	if not item then
		RAME.log.error("Local UI file browser navigating to null folder")
		return
	end
	item:expand()
	local first_time_init = ctx.parent_item == nil
	ctx.parent_item = item
	ctx.first_item = nil
	for _,i in pairs(item.items or {}) do
		ctx.first_item = i
		break
	end

	if ctx.parent_item ~= RAME.root then
		-- "zero entry" is ".." when we're not at root level
		ctx.scroll_top_item = nil
		ctx.is_root = false
	else
		ctx.scroll_top_item = ctx.first_item
		ctx.is_root = true
	end
	local rame_player_cursor_item = Item.find(RAME.player.cursor())
	if first_time_init and rame_player_cursor_item and rame_player_cursor_item.parent == item then
		ctx.cursor_item = rame_player_cursor_item
	else
		ctx.cursor_item = ctx.scroll_top_item
	end

	if previous_sub_level and ctx.first_item then
		-- try to init cursor to subfolder where we just returned from
		local i, wrapped = ctx.first_item, false
		while not wrapped do
			i, wrapped = i:navigate(false, true) --fwd w/dirs
			if i == previous_sub_level then
				ctx.cursor_item = i
				break
			end
		end
	end

	if ctx.first_item and not ctx.first_item.scanned then
		scan_folder_items(ctx.first_item)
	end
end


local file_browser_iconmap = {
	none = 0, -- regular files
	memcard = 7,  -- item.type "device"
	folder = 8,   -- item.type "directory"
	playlist = 9, -- item.type "playlist"
}

local file_browser_playing_status_row_color = {
	stopped = "FFFFFFFF",
	playing = "FFFF5555",
	paused = "FFEE9900",
	buffering = "FFBB4444",
	waiting = "FFBB4444",
}

local function update_local_ui_file_browser(out)
	local status = RAME.player.status()
	local ctx = file_browser_context
	local rame_player_cursor_item = Item.find(RAME.player.cursor())
	if not ctx.parent_item then
		if rame_player_cursor_item == nil or rame_player_cursor_item.parent == nil then
			file_browser_set_parent_folder(ctx, RAME.root)
		else
			file_browser_set_parent_folder(ctx, rame_player_cursor_item.parent)
		end
	elseif ctx.parent_item.parent == nil and not ctx.is_root then
		-- current folder has disappeared
		file_browser_set_parent_folder(ctx, RAME.root)
	end

	-- start from top of current scroll window:
	local row_item = ctx.scroll_top_item
	-- these values are primed for custom ".." folder first entry, when needed
	-- (these will be overridden before using if not needed)
	local row_text = ".."
	local row_icon = file_browser_iconmap.folder
	local view_wrapped = ctx.first_item == nil -- inits to true if no items => empty folder
	local last_updated_view_row = 0
	local bottom_dist = 0 -- inclusive
	local cursor_row_in_view = 0
	local monotime = cqueues.monotime()

	local cursor_highlight_color = "FF555588"
	if ctx.hold_cursor_feedback_color_until_time ~= 0 then
		if monotime < ctx.hold_cursor_feedback_color_until_time then
			cursor_highlight_color = "FFAA2200"
		else
			ctx.hold_cursor_feedback_color_until_time = 0
		end
	end

	if ctx.cursor_item and ctx.cursor_item.parent == nil then
		-- cursor item has disappeared (e.g. device removed)
		if not ctx.is_root then
			ctx.cursor_item = nil
		else
			ctx.cursor_item = ctx.first_item
		end
		ctx.scroll_top_item = ctx.cursor_item
	end

	-- check if folder/playlist contents are changed so that first item needs to be updated
	local verify_first_item = nil
	for _,i in pairs((ctx.parent_item and ctx.parent_item.items) or {}) do
		verify_first_item = i
		break
	end
	if verify_first_item and verify_first_item ~= ctx.first_item then
		ctx.first_item = verify_first_item
		scan_folder_items(verify_first_item)
	end

	for row = 1,INFODISPLAY_ROW_COUNT do
		local row_fg,row_bg = "FF999999", "FF000000"

		ctx.scroll_bottom_item = row_item
		bottom_dist = bottom_dist + 1

		if row == 1 and ctx.scroll_top_item == nil then
			-- row text&item update is skipped for initial ".." entry if present
			-- => using the initial row_text & row_icon
			if ctx.cursor_item == nil then
				row_bg = cursor_highlight_color -- cursor is in topmost ".." entry
				cursor_row_in_view = row
			end
			row_item = ctx.first_item -- setup next row_item to be first in list
		else
			-- normal row handling code --
			row_text = row_item.filename or row_item.title or row_item.uri

			if row_item.type == "directory" then
				row_icon = file_browser_iconmap.folder
			elseif row_item.type == "device" then
				row_icon = file_browser_iconmap.memcard
				if row_item.id == "rame" and row_item.title then
					row_text = row_item.title
				elseif row_item.filename and row_item.title then
					row_text = row_item.filename .. " (" .. row_item.title .. ")"
				end
			elseif row_item.type == "playlist" then
				row_icon = file_browser_iconmap.playlist
			else row_icon = file_browser_iconmap.none end

			if rame_player_cursor_item == row_item then
				row_fg = file_browser_playing_status_row_color[status] or "FFFF00FF" --pink=status color missing
			end

			if ctx.cursor_item == row_item then
				row_bg = cursor_highlight_color -- cursor is on this row
				cursor_row_in_view = row
			end

			-- setup next row_item
			row_item,view_wrapped = row_item:navigate(false, true) --fwd w/dirs
		end

		-- update row state to display process if it was changed
		if row_text ~= ctx.prev_text[row] then
			out:write(("X%d:%s\n"):format(row, row_text))
			ctx.prev_text[row] = row_text
		end
		if row_fg ~= ctx.prev_color_fg[row] or row_bg ~= ctx.prev_color_bg[row] then
			out:write(("O%d:%s,%s\n"):format(row, row_fg, row_bg))
			ctx.prev_color_fg[row] = row_fg
			ctx.prev_color_bg[row] = row_bg
		end
		if row_icon ~= ctx.prev_icon[row] then
			out:write(("S%d:%d\n"):format(row, row_icon))
			ctx.prev_icon[row] = row_icon
		end
		
		last_updated_view_row = row
		if view_wrapped then break end
	end

	if last_updated_view_row < INFODISPLAY_ROW_COUNT then
		-- clear leftover rows in view (needed if device is removed in root)
		for row = last_updated_view_row + 1, INFODISPLAY_ROW_COUNT do
			out:write(("X%d:\nS%d:0\nO%d:FF999999\n"):format(row, row, row))
			ctx.prev_text[row] = ""
			ctx.prev_icon[row] = 0
			ctx.prev_color_fg[row] = "FF999999"
			ctx.prev_color_bg[row] = 0
		end
		-- make sure scroll is at top
		if ctx.is_root then ctx.scroll_top_item = ctx.first_item
		else ctx.scroll_top_item = nil end
		ctx.scroll_disabled = true
	else
		ctx.scroll_disabled = false
	end


	local scroll_move, cursor_move = 0, 0

	local rotary_delta = RAME.localui.rotary_delta()
	if rotary_delta ~= 0 then
		cursor_move = cursor_move + rotary_delta
		RAME.localui.rotary_delta(0)
		RAME.localui.rotary_flag(false)
	end

	-- move cursor
	for move=1,math.abs(cursor_move) do
		if cursor_move < 0 and ctx.cursor_item ~= nil then

			if ctx.cursor_item == ctx.scroll_top_item or scroll_move ~= 0 then
				scroll_move = scroll_move - 1
			end

			local new_item, cwrapped = ctx.cursor_item:navigate(true, true) --backwd w/dirs
			if cwrapped then
				if not ctx.is_root and ctx.cursor_item == ctx.first_item then
					ctx.cursor_item = nil -- move up to top ".." entry
				end
			else
				ctx.cursor_item = new_item
			end

		elseif cursor_move > 0 then

			if ctx.cursor_item == ctx.scroll_bottom_item or scroll_move ~= 0 then
				scroll_move = scroll_move + 1
			end

			local new_item, cwrapped
			if not ctx.is_root and ctx.cursor_item == nil then
				new_item, cwrapped = ctx.first_item, false -- move down from top ".." entry
			else
				new_item, cwrapped = ctx.cursor_item:navigate(false, true) --fwd w/dirs
			end
			if not cwrapped then
				ctx.cursor_item = new_item
			else
				-- reached bottom, do nothing
			end
		end
	end

	if scroll_move ~= 0 and not ctx.scroll_disabled then
		if scroll_move < 0 then
			ctx.scroll_top_item = ctx.cursor_item
		elseif scroll_move > 0 then
			for move=1,scroll_move do
				local top_new_item, bottom_new_item, twrapped, bwrapped
				if not ctx.is_root and ctx.scroll_top_item == nil then
					top_new_item, twrapped = ctx.first_item, false
				else
					top_new_item, twrapped = ctx.scroll_top_item:navigate(false, true) --fwd w/dirs
				end
				bottom_new_item, bwrapped = ctx.scroll_bottom_item:navigate(false, true) --fwd w/dirs
				if not twrapped and not bwrapped then
					ctx.scroll_top_item = top_new_item
					ctx.scroll_bottom_item = bottom_new_item
				end
			end
		end
	end

	if cursor_row_in_view == 0 and ctx.cursor_item and ctx.cursor_item.parent then
		-- e.g. chapter expansion has pushed cursor off from scroll view,
		-- update scroll position so that cursor is at bottom
		local top_dist = 1
		ctx.scroll_top_item = ctx.cursor_item
		while top_dist < INFODISPLAY_ROW_COUNT do
			if ctx.scroll_top_item == nil then break end
			local new_item,twrapped = ctx.scroll_top_item:navigate(true, true) --backwd w/dirs
			if twrapped then
				if not ctx.is_root then
					ctx.scroll_top_item = nil
				else
					break
				end
			else
				ctx.scroll_top_item = new_item
			end
			top_dist = top_dist + 1
		end
	end

	if RAME.localui.button_play() then
		local playable = ctx.cursor_item and (ctx.cursor_item.type =="regular" or ctx.cursor_item.type == "chapter")
		if status == "stopped" and playable then
			RAME.player.cursor(ctx.cursor_item.id)
			RAME:action("play")
		elseif status == "paused" and playable and ctx.cursor_item == rame_player_cursor_item then
			RAME:action("play")
		end
		RAME.localui.button_play(false)
	end

	if RAME.localui.button_ok() then
		-- rotary "OK" pressed
		if not ctx.cursor_item and not ctx.is_root then
			-- entering special ".." item => go up a level and force display state refresh
			file_browser_set_parent_folder(ctx, ctx.parent_item.parent, ctx.parent_item)
			local_ui_state_change(out, RAME.localui.states.FILE_BROWSER, RAME.localui.states.FILE_BROWSER)
		elseif ctx.cursor_item and (ctx.cursor_item.type == "device" or
		                            ctx.cursor_item.type == "directory" or
		                            ctx.cursor_item.type == "playlist") then
			-- enter folder and force display state refresh
			file_browser_set_parent_folder(ctx, ctx.cursor_item)
			local_ui_state_change(out, RAME.localui.states.FILE_BROWSER, RAME.localui.states.FILE_BROWSER)
		elseif ctx.cursor_item and (ctx.cursor_item.type == "regular" or ctx.cursor_item.type == "chapter") then
			-- on top of playable item
			if status ~= "stopped" then
				-- cursor color feedback when cursor cannot be set (not stopped)
				ctx.hold_cursor_feedback_color_until_time = monotime + 0.5
			else
				RAME.player.cursor(ctx.cursor_item.id)
			end
		end
		RAME.localui.button_ok(false)
	end

end -- update_local_ui_file_browser



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
	RAME.localui.state:push_to(update)
	RAME.localui.rotary_flag:push_to(update)
	RAME.localui.rotary_delta:push_to(update)
	RAME.localui.button_ok:push_to(update)
	RAME.localui.button_play:push_to(update)
	RAME.remounter.rw_mount_count:push_to(update)

	--S[1..7]:0(no space), 1(empty), 2(play), 3(pause), 4(stopped), 5(buffering), 6(waiting), 7(memcard), 8(folder)
	--T:a,b
	--X[1..7]:text
	--P[1..8]:0-1000[,AARRGGBB] -- above which row:progress,color
	--V:0(disabled), 1(enabled) -- video cloning
	--O[1..7]:AARRGGBB[,AARRGGBB] -- set fg/bg color
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
	local prev_local_ui_state = nil

	while true do
		local monotime = cqueues.monotime()
		pending = false

		local status = RAME.player.status()
		local reboot_required = RAME.system.reboot_required()
		local play_status_id = statmap[status] or 0
		local local_ui_state = RAME.localui.state()
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

		if local_ui_state ~= prev_local_ui_state then
			local_ui_state_change(out, prev_local_ui_state, local_ui_state)
			prev_local_ui_state = local_ui_state
			-- these need to be refreshed when switching states: (local scope)
			last_displayed_filename = ""
			last_displayed_notifyinfo = ""
		end

		if local_ui_state ~= RAME.localui.states.DEFAULT then
			if video_enabled == 0 and local_ui_state == RAME.localui.states.INFO_WHILE_PLAYING then
				-- Return to default state if playing stops while in info_while_playing
				turn_off_menu = true
			end

			video_enabled = 0
		end

		fw_upgrade = RAME.system.firmware_upgrade()
		if fw_upgrade ~= nil and type(fw_upgrade) == "number" then
			if fw_upgrade < 100 then
				play_status_id = statmap.buffering -- animated
			else
				play_status_id = statmap.stopped
			end
		end

		out:write(("V:%d\n"):format(video_enabled))

		if local_ui_state == RAME.localui.states.FILE_BROWSER then
			update_local_ui_file_browser(out)
			pending = true -- keep refreshing
			goto update_done
		end

		if play_status_id > 0 then
			out:write(("S:%d\n"):format(play_status_id))
		end

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
			scan_folder_items(item)
		end
		filename = item and (item.filename or item.uri) or ""

		if filename ~= last_displayed_filename then
			out:write(("X6:%s\n"):format(filename))
			last_displayed_filename = filename
		end

		if play_status_id == statmap.buffering then
			out:write("P:0\n")
			if not showing_volume then
				-- don't show time when we're still buffering
				out:write("X7:\n") -- empty last row
			end
		elseif play_status_id > 0 then
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

		if turn_off_menu then
			cqueues.sleep(0.1)
			RAME.localui.state(RAME.localui.states.DEFAULT)
		end

		if not pending then cond:wait(max_cond_wait) end
		-- Aggregate further changes before updating the screen
		cqueues.poll(0.02)
	end
end

return Plugin
