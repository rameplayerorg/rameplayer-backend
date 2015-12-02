local plpath = require 'pl.path'
local cqueues = require 'cqueues'
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
		local status = RAME.player.status()
		local status_id = statmap[status] or 0
		out:write(("S:%d\n"):format(status_id))

		if status_id > 0 then
			--out:write(("X1:%s\n"):format(RAME.status.media.filename or ""))
			local position = RAME.player.position()
			local duration = RAME.player.duration()
			if duration > 0 then
				out:write(("T:%.0f,%.0f\n"):format(position * 1000, duration * 1000))
				out:write(("P:%.0f\n"):format(position / duration * 1000))
			else
				out:write(("T:%.0f\nP:0\n"):format(position * 1000))
			end
		else
			out:write(("S:0\nX1:IP %s\nX2:\nP:0\n"):format(RAME.system.ip()))
		end

		cqueues.poll(0.2)
	end
end

return Plugin
