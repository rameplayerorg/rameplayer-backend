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
	local status = plfile.write(file, data)
	process.run("mount", "-o", "remount,ro", "/media/mmcblk0p1")

	if not status then return nil, "file write failed" else return end
end

-- one time (1st boot) operation only
function Plugin.init()
	if not plpath.exists(RAME.config.settings_path.."ramehw.txt") then
		local ramehw = {}

		if plpath.exists("/proc/device-tree/rame/eeprom-cids") then
			local str, cid
			local cids = {}
	 		str = plfile.read("/proc/device-tree/rame/eeprom-cids")

			-- extract numbers from string into array
	 		for cid in str:gmatch("%d+") do cids[#cids+1] = cid end

			-- replace dts with correct dir
			for _, _, files in pldir.walk("/media/mmcblk0p1/overlays") do
				for i, val in pairs(files) do
					for _, val2 in pairs(cids) do
						if val2 == val:match("rame%-cid(%d)") then
							--print(i, val)
							table.insert(ramehw, "dtoverlay=" ..
										val:match("(rame%-cid%d[^.]+)"))
						end
					end
				end
			end
		else
			--print("no eeprom-cids found")
			table.insert(ramehw, "#No additional HW components detected")
		end

		if write_file_sd(RAME.config.settings_path.."ramehw.txt",
			table.concat(ramehw, "\n")) then
			-- automatic reboot here
			--process.run("reboot", "now")
			-- Signal the user that reboot is required
			RAME.system.reboot_required(true)
		end
	end
end

return Plugin
