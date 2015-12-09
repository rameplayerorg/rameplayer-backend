-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local plfile = require 'pl.file'
local plutils = require 'pl.utils'
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

-- REST API: /settings/
local Settings = {
	GET  = { },
	POST = { },
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

function Settings.GET.user(ctx, reply)
	return read_json(RAME.path_settings_user)
end

function Settings.POST.user(ctx, reply)
	return write_json(RAME.path_settings_user, ctx.body)
end

function Settings.GET.system(ctx, reply)
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

	return 200, json_table
end

-- todo add support for IP settings
-- these settings require reboot which is not implemented
function Settings.POST.system(ctx, reply)
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

	dhcpcd = dhcpcd .. "interface eth0\n"
	dhcpcd = dhcpcd .. "static ip_address=" .. json_table.ipAddress .. "/"
					.. to_cidr_prefix(json_table.ipSubnetMask) .. "\n"

	dhcpcd = dhcpcd .. "static routers=" .. json_table.ipDefaultGateway .. "\n"
	dhcpcd = dhcpcd .. "static domain_name_servers=" .. json_table.ipDnsPrimary
					.. " " .. json_table.ipDnsSecondary .. "\n"

	if not write_file_lbu("/etc/dhcpcd.conf", dhcpcd) then
		return 500, "file write error" end

	if not write_file_sd(RAME.path_rpi_config, usercfg) then
		return 500, "file write error" else return 200 end
	return 200
end

-- REST API: /version/
local Version = {
	GET  = { },
}

function Version.GET(ctx, reply)
	local data = {}
	data["hw"] = plfile.read("/sys/firmware/devicetree/base/model")
	if not data["hw"] then return 500, "file read error" end

	-- last byte of hw ver data is special char that is left out
	data["hw"] = data["hw"]:sub(1, data["hw"]:len() - 1)
	data["backend"] = RAME.version

	return 200, data
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, Settings) end
	RAME.rest.version = function(ctx, reply) return ctx:route(reply, Version) end
end

return Plugin
