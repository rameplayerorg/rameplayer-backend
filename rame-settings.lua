-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local plfile = require 'pl.file'
local plutils = require 'pl.utils'
local plconfig = require "pl.config"
local plpath = require 'pl.path'
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

-- 1st tries to REPLACE existing string(s) if no match APPENDS string
-- if replace = "" erases matching string entry
-- if match1 = is whatever that doesn't match adds an entry
local function update(txt, replace, match1, match2)
	-- lua doesn't have optional group patterns so have to do with try-err
	txt, i = txt:gsub(match1, replace)
	if i == 0 and match2 then txt, i = txt:gsub(match2, replace) end

	-- if replace string is empty i.e. "" doesn't APPEND because it was removal
	if i == 0 and replace ~= "" then txt = txt .. replace .. "\n" end
	return txt
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

local function activate_config(conf)
	RAME.config.omxplayer_audio_out = omxplayer_audio_outs[conf.audioPort]
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
		ipDhcpClient = true,
	}

	local usercfg = plutils.readlines(RAME.config.settings_path.."usercfg.txt")
	for _, val in ipairs(usercfg or {}) do
		if val ~= "" and rpi_resolutions_rev[val] then
			conf.resolution = rpi_resolutions_rev[val]
		end
		if rpi_audio_ports_rev[val] then
			conf.audioPort = rpi_audio_ports_rev[val]
		end
	end

	local dhcpcd = plconfig.read("/etc/dhcpcd.conf", {list_delim=' '})
	for i, v in pairs(dhcpcd or {}) do
		if i == "static_ip_address" then
			local ip, cidr = v:match("(%d+.%d+.%d+.%d+)/(%d+)")
			conf.ipAddress = ip
			conf.ipSubnetMask = ipv4_masks[cidr]
			-- if static address found setting the DHCP client to false
			conf.ipDhcpClient = false
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
	local args = ctx.args
	local err, msg, i, str

	err, msg = check_fields(args, {"resolution", "audioPort", "ipDhcpClient"})
	if err then return err, msg end

	local rpi_resolution = rpi_resolutions[args.resolution]
	if not rpi_resolution then return 422, "invalid resolution" end

	local rpi_audio_port = rpi_audio_ports[args.audioPort]
	if not rpi_audio_port then return 422, "invalid audioPort" end

	-- Read existing usercfg.txt
	local usercfg = plfile.read(RAME.config.settings_path.."usercfg.txt")
	if not usercfg then return 500, "file read failed" end

	usercfg = update(usercfg, "hdmi_group=1", "hdmi_group=1")
	usercfg = update(usercfg, rpi_resolution, "hdmi_mode=%d+")
	usercfg = update(usercfg, rpi_audio_port, "hdmi_drive=%d #both",
						  "hdmi_drive=%d")

	-- Read existing configuration
	local dhcpcd = plfile.read("/etc/dhcpcd.conf")
	if not dhcpcd then return 500, "file read failed" end

	if args.ipDhcpClient == false then
		err, msg = check_fields(args, {"ipAddress", "ipSubnetMask", "ipDefaultGateway", "ipDnsPrimary", "ipDnsSecondary", "ipDhcpServer"})
		if err then return err, msg end

		str = ipv4_masks_rev[args.ipSubnetMask]
		if not str then return 422, "invalid subnet mask" end

		dhcpcd = update(dhcpcd, "static ip_address="..args.ipAddress.."/"..str,
						"static ip_address=%d+.%d+.%d+.%d+/%d+")
		dhcpcd = update(dhcpcd, "static routers=" .. args.ipDefaultGateway,
						"static routers=%d+.%d+.%d+.%d+")
		dhcpcd = update(dhcpcd, "static domain_name_servers="
				 .. args.ipDnsPrimary .. " " .. args.ipDnsSecondary,
				 "static domain_name_servers=%d+.%d+.%d+.%d+%s?%d+.%d+.%d+.%d+",
				 "static domain_name_servers=%d+.%d+.%d+.%d+%s?")
		if args.ipDchpServer == true then
			-- DHCP SERVER in used
		end
	else -- clearing the possible static IP configuration lines
		dhcpcd = update(dhcpcd, "", "static ip_address=%d+.%d+.%d+.%d+/%d+\n")
		dhcpcd = update(dhcpcd, "", "static routers=%d+.%d+.%d+.%d+\n")
		dhcpcd = update(dhcpcd, "",
			"static domain_name_servers=%d+.%d+.%d+.%d+%s?%d+.%d+.%d+.%d+\n",
 			"static domain_name_servers=%d+.%d+.%d+.%d+%s?\n")
	end

	if not write_file_lbu("/etc/dhcpcd.conf", dhcpcd) or
	   not write_file_sd(RAME.config.settings_path.."usercfg.txt", usercfg) then
		return 500, "file write error"
	end

	activate_config(args)
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
	local ok, conf = SETTINGS.GET.system()
	if ok == 200 then activate_config(conf) end

	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, SETTINGS) end
	RAME.rest.version = function(ctx, reply) return ctx:route(reply, VERSION) end
end

return Plugin
