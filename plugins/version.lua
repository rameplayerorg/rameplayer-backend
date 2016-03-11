local plfile = require 'pl.file'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local RAME = require 'rame.rame'

-- REST API: /version/
local VERSION = { GET = {} }

function VERSION.GET(ctx, reply)
	return 200, {
		hw = RAME.version.hardware(),
		hwAddon = RAME.version.hardware_addon(),
		hwCfg = RAME.version.hardware_cfg(),
		backend = RAME.version.backend(),
		firmware = RAME.version.firmware(),
	}
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	local hat_path = "/proc/device-tree/hat/"
	local rame_cfg_path = "/proc/device-tree/rame/"
	local fw_ver_path = "/media/mmcblk0p1/rameversion.txt"

	-- e.g. "Raspberry Pi 2 Model B Rev 1.1" (cleartext hardware model)
	local hw_base = ""
	-- e.g. "a01041" (hardware revision from /proc/cpuinfo)
	local hw_revision = ""

	-- under hat_path:
	-- e.g.: "RamePlayer", "0x0001", "0x0002", "00000000-0000-0000-0000-000000000000"
	local addon_board_name, addon_board_id, addon_board_ver, addon_board_uuid = "","","",""
	local hw_addon_info = ""

	-- under rame_cfg_path:
	-- e.g.: "3,4,5,6" (effective), "3,4,5,6" (eeprom info), "RamePlayer chassis 1.0"
	local rame_cfg_cids, rame_cfg_eeprom_cids, rame_cfg_hardware = "","",""
	-- e.g.: 60 (effective), 60 (eeprom info) -- 60="3C" as hex string
	local rame_cfg_cids_id, rame_cfg_eeprom_cids_id = 0,0
	local rame_cfg_info = ""

	local hw_base_model = plfile.read("/sys/firmware/devicetree/base/model"):sub(1, -2) or ""
	--print("hw_base_model", hw_base_model)
	for rev in plfile.read("/proc/cpuinfo"):gmatch("Revision.-:%s*([^\n]+)") do
		hw_revision = rev
		--print("hw_revision", hw_revision)
	end
	hw_base = hw_base_model.." ("..hw_revision..")"

	if plpath.exists(hat_path.."product")
	  and plpath.exists(hat_path.."product_ver")
 	  and plpath.exists(hat_path.."product_id")
	  and plpath.exists(hat_path.."uuid") then
		addon_board_name = (plfile.read(hat_path.."product"):match("[^\n]+") or ""):sub(1, -2)
		addon_board_pid  = (plfile.read(hat_path.."product_id"):match("[^\n]+") or ""):sub(1, -2)
		addon_board_ver  = (plfile.read(hat_path.."product_ver"):match("[^\n]+") or ""):sub(1, -2)
		addon_board_uuid = (plfile.read(hat_path.."uuid"):match("[^\n]+") or ""):sub(1, -2)
		hw_addon_info =   addon_board_name..
		       " (p.id:"..addon_board_pid..
		          " v.:"..addon_board_ver..
		        " uuid:"..addon_board_uuid..")"
		print("hw_addon_info", hw_addon_info)
		hw_base = hw_base.." "..addon_board_name
	end

	print("hw_base", hw_base)

	if plpath.exists(rame_cfg_path) then
		local cids = {}
		-- find loaded rame device tree overlays
		for _, file in ipairs(pldir.getfiles(rame_cfg_path, "cid*")) do
			for cid in file:gmatch("cid(%d+)") do
				table.insert(cids, cid)
				rame_cfg_cids_id = rame_cfg_cids_id + (1 << (cid - 1))
			end
		end
		table.sort(cids)
		rame_cfg_cids = table.concat(cids, ",")
		--print("rame_cfg_cids", rame_cfg_cids)
		--print("rame_cfg_cids_id", rame_cfg_cids_id)

		if plpath.exists(rame_cfg_path.."eeprom-cids") then
			rame_cfg_eeprom_cids = plfile.read(rame_cfg_path.."eeprom-cids"):match("[^\n]+") or ""
		end
		--print("rame_cfg_eeprom_cids", rame_cfg_eeprom_cids)
		local eeprom_cids = {}
		for cid in rame_cfg_eeprom_cids:gmatch("%d+") do
			table.insert(eeprom_cids, cid)
			rame_cfg_eeprom_cids_id = rame_cfg_eeprom_cids_id + (1 << (cid - 1))
		end
		--print("rame_cfg_eeprom_cids_id", rame_cfg_eeprom_cids_id)

		if plpath.exists(rame_cfg_path.."hardware") then
			rame_cfg_hardware = plfile.read(rame_cfg_path.."hardware"):match("[^\n]+") or ""
		end
		--print("rame_cfg_hardware", rame_cfg_hardware)

		rame_cfg_info = ("id/cids=%X/%s id/eeprom_cids=%X/%s (%s)"):format(
			rame_cfg_cids_id, rame_cfg_cids,
			rame_cfg_eeprom_cids_id, rame_cfg_eeprom_cids,
			rame_cfg_hardware)
		print("rame_cfg_info", rame_cfg_info)
	end

	RAME.version.hardware(hw_base)
	RAME.version.hardware_addon(hw_addon_info)
	RAME.version.hardware_cfg(rame_cfg_info)

	-- RAME.version.backend is set on build script
	local firmware = "?"
	if plpath.exists(fw_ver_path) then
		firmware = plfile.read(fw_ver_path):match("[^\n]+") or "?"
	end
	RAME.version.firmware(firmware)

	local ver_short = ("%s/%X:%X,%s"):format(firmware, rame_cfg_cids_id,
	                                      rame_cfg_eeprom_cids_id, hw_revision)
	print("ver_short", ver_short)
	RAME.version.short(ver_short)

	RAME.rest.version = function(ctx, reply) return ctx:route(reply, VERSION) end
end

return Plugin
