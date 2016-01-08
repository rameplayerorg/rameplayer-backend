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

-- gives first and last ip address in quadrant from given ip and cidr_mask
-- lua 5.3 code compatible only (bitwise operation)
function give_last_quadrant(ip_address, cidr_mask)
 	local quad = {}
	local net_addr = ""
	local broadcast_addr = ""
	local last_addr = ""
	local first_addr = ""
	local start_range, last_no, first_no

	-- Max number of host = 32bits (ipv4 lenght) - subnet mask prefix
	-- -2 reserved for network and broadcast addresses
	local max_amount_host = math.floor((2^(32-cidr_mask))-2)
	-- DEFAULTS to last quadrant (rounded) of IP address range
	local qrt_amount_hosts = math.floor(max_amount_host/4)
	-- give max. C-class range
	if qrt_amount_hosts > 254 then qrt_amount_hosts = 254 end

	local MSB = { 128, 192, 224, 240, 248, 252, 254 }
	local INV_HOST_MASK = { 127, 63, 31, 15, 7, 3, 1 }

 	-- extract numbers from dotted notation into table
 	for octet in ip_address:gmatch("%d+") do quad[#quad+1] = octet end

	for i=1, #quad do
		cidr_mask = cidr_mask - 8
		if cidr_mask >= 0 then
			net_addr = net_addr .. quad[i]
			broadcast_addr = broadcast_addr .. quad[i]
		elseif cidr_mask < 0 and cidr_mask > -8 then
			first_no = quad[i] & MSB[cidr_mask+8]
			last_no = quad[i] | INV_HOST_MASK[cidr_mask + 8]
			if i == #quad then -- last octet
				-- 1st usable address is network address + 1
				first_addr = net_addr .. (first_no + 1)
				-- Last usable address is broadcast address - 1
				last_addr = broadcast_addr .. (last_no - 1)
				start_range = broadcast_addr .. (last_no - qrt_amount_hosts)
			end
			net_addr = net_addr .. first_no
			broadcast_addr = broadcast_addr .. last_no
		else -- leftover octects are set to min and max values
			first_no = 0
			last_no = 255
			if i == #quad then -- last octet
				first_addr = net_addr .. (first_no + 1)
				last_addr = broadcast_addr .. (last_no - 1)
				start_range = broadcast_addr .. (last_no - qrt_amount_hosts)
			end
			net_addr = net_addr .. first_no
			broadcast_addr = broadcast_addr .. last_no
		end

		-- adding the dots in between
		if i < #quad then
			net_addr = net_addr .. "."
			broadcast_addr = broadcast_addr .. "."
		end
	end

	return start_range, last_addr
end

-- 1st tries to REPLACE existing string(s) if no match APPENDS string
-- if replace = "" erases matching string entry
-- if match = is whatever that doesn't match adds an entry
local function update(txt, match, replace)
	-- lua doesn't have optional group patterns so have to do with try-err
	txt, i = txt:gsub(match, replace)

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

	local hostname = plfile.read("/etc/hostname")
	if hostname then conf.hostname = hostname:match("[^\n]+") end

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
	local err, msg, i, cidr_prefix

	err, msg = check_fields(args, {"resolution", "audioPort", "ipDhcpClient"})
	if err then return err, msg end

	local rpi_resolution = rpi_resolutions[args.resolution]
	if not rpi_resolution then return 422, "invalid resolution" end

	local rpi_audio_port = rpi_audio_ports[args.audioPort]
	if not rpi_audio_port then return 422, "invalid audioPort" end

	-- creates the usercfg.txt if not in filesystem (1st boot)
	if not plpath.exists(RAME.config.settings_path.."usercfg.txt") then
		usercfg = rpi_audio_ports["rameAnalogOnly"] .. "\n"
		if not write_file_sd(RAME.config.settings_path.."usercfg.txt", usercfg)
		then return 500, "file write error" end
	end

	-- Read existing usercfg.txt
	local usercfg = plfile.read(RAME.config.settings_path.."usercfg.txt")
	if not usercfg then return 500, "file read failed" end

	usercfg = update(usercfg, "hdmi_group=1", "hdmi_group=1")
	usercfg = update(usercfg, "hdmi_mode=[^\n]+", rpi_resolution)
	usercfg = update(usercfg, "hdmi_drive=[^\n]+", rpi_audio_port)

	if args.hostname then
		local hostname = plfile.read("/etc/hostname")
		if hostname and hostname ~= args.hostname.."\n" then
			hostname = args.hostname.."\n"
			if not write_file_lbu("/etc/hostname", hostname) then
			   return 500, "file write error" end
		end
	end

	-- Read existing configuration
	local dhcpcd = plfile.read("/etc/dhcpcd.conf")
	if not dhcpcd then return 500, "file read failed" end

	if args.ipDhcpClient == false then
		err, msg = check_fields(args, {"ipAddress", "ipSubnetMask", "ipDefaultGateway", "ipDnsPrimary", "ipDnsSecondary", "ipDhcpServer"})
		if err then return err, msg end

		cidr_prefix = ipv4_masks_rev[args.ipSubnetMask]
		if not cidr_prefix then return 422, "invalid subnet mask" end

		dhcpcd = update(dhcpcd, "static ip_address=[^\n]+",
				"static ip_address=" .. args.ipAddress .. "/" .. cidr_prefix)
		dhcpcd = update(dhcpcd, "static routers=[^\n]+",
						"static routers=" .. args.ipDefaultGateway)
		dhcpcd = update(dhcpcd, "static domain_name_servers=[^\n]+",
	"static domain_name_servers="..args.ipDnsPrimary.." "..args.ipDnsSecondary)
		if args.ipDhcpServer == true then
			local ipRangeStart, ipRangeEnd
			local udhcpd = plfile.read("/etc/udhcpd.conf")
			if not udhcpd then return 500, "file read failed" end

			ipRangeStart, ipRangeEnd = give_last_quadrant(args.ipAddress,
														  cidr_prefix)
			udhcpd = update(udhcpd, "start\t\t[^\n]+","start\t\t"..ipRangeStart)
			udhcpd = update(udhcpd, "end\t\t[^\n]+", "end\t\t"..ipRangeEnd)

			-- Note! Matches only "opt" not "option" so any hand made changes
			-- are not necessarily detected by this code
			udhcpd = update(udhcpd, "option\tsubnet[^\n]+",
							"option\tsubnet\t" .. args.ipSubnetMask)
			udhcpd = update(udhcpd, "opt\trouter[^\n]+",
							"opt\trouter\t" .. args.ipDefaultGateway)
			udhcpd = update(udhcpd, "opt\tdns[^\n]+",
					 "opt\tdns\t"..args.ipDnsPrimary.." "..args.ipDnsSecondary)

			if not write_file_lbu("/etc/udhcpd.conf", udhcpd) then
				return 500, "file write error"
			end
		end
	else -- clearing the possible static IP configuration lines
		dhcpcd = update(dhcpcd, "static ip_address=[^\n]+\n", "")
		dhcpcd = update(dhcpcd, "static routers=[^\n]+\n", "")
		dhcpcd = update(dhcpcd, "static domain_name_servers=[^\n]+\n", "")
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
