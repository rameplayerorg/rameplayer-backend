local plfile = require 'pl.file'
local RAME = require 'rame.rame'

-- REST API: /version/
local VERSION = { GET = {} }

function VERSION.GET(ctx, reply)
	return 200, {
		hw = RAME.version.hardware(),
		backend = RAME.version.backend(),
		firmware = RAME.version.firmware(),
	}
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	local hw = plfile.read("/sys/firmware/devicetree/base/model") or ""
	RAME.version.hardware(hw:sub(1, -2))
	-- RAME.version.backend is set on build script
	local firmware = plfile.read("/media/mmcblk0p1/rameversion.txt") or ""
	RAME.version.firmware(firmware:match("[^\n]+"))

	RAME.rest.version = function(ctx, reply) return ctx:route(reply, VERSION) end
end

return Plugin
