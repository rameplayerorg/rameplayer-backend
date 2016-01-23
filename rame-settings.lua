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

-- from the end backwards
function ripairs(t)
  local function ripairs_it(t,i)
    i=i-1
    local v=t[i]
    if v==nil then return v end
    return i,v
  end
  return ripairs_it, t, #t+1
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

	process.run("lbu", "commit", "-d")
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
	local changed = false
	local rpi_conf = {}
	local ip_conf = {}
	local udhcpd_conf = {}

	err, msg = check_fields(args, {"resolution", "audioPort", "ipDhcpClient"})
	if err then return err, msg end

	--
	-- USERCFG.TXT
	--
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
	local usercfg = plutils.readlines(RAME.config.settings_path.."usercfg.txt")
	if not usercfg then return 500, "file read failed" end

	-- If rameAutodetect resolution REMOVING forced resolution config
	if args.resolution == "rameAutodetect" then
		for i, val in ripairs(usercfg) do
			if val:match("hdmi_mode=[^\n]+")
			 or val:match("hdmi_group=[^\n]+") then
				table.remove(usercfg, i)
				changed = true
			end
		end
	else
		rpi_conf.hdmi_group = "hdmi_group=1"
		rpi_conf.resolution = rpi_resolutions[args.resolution]
	end
	rpi_conf.audio_port = rpi_audio_ports[args.audioPort]

	for i, val in ipairs(usercfg) do
		if val:match("hdmi_group=[^\n]+") then
			rpi_conf.hdmi_group = nil
		elseif val:match("hdmi_mode=[^\n]+") then
			-- updating only if change in config
			if val ~= rpi_conf.resolution then
				usercfg[i] = rpi_conf.resolution
				changed = true
			end
			rpi_conf.resolution = nil
		elseif val:match("hdmi_drive=[^\n]+") then
			if val ~= rpi_conf.audio_port then
				usercfg[i] = rpi_conf.audio_port
				changed = true
			end
			rpi_conf.audio_port = nil
		end
	end

	-- APPEND possible new config lines
	for i, val in pairs(rpi_conf) do
		if val then
			table.insert(usercfg, val)
			changed = true
		end
	end

	if changed then
		if not write_file_sd(RAME.config.settings_path.."usercfg.txt",
							 table.concat(usercfg, "\n")) then
			return 500, "file write error" end
		changed = false
		-- Signal the user that reboot is required
		RAME.system.reboot_required = true
	end

	--
	-- HOSTNAME
	--
	if args.hostname then
		local hostname = plfile.read("/etc/hostname")
		if hostname and hostname ~= args.hostname.."\n" then
			hostname = args.hostname.."\n"
			if not write_file_lbu("/etc/hostname", hostname) then
			   return 500, "file write error" end
			-- Signal the user that reboot is required
			RAME.system.reboot_required = true
		end
	end

	--
	-- IP
	--
	-- Read existing configuration
	local dhcpcd = plutils.readlines("/etc/dhcpcd.conf")
	if not dhcpcd then return 500, "file read failed" end

	if args.ipDhcpClient == false then
		err, msg = check_fields(args, {"ipAddress", "ipSubnetMask", "ipDefaultGateway", "ipDnsPrimary", "ipDnsSecondary", "ipDhcpServer"})
		if err then return err, msg end

		cidr_prefix = ipv4_masks_rev[args.ipSubnetMask]
		if not cidr_prefix then return 422, "invalid subnet mask" end

		ip_conf = {
		ip_address = "static ip_address="..args.ipAddress.."/"..cidr_prefix,
		default_gw = "static routers="..args.ipDefaultGateway,
		dns = "static domain_name_servers="..args.ipDnsPrimary
					.." "..args.ipDnsSecondary
		}

		for i, val in ipairs(dhcpcd) do
			if val:match("static ip_address=[^\n]+") then
				-- updating only if change in config
				if val ~= ip_conf.ip_address then
					dhcpcd[i] = ip_conf.ip_address
					changed = true
				end
				-- if config-line exist not appending the line
				ip_conf.ip_address = nil
			elseif val:match("static routers=[^\n]+") then
				if val ~= ip_conf.default_gw then
					dhcpcd[i] = ip_conf.default_gw
					changed = true
				end
				ip_conf.default_gw = nil
			elseif val:match("static domain_name_servers=[^\n]+") then
				if val ~= ip_conf.dns then
					dhcpcd[i] = ip_conf.dns
					changed = true
				end
				ip_conf.dns = nil
			end
		end

		for i, val in pairs(ip_conf) do
			-- for those values that were new to config APPEND
			if val then
				table.insert(dhcpcd, val)
				changed = true
			end
		end

		if args.ipDhcpServer == true then
			err, msg = check_fields(args, {"ipDhcpRangeStart", "ipDhcpRangeStart"})
			if err then return err, msg end

			local udhcpd = plutils.readlines("/etc/udhcpd.conf")
			if not udhcpd then return 500, "file read failed" end

			udhcpd_conf = {
				range_start = "start\t\t" .. args.ipDhcpRangeStart,
				range_end = "end\t\t" .. args.ipDhcpRangeEnd,
				subnet_mask = "option\tsubnet\t" .. args.ipSubnetMask,
				default_gw = "opt\trouter\t" .. args.ipDefaultGateway,
				dns = "opt\tdns\t"..args.ipDnsPrimary.." "..args.ipDnsSecondary
			}

			for i, val in ipairs(udhcpd) do
				if val:match("start\t\t[^\n]+") then
					if val ~= udhcpd_conf.range_start then
						udhcpd[i] = udhcpd_conf.range_start
						changed = true
					end
					-- if config-line exist not appending the line
					udhcpd_conf.range_start = nil
				elseif val:match("end\t\t[^\n]+") then
					if val ~= udhcpd_conf.range_end then
						udhcpd[i] = udhcpd_conf.range_end
						changed = true
					end
					udhcpd_conf.range_end = nil
				elseif val:match("option\tsubnet[^\n]+") then
					if val ~= udhcpd_conf.subnet_mask then
						udhcpd[i] = udhcpd_conf.subnet_mask
						changed = true
					end
					udhcpd_conf.subnet_mask = nil
				elseif val:match("opt\trouter[^\n]+") then
					if val ~= udhcpd_conf.default_gw then
						udhcpd[i] = udhcpd_conf.default_gw
						changed = true
					end
					udhcpd_conf.default_gw = nil
				elseif val:match("opt\tdns[^\n]+") then
					if val ~= udhcpd_conf.dns then
						udhcpd[i] = udhcpd_conf.dns
						changed = true
					end
					udhcpd_conf.dns = nil
				end
			end

			for i, val in pairs(udhcpd_conf) do
				-- for those values that were new to config APPEND
				if val then
					table.insert(udhcpd, val)
					changed = true
				end
			end

			if changed then
				if not write_file_lbu("/etc/udhcpd.conf",
									  table.concat(udhcpd, "\n"))
					then return 500, "file write error" end
				changed = false
				-- Signal the user that reboot is required
				RAME.system.reboot_required = true
			end
			process.run("rc-update", "add", "udhcpd", "default")
		elseif args.ipDhcpServer == false then
			process.run("rc-update", "del", "udhcpd", "default")
		end
	elseif args.ipDhcpClient == true then
		-- removing possible static config entries
		-- need to in reverse order for remove to work
		for i, val in ripairs(dhcpcd) do
			if val:match("static ip_address=[^\n]+") or
			   val:match("static routers=[^\n]+") or
			   val:match("static domain_name_servers=[^\n]+") then
				table.remove(dhcpcd, i)
				changed = true
			end
		end
	end

	if changed then
		if not write_file_lbu("/etc/dhcpcd.conf", table.concat(dhcpcd, "\n"))
		  	then return 500, "file write error" end
		changed = false
		-- Signal the user that reboot is required
		RAME.system.reboot_required = true
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
