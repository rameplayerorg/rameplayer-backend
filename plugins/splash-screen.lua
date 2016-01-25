local plfile = require 'pl.file'
local plpath = require 'pl.path'

local Plugin = { }
function Plugin.early_init()
	local splashctrl = "/.splash.ctrl"
	local fbdev = "/dev/fb0"

	if not plpath.exists(splashctrl) then return end

	plfile.write(splashctrl, "quit")
	plfile.delete(splashctrl)
	if plpath.exists(fbdev) then
		plfile.write(fbdev, string.char(0):rep(1024*2700))
	end
end

return Plugin
