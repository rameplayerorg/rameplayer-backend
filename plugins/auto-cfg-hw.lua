local plfile = require 'pl.file'
local plpath = require 'pl.path'
local pldir = require "pl.dir"
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local ramehw_txt = "ramehw.txt"
local Plugin = {}

function Plugin.init()
	local ramehw = {}
	if plpath.exists("/proc/device-tree/rame/eeprom-cids") then
		local cids, cid = {}
		local str = plfile.read("/proc/device-tree/rame/eeprom-cids") or ""

		-- extract numbers from string into table
		for cid in str:gmatch("%d+") do cids[cid] = true end

		-- replace dts with correct dir
		for _, file in ipairs(pldir.getfiles("/media/mmcblk0p1/overlays", "rame-cid*.dtb")) do
			if cids[file:match("rame%-cid(%d)")] then
				table.insert(ramehw, "dtoverlay=" ..
					file:match("(rame%-cid%d[^.]+)"))
			end
		end
	else
		--print("no eeprom-cids found")
		table.insert(ramehw, "# No additional HW components detected")
	end

	local oldcfg = RAME.read_settings_file(ramehw_txt)
	local newcfg = table.concat(ramehw, "\n").."\n"
	if oldcfg == newcfg then return end

	RAME.write_settings_file(ramehw_txt, newcfg)
	-- automatic reboot here
	--process.run("reboot", "now")
	-- Signal the user that reboot is required
	RAME.system.reboot_required(true)
end

return Plugin
