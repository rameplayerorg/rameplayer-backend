local cqueues = require 'cqueues'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'
local push = require 'cqp.push'
local process = require 'cqp.process'
local condition = require 'cqueues.condition'
local Item = require 'rame.item'
local UrlMatch = require 'rame.urlmatch'

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
	settings = {
		autoplayUsb = false,
	},
	system = {
		ip = push.property("0.0.0.0", "Current IP-address"),
		hostname = push.property("", "hostname"),
		reboot_required = push.property(false, "Reboot required"),
		update_available = push.property(false, "Update available"),
		firmware_upgrade = push.property(nil, "Firmware upgrade progress"),
		headphone_volume = push.property(100, "Headphone volume"),
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
	root = Item.new_list{id="root", title="Root"},
	rame = Item.new_list{id="rame", filename="rame", title="RAME"},
	default = Item.new_list{id="default", title="Default playlist", editable=true},
	rest = {},
	plugins = {},

	idle_uri = nil,
	idle_controls = {
		cond = condition.new(),
	},
	wait_controls = {},
	players = UrlMatch.new(),
}

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

				print(("Plugin %s: %s"):format(f, act and "loaded" or "not active: "..(err or "disabled")))
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
			self.player.control.stop()
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

	if command == "autoplay" or command == "play" then
		print("Player: sending " .. command .. " command, cursor " .. self.player.cursor())
		self.player.__autoplay = (command == "autoplay")
		self.player.__playing = true
		if pos and pos < 0 then self.player.__wait = -pos end
		-- This kills the idle player to wake up idle thread
		if self.player.control and self.player.control.stop then
			self.player.control.stop()
		end
	end

	return 200
end

function RAME.idle_controls.play()
	RAME.idle_controls.cond:wait()
end

function RAME.idle_controls.stop()
	RAME.idle_controls.cond:signal()
end

function RAME.wait_controls.pause()
	RAME.player.status((RAME.player.status() == "waiting") and "paused" or "waiting")
	return true
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

function RAME.main()
	local self = RAME
	self.player.cursor:push_to(on_cursor_change)
	cqueues.running():wrap(Item.scanner)

	while true do
		-- Start process matching current state
		local move_next = true
		local item = Item.find(self.player.cursor())
		self.player.position(0)
		self.player.duration(0)

		-- item or idle url to play?
		local uri, control
		if item and self.player.__playing then
			uri = item.uri
			control = RAME.players:resolve(uri)
			self.player.status("buffering")
		else
			uri = self.idle_uri
			control = RAME.players:resolve(uri)
			       or RAME.idle_controls
			self.player.__wait = nil
			self.player.status("stopped")
		end

		if control and self.player.__playing and self.player.__wait then
			self.player.status("waiting")
			self.player.control = self.wait_controls
			while self.player.__playing and self.player.__wait > 0 do
				self.player.position(-self.player.__wait)
				local d = math.min(0.1, self.player.__wait)
				cqueues.sleep(d)
				if self.player.status() == "waiting" then
					self.player.__wait = self.player.__wait - d
				end
			end
			self.player.control = nil
			self.player.__wait = nil

			-- stopped while waiting?
			if not self.player.__playing then
				control = nil
				move_next = false
			end
		end

		if control then
			print("Playing", uri, control, item)
			self.player.control = control
			move_next = RAME.player.control.play(uri)
			self.player.control = nil
			print("Stopped", uri)
		end

		-- Move cursor to next item if playback stopped normally
		if item and move_next then
			item = item:navigate()
			self.player.cursor(item.id)
			self.player.__playing = self.player.__autoplay
		end
	end
end

function RAME.read_settings_file(file)
	return plfile.read(RAME.config.settings_path..file)
end

function RAME.write_settings_file(file, data)
	process.run("mount", "-o", "remount,rw", "/media/mmcblk0p1")
	pldir.makepath(RAME.config.settings_path)
	local ok = plfile.write(RAME.config.settings_path..file, data)
	process.run("mount", "-o", "remount,ro", "/media/mmcblk0p1")
	return ok
end

function RAME.commit_overlay()
	process.run("lbu", "commit", "-d")
	return true
end

return RAME
