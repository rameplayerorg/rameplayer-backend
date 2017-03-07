local plfile = require 'pl.file'
local plpath = require 'pl.path'
local pldir = require "pl.dir"
local plutils = require "pl.utils"
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local ramehw_txt = "ramehw.txt"
local Plugin = {}

function Plugin.init()
	local updated = false
	local auto_reboot = false
	local ramehw = plutils.readlines(RAME.config.settings_path..ramehw_txt) or {}
	if next(ramehw) == nil then
		auto_reboot = true
		table.insert(ramehw, "# NOTE: This file is auto-updated")
	end

	if plpath.exists("/proc/device-tree/rame/eeprom-cids") then
		local cids, cid = {}
		local str = plfile.read("/proc/device-tree/rame/eeprom-cids") or ""

		-- extract numbers from string into table
		for cid in str:gmatch("%d+") do cids[cid] = true end

		-- find matches between eeprom cids and available rame dtb overlays
		for _, file in ipairs(pldir.getfiles("/media/mmcblk0p1/overlays", "*rame-cid*.dtbo")) do
			if cids[file:match(".*rame%-cid(%d+).*")] then
				-- found overlay for cid, check if its dtb is already in ramehw
				local dtoverlay_entry = "dtoverlay=" ..
					file:match(".*(rame%-cid%d+[^.]+).*")
				local exists = false
				for _, ramehw_row in pairs(ramehw) do
					if ramehw_row == dtoverlay_entry then
						exists = true
					end
				end
				if not exists then
					table.insert(ramehw, dtoverlay_entry)
					updated = true
				end
			end
		end
	end

	if updated then
		local newcfg = table.concat(ramehw, "\n").."\n"
		RAME.write_settings_file(ramehw_txt, newcfg)
		if auto_reboot then
			RAME.reboot_device()
		else
			-- Signal the user that reboot is required
			RAME.system.reboot_required(true)
		end
	end
end

return Plugin
