local plfile = require 'pl.file'
local plpath = require 'pl.path'

local splashctrl = "/.splash.ctrl"
local fbdev = "/dev/fb0"

local Plugin = { }

function Plugin.active()
	return plpath.exists(splashctrl), "fbsplash not present"
end

function Plugin.early_init()
	if plpath.exists(splashctrl) then
		plfile.write(splashctrl, "quit")
		plfile.delete(splashctrl)
	end
	if plpath.exists(fbdev) then
		local f = io.open(fbdev, "w")
		if f then
			local zeros = string.char(0):rep(4*1024)
			while f:write(zeros) do end
			f:close()
		end
	end
end

return Plugin
