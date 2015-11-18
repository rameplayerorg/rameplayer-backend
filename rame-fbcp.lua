local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local process = require 'cqp.process'

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
	--S:0(no space), 1(empty), 2(play), 3(pause), 4(stopped)
	--T:a,b
	--X[12]:text
	--P:0-1000 (progress)
	local statmap = {
		stopped = 4,
		playing = 2,
		paused = 3,
	}
	local out = process.popenw(fbcputil)
	while true do
		if RAME.status.position and RAME.status.position > 0.001 then
			out:write(("S:%d\n"):format(statmap[RAME.status.state] or 1))
			out:write(("X1:%s\n"):format(RAME.status.media.filename or ""))
			if RAME.status.media.duration and RAME.status.media.duration > 0.001 then
				out:write(("T:%.0f,%.0f\n"):format(RAME.status.position * 1000, RAME.status.media.duration * 1000))
				out:write(("P:%.0f\n"):format(RAME.status.position / RAME.status.media.duration * 1000))
			else
				out:write(("T:%.0f\nP:0\n"):format(RAME.status.position * 1000))
			end
		else
			out:write(("S:0\nX1:IP %s\nX2:\nP:0\n"):format(RAME.ip or "(none)"))
		end
		cqueues.poll(0.2)
	end
end

return Plugin
