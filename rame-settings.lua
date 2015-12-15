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
	rameHdmiAndAnalog = "hdmi_drive=2",
}
local rpi_audio_ports_rev = revtable(rpi_audio_ports)

local omxplayer_audio_outs = {
	rameAnalogOnly = "local",
	rameHdmiOnly = "hdmi",
	rameHdmiAndAnalog = "both",
	-- needs specific ALSA build of omxplayer
	rameAlsaOnly = "alsa",
	-- tbd how to signal both alsa and HDMI
}
local omxplayer_audio_outs_rev = revtable(omxplayer_audio_outs)

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

-- converts traditional dotted subnet mask into CDIR prefix
-- lua 5.3 code compatible only (bitwise operation)
function to_cidr_prefix(netmask)
	local quad = {}
	-- extract numbers from dotted notation into table
	for octet in netmask:gmatch("%d+") do quad[#quad+1] = octet end

	local mask_bit_count = 0
	local stop = false
	for i=1, #quad do
		if not stop then
			for bits=1, 8 do
				-- check if most signficant bit (MSB) is 1
				if quad[i] & 0x80 == 0x80 then
					mask_bit_count = mask_bit_count + 1
					-- make the next bit to be the most signficant
					quad[i] = quad[i] << 1
				else
					-- when the MSB is 0 then bitmask is over! breaking out of loop
					-- and stopping further iterations on next octet
					stop = true
					break
				end
			end
		end
	end
	return mask_bit_count
end

-- converts CDIR prefix into traditional dotted subnet mask
-- lua 5.3 code compatible only (bitwise operation)
function to_netmask(cidr_prefix)
	-- need to count the full octects and the left over bits
	local full_mask_bytes = 0
	while tonumber(cidr_prefix) >= 8  do
		cidr_prefix = cidr_prefix - 8
		full_mask_bytes = full_mask_bytes + 1
	end

	local bit_to_integer = {128,192,224,240,248,252,254}
	local netmask_string = ""
	for i=1, 4 do
		if full_mask_bytes > 0 then
			netmask_string = netmask_string .. "255"
			full_mask_bytes = full_mask_bytes - 1
 		elseif cidr_prefix > 0 then
			--bits to integer mask values
			netmask_string = netmask_string .. bit_to_integer[cidr_prefix]
			cidr_prefix = 0
		else -- filling with zero
			netmask_string = netmask_string .. "0"
		end
		if i < 4 then netmask_string = netmask_string .. "." end
	end

	return netmask_string
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
			-- if HDMI carries audio need to check how omxplayer routes audio
			if val == "hdmi_drive=2" then
				conf.audioPort = omxplayer_audio_outs_rev[RAME.omxplayer_audio_out]
			end
		end
	end

	local dhcpcd_lines = plconfig.read("/etc/dhcpcd.conf", {list_delim=' '})
	if not dhcpcd_lines then return 500, "file read failed" end

	for i, v in pairs(dhcpcd_lines) do
		if i == "static_ip_address" then
			local ip, cidr = v:match("(%d+.%d+.%d+.%d+)/(%d+)")
			conf.ipAddress = ip
			conf.ipSubnetMask = to_netmask(cidr)
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

local function check_fields(data, schema)
	for _, field in ipairs(schema) do
		if not data[field] then
			return 422, "missing required parameter: "..field
		end
	end
end

-- todo add support for IP settings
-- these settings require reboot which is not implemented
function SETTINGS.POST.system(ctx, reply)
	local usercfg = { "hdmi_group=1" }
	local args = ctx.args
	local err, msg, i

	err, msg = check_fields(args, {"resolution", "audioPort", "ipDhcpClient"})
	if err then return err, msg end

	local rpi_resolution = rpi_resolutions[args.resolution]
	if not rpi_resolution then return 422, "invalid resolution" end
	table.insert(usercfg, rpi_resolution)

	local rpi_audio_port = rpi_audio_ports[args.audioPort]
	if not rpi_audio_port then return 422, "invalid audioPort" end
	table.insert(usercfg, rpi_audio_port)
	if args.audioPort == "rame_analog_only" and RAME.alsa_support then
		RAME.omxplayer_audio_out = omxplayer_audio_outs["rame_alsa_only"]
	--elseif args.audio_port == "rame_hdmi_and_analog" and RAME.alsa_support
		-- todo this case is not defined!!
	else
		RAME.omxplayer_audio_out = omxplayer_audio_outs[args.audioPort]
	end

	if args.ipDchpClient ~= true then
		err, msg = check_fields(args, {"ipAddress", "ipSubnetMask", "ipDefaultGateway", "ipDnsPrimary", "ipDnsSecondary", "ipDhcpServer"})
		if err then return err, msg end

		if args.ipDchpServer == true then
			-- DHCP SERVER in used
		end
	end

	-- Read existing configuration and apped data
	local dhcpcd = plfile.read("/etc/dhcpcd.conf")
	if not dhcpcd then return 500, "file read failed" end

	-- Replace with given configuration
	dhcpcd = dhcpcd:gsub("static ip_address=%d+.%d+.%d+.%d+/%d+",
			     "static ip_address=" .. args.ipAddress .. "/"
			     .. to_cidr_prefix(args.ipSubnetMask))

	dhcpcd = dhcpcd:gsub("static routers=%d+.%d+.%d+.%d+",
			     "static routers=" .. args.ipDefaultGateway)

	-- lua doesn't have optional group patterns so have to do with try-err:
	--1st matching with 2 IP address and if not matching then try with 1 IP addr
	dhcpcd, i = dhcpcd:gsub("static domain_name_servers=%d+.%d+.%d+.%d+%s?%d+.%d+.%d+.%d+",
				"static domain_name_servers=" .. args.ipDnsPrimary
				.. " " .. args.ipDnsSecondary )
	if i == 0 then
		dhcpcd, i = dhcpcd:gsub("static domain_name_servers=%d+.%d+.%d+.%d+%s?",
				        "static domain_name_servers=" .. args.ipDnsPrimary
					.. " " .. args.ipDnsSecondary )
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
	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, SETTINGS) end
	RAME.rest.version = function(ctx, reply) return ctx:route(reply, VERSION) end
end

return Plugin
