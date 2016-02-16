local plfile = require 'pl.file'
local plpath = require 'pl.path'
local pldir = require "pl.dir"
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local Plugin = {}

-- todo:
-- move write_file_sd to onw lua module so that it can be reused

-- note errorhandling: if rw mount fails the file write fails so no need
-- check will the mount fail or not
function write_file_sd(file, data)
	process.run("mount", "-o", "remount,rw", "/media/mmcblk0p1")
	plfile.write(file, data)
	process.run("mount", "-o", "remount,ro", "/media/mmcblk0p1")
end

function Plugin.init()
	local config = RAME.config.settings_path.."ramehw.txt"

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

	local oldcfg = plfile.read(config)
	local newcfg = table.concat(ramehw, "\n").."\n"
	if oldcfg == newcfg then return end

	write_file_sd(config, newcfg)
	-- automatic reboot here
	--process.run("reboot", "now")
	-- Signal the user that reboot is required
	RAME.system.reboot_required(true)
end

return Plugin
