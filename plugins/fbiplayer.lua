local plpath = require 'pl.path'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local Plugin = {
	control = {
		cond = condition.new(),
	}
}

function Plugin.control.play(uri, mode, initpos)
	local filename, chapter_id = RAME.resolve_uri(uri)
	process.run("fbi", "-noverbose", "-autozoom", "-1", "-t", "1", filename)
	RAME.player.status("playing")
	Plugin.control.cond:wait()
	process.run("sh", "-c", "cat /dev/zero > /dev/fb0")
	return true
end

function Plugin.control.stop()
	Plugin.control.cond:signal()
end

function Plugin.active()
	return plpath.isfile("/usr/bin/fbi"), "fbi not found"
end

function Plugin.early_init()
	local exts = { "gif", "jpg", "jpeg", "png", "tif", "tiff" }
	RAME.players:register("file", exts, 10, Plugin.control)
end

return Plugin
