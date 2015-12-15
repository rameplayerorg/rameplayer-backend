-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local plfile = require 'pl.file'
local plutils = require 'pl.utils'
local plconfig = require "pl.config"
local process = require 'cqp.process'
local RAME = require 'rame'

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

local rpi_audio_ports = {
	rameAnalogOnly = "hdmi_drive=1",
	rameHdmiOnly =  "hdmi_drive=2",
	rameHdmiAndAnalog = "hdmi_drive=2",
}

local omxplayer_audio_outs = {
	rameAnalogOnly = "local",
	rameHdmiOnly = "hdmi",
	rameHdmiAndAnalog = "both",
	-- needs specific ALSA build of omxplayer
	rameAlsaOnly = "alsa",
	-- tbd how to signal both alsa and HDMI
}

function read_json(file)
	local data = plfile.read(file)
	return data and 200 or 500, data
end

function write_json(file, data)
	-- validating that data is JSON by encoding & decoding
	local json_table = json.decode(data)
	if not json_table then return 500, "json decode failed" end

	local body = json.encode(json_table)
	if not body then return 500, "json encode failed" end

	return write_file_sd(file, data)
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

	local bit_to_integer = {}
	bit_to_integer[7] = 254 --'1111 1110'
	bit_to_integer[6] = 252 --'1111 1100'
	bit_to_integer[5] = 248 --'1111 1000'
	bit_to_integer[4] = 240 --'1111 0000'
	bit_to_integer[3] = 224 --'1110 0000'
	bit_to_integer[2] = 192 --'1100 0000'
	bit_to_integer[1] = 128 --'1000 0000'

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
	return read_json(RAME.path_settings_user)
end

function SETTINGS.POST.user(ctx, reply)
	return write_json(RAME.path_settings_user, ctx.body)
end

function SETTINGS.GET.system(ctx, reply)
	local json_table = {}

	local usercfg_lines = plutils.readlines(RAME.path_rpi_config)
	if not usercfg_lines then return 500, "file read failed" end

   	for i1, v1 in ipairs(usercfg_lines) do
		for i2, v2 in pairs(rpi_resolutions) do
			if v1 == v2 then
				json_table["resolution"] = i2
			end
		end
		for i2, v2 in pairs(rpi_audio_ports) do
			if v1 == v2 then
				json_table["audioPort"] = i2

				-- if HDMI carries audio need to check how omxplayer routs audio
				if v2 == "hdmi_drive=2" then
 					if RAME.omxplayer_audio_out ==
					   omxplayer_audio_outs["rameHdmiAndAnalog"] then -- "both"
					   	json_table["audioPort"] = "rameHdmiAndAnalog"
					elseif RAME.omxplayer_audio_out ==
					       omxplayer_audio_outs["rameHdmiOnly"] then -- "hdmi"
  						json_table["audioPort"] = "rameHdmiOnly"
					else return 500 end
				end
			end
		end
    end

	local dhcpcd_lines = plconfig.read("/etc/dhcpcd.conf", {list_delim=' '})
	if not dhcpcd_lines then return 500, "file read failed" end

	for i, v in pairs(dhcpcd_lines) do
		if i == "static_ip_address" then
			-- matching only the IP address part without prefix
			json_table["ipAddress"] = v:match("%d+.%d+.%d+.%d+")
			-- take CIDR prefix
			json_table["ipSubnetMask"] = to_netmask(v:match("/(%d+)"))
		end
		if i == "static_routers" then
			json_table["ipDefaultGateway"] = v
		end

		if i == "static_domain_name_servers" then
			if #v then -- there is length in array so array exists
					   --(and it must have at least 2 entries to be array)
				json_table["ipDnsPrimary"] = v[1]
				json_table["ipDnsSecondary"] = v[2]
			else
				json_table["ipDnsPrimary"] = v
			end

		end
	end

	return 200, json_table
end

-- todo add support for IP settings
-- these settings require reboot which is not implemented
function SETTINGS.POST.system(ctx, reply)
	local usercfg = "hdmi_group=1" .. "\n"
	local json_table = json.decode(ctx.body)
	if not json_table then return 415, "malformed json" end

	local rpi_resolution = rpi_resolutions[json_table.resolution]
	if rpi_resolution then
		usercfg = usercfg .. rpi_resolution .. "\n"
	else return 422, "missing required json param: resolution" end

	local rpi_audio_port = rpi_audio_ports[json_table.audioPort]
	if rpi_audio_port then
		usercfg = usercfg .. rpi_audio_port .. "\n"

		if json_table.audioPort == "rame_analog_only" and RAME.alsa_support then
			RAME.omxplayer_audio_out = omxplayer_audio_outs["rame_alsa_only"]
		--elseif json_data.audio_port == "rame_hdmi_and_analog"
				 --and RAME.alsa_support
			-- todo this case is not defined!!
		else
			RAME.omxplayer_audio_out = omxplayer_audio_outs[json_table.audioPort]
		end
	else return 422, "missing required json param: audioPort" end

	if json_table.ipDhcpClient == nil then
		return 422, "missing required json param: ipDhcpClient" end

	if json_table.ipDchpClient == true then
		-- DHCP CLIENT being used
	else
		if json_table.ipAddress then
		else return 422, "missing required json param: ipAddress" end

		if json_table.ipSubnetMask then
		else return 422, "missing required json param: ipSubnetMask" end

		if json_table.ipDefaultGateway then
		else return 422, "missing required json param: ipDefaultGateway" end

		if json_table.ipDnsPrimary then
		else return 422, "missing required json param: ipDnsPrimary" end

		if json_table.ipDnsSecondary then
		else return 422, "missing required json param: ipDnsSecondary" end

		if json_table.ipDhcpServer == nil then
			return 422, "missing required json param: ipDhcpServer" end

		if json_table.ipDchpServer == true then
			-- DHCP SERVER in used
		end
	end

	-- Read existing configuration and apped data
	local dhcpcd = plfile.read("/etc/dhcpcd.conf")
	if not dhcpcd then return 500, "file read failed" end
	local i = 0
	-- Replace with given configuration
	dhcpcd, i = dhcpcd:gsub("static ip_address=%d+.%d+.%d+.%d+/%d+",
						 "static ip_address=" .. json_table.ipAddress .. "/"
		  		 		  .. to_cidr_prefix(json_table.ipSubnetMask))

	dhcpcd, i = dhcpcd:gsub("static routers=%d+.%d+.%d+.%d+",
					  	 "static routers=" .. json_table.ipDefaultGateway)


	-- lua doesn't have optional group patterns so have to do with try-err:
	--1st matching with 2 IP address and if not matching then try with 1 IP addr
	dhcpcd, i = dhcpcd:gsub("static domain_name_servers=%d+.%d+.%d+.%d+%s?%d+.%d+.%d+.%d+",
			           "static domain_name_servers=" .. json_table.ipDnsPrimary
					   .. " " .. json_table.ipDnsSecondary )
	if i == 0 then
		dhcpcd, i = dhcpcd:gsub("static domain_name_servers=%d+.%d+.%d+.%d+%s?",
				           		"static domain_name_servers=" .. json_table.ipDnsPrimary
						   		.. " " .. json_table.ipDnsSecondary )
	end

	if not write_file_lbu("/etc/dhcpcd.conf", dhcpcd) then
		return 500, "file write error" end

	if not write_file_sd(RAME.path_rpi_config, usercfg) then
		return 500, "file write error" else return 200 end
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
