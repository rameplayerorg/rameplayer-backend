local json = require 'cjson.safe'
local cqueues = require 'cqueues'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'
local push = require 'cqp.push'
local process = require 'cqp.process'
local condition = require 'cqueues.condition'
local Item = require 'rame.item'
local UrlMatch = require 'rame.urlmatch'
local syslog = require 'posix.syslog'

local RAME = {
	version = {
		backend = push.property("development", "Backend version"),
		firmware = push.property(nil, "Firmware version"),
		hardware = push.property(nil, "Hardware version"),
		hardware_addon = push.property(nil, "Hardware addon"),
		hardware_cfg = push.property(nil, "Hardware config"),
		short = push.property(nil, "Short combined version"), -- for local UI
	},
	running = true,
	config = {
		settings_path = "/media/mmcblk0p1/user/",
		omxplayer_audio_out = "hdmi",
	},
	user_settings = {
		autoplayUsb = false,
	},
	system_settings = {
		audioPort = "rameAnalogOnly",
		audioMono = false,
	},
	system = {
		ip = push.property("(No link)", "Current IP-address"),
		net_connection = push.property(false, "Network connection"),
		hostname = push.property("", "hostname"),
		reboot_required = push.property(false, "Reboot required"),
		update_available = push.property(false, "Update available"),
		firmware_upgrade = push.property(nil, "Firmware upgrade progress"),
		headphone_volume = push.property(100, "Headphone volume"),
		lineout_volume = push.property(100, "Lineout volume"),
		audio_mono_out = push.property(false, "Downmix audio to mono"),
		rebooting_flag = push.property(false, "Imminent reboot notification flag"),
		media_mount = push.property(nil, "Media mount event"),
		timezone = push.property("UTC", "Timezone"),
	},
	player = {
		status   = push.property("stopped", "Playback status"),
		command  = push.property("stop", "Active playback command"),
		cursor   = push.property("", "Active media"),
		position = push.property(0, "Active media play position"),
		duration = push.property(0, "Active media duration"),
	},
	recorder = {
		enabled = push.property(false, "Streaming enabled"),
		running = push.property(false, "Streaming / recording in progress"),
		streaming = push.property(false, "Streaming in progress"),
		recording = push.property(false, "Recording in progress"),
		last_statusline,
		last_warning,
		last_error,
	},
	localui = {
		states = {
			DEFAULT = 0,
			INFO_WHILE_PLAYING = 1,
			FILE_BROWSER = 2,
			_COUNT = 3
		},
		state = push.property(0, "Local UI state"),
		rotary_flag = push.property(false, "Rotary notification flag"),
		rotary_delta = push.property(0, "Rotary delta"), -- when not directly to headphone volume
		button_ok = push.property(false, "OK button"),
		button_play = push.property(false, "Rerouted Play button"),
		button_repeatplay = push.property(false, "Rerouted Repeat-Play"),
	},
	cluster = {
		controller = push.property(false, "Cluster controller text"),
		controllers = {},
	},
	media = {},
	mountpoint_fstype = {},
	root = Item.new_list{id="root", title="Root"},
	rame = Item.new_list{
		id="rame",
		["type"]="device",
		title="RAME",
		filename="rame",
		mountpoint="/media/mmcblk0p1",
		playlists={},
		playlistsfile="/user/playlists.json",
	},
	default = Item.new_list{
		id="default",
		["type"]="playlist",
		title="Default playlist",
		editable=true
	},
	rest = {},
	plugins = {},
	log = {
		levels = {
			DEBUG   = syslog.LOG_DEBUG,   -- 7
			INFO    = syslog.LOG_INFO,    -- 6
			WARNING = syslog.LOG_WARNING, -- 4
			ERROR   = syslog.LOG_ERR,     -- 3
		},
		level_func = {},
		syslog = syslog,
		with_stdout = true,
	},

	idle_uri = nil,
	idle_controls = {
		cond = condition.new(),
	},
	null_controls = {},
	wait_controls = {
		cond = condition.new(),
	},
	players = UrlMatch.new(),
	remounter = {
		remounting = false,
		cond = condition.new(),
		c = {},
		rw_mount_count = push.property(0, "Count of active RW mount points"),
	},
}

syslog.openlog("RAME")

RAME.root:add(RAME.rame)

function RAME:load_plugins(...)
	for _, path in ipairs(table.pack(...)) do
		if plpath.isdir(path) then
			local files = pldir.getfiles(path, "*.lua")
			for _, f in pairs(files) do
				local ok, plugin = pcall(dofile, f)
				local act, err = true
				if ok then
					if plugin.active then
						act, err = plugin.active()
					end
				else
					act, err = false, "failed to load: " .. plugin
				end

				RAME.log.info(("Plugin %s: %s"):format(f, act and "loaded" or "not active: "..(err or "disabled")))
				if act then
					self.plugins[plpath.basename(f)] = plugin
				end
			end
		end
	end
end

function RAME:hook(hook, ...)
	local ret=true
	for name, p in pairs(self.plugins) do
		local f = p[hook]
		if f then
			if f(...) == false then ret=false end
		end
	end
	return ret
end

function RAME:reset_player_schedule()
	self.player.__resume_command = nil
	self.player.__resume_itemid = nil
	self.player.__scheduled_listid = nil
end

-- commands:
--   autoplay with item_id
--   set_cursor with item_id
--   play (with delay)
--   seek (with negative offset)
--   pause, stop, next, prev

function RAME:action(command, item_id, pos)
	local status = RAME.player.status()

	if command == "seek" then
		if status == "stopped" then return 400 end
		if pos == nil then return 400 end
		if pos < 0 then
			-- Kill player and go to waiting state
			self.player.__wait = math.abs(pos)
			if self.player.control and self.player.control.stop then
				self.player.control.stop()
			end
			return 200
		end
		if self.player.control and self.player.control.seek then
			return self.player.control.seek(pos) and 200 or 400
		end
		return 400
	end

	if command == "scheduledplay" then
		-- Keep the original item id to be resumed in case we are
		-- interrupting earlier scheduled item
		if not self.player.__resume_command then
			local command = self.player.command()
			if command ~= "autoplay" and command ~= "repeatplay" then
				command = "stop"
			end
			self.player.__resume_command = command
			self.player.__resume_itemid = self.player.cursor()
		end
		RAME.log.info(("Starting scheduled play, will resume item ID %s, cmd %s"):format(self.player.__resume_itemid, self.player.__resume_command))
		if status ~= "stopped" then
			self.player.__scheduled_listid = item_id
			self.player.command("autoplay")
			if self.player.control and self.player.control.stop then
				self.player.control.stop()
			end
			return 200
		end
		local item = Item.find(item_id)
		if item then
			command = "autoplay"
			item_id = item:get_first_play_item_id()
		else
			command = "stop"
			item_id = nil
		end
	end

	if command == "stop" then
		self.player.command("stop")
		self:reset_player_schedule()
		if status ~= "stopped" and self.player.control and self.player.control.stop then
			self.player.control.stop()
		end
		return 200
	end

	if command == "pause" or (command == "play" and status == "paused") then
		if self.player.control and self.player.control.pause then
			return self.player.control.pause() and 200 or 400
		end
		return 400
	end

	if command == "menu" then
		if self.player.command() ~= "stop" then
			self.localui.state((self.localui.state() + 1) % self.localui.states._COUNT)
		else -- not playing:
			local state, new_state = self.localui.state()
			if state == self.localui.states.DEFAULT then
				new_state = self.localui.states.FILE_BROWSER
			elseif state == self.localui.states.INFO_WHILE_PLAYING then
				new_state = self.localui.states.DEFAULT -- shouldn't happen
			elseif state == self.localui.states.FILE_BROWSER then
				new_state = self.localui.states.DEFAULT
			end
			if new_state then self.localui.state(new_state) end
		end
		--self.localui.menu(not self.localui.menu())
	end

	if command == "ok" then
		-- todo: refactor keyboard&rotary handling modes, maybe similar to
		--       how different controls are made for RAME.player.control
		if self.config.second_display then
			if self.localui.state() == self.localui.states.FILE_BROWSER then
				self.localui.button_ok(true)
			else
				-- placeholder test functionality for pressing rotary button
				self.localui.rotary_flag(true)
			end
		end
	end

	if status ~= "stopped" then return 400 end
	if command == "set_cursor" and not item_id then return 404 end
	if item_id and Item.find(item_id) == nil then return 404 end

	if command == "next" or command == "prev" then
		local item, cursor_id = Item.find(self.player.cursor()), nil
		if not item then return 404 end
		item = item:navigate(command == "prev")
		item_id = item.id
	end

	if item_id then RAME.player.cursor(item_id) end

	if command == "repeatplay" or command == "autoplay" or command == "play" then
		local item = Item.find(RAME.player.cursor())
		local parent = item and item.parent or {}
		if command == "play" and parent.autoPlayNext then
			command = "autoplay"
		end

		RAME.log.info("Player: sending " .. command .. " command, cursor " .. self.player.cursor())
		self.player.command(command)

		if parent.shufflePlay then parent:refresh_shuffle_order() end
		if pos then
			if pos < 0 then
				self.player.__wait = -pos
			else
				self.player.__initpos = pos
			end
		end
		-- This kills the idle player to wake up idle thread
		if self.player.control and self.player.control.stop then
			self.player.control.stop()
		end
	end

	return 200
end

function RAME.idle_controls.play()
	RAME.idle_controls.cond:wait()
	return nil
end

function RAME.idle_controls.stop()
	RAME.idle_controls.cond:signal()
end

function RAME.null_controls.play()
	return nil
end

function RAME.wait_controls.seek(pos)
	RAME.player.__wait = 0
	RAME.player.__initpos = pos
	RAME.idle_controls.cond:signal()
	return true
end

function RAME.wait_controls.pause()
	RAME.player.status((RAME.player.status() == "waiting") and "paused" or "waiting")
	return true
end

function RAME.wait_controls.stop()
	RAME.player.__wait = nil
	RAME.wait_controls.cond:signal()
end

local function on_cursor_change(item_id)
	if RAME.cursor_item then
		RAME.cursor_item.on_delete = nil
	end
	local item = Item.find(item_id)
	if item then
		item.on_delete = function()
			RAME:action("stop")
			RAME.player.cursor("")
		end
	end
	RAME.cursor_item = item
end

function RAME.resolve_uri(uri)
	if uri:match("^file:") == nil then return uri end
	local host, path, fragment = uri:match("^file://([^/]+)([^#]*)#?(.*)")
	local chapter_id = fragment and fragment:match("^id=(.+)") or nil
	if host == nil or RAME.media[host] == nil then return nil end
	local file = RAME.media[host]..path
	--RAME.log.debug(("Mapped %s -> %s (%s)"):format(uri, file, chapter_id or "-"))
	return file, chapter_id
end

function RAME.read_settings_file(file)
	return plfile.read(RAME.config.settings_path..file)
end

-- Extracts mountpoint from given path or nil
function RAME.get_mountpoint(path)
	-- simply take two first directories
	return path:match('/[^/]*/[^/]*')
end

-- returns parsed output from 'df' command
-- df output example:
-- Filesystem           1K-blocks      Used Available Use% Mounted on
-- /dev/sda1              7553608    628612   6924996   8% /media/sda1
function RAME.get_disk_space(path)
	local out = process.popen("df", path):read_all() or ""
	local devname, blocks, used, available, mountpoint = out:match("\n([/a-z0-9]+)%s+(%d+)%s+(%d+)%s+(%d+)%s+%S+%s+(%S+)")
	if devname == nil then
		-- error when parsing
		-- it's okay, since user may have mistyped, or there's no media
		--RAME.log.error(("Invalid output from command df %s: %s"):format(path, out))
		return nil
	end
	return {
		mountpoint=mountpoint,
		type=RAME.mountpoint_fstype[mountpoint] or "?",
		blocks=tonumber(blocks),
		used=tonumber(used),
		available=tonumber(available),
	}
end

-- Remounts given mountpoint readwrite,
-- calls given function and
-- remounts mountpoint back to readonly
function RAME.remounter:wrap(mountpoint, func)
	if self.remounting then
		self.cond:wait() -- wait remount to end
	end

	self.c[mountpoint] = (self.c[mountpoint] or 0) + 1
	if self.c[mountpoint] == 1 then
		-- remount to rw
		self.remounting = true
		RAME.log.debug(("remounting rw %s"):format(mountpoint))
		local err = process.popen_err("mount", "-o", "remount,rw", mountpoint):read_all() or ""
		if err ~= "" then
			RAME.log.error(("remounting rw %s failed: %s"):format(mountpoint, err))
		end
		self.remounting = false
		RAME.remounter.rw_mount_count(RAME.remounter.rw_mount_count() + 1)
		RAME.log.debug("rw_mount_count "..RAME.remounter.rw_mount_count())
		self.cond:signal()
	end

	-- run user given function
	local ret = func()

	if self.remounting then
		self.cond:wait() -- wait remount to end
	end

	-- remount to readonly if this is last reference
	self.c[mountpoint] = self.c[mountpoint] - 1
	if self.c[mountpoint] == 0 then
		self.remounting = true
		RAME.log.debug(("remounting ro %s"):format(mountpoint))
		process.run("sync")
		local err = process.popen_err("mount", "-o", "remount,ro", mountpoint):read_all() or ""
		if err ~= "" then
			RAME.log.error(("remounting ro %s failed: %s"):format(mountpoint, err))
		end
		self.remounting = false
		RAME.remounter.rw_mount_count(RAME.remounter.rw_mount_count() - 1)
		RAME.log.debug("rw_mount_count "..RAME.remounter.rw_mount_count())
		self.cond:signal()
	end

	return ret
end

function RAME.remount_rw_write(mountpoint, file, data)
	return RAME.remounter:wrap(mountpoint, function()
		local dirname = plpath.dirname(file)
		if dirname ~= mountpoint then pldir.makepath(dirname) end
		local ok, err = plfile.write(file, data)
		if err ~= nil then
			RAME.log.error(("File write error %s: %s"):format(file, err))
		end
		return ok
	end)
end

function RAME.write_settings_file(file, data)
	return RAME.remount_rw_write("/media/mmcblk0p1", RAME.config.settings_path..file, data)
end

function RAME.factory_reset()
	process.run("sh", "-c", [[mount -o remount,rw /media/mmcblk0p1; rm -rf /media/mmcblk0p1/user /media/mmcblk0p1/*.apkovl.tar.gz; cp /media/mmcblk0p1/factory.rst /media/mmcblk0p1/rame.apkovl.tar.gz; mount -o remount,ro /media/mmcblk0p1]])
end

function RAME.reboot_device()
	RAME.system.rebooting_flag(true)
	cqueues.poll(0.5)
	process.run("reboot", "now")
end

function RAME.commit_overlay()
	process.run("lbu", "commit", "-d")
	return true
end

function RAME.load_playlists(item, bootmedia)
	local lists,err = json.decode(plfile.read(item.mountpoint .. item.playlistsfile) or "{}")
	item:load_playlists(lists, function(item, playlistdata)
		RAME.remount_rw_write(item.mountpoint, item.mountpoint..item.playlistsfile, json.encode(playlistdata))
	end)
	for name, pitem in pairs(item.playlists) do
		RAME.root:add(pitem)
		if name == "autoplay" and #pitem.items > 0
		   and (bootmedia or RAME.user_settings.autoplayUsb) then
			RAME:action("autoplay", pitem:get_first_play_item_id())
		end
	end
end

function RAME.playlist_scheduler()
	local self = RAME
	local timerfd = require 'cqp.timerfd'
	local timer = timerfd.new()

	RAME.log.debug("Scheduler started")
	self.__scheduler_timer = timer
	while next(Item.__all_scheduled) do
		-- Find the next scheduled item if any
		local now = os.time()
		local next_list, next_time = nil, now + 10*24*60*60
		for _, item in pairs(Item.__all_scheduled) do
			local tm = os.date("*t", now)
			-- Calculate next calendar time to play
			local secs = item.scheduledTime
			local h, m, s = secs // 3600, (secs // 60) % 60, secs % 60
			for i = 0, 7 do
				-- Calculate the scheduled localtime for i'th day
				-- in that days daylight savings time setting.
				tm.hour, tm.min, tm.sec, tm.isdst = h, m, s, nil
				local playtime = os.time(tm)
				if playtime > next_time then break end

				-- As side effect 'tm' is updated with normalized
				-- time. Check that the resulting time matches what
				-- we asked. It differs if there was a DST change
				-- and the time requested does not exist.
				if tm.hour == h and tm.min == m and tm.sec == s and
				   playtime > now and item.scheduledMonSun[1+((tm.wday+5) % 7)] then
					next_list = item
					next_time = playtime
					break
				end

				tm.day = tm.day + 1
			end
		end
		if not next_list then break end

		-- Wait until scheduled time or recalculation needed
		-- Cancel is triggered by above 'reschedule' on item change,
		-- and by the kernel on system time jump.
		timer:set(next_time, nil, true)
		RAME.log.debug(("Scheduled playlist %s (%s) in %d sec"):format(next_list.id, next_list.title, next_time - now))
		local val, err, errno = timer:read()
		if val and val > 0 then
			-- Timer Triggered - time to play the item
			RAME.log.debug(("SCHEDULE PLAY playlist %s (%s)"):format(next_list.id, next_list.title))
			RAME:action("scheduledplay", next_list.id)
		else
			-- Cancelled, aggregate potentual further wakeups
			cqueues.poll(0.01)
		end
	end
	self.__scheduler_timer = nil
	timer:close()
	RAME.log.debug("Scheduler exited")
end

function RAME.reschedule()
	if RAME.__scheduler_timer then
		RAME.__scheduler_timer:cancel()
	elseif next(Item.__all_scheduled) then
		cqueues.running():wrap(RAME.playlist_scheduler)
	end
end

function RAME.main()
	local self = RAME
	self.player.cursor:push_to(on_cursor_change)
	cqueues.running():wrap(Item.scanner)
	cqueues.poll(0.1)
	self.load_playlists(self.rame, true)

	while true do
		-- Start process matching current state
		local move_next = true
		local item = Item.find(self.player.cursor())
		self.player.position(0)
		self.player.duration(0)

		-- item or idle url to play?
		local uri, control
		local playing = item and self.player.command() ~= "stop"
		if playing then
			uri = item.uri
			control = RAME.players:resolve(uri)
			       or RAME.null_controls
		else
			uri = self.idle_uri
			control = RAME.players:resolve(uri)
			       or RAME.idle_controls
			self.player.__wait = nil
			self.player.status("stopped")
		end

		-- Main item playback loop. This plays the "idle player" once
		-- if in "stopped" state. If in real playback mode, this will
		-- optionall start with "waiting" state, or go to "buffering"
		-- and then "playing" state. To loop is needed when the item
		-- is seeked to negative offset and the playback will go to
		-- again to "waiting" mode.
		repeat
			if self.player.command() ~= "stop" and self.player.__wait then
				self.player.status("waiting")
				self.player.control = self.wait_controls
				while self.player.__wait and self.player.__wait > 0 do
					self.player.position(-self.player.__wait)
					local d = 0.1
					if self.player.status() ~= "paused" then
						d = math.min(d, self.player.__wait)
						self.player.__wait = self.player.__wait - d
					end
					cqueues.poll(self.wait_controls.cond, d)
				end
				self.player.control = nil

				-- stopped while waiting?
				if self.player.__wait == nil then
					control = self.null_controls
					move_next = false
					break
				end
				self.player.__wait = nil
			end
			if self.player.command() ~= "stop" then
				self.player.status("buffering")
			end

			--print("Playing", uri, control, item)
			RAME.log.info("Playing", uri)
			local initpos = self.player.__initpos
			local chstartpos, chendpos = nil, nil
			if item and item.chapter_id and item.starttime then
				-- omxplayer seems to assume seek positions in whole seconds
				-- (and no support for seeking to previous keyframe and finding exact pos frame-by-frame)
				initpos = math.floor(item.starttime)
				-- also give exact chapter start and end times
				chstartpos = item.starttime
				chendpos = item.endtime
			end
			self.player.control = control
			self.player.__initpos = nil
			move_next = RAME.player.control.play(uri, self.player.command(), initpos, chstartpos, chendpos)
			self.player.control = nil
			RAME.log.info("Stopped", uri)
		until not playing or self.player.__wait == nil

		if playing then
			local autoplay = (self.player.command() == "autoplay")
			local wrapped = true
			if self.player.__scheduled_listid then
				-- Scheduled playlist interruption
				item = Item.find(self.player.__scheduled_listid)
				item = item and item:get_first_play_item_id()
				self.player.__scheduled_listid = nil
				if item then
					-- Start scheduled playlist
					self.player.cursor(item)
				else
					-- Scheduled list was empty, resume what was interrupted
					self.player.cursor(self.player.__resume_itemid or "")
					self.player.command(self.player.__resume_command or "stop")
					self:reset_player_schedule()
					autoplay = true
				end
				wrapped = false
			elseif item and (move_next or autoplay) then
				-- Move cursor to next item if playback stopped normally
				-- or in autoplay mode and stop was not requested
				item, wrapped = item:navigate()
				if wrapped and self.player.__resume_command
				   and not (item.parent and item.parent.autoPlayNext) then
					-- Resume to interrupted playlist's item or stop state
					-- after scheduled playlist finishes
					self.player.cursor(self.player.__resume_itemid or "")
					self.player.command(self.player.__resume_command or "stop")
					self:reset_player_schedule()
					autoplay, wrapped = true, false
				else
					self.player.cursor(item.id)
				end
			end
			if not autoplay then
				-- stop if not in autoplay mode
				self.player.command("stop")
				self:reset_player_schedule()
			elseif wrapped and not move_next then
				-- the last item of playlist failed to
				-- play, add a brief wait to restart loop
				-- so we don't busy loop
				self.player.__wait = 2.0
			end
		end
	end
end

function RAME.check_fields(data, schema)
	if type(data) ~= "table" then return 422, { error="input missing" } end
	for field, spec in pairs(schema) do
		local t = type(spec)
		if t == "string" then
			spec = { typeof=spec }
		elseif t == "function" then
			spec = { validate=spec }
		elseif t ~= "table" then
			return 422, { error="bad schema: "..field }
		end

		local val = data[field]
		if val == nil and spec.optional ~= true then
			return 422, { error="missing required parameter: "..field }
		elseif val ~= nil then
			if (spec.typeof and type(val) ~= spec.typeof) or
			   (spec.validate and not spec.validate(val)) or
			   (spec.choices and spec.choices[val] == nil) then
				return 422, { error="invalid value for parameter: "..field }
			end
		end
		-- following criteria is omitted val ~= nil and spec.optional == true
	end
end

function RAME.log.level(str)
	return RAME.log.levels[str] or RAME.log.levels["DEBUG"]
end

function RAME.log.info(...)
	syslog.syslog(RAME.log.level("INFO"), table.concat({...}, " "))
	if RAME.log.with_stdout then
		print("info:", ...)
	end
end

function RAME.log.warn(...)
	syslog.syslog(RAME.log.level("WARNING"), table.concat({...}, " "))
	if RAME.log.with_stdout then
		print("warn:", ...)
	end
end

function RAME.log.error(...)
	syslog.syslog(RAME.log.level("ERROR"), table.concat({...}, " "))
	if RAME.log.with_stdout then
		print("error:", ...)
	end
end

function RAME.log.debug(...)
	syslog.syslog(RAME.log.level("DEBUG"), table.concat({...}, " "))
	if RAME.log.with_stdout then
		print("debug:", ...)
	end
end

RAME.log.level_func = {
	DEBUG   = RAME.log.debug,
	INFO    = RAME.log.info,
	WARNING = RAME.log.warn,
	ERROR   = RAME.log.error,
}

RAME.system.timezone:push_to(RAME.reschedule)
Item.reschedule = RAME.reschedule

return RAME
