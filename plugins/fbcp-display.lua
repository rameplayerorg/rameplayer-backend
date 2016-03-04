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
	RAME.localui.menu:push_to(update)

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
	while true do
		pending = false

		local status = RAME.player.status()
		local status_id = statmap[status] or 0
		local menu = RAME.localui.menu()
		local video_enabled = vidmap[status] or 0

		local turn_off_menu = false
		if menu then
			if video_enabled == 0 then
				-- In current placeholder implementation state, Rame menu
				-- button just blinks its led when video is not playing.
				turn_off_menu = true
			end

			video_enabled = 0
		end

		out:write(("S:%d\nV:%d\n"):format(status_id, video_enabled))

		local hostname = RAME.system.hostname() or nil
		if hostname then
			out:write(("X1:%s\n"):format(hostname))
		end
		out:write(("X2:IP %s\n"):format(RAME.system.ip()))

		local reboot_required = RAME.system.reboot_required() and true or nil
		if reboot_required then
			out:write("X4:‼ Restart Pending...\n")
		end

		local item = Item.find(RAME.player.cursor())
		local filename = item and item.filename or ""

		if status_id > 0 then
			out:write(("X6:%s\n"):format(filename))
			local position = math.abs(RAME.player.position())
			local duration = RAME.player.duration()
			if duration > 0 then
				out:write(("T:%.0f,%.0f\n"):format(position * 1000, duration * 1000))
				out:write(("P:%.0f\n"):format(position / duration * 1000))
			else
				out:write(("T:%.0f\nP:0\n"):format(position * 1000))
			end
		else
			out:write(("S:4\nX6:%s\nX7:\nP:0\n"):format(filename))
		end

		if turn_off_menu then
			cqueues.sleep(0.25)
			RAME.localui.menu(false)
		end

		if not pending then cond:wait() end
		-- Aggregate further changes before updating the screen
		cqueues.poll(0.01)
	end
end

return Plugin
