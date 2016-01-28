local cqueues = require 'cqueues'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local push = require 'cqp.push'
local process = require 'cqp.process'
local Item = require 'rame.item'
local UrlMatch = require 'rame.urlmatch'

local RAME = {
	version = "development",
	running = true,
	config = {
		settings_path = "/media/mmcblk0p1/",
		omxplayer_audio_out = "hdmi",
	},
	system = {
		ip = push.property("0.0.0.0", "Current IP-address"),
		reboot_required = push.property(false, "Reboot required"),
		update_available = push.property(false, "Update available"),
	},
	player = {
		status   = push.property("stopped", "Playback status"),
		cursor   = push.property("", "Active media"),
		position = push.property(0, "Active media play position"),
		duration = push.property(0, "Active media duration"),
	},
	root = Item.new_list{id="root", title="Root"},
	default = Item.new_list{id="default", title="Default playlist", editable=true},
	rest = {},
	plugins = {},

	idleplayer = { rametext = plpath.exists("/usr/bin/rametext") },
	players = UrlMatch.new(),
}

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

function RAME:__trigger(item_id, autoplay)
	print("Player: requested to play: " .. item_id)
	self.player.__next_item_id = item_id
	self.player.__autoplay = autoplay and true or false
	self.player.__trigger = -1
	self.player.control.stop()
	return true
end

function RAME:set_cursor(id)
	self:__trigger(id, true)
end

function RAME:action(id, autoplay)
	self:__trigger(id, autoplay)
end

function RAME.idleplayer.play()
	local self = RAME.idleplayer
	local text = ""
	if not RAME.config.second_display then
		local ip = RAME.system.ip()
		text = ip ~= "0.0.0.0" and ip or "No Media"
	end
	if self.rametext then
		self.proc = process.spawn("rametext", text)
	else
		self.proc = process.spawn("sleep", "1000")
	end
	self.proc:wait()
	self.proc = nil
end

function RAME.idleplayer.stop()
	local self = RAME.idleplayer
	if self.proc then
		self.proc:kill(9)
	end
end

function RAME.main()
	local self = RAME
	cqueues.running():wrap(Item.scanner)
	self.system.ip:push_to(function()
		-- Refresh text if IP changes and not playing.
		-- Perhaps later rametext can be updated to get text
		-- updates via stdin or similar.
		if self.player.control == RAME.idleplayer then
			self.player.control.stop()
		end
	end)

	while true do
		-- If cursor changed or play/stop requested
		local play_requested, wrapped = false, false
		local cursor_id  = self.player.cursor()
		local request_id = self.player.__next_item_id or "next"
		local item

		if request_id == "next" or request_id == "prev" then
			item, cursor_id = Item.find(cursor_id), nil
			if item then
				item, wrapped = item:navigate(request_id == "prev")
				cursor_id = item.id
				play_requested = self.player.__autoplay
			end
			if wrapped then
				local r = RAME.player.__repeat or 0
				play_requested = r ~= 0 and play_requested
				if r >= 1 then
					self.player.__repeat = r - 1
				end
			end
		elseif request_id == "stop" then
			play_requested = false
		elseif request_id == "play" then
			item = Item.find(cursor_id)
			play_requested = true
		else
			cursor_id = request_id
			item = Item.find(cursor_id)
			play_requested = self.player.__autoplay
		end

		-- Start process matching current state
		print("Play", cursor_id, item)
		self.player.__next_item_id = nil
		self.player.cursor(cursor_id)
		self.player.position(0)
		self.player.duration(0)

		local uri = item and item.uri
		if uri or not play_requested then
			if play_requested then
				item.on_delete = function() return RAME:__trigger("") end
				self.player.status("buffering")
				RAME.player.control = RAME.players:resolve(item.uri)
			else
				self.player.status("stopped")
				RAME.player.control = RAME.idleplayer
			end
			print("Playing", uri)
			RAME.player.control.play(uri)
			RAME.player.control = nil
			print("Stopped", uri)
			if item then item.on_delete = nil end
		end
	end
end

return RAME
