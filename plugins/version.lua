local plfile = require 'pl.file'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
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
	local str, addon_board_name, addon_board_id, addon_board_ver
	local base_board_name = plfile.read("/sys/firmware/devicetree/base/model"):sub(1, -2) or ""

	if plpath.exists("/proc/device-tree/rame/product")
	  and plpath.exists("/proc/device-tree/rame/product_ver")
 	  and plpath.exists("/proc/device-tree/rame/product_id") then
		addon_board = plfile.read("/proc/device-tree/rame/product"):match("[^\n]+") or ""
		addon_board_id = plfile.read("product_id"):match("[^\n]+") or ""
		addon_board_ver = plfile.read("/proc/device-tree/rame/product_ver"):match("[^\n]+") or ""
		RAME.version.hardware(base_board_name.." "..addon_board_name.." "..addon_board_id
							  .." ("..addon_board_ver..")")
	else
		RAME.version.hardware(base_board_name)
	end

	if plpath.exists("/proc/device-tree/rame/") then
  		local rame_hw_id = 0
		-- find loaded rame dtb overlays
		for _, file in ipairs(pldir.getfiles("rame", "cid*")) do
			print(file)
			for cid in file:gmatch("%d+") do rame_hw_id = rame_hw_id + (1 << (cid - 1)) end
			print("rame_hw_id", rame_hw_id)
		end

		print("rame_hw_id", rame_hw_id)
	end

	-- RAME.version.backend is set on build script
	local firmware = plfile.read("/media/mmcblk0p1/rameversion.txt") or ""
	RAME.version.firmware(firmware:match("[^\n]+"))

	RAME.rest.version = function(ctx, reply) return ctx:route(reply, VERSION) end
end

return Plugin
