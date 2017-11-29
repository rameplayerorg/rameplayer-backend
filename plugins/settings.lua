-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local lfs = require 'lfs'
local plfile = require 'pl.file'
local plutils = require 'pl.utils'
local plconfig = require "pl.config"
local plpath = require 'pl.path'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local ramecfg_txt = "ramecfg.txt"
local user_settings_json = "user_settings.json"
local system_settings_json = "system_settings.json"
local timezone = ''
local timezone_path = "/usr/share/zoneinfo/"
local timezones = nil

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
	"255.255.255.248", "255.255.255.252"
}
local ipv4_masks_rev = revtable(ipv4_masks)

-- supported (selection) resolutions on RPi
local rpi_resolutions = {
	rameAutodetect = "#hdmi_mode=autodetect",
	rame720p50 = "hdmi_mode=19",
	rame720p60 = "hdmi_mode=4",
	rame1080i50 = "hdmi_mode=20",
	rame1080i60 = "hdmi_mode=5",
	rame1080p50 = "hdmi_mode=31",
	rame1080p60 = "hdmi_mode=16",
	rameAnalogPAL = "sdtv_mode=2 #Normal PAL",
	rameAnalogNTSC = "sdtv_mode=0 #Normal NTSC",
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
	if plpath.exists("/proc/asound/RPiCirrus") then
		local audiomode = conf.audioMono and 'mono' or 'stereo'
		RAME.log.info("Configuring audio board to "..audiomode)
		process.run('/usr/libexec/wolfson/wolfson.sh', audiomode)
	end
end

local function pexec(...)
	return process.popen(...):read_all()
end

local function entries(e)
	if type(e) == "table" then
		return table.unpack(e)
	end
	return e
end

-- returns true if given name is valid timezone
function is_valid_tz(name)
	return name:sub(1,1) ~= '.' and
		name ~= 'right' and
		name ~= 'posixrules' and
		name:match('%.tab$') == nil
end

-- returns table of timezones
function read_timezones(path, prefix)
	prefix = prefix or ''
	local l = {}
	if plpath.exists(path) == false then
		RAME.log.error(("Timezone path not found: %s"):format(path))
		return l
	end
	for file in lfs.dir(path) do
		if is_valid_tz(file) then
			local f = path .. '/' .. file
			local attr = lfs.attributes(f)
			if attr.mode == 'directory' then
				local sub = read_timezones(f, file .. '/')
				for _, v in ipairs(sub) do
					table.insert(l, v)
				end
			else
				table.insert(l, prefix .. file)
			end
		end
	end
	table.sort(l)
	return l
end

-- REST API: /settings/
local SETTINGS = { GET = {}, POST = {}, PUT = {} }

function SETTINGS.GET.user(ctx, reply)
	return 200, RAME.user_settings
end

local user_settings_fields = {
	autoplayUsb = "boolean"
}

local system_settings_fields = {
	audioPort = "string",
	audioMono = "boolean",
}

function SETTINGS.POST.user(ctx, reply)
	local args = ctx.args
	local err, msg

	-- Validate and deep copy the settings
	err, msg = RAME.check_fields(args, user_settings_fields)
	if err then return err, msg end
	local c = {}
	for key, spec in pairs(user_settings_fields) do
		c[key] = args[key]
	end


	-- Write and Activate new settings
	if RAME.user_settings.autoplayUsb ~= c.autoplayUsb then
		RAME.user_settings.autoplayUsb = c.autoplayUsb
		if not RAME.write_settings_file(user_settings_json, json.encode(c)) then
			RAME.log.error("File write error: "..user_settings_json)
			return 500, { error="File write error: "..user_settings_json }
		end
	end

	return 200, {}
end

function SETTINGS.GET.system(ctx, reply)
	local conf = {
		-- Defaults if not found from config files
		resolution = "rameAutodetect",
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
		if rpi_display_rotation_rev[val] then
			conf.displayRotation = rpi_display_rotation_rev[val]
		end
	end

	conf.audioPort = RAME.system_settings.audioPort
	conf.audioMono = RAME.system_settings.audioMono

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
			local srv = l:match("nameserver (%d+.%d+.%d+.%d+)")
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

	-- read current timezone, stripping newline
	local tz = plutils.readfile("/etc/timezone") or ''
	timezone = tz:sub(1, -2)
	conf.timezone = timezone

	-- cache timezones
	if timezones == nil then
		timezones = read_timezones(timezone_path)
	end
	conf.timezones = timezones

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
		audioPort = {typeof="string",choices=omxplayer_audio_outs},
		ipDhcpClient = "boolean",
		displayRotation = {validate=check_display_rotation},
		hostname = {validate=check_hostname, optional=true},
		ntpServerAddress = {typeof="string", optional=true},
		dateAndTimeInUTC = {typeof="string", optional=true},
	})
	if err then return err, msg end

	--
	-- RPi PARAMS RESOLUTION AND DISPLAY-ROTATION
	--
	table.insert(rpi_conf, "# NOTE: This file is auto-updated")
	table.insert(rpi_conf, "hdmi_group=1")
	table.insert(rpi_conf, rpi_resolutions[args.resolution])
	table.insert(rpi_conf, rpi_display_rotation[args.displayRotation])

	local old_config = plutils.readfile(RAME.config.settings_path..ramecfg_txt)
	local new_config = table.concat(rpi_conf, "\n")
	if old_config ~= new_config then
		if not RAME.write_settings_file(ramecfg_txt, new_config) then
			RAME.log.error("File write error: "..ramecfg_txt)
			return 500, { error="File write error: "..ramecfg_txt }
		end
		RAME.system.reboot_required(true)
	end

	--
	-- AUDIO-PORT
	--
	if RAME.system_settings.audioPort ~= args.audioPort or
	   RAME.system_settings.audioMono ~= args.audioMono then
		RAME.system_settings.audioPort = args.audioPort
		RAME.system_settings.audioMono = args.audioMono

		-- AudioPort is saved on system_settings_json
		if not RAME.write_settings_file(system_settings_json,
			   							json.encode(RAME.system_settings)) then
			RAME.log.error("File write error: "..system_settings_json)
			return 500, { error="File write error: "..system_settings_json }
		end
	end

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
		process.run("/etc/init.d/hostname", "restart")
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
		if args.ipDnsSecondary and not args.ipDnsPrimary then
			-- only secondary given, swap it as primary
			args.ipDnsPrimary = args.ipDnsSecondary
			args.ipDnsSecondary = nil
		end
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
			process.run("/etc/init.d/dhcpcd", "restart")
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
			}
			if args.ipDnsPrimary then
				local dnscfg = "opt\tdns\t"..args.ipDnsPrimary
				if args.ipDnsSecondary then
					dnscfg = dnscfg.." "..args.ipDnsSecondary
				end
				udhcpd_conf["dns"] = dnscfg
			end
			if args.ipDefaultGateway then
				udhcpd_conf["default_gw"] = "opt\trouter\t" .. args.ipDefaultGateway
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
			process.run("/etc/init.d/udhcpd", "start", "--ifstopped")
			commit = true
		elseif args.ipDhcpServer == false then
			process.run("rc-update", "del", "udhcpd", "default")
			process.run("/etc/init.d/udhcpd", "stop", "--ifstarted")
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
		process.run("/etc/init.d/udhcpd", "stop", "--ifstarted")
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
			process.run("/etc/init.d/ntpd", "restart")
			commit = true
		end
	end

	-- optional
	if args.dateAndTimeInUTC then
		RAME.log.info("New date&time: "..args.dateAndTimeInUTC)
		process.run("date", "-u", "-s", args.dateAndTimeInUTC)
		-- write date&time to RTC if it's available:
		if plpath.exists("/dev/rtc") then
			process.run("hwclock", "-u", "-w")
		end
	end

	--
	-- TIMEZONE
	--
	if args.timezone and timezone ~= args.timezone then
		RAME.log.info("prev. timezone: " .. timezone)
		RAME.log.info("Setting timezone: " .. args.timezone)
		if not plfile.write("/etc/timezone", args.timezone .. "\n") then
			RAME.log.error("File write error: ".."/etc/timezone")
			return 500, { error="File write error: ".."/etc/timezone" }
		end
		local tz_path = "/usr/share/zoneinfo/" .. args.timezone
		process.run("ln", "-sf", tz_path, "/etc/localtime")
		if RAME.config.second_display then
			RAME.system.reboot_required(true)
		end
		timezone = args.timezone
		commit = true
	end

	activate_config(args)
	if commit then
		RAME.commit_overlay()
	end

	return 200, args
end

function SETTINGS.PUT.reboot(ctx, reply)
	RAME.reboot_device()
	return 200, {}
end

function SETTINGS.PUT.reset(ctx, reply)
	RAME.factory_reset()
	RAME.reboot_device()
	return 200, {}
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	local ok, conf
	conf = json.decode(RAME.read_settings_file(user_settings_json) or "")
	if RAME.check_fields(conf, user_settings_fields) == nil then
		RAME.user_settings = conf
	end

	conf = json.decode(RAME.read_settings_file(system_settings_json) or "")
	if RAME.check_fields(conf, system_settings_fields) == nil then
		RAME.system_settings = conf
	end

	ok, conf = SETTINGS.GET.system()
	if ok == 200 then activate_config(conf) end

	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, SETTINGS) end
end

return Plugin
