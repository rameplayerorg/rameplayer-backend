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
	},
	system = {
		ip = push.property("(No link)", "Current IP-address"),
		hostname = push.property("", "hostname"),
		reboot_required = push.property(false, "Reboot required"),
		update_available = push.property(false, "Update available"),
		firmware_upgrade = push.property(nil, "Firmware upgrade progress"),
		headphone_volume = push.property(100, "Headphone volume"),
		lineout_volume = push.property(100, "Lineout volume"),
		rebooting_flag = push.property(false, "Imminent reboot notification flag"),
	},
	player = {
		status   = push.property("stopped", "Playback status"),
		cursor   = push.property("", "Active media"),
		position = push.property(0, "Active media play position"),
		duration = push.property(0, "Active media duration"),
	},
	localui = {
		menu = push.property(false, "Local UI menu toggle"),
		rotary_flag = push.property(false, "Rotary notification flag"),
	},
	cluster = {
		controller = push.property(false, "Cluster controller text"),
		controllers = {},
	},
	media = {},
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

	if command == "stop" then
		self.player.__playing = false
		self.player.__autoplay = false
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
		self.localui.menu(not self.localui.menu())
	end

	if command == "ok" then
		-- placeholder test functionality for pressing rotary button
		self.localui.rotary_flag(true)
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
		RAME.log.info("Player: sending " .. command .. " command, cursor " .. self.player.cursor())
		self.player.__itemrepeat = (command == "repeatplay")
		self.player.__autoplay = (command == "autoplay") or parent.autoPlayNext
		self.player.__playing = true
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
	local host, path = uri:match("^file://([^/]+)(.*)")
	if host == nil or RAME.media[host] == nil then return nil end
	local file = RAME.media[host]..path
	RAME.log.debug(("Mapped %s -> %s"):format(uri, file))
	return file
end

function RAME.read_settings_file(file)
	return plfile.read(RAME.config.settings_path..file)
end

function RAME.remount_rw_write(mountpoint, file, data)
	process.run("mount", "-o", "remount,rw", mountpoint)
	local dirname = plpath.dirname(file)
	if dirname ~= mountpoint then pldir.makepath(dirname) end
	local ok, err = plfile.write(file, data)
	if err ~= nil then
		RAME.log.error(("File write error %s: %s"):format(file, err))
	end
	process.run("mount", "-o", "remount,ro", mountpoint)
	return ok
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
			RAME:action("autoplay", pitem.items[1].id)
		end
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
		local playing = item and self.player.__playing
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

		-- main play loop of item
		repeat
			if self.player.__playing and self.player.__wait then
				self.player.status("waiting")
				self.player.control = self.wait_controls
				while self.player.__playing and self.player.__wait > 0 do
					self.player.position(-self.player.__wait)
					local d = math.min(0.1, self.player.__wait)
					cqueues.poll(self.wait_controls.cond, d)
					if self.player.status() == "waiting" then
						self.player.__wait = self.player.__wait - d
					end
				end
				self.player.control = nil
				self.player.__wait = nil

				-- stopped while waiting?
				if not self.player.__playing then
					control = self.null_controls
					move_next = false
				end
			end
			if self.player.__playing then
				self.player.status("buffering")
			end

			--print("Playing", uri, control, item)
			RAME.log.info("Playing", uri)
			local initpos = self.player.__initpos
			self.player.control = control
			self.player.__initpos = nil
			move_next = RAME.player.control.play(uri, self.player.__itemrepeat, initpos)
			self.player.control = nil
			RAME.log.info("Stopped", uri)
		until not playing or self.player.__wait == nil

		if playing then
			local wrapped = true
			if item and not self.player.__itemrepeat
			   and (move_next or (self.player.__playing and self.player.__autoplay)) then
				-- Move cursor to next item if playback stopped normally
				-- or in autoplay mode and stop was not requested
				item, wrapped = item:navigate()
				self.player.cursor(item.id)
			end
			if not self.player.__autoplay then
				-- stop if not in autoplay mode
				self.player.__playing = false
				self.player.__itemrepeat = false
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


return RAME
