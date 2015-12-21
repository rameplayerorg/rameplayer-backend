local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local process = require 'cqp.process'
local RAME = require 'rame'

local fbcputil = "/usr/bin/ramefbcp"
local Plugin = {}

function Plugin.active()
	if not plpath.isfile(fbcputil) then
		return nil, fbcputil.." not found"
	end
	if not plpath.exists("/dev/fb1") then
		return nil, "/dev/fb1 not found"
	end
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

	--S:0(no space), 1(empty), 2(play), 3(pause), 4(stopped), 5(buffering)
	--T:a,b
	--X[12]:text
	--P:0-1000 (progress)
	local statmap = {
		playing = 2,
		paused = 3,
		buffering = 5,
	}
	local out = process.popenw(fbcputil)
	while true do
		pending = false

		local status = RAME.player.status()
		local status_id = statmap[status] or 0
		out:write(("S:%d\n"):format(status_id))

		local item = RAME:get_item(RAME.player.cursor())
		local filename = item and item.meta.filename or ""

		if status_id > 0 then
			out:write(("X1:%s\n"):format(filename))
			local position = RAME.player.position()
			local duration = RAME.player.duration()
			if duration > 0 then
				out:write(("T:%.0f,%.0f\n"):format(position * 1000, duration * 1000))
				out:write(("P:%.0f\n"):format(position / duration * 1000))
			else
				out:write(("T:%.0f\nP:0\n"):format(position * 1000))
			end
		else
			out:write(("S:0\nX1:%s\nX2:IP %s\nP:0\n"):format(filename, RAME.system.ip()))
		end

		if not pending then cond:wait() end
		-- Aggregate further changes before updating the screen
		cqueues.poll(0.01)
	end
end

return Plugin
