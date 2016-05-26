-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local plfile = require 'pl.file'
local plutils = require 'pl.utils'
local plconfig = require "pl.config"
local plpath = require 'pl.path'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local ramecfg_txt = "ramecfg.txt"
local settings_json = "settings.json"

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
	"255.248.0.0", "255.252.0.0", "255.254.0.0", "255.255.0.0",
	"255.255.128.0", "255.255.192.0", "255.255.224.0", "255.255.240.0",
	"255.255.248.0", "255.255.252.0", "255.255.254.0", "255.255.255.0",
	"255.255.255.128", "255.255.255.192", "255.255.255.224", "255.255.255.240",
	"255.255.255.248", "255.255.255.252", "255.255.255.254", "255.255.255.255"
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

-- supported displayRotation on RPi
local rpi_display_rotation = {
	[0] = "display_rotate=0 #Normal",
	[90] = "display_rotate=1 #90 degrees",
	[180] = "display_rotate=2 #180 degrees",
	[270] = "display_rotate=3 #270 degrees",
}
local rpi_display_rotation_rev = revtable(rpi_display_rotation)

-- Certain HDMI devices do not work with hdmi_drive setting thus implementation
-- of audio setting is RAME internal only
local rpi_audio_ports = {
	rameAnalogOnly = "#hdmi_drive=1 analog",
	rameHdmiOnly =  "#hdmi_drive=2 hdmi",
	rameHdmiAndAnalog = "#hdmi_drive=2 both",
}
local rpi_audio_ports_rev = revtable(rpi_audio_ports)

local omxplayer_audio_outs = {
	rameAnalogOnly = "local",
	rameHdmiOnly = "hdmi",
	rameHdmiAndAnalog = "both",
}

local function check_display_rotation(value)
	if type(value) ~= "number" then return false end
	if value == 0 or value == 90 or value == 180 or value == 270 then
		return true else return false end
end

local function check_hostname(value)
	if type(value) ~= "string" then return false end
	if #value < 1 or #value > 63 then return false end
	return value:match("^[a-zA-Z0-9][-a-zA-Z0-9]*$") ~= nil
end

local function check_ip(value)
	if type(value) ~= "string" then return false end
	return value:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function activate_config(conf)
	RAME.system.hostname(conf.hostname)
	RAME.config.omxplayer_audio_out = omxplayer_audio_outs[conf.audioPort]
end

local function pexec(...)
	return process.popen(...):read_all()
end

local function entries(e)
	return type(e) == "table" and table.unpack(e) or e
end

-- REST API: /settings/
local SETTINGS = { GET = {}, POST = {}, PUT = {} }

function SETTINGS.GET.user(ctx, reply)
	return 200, RAME.settings
end

local settings_fields = {
	autoplayUsb = "boolean"
}

function SETTINGS.POST.user(ctx, reply)
	local args = ctx.args
	local err, msg

	-- Validate and deep copy the settings
	err, msg = RAME.check_fields(args, settings_fields)
	if err then return err, msg end
	local c = {}
	for key, spec in pairs(settings_fields) do
		c[key] = args[key]
	end

	-- Write and activate new settings
	if not RAME.write_settings_file(settings_json, json.encode(c)) then
		RAME.log.error("File write error: "..settings_json)
		return 500, { error="File write error: "..settings_json }
	end
	RAME.settings = c
	return 200
end

function SETTINGS.GET.system(ctx, reply)
	local conf = {
		-- Defaults if not found from config files
		resolution = "rameAutodetect",
		audioPort = "rameAnalogOnly",
		displayRotation = 0,
		ipDhcpClient = true,
		ipDhcpServer = false,
	}

	local hostname = plfile.read("/etc/hostname")
	if hostname then conf.hostname = hostname:match("[^\n]+") end

	local usercfg = plutils.readlines(RAME.config.settings_path..ramecfg_txt)
	for _, val in ipairs(usercfg or {}) do
		if val ~= "" and rpi_resolutions_rev[val] then
			conf.resolution = rpi_resolutions_rev[val]
		end
		if rpi_audio_ports_rev[val] then
			conf.audioPort = rpi_audio_ports_rev[val]
		end
		if rpi_display_rotation_rev[val] then
			conf.displayRotation = rpi_display_rotation_rev[val]
		end
	end

	local dhcpcd = plconfig.read("/etc/dhcpcd.conf", {list_delim=' '}) or {}
	if dhcpcd.static_ip_address then
		local ip, cidr = dhcpcd.static_ip_address:match("(%d+.%d+.%d+.%d+)/(%d+)")
		conf.ipDhcpClient = false
		conf.ipAddress = ip
		conf.ipSubnetMask = ipv4_masks[tonumber(cidr)]
		conf.ipDefaultGateway = dhcpcd.static_routers
		conf.ipDnsPrimary, conf.ipDnsSecondary = entries(dhcpcd.static_domain_name_servers)
	else
		local routes = pexec("ip", "-4", "route", "show", "dev", "eth0") or ""
		local cidr = routes:match("[0-9.]+/(%d+) dev")
		local dns = {}
		for l in io.lines("/etc/resolv.conf") do
			local srv = l:match("nameserver ([^ ]+)")
			if srv then table.insert(dns, srv) end
		end
		conf.ipAddress = RAME.system.ip()
		conf.ipSubnetMask = ipv4_masks[tonumber(cidr)]
		conf.ipDefaultGateway = routes:match("default via ([0-9.]+) ")
		conf.ipDnsPrimary, conf.ipDnsSecondary = entries(dns)
	end

	local rc_default = pexec("rc-update", "show", "default")
	local udhcpd_status = rc_default:match("udhcpd")
	if udhcpd_status then
		conf.ipDhcpServer = true
		local udhcpd = plutils.readlines("/etc/udhcpd.conf")
		if not udhcpd then
			RAME.log.error("File read failed: ".."/etc/udhcpd.conf")
			return 500, { error="File read failed: ".."/etc/udhcpd.conf" }
		end
		for i, val in ipairs(udhcpd) do
			local range_start = val:match("start%s+([^\n]+)")
			local range_end = val:match("end%s+([^\n]+)")
			if range_start then conf.ipDhcpRangeStart = range_start end
			if range_end then conf.ipDhcpRangeEnd = range_end end
		end
	end

	local ntp_server = plfile.read("/etc/ntp.conf")
	if ntp_server then conf.ntpServerAddress = ntp_server:match("server ([^\n]+)") end

	conf.dateAndTimeInUTC = os.date("!%Y-%m-%d %T")
	return 200, conf
end

function SETTINGS.POST.system(ctx, reply)
	local args = ctx.args
	local err, msg, i, cidr_prefix, str
	local changed = false
	local commit = false
	local rpi_conf = {}
	local ip_conf = {}
	local udhcpd_conf = {}

	err, msg = RAME.check_fields(args, {
		resolution = {typeof="string",choices=rpi_resolutions},
		audioPort = {typeof="string",choices=rpi_audio_ports},
		ipDhcpClient = "boolean",
		displayRotation = {validate=check_display_rotation},
		hostname = {validate=check_hostname, optional=true},
		ntpServerAddress = {typeof="string", optional=true},
		dateAndTimeInUTC = {typeof="string", optional=true},
	})
	if err then return err, msg end

	-- POST always writes the settings again
	if args.resolution ~= "rameAutodetect" then
		table.insert(rpi_conf, "hdmi_group=1")
		table.insert(rpi_conf, rpi_resolutions[args.resolution])
	end
	table.insert(rpi_conf, rpi_audio_ports[args.audioPort])
	table.insert(rpi_conf, rpi_display_rotation[args.displayRotation])

	if not RAME.write_settings_file(ramecfg_txt, table.concat(rpi_conf, "\n")) then
		RAME.log.error("File write error: "..ramecfg_txt)
		return 500, { error="File write error: "..ramecfg_txt }
	end

	-- Signal the user that reboot is required
	RAME.system.reboot_required(true)

	--
	-- HOSTNAME
	--
	local hostname = plfile.read("/etc/hostname")
	if hostname and args.hostname and hostname ~= args.hostname.."\n" then
		hostname = args.hostname.."\n"
		if not plfile.write("/etc/hostname", hostname) then
			RAME.log.error("File write error: ".."/etc/hostname")
			return 500, { error="File write error: ".."/etc/hostname" }
		end
		commit = true
	end

	--
	-- IP
	--
	-- Read existing configuration
	local dhcpcd = plutils.readlines("/etc/dhcpcd.conf")
	if not dhcpcd then
		RAME.log.error("File read failed: ".."/etc/dhcpcd.conf")
		return 500, { error="File read failed: ".."/etc/dhcpcd.conf" }
	end

	if args.ipDhcpClient == false then
		local optional = true
		err, msg = RAME.check_fields(args, {
			ipAddress = check_ip,
			ipSubnetMask = {typeof="string", choices=ipv4_masks_rev},
			ipDefaultGateway = { validate=check_ip, optional=true },
			ipDnsPrimary = { validate=check_ip, optional=true },
			ipDnsSecondary = { validate=check_ip, optional=true },
			ipDhcpServer = { typeof="boolean", optional=true},
		})
		if err then return err, msg end

		cidr_prefix = ipv4_masks_rev[args.ipSubnetMask]

		ip_conf = {
			ip_address = "static ip_address="..args.ipAddress.."/"..cidr_prefix,
		}
		if args.ipDnsPrimary then
			ip_conf["dns"] = "static domain_name_servers="..args.ipDnsPrimary
			if args.ipDnsSecondary then
				ip_conf["dns"] = ip_conf["dns"].." "..args.ipDnsSecondary
			end
		end
		if args.ipDefaultGateway then
			ip_conf["default_gw"] = "static routers="..args.ipDefaultGateway
		end

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

		if changed then
			if not plfile.write("/etc/dhcpcd.conf", table.concat(dhcpcd, "\n")) then
				RAME.log.error("File write error: ".."/etc/dhcpcd.conf")
				return 500, { error="File write error: ".."/etc/dhcpcd.conf" }
			end
			changed = false
			commit = true
		end

		if args.ipDhcpServer == true then
			err, msg = RAME.check_fields(args, {
				ipDhcpRangeStart = check_ip,
				ipDhcpRangeEnd = check_ip,
			})
			if err then return err, msg end

			local udhcpd = plutils.readlines("/etc/udhcpd.conf")
			if not udhcpd then
				RAME.log.error("File read failed: ".."/etc/udhcpd.conf")
				return 500, { error="File read failed: ".."/etc/udhcpd.conf" }
			end

			udhcpd_conf = {
				range_start = "start\t\t" .. args.ipDhcpRangeStart,
				range_end = "end\t\t" .. args.ipDhcpRangeEnd,
				subnet_mask = "option\tsubnet\t" .. args.ipSubnetMask,
				default_gw = "opt\trouter\t" .. args.ipDefaultGateway,
			}
			if args.ipDnsPrimary then
				local dnscfg = "opt\tdns\t"..args.ipDnsPrimary
				if args.ipDnsSecondary then
					dnscfg = dnscfg.." "..args.ipDnsSecondary
				end
				udhcpd_conf["dns"] = dnscfg
			end

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
				if not plfile.write("/etc/udhcpd.conf", table.concat(udhcpd, "\n")) then
					RAME.log.error("File write error: ".."/etc/udhcpd.conf")
					return 500, {error="File write error: ".."/etc/udhcpd.conf"}
				end
				changed = false
				commit = true
			end
			process.run("rc-update", "add", "udhcpd", "default")
			commit = true
		elseif args.ipDhcpServer == false then
			process.run("rc-update", "del", "udhcpd", "default")
			commit = true
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

		if changed then
			if not plfile.write("/etc/dhcpcd.conf", table.concat(dhcpcd, "\n")) then
				RAME.log.error("File write error: ".."/etc/dhcpcd.conf")
				return 500, { error="File write error: ".."/etc/dhcpcd.conf" }
			end
			changed = false
			commit = true
		end

		-- removing the DHCP server service ALWAYS when set in DHCP client mode!
		process.run("rc-update", "del", "udhcpd", "default")
		commit = true
	end


	-- optional
	if args.ntpServerAddress then
		local ntp_server = plfile.read("/etc/ntp.conf")
		local str = "server "..args.ntpServerAddress.."\n"
		if ntp_server and ntp_server ~= str then
			if not plfile.write("/etc/ntp.conf", str) then
				RAME.log.error("File write error: ".."/etc/ntp.conf")
				return 500, { error="File write error: ".."/etc/ntp.conf" }
			end
			commit = true
		end
	end

	-- optional
	if args.dateAndTimeInUTC then
		RAME.log.info("New date&time: "..args.dateAndTimeInUTC)
		process.run("date", "-u", "-s", args.dateAndTimeInUTC)
		-- write date&time to RTC if it's available:
		if plpath.exists("/proc/device-tree/rame/cid6") then
			process.run("hwclock", "-u", "-w")
		end
	end

	activate_config(args)
	if commit then
		RAME.commit_overlay()
		RAME.system.reboot_required(true)
	end

	return 200
end

function SETTINGS.PUT.reboot(ctx, reply)
	process.run("reboot", "now")
	return 200
end

function SETTINGS.PUT.reset(ctx, reply)
	process.run("mount", "-o", "remount,rw", "/media/mmcblk0p1")
	-- all the user specific configuration is erased
	process.run("rm", "-rf", "/media/mmcblk0p1/user")
	-- config overlay is destroed
	process.run("rm", "-rf", "/media/mmcblk0p1/*.apkovl.tar.gz")
	-- copying the default (factory) settings
	process.run("cp", "factory.rst", "/media/mmcblk0p1/rame.apkovl.tar.gz")
	process.run("mount", "-o", "remount,ro", "/media/mmcblk0p1")
	process.run("reboot", "now")
	return 200
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	local ok, conf = SETTINGS.GET.system()
	if ok == 200 then activate_config(conf) end

	local conf = json.decode(RAME.read_settings_file(settings_json) or "")
	if RAME.check_fields(conf, settings_fields) == nil then
		RAME.settings = conf
	end

	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, SETTINGS) end
end

return Plugin
