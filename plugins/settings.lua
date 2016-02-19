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

local function check_hostname(value)
	if type(value) ~= "string" then return false end
	if #value < 1 or #value > 63 then return false end
	return value:match("^[a-zA-Z0-9][-a-zA-Z0-9]*$") ~= nil
end

local function check_ip(value)
	if type(value) ~= "string" then return false end
	return value:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function check_fields(data, schema)
	if type(data) ~= "table" then return 422, "input missing" end
	for field, spec in pairs(schema) do
		local t = type(spec)
		if t == "string" then
			spec = { typeof=spec }
		elseif t == "function" then
			spec = { validate=spec }
		elseif t ~= "table" then
			return 422, "bad schema: "..field
		end

		local val = data[field]
		if val == nil and spec.optional ~= true then
			return 422, "missing required parameter: "..field
		end
		if (spec.typeof and type(val) ~= spec.typeof) or
		   (spec.validate and not spec.validate(val)) or
		   (spec.choices and spec.choices[val] == nil) then
			return 422, "invalid value for parameter: "..field
		end
	end
end

local function activate_config(conf)
	RAME.config.omxplayer_audio_out = omxplayer_audio_outs[conf.audioPort]
end

local function pexec(...)
	return process.popen(...):read_all()
end

local function entries(e)
	return type(e) == "table" and table.unpack(e) or e
end


-- REST API: /settings/
local SETTINGS = { GET = {}, POST = {} }

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
	err, msg = check_fields(args, settings_fields)
	if err then return err, msg end
	local c = {}
	for key, spec in pairs(settings_fields) do
		c[key] = args[key]
	end

	-- Write and activate new settings
	if not RAME.write_settings_file(settings_json, json.encode(c)) then
		return 500, "file write error"
	end
	RAME.settings = c
	return 200
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

	local usercfg = plutils.readlines(RAME.config.settings_path..ramecfg_txt)
	for _, val in ipairs(usercfg or {}) do
		if val ~= "" and rpi_resolutions_rev[val] then
			conf.resolution = rpi_resolutions_rev[val]
		end
		if rpi_audio_ports_rev[val] then
			conf.audioPort = rpi_audio_ports_rev[val]
		end
	end

	local dhcpcd = plconfig.read("/etc/dhcpcd.conf", {list_delim=' '}) or {}
	if dhcpcd.static_ip_address then
		local ip, cidr = dhcpcd.static_ip_address:match("(%d+.%d+.%d+.%d+)/(%d+)")
		conf.ipDhcpClient = false
		conf.ipAddress = ip
		conf.ipSubnetMask = ipv4_masks[cidr]
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
		conf.ipSubnetMask = ipv4_masks[cidr]
		conf.ipDefaultGateway = routes:match("default via ([0-9.]+) ")
		conf.ipDnsPrimary, conf.ipDnsSecondary = entries(dns)
	end

	return 200, conf
end

function SETTINGS.POST.system(ctx, reply)
	local args = ctx.args
	local err, msg, i, cidr_prefix
	local changed = false
	local commit = false
	local rpi_conf = {}
	local ip_conf = {}
	local udhcpd_conf = {}

	err, msg = check_fields(args, {
		resolution = {typeof="string",choices=rpi_resolutions},
		audioPort = {typeof="string",choices=rpi_audio_ports},
		ipDhcpClient = "boolean",
		hostname = check_hostname,
	})
	if err then return err, msg end

	local rpi_resolution = rpi_resolutions[args.resolution]
	local rpi_audio_port = rpi_audio_ports[args.audioPort]

	-- ramecfg.txt parsing
	local usercfg = plutils.readlines(RAME.config.settings_path..ramecfg_txt) or {""}

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
		if not RAME.write_settings_file(ramecfg_txt, table.concat(usercfg, "\n")) then
			return 500, "file write error"
		end
		changed = false
		-- Signal the user that reboot is required
		RAME.system.reboot_required(true)
	end

	--
	-- HOSTNAME
	--
	local hostname = plfile.read("/etc/hostname")
	if hostname and hostname ~= args.hostname.."\n" then
		hostname = args.hostname.."\n"
		if not plfile.write("/etc/hostname", hostname) then
			return 500, "file write error"
		end
		commit = true
	end

	--
	-- IP
	--
	-- Read existing configuration
	local dhcpcd = plutils.readlines("/etc/dhcpcd.conf")
	if not dhcpcd then return 500, "file read failed" end

	if args.ipDhcpClient == false then
		err, msg = check_fields(args, {
			ipAddress = check_ip,
			ipSubnetMask = {typeof="string", choices = ipv4_masks_rev},
			ipDefaultGateway = check_ip,
			ipDnsPrimary = check_ip,
			ipDnsSecondary = check_ip,
			ipDhcpServer = "boolean",
		})
		if err then return err, msg end

		cidr_prefix = ipv4_masks_rev[args.ipSubnetMask]
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
			err, msg = check_fields(args, {
				ipDhcpRangeStart = check_ip,
				ipDhcpRangeStart = check_ip,
			})
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
				if not plfile.write("/etc/udhcpd.conf", table.concat(udhcpd, "\n")) then
					return 500, "file write error"
				end
				changed = false
				commit = true
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
		if not plfile.write("/etc/dhcpcd.conf", table.concat(dhcpcd, "\n")) then
			return 500, "file write error"
		end
		changed = false
		commit = true
	end

	activate_config(args)
	if commit then
		RAME.commit_overlay()
		RAME.system.reboot_required(true)
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
	local ok, conf = SETTINGS.GET.system()
	if ok == 200 then activate_config(conf) end

	local conf = json.decode(RAME.read_settings_file(settings_json) or "")
	if check_fields(conf, settings_fields) == nil then
		RAME.settings = conf
	end

	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, SETTINGS) end
	RAME.rest.version = function(ctx, reply) return ctx:route(reply, VERSION) end
end

return Plugin
