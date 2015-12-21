-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local plfile = require 'pl.file'
local plutils = require 'pl.utils'
local plconfig = require "pl.config"
local process = require 'cqp.process'
local RAME = require 'rame'

local function revtable(tbl)
	local rev={}
	for k, v in pairs(tbl) do rev[v] = k end
	return rev
end

--  valid IPv4 subnet masks
local ipv4_masks = {
	"128.0.0.0", "192.0.0.0", "224.0.0.0", "240.0.0.0",
	"248.0.0.0", "252.0.0.0", "254.0.0.0", "255.0.0.0",
	"255.128.0.0", "255.192.0.0", "255.224.0.0", "255.240.0.0",
	"225.248.0.0", "255.252.0.0", "255.254.0.0", "255.255.0.0",
	"255.255.128.0", "255.255.192.0", "255.255.224.0", "255.255.240.0",
	"225.255.248.0", "255.255.252.0", "255.255.254.0", "255.255.255.0",
	"255.255.255.128", "255.255.255.192", "255.255.255.224", "255.255.255.240",
	"225.255.255.248", "255.255.255.252", "255.255.255.254", "255.255.255.255"
}
local ipv4_masks_rev = revtable(ipv4_masks)

-- supported (selection) resolutions on RPi
local rpi_resolutions = {
	rameAutodetect = "",
	rame720p50 = "hdmi_mode=19",
	rame720p60 = "hdmi_mode=4",
	rame1080i50 = "hdmi_mode=20",
	rame1080i60 = "hdmi_mode=5",
	rame1080p50 = "hdmi_mode=31",
	rame1080p60 = "hdmi_mode=16",
}
local rpi_resolutions_rev = revtable(rpi_resolutions)

local rpi_audio_ports = {
	rameAnalogOnly = "hdmi_drive=1",
	rameHdmiOnly =  "hdmi_drive=2",
	rameHdmiAndAnalog = "hdmi_drive=2 #both",
}
local rpi_audio_ports_rev = revtable(rpi_audio_ports)

local omxplayer_audio_outs = {
	rameAnalogOnly = "local",
	rameHdmiOnly = "hdmi",
	rameHdmiAndAnalog = "both",
}

local function check_fields(data, schema)
	for _, field in ipairs(schema) do
		if not data[field] == nil then
			return 422, "missing required parameter: "..field
		end
	end
end

function read_json(file)
	local data = plfile.read(file)
	return data and 200 or 500, data
end

function write_json(file, data)
	if not data then return 500, "no arguments" end
	return write_file_sd(file, json.encode(data))
end

-- note errorhandling: if rw mount fails the file write fails so no need
-- check will the mount fails or not
function write_file_sd(file, data)
	process.run("mount", "-o", "remount,rw", "/media/mmcblk0p1")
	local status = plfile.write(file, data)
	process.run("mount", "-o", "remount,ro", "/media/mmcblk0p1")

	if not status then return 500, "file write failed" else return 200 end
end

-- todo check the process command output
function write_file_lbu(file, data)
	local status = plfile.write(file, data)
	if not status then return 500, "file write failed" end

	process.run("lbu", "commit")
	return 200
end

-- REST API: /settings/
local SETTINGS = { GET = {}, POST = {} }

function SETTINGS.GET.user(ctx, reply)
	return read_json(RAME.config.settings_path.."settings-user.json")
end

function SETTINGS.POST.user(ctx, reply)
	return write_json(RAME.config.settings_path.."settings-user.json", ctx.args)
end

function SETTINGS.GET.system(ctx, reply)
	local conf = {
		-- Defaults if not found from config files
		resolution = "rameAutodetect",
		audioPort = "rameAnalogOnly",
	}

	local usercfg_lines = plutils.readlines(RAME.config.settings_path.."usercfg.txt")
	if not usercfg_lines then return 500, "file read failed" end

	for _, val in ipairs(usercfg_lines) do
		if val ~= "" and rpi_resolutions_rev[val] then
			conf.resolution = rpi_resolutions_rev[val]
		end
		if rpi_audio_ports_rev[val] then
			conf.audioPort = rpi_audio_ports_rev[val]
			RAME.config.omxplayer_audio_out = omxplayer_audio_outs[conf.audioPort]
		end
	end

	local dhcpcd_lines = plconfig.read("/etc/dhcpcd.conf", {list_delim=' '})
	if not dhcpcd_lines then return 500, "file read failed" end

	for i, v in pairs(dhcpcd_lines) do
		if i == "static_ip_address" then
			local ip, cidr = v:match("(%d+.%d+.%d+.%d+)/(%d+)")
			conf.ipAddress = ip
			conf.ipSubnetMask = ipv4_masks[cidr]
		elseif i == "static_routers" then
			conf.ipDefaultGateway = v
		elseif i == "static_domain_name_servers" then
			if #v then
				-- there is length in array so array exists
				-- (and it must have at least 2 entries to be array)
				conf.ipDnsPrimary = v[1]
				conf.ipDnsSecondary = v[2]
			else
				conf.ipDnsPrimary = v
			end
		end
	end

	return 200, conf
end

-- todo add support for IP settings
-- these settings require reboot which is not implemented
function SETTINGS.POST.system(ctx, reply)
	local usercfg = { "hdmi_group=1" }
	local args = ctx.args
	local err, msg, i, str, temp

	err, msg = check_fields(args, {"resolution", "audioPort", "ipDhcpClient"})
	if err then return err, msg end

	local rpi_resolution = rpi_resolutions[args.resolution]
	if not rpi_resolution then return 422, "invalid resolution" end
	table.insert(usercfg, rpi_resolution)

	local rpi_audio_port = rpi_audio_ports[args.audioPort]
	if not rpi_audio_port then return 422, "invalid audioPort" end
	table.insert(usercfg, rpi_audio_port)
	RAME.config.omxplayer_audio_out = omxplayer_audio_outs[args.audioPort]

	-- Read existing configuration
	local dhcpcd = plfile.read("/etc/dhcpcd.conf")
	if not dhcpcd then return 500, "file read failed" end

	if args.ipDhcpClient == false then
		err, msg = check_fields(args, {"ipAddress", "ipSubnetMask", "ipDefaultGateway", "ipDnsPrimary", "ipDnsSecondary", "ipDhcpServer"})
		if err then return err, msg end

		temp = ipv4_masks_rev[args.ipSubnetMask]
		if not temp then return 422, "invalid subnet mask" end
		str = "static ip_address=" .. args.ipAddress .. "/" .. temp
		-- try REPLACING the config
		dhcpcd, i = dhcpcd:gsub("static ip_address=%d+.%d+.%d+.%d+/%d+", str)
		-- if no match APPENDING config
		if i == 0 then dhcpcd = dhcpcd .. str .. "\n" end

		str = "static routers=" .. args.ipDefaultGateway
		dhcpcd, i = dhcpcd:gsub("static routers=%d+.%d+.%d+.%d+", str)
		if i == 0 then dhcpcd = dhcpcd .. str .. "\n" end

		str = "static domain_name_servers=" .. args.ipDnsPrimary .. " "
			  .. args.ipDnsSecondary
		-- lua doesn't have optional group patterns so have to do with try-err:
		--1st matching with 2 IP address and if not matching then try with 1 IP addr
		dhcpcd, i = dhcpcd:gsub("static domain_name_servers=%d+.%d+.%d+.%d+%s?%d+.%d+.%d+.%d+",
					str)
		if i == 0 then
			dhcpcd, i = dhcpcd:gsub("static domain_name_servers=%d+.%d+.%d+.%d+%s?",
					    str)
			if i == 0 then dhcpcd = dhcpcd .. str .. "\n" end
		end

		if args.ipDchpServer == true then
			-- DHCP SERVER in used
		end
	else -- clearing the possible static IP configuration lines
		dhcpcd, i = dhcpcd:gsub("static ip_address=%d+.%d+.%d+.%d+/%d+\n", "")
		dhcpcd, i = dhcpcd:gsub("static routers=%d+.%d+.%d+.%d+\n", "")
		dhcpcd, i = dhcpcd:gsub("static domain_name_servers=%d+.%d+.%d+.%d+%s?%d+.%d+.%d+.%d+\n", "")
		if i == 0 then
			dhcpcd, i = dhcpcd:gsub("static domain_name_servers=%d+.%d+.%d+.%d+%s?\n", "")
		end
	end

	if not write_file_lbu("/etc/dhcpcd.conf", dhcpcd) or
	   not write_file_sd(RAME.config.settings_path.."usercfg.txt", table.concat(usercfg, "\n")) then
		return 500, "file write error"
	end

	return 200
end

-- REST API: /version/
local VERSION = {}

function VERSION.GET(ctx, reply)
	local hw = plfile.read("/sys/firmware/devicetree/base/model") or ""
	return 200, {
		hw = hw:sub(1, -2),
		backend = RAME.version,
	}
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	SETTINGS.GET.system()
	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, SETTINGS) end
	RAME.rest.version = function(ctx, reply) return ctx:route(reply, VERSION) end
end

return Plugin
