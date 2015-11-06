local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local process = require 'cqp.process'

local Plugin = {}

function Plugin.active()
	if not plpath.isfile("/usr/local/bin/fbcp") then
		return nil, "fbcp not found"
	end
	if not plpath.exists("/dev/fb1") then
		return nil, "/dev/fb1 not found"
	end
	return true
end

function Plugin.main()
	while true do
		process.run("fbcp")
		cqueues.poll(1)
	end
end

return Plugin
