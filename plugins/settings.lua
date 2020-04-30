-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local lfs = require 'lfs'
local posix = require 'posix'
local plfile = require 'pl.file'
local plutils = require 'pl.utils'
local plconfig = require "pl.config"
local plpath = require 'pl.path'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local ramecfg_txt = "ramecfg.txt"
local user_settings_json = "user_settings.json"
local system_settings_json = "system_settings.json"
local timezone_path = "/usr/share/zoneinfo/"

local timezones_list, timezones_map = {}, {}

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
local rpi_resolution_string_match_to_hdmigroup = {
	-- rpi_resolutions keys are matched with these keys:
	rameAuto = "hdmi_group=0", -- "rameAutodetect"
	rameCEA = "hdmi_group=1", -- all "rameCEA..." entries
	rameDMT = "hdmi_group=2", -- all "rameDMT..." entries
}
local rpi_resolutions = {
	rameAutodetect = "#hdmi_mode=autodetect",
	-- Analog modes:
	rameAnalogNTSC            = "sdtv_mode=0 #Normal NTSC",
	rameAnalogNTSCJapan       = "sdtv_mode=1 #NTSC Japan",
	rameAnalogPAL             = "sdtv_mode=2 #Normal PAL",
	rameAnalogPALBrazil       = "sdtv_mode=3 #PAL Brazil",
	rameAnalogNTSCProgressive = "sdtv_mode=16 #Progressive NTSC",
	rameAnalogPALProgressive  = "sdtv_mode=18 #Progressive PAL",
	-- "Legacy" rame resolution fields, upgraded to rameCEA* when found: (CEA modes in hdmi_group=1):
	rame720p50  = "hdmi_mode=19",  --upgraded when found
	rame720p60  = "hdmi_mode=4",   --upgraded when found
	rame1080i50 = "hdmi_mode=20", --upgraded when found
	rame1080i60 = "hdmi_mode=5",  --upgraded when found
	rame1080p50 = "hdmi_mode=31", --upgraded when found
	rame1080p60 = "hdmi_mode=16", --upgraded when found
	-- postfixes: w=16:9 for modes which are usually 4:3,
	--            pq=quad pixels, pd=double pixels, rb=reduced blanking
	rameCEA1_VGA640x480 = "hdmi_mode=1 #CEA",
	rameCEA2_480p60     = "hdmi_mode=2 #CEA",
	rameCEA3_480p60w    = "hdmi_mode=3 #CEA",
	rameCEA4_720p60     = "hdmi_mode=4 #CEA",
	rameCEA5_1080i60    = "hdmi_mode=5 #CEA",
	rameCEA6_480i60     = "hdmi_mode=6 #CEA",
	rameCEA7_480i60w    = "hdmi_mode=7 #CEA",
	rameCEA8_240p60     = "hdmi_mode=8 #CEA",
	rameCEA9_240p60w    = "hdmi_mode=9 #CEA",
	rameCEA10_480i60pq  = "hdmi_mode=10 #CEA",
	rameCEA11_480i60pqw = "hdmi_mode=11 #CEA",
	rameCEA12_240p60pq  = "hdmi_mode=12 #CEA",
	rameCEA13_240p60pqw = "hdmi_mode=13 #CEA",
	rameCEA14_480p60pd  = "hdmi_mode=14 #CEA",
	rameCEA15_480p60pdw = "hdmi_mode=15 #CEA",
	rameCEA16_1080p60   = "hdmi_mode=16 #CEA",
	rameCEA17_576p50    = "hdmi_mode=17 #CEA",
	rameCEA18_576p50w   = "hdmi_mode=18 #CEA",
	rameCEA19_720p50    = "hdmi_mode=19 #CEA",
	rameCEA20_1080i50   = "hdmi_mode=20 #CEA",
	rameCEA21_576i50    = "hdmi_mode=21 #CEA",
	rameCEA22_576i50w   = "hdmi_mode=22 #CEA",
	rameCEA23_288p50    = "hdmi_mode=23 #CEA",
	rameCEA24_288p50w   = "hdmi_mode=24 #CEA",
	rameCEA25_576i50pq  = "hdmi_mode=25 #CEA",
	rameCEA26_576i50pqw = "hdmi_mode=26 #CEA",
	rameCEA27_288p50pq  = "hdmi_mode=27 #CEA",
	rameCEA28_288p50pqw = "hdmi_mode=28 #CEA",
	rameCEA29_576p50pd  = "hdmi_mode=29 #CEA",
	rameCEA30_576p50pdw = "hdmi_mode=30 #CEA",
	rameCEA31_1080p50   = "hdmi_mode=31 #CEA",
	rameCEA32_1080p24   = "hdmi_mode=32 #CEA",
	rameCEA33_1080p25   = "hdmi_mode=33 #CEA",
	rameCEA34_1080p30   = "hdmi_mode=34 #CEA",
	rameCEA35_480p60pq  = "hdmi_mode=35 #CEA",
	rameCEA36_480p60pqw = "hdmi_mode=36 #CEA",
	rameCEA37_576p50pq  = "hdmi_mode=37 #CEA",
	rameCEA38_576p50pqw = "hdmi_mode=38 #CEA",
	rameCEA39_1080i50rb = "hdmi_mode=39 #CEA",
	rameCEA40_1080i100  = "hdmi_mode=40 #CEA",
	rameCEA41_720p100   = "hdmi_mode=41 #CEA",
	rameCEA42_576p100   = "hdmi_mode=42 #CEA",
	rameCEA43_576p100w  = "hdmi_mode=43 #CEA",
	rameCEA44_576i100   = "hdmi_mode=44 #CEA",
	rameCEA45_576i100w  = "hdmi_mode=45 #CEA",
	rameCEA46_1080i120  = "hdmi_mode=46 #CEA",
	rameCEA47_720p120   = "hdmi_mode=47 #CEA",
	rameCEA48_480p120   = "hdmi_mode=48 #CEA",
	rameCEA49_480p120w  = "hdmi_mode=49 #CEA",
	rameCEA50_480i120   = "hdmi_mode=50 #CEA",
	rameCEA51_480i120w  = "hdmi_mode=51 #CEA",
	rameCEA52_576p200   = "hdmi_mode=52 #CEA",
	rameCEA53_576p200w  = "hdmi_mode=53 #CEA",
	rameCEA54_576i200   = "hdmi_mode=54 #CEA",
	rameCEA55_576i200w  = "hdmi_mode=55 #CEA",
	rameCEA56_480p240   = "hdmi_mode=56 #CEA",
	rameCEA57_480p240w  = "hdmi_mode=57 #CEA",
	rameCEA58_480i240   = "hdmi_mode=58 #CEA",
	rameCEA59_480i240w  = "hdmi_mode=59 #CEA",
	-- DMT modes: (hdmi_group=2)
	-- postfixes: rb=reduced blanking
	rameDMT1_640x350x85         = "hdmi_mode=1 #DMT",
	rameDMT2_640x400x85         = "hdmi_mode=2 #DMT",
	rameDMT3_720x400x85         = "hdmi_mode=3 #DMT",
	rameDMT4_640x480x60         = "hdmi_mode=4 #DMT",
	rameDMT5_640x480x72         = "hdmi_mode=5 #DMT",
	rameDMT6_640x480x75         = "hdmi_mode=6 #DMT",
	rameDMT7_640x480x85         = "hdmi_mode=7 #DMT",
	rameDMT8_800x600x56         = "hdmi_mode=8 #DMT",
	rameDMT9_800x600x60         = "hdmi_mode=9 #DMT",
	rameDMT10_800x600x72        = "hdmi_mode=10 #DMT",
	rameDMT11_800x600x75        = "hdmi_mode=11 #DMT",
	rameDMT12_800x600x85        = "hdmi_mode=12 #DMT",
	rameDMT13_800x600x120       = "hdmi_mode=13 #DMT",
	rameDMT14_848x480x60        = "hdmi_mode=14 #DMT",
	--rameDMT15_1024x768x43       = "hdmi_mode=15 #DMT", -- not RPi compatible
	rameDMT16_1024x768x60       = "hdmi_mode=16 #DMT",
	rameDMT17_1024x768x70       = "hdmi_mode=17 #DMT",
	rameDMT18_1024x768x75       = "hdmi_mode=18 #DMT",
	rameDMT19_1024x768x85       = "hdmi_mode=19 #DMT",
	rameDMT20_1024x768x120      = "hdmi_mode=20 #DMT",
	rameDMT21_1152x864x75       = "hdmi_mode=21 #DMT",
	rameDMT22_1280x768rb        = "hdmi_mode=22 #DMT",
	rameDMT23_1280x768x60       = "hdmi_mode=23 #DMT",
	rameDMT24_1280x768x75       = "hdmi_mode=24 #DMT",
	rameDMT25_1280x768x85       = "hdmi_mode=25 #DMT",
	rameDMT26_1280x768x120rb    = "hdmi_mode=26 #DMT",
	rameDMT27_1280x800rb        = "hdmi_mode=27 #DMT",
	rameDMT28_1280x800x60       = "hdmi_mode=28 #DMT",
	rameDMT29_1280x800x75       = "hdmi_mode=29 #DMT",
	rameDMT30_1280x800x85       = "hdmi_mode=30 #DMT",
	rameDMT31_1280x800x120rb    = "hdmi_mode=31 #DMT",
	rameDMT32_1280x960x60       = "hdmi_mode=32 #DMT",
	rameDMT33_1280x960x85       = "hdmi_mode=33 #DMT",
	--rameDMT34_1280x960x120rb    = "hdmi_mode=34 #DMT", -- >pixel clock limit
	rameDMT35_1280x1024x60      = "hdmi_mode=35 #DMT",
	rameDMT36_1280x1024x75      = "hdmi_mode=36 #DMT",
	rameDMT37_1280x1024x85      = "hdmi_mode=37 #DMT",
	--rameDMT38_1280x1024x120rb   = "hdmi_mode=38 #DMT", -- >pixel clock limit
	rameDMT39_1360x768x60       = "hdmi_mode=39 #DMT",
	rameDMT40_1360x768x120rb    = "hdmi_mode=40 #DMT",
	rameDMT41_1400x1050rb       = "hdmi_mode=41 #DMT",
	rameDMT42_1400x1050x60      = "hdmi_mode=42 #DMT",
	rameDMT43_1400x1050x75      = "hdmi_mode=43 #DMT",
	rameDMT44_1400x1050x85      = "hdmi_mode=44 #DMT",
	--rameDMT45_1400x1050x120rb   = "hdmi_mode=45 #DMT", -- >pixel clock limit
	rameDMT46_1440x900rb        = "hdmi_mode=46 #DMT",
	rameDMT47_1440x900x60       = "hdmi_mode=47 #DMT",
	rameDMT48_1440x900x75       = "hdmi_mode=48 #DMT",
	rameDMT49_1440x900x85       = "hdmi_mode=49 #DMT",
	--rameDMT50_1440x900x120rb    = "hdmi_mode=50 #DMT", -- >pixel clock limit
	rameDMT51_1600x1200x60      = "hdmi_mode=51 #DMT",
	rameDMT52_1600x1200x65      = "hdmi_mode=52 #DMT",
	--rameDMT53_1600x1200x70      = "hdmi_mode=53 #DMT", -- >pixel clock limit
	--rameDMT54_1600x1200x75      = "hdmi_mode=54 #DMT", -- >pixel clock limit
	--rameDMT55_1600x1200x85      = "hdmi_mode=55 #DMT", -- >pixel clock limit
	--rameDMT56_1600x1200x120rb   = "hdmi_mode=56 #DMT", -- >pixel clock limit
	rameDMT57_1680x1050rb       = "hdmi_mode=57 #DMT",
	rameDMT58_1680x1050x60      = "hdmi_mode=58 #DMT",
	--rameDMT59_1680x1050x75      = "hdmi_mode=59 #DMT", -- >pixel clock limit
	--rameDMT60_1680x1050x85      = "hdmi_mode=60 #DMT", -- >pixel clock limit
	--rameDMT61_1680x1050x120rb   = "hdmi_mode=61 #DMT", -- >pixel clock limit
	--rameDMT62_1792x1344x60      = "hdmi_mode=62 #DMT", -- >pixel clock limit
	--rameDMT63_1792x1344x75      = "hdmi_mode=63 #DMT", -- >pixel clock limit
	--rameDMT64_1792x1344x120rb   = "hdmi_mode=64 #DMT", -- >pixel clock limit
	--rameDMT65_1856x1392x60      = "hdmi_mode=65 #DMT", -- >pixel clock limit
	--rameDMT66_1856x1392x75      = "hdmi_mode=66 #DMT", -- >pixel clock limit
	--rameDMT67_1856x1392x120rb   = "hdmi_mode=67 #DMT", -- >pixel clock limit
	rameDMT68_1920x1200rb       = "hdmi_mode=68 #DMT",
	--rameDMT69_1920x1200x60    = "hdmi_mode=69 #DMT", -- >pixel clock limit
	--rameDMT70_1920x1200x75    = "hdmi_mode=70 #DMT", -- >pixel clock limit
	--rameDMT71_1920x1200x85    = "hdmi_mode=71 #DMT", -- >pixel clock limit
	--rameDMT72_1920x1200x120rb = "hdmi_mode=72 #DMT", -- >pixel clock limit
	--rameDMT73_1920x1440x60    = "hdmi_mode=73 #DMT", -- >pixel clock limit
	--rameDMT74_1920x1440x75    = "hdmi_mode=74 #DMT", -- >pixel clock limit
	--rameDMT75_1920x1440x120rb = "hdmi_mode=75 #DMT", -- >pixel clock limit
	--rameDMT76_2560x1600rb     = "hdmi_mode=76 #DMT", -- >pixel clock limit
	--rameDMT77_2560x1600x60    = "hdmi_mode=77 #DMT", -- >pixel clock limit
	--rameDMT78_2560x1600x75    = "hdmi_mode=78 #DMT", -- >pixel clock limit
	--rameDMT79_2560x1600x85    = "hdmi_mode=79 #DMT", -- >pixel clock limit
	--rameDMT80_2560x1600x120rb = "hdmi_mode=80 #DMT", -- >pixel clock limit
	rameDMT81_1366x768x60     = "hdmi_mode=81 #DMT",
	rameDMT82_1920x1080x60    = "hdmi_mode=82 #DMT", -- 1080p
	rameDMT83_1600x900rb      = "hdmi_mode=83 #DMT",
	--rameDMT84_2048x1152rb     = "hdmi_mode=84 #DMT", -- >pixel clock limit
	rameDMT85_1280x720x60     = "hdmi_mode=85 #DMT", -- 720p
	rameDMT86_1366x768rb      = "hdmi_mode=86 #DMT",
	rameDMT87_custom = "hdmi_mode=87 #DMT", -- put raw hdmi_timings to user/config.txt on SD-card
}
local rpi_resolutions_rev = revtable(rpi_resolutions)
local rpi_resolutionfield_update = {
	rame720p50  = rpi_resolutions.rameCEA19_720p50,
	rame720p60  = rpi_resolutions.rameCEA4_720p60,
	rame1080i50 = rpi_resolutions.rameCEA20_1080i50,
	rame1080i60 = rpi_resolutions.rameCEA5_1080i60,
	rame1080p50 = rpi_resolutions.rameCEA31_1080p50,
	rame1080p60 = rpi_resolutions.rameCEA16_1080p60,
}

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
	RAME.system.audio_mono_out(conf.audioMono)
	RAME.config.omxplayer_audio_out = omxplayer_audio_outs[conf.audioPort]
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
local function is_valid_tz(name)
	return name:sub(1,1) ~= '.' and
		name ~= 'right' and
		name ~= 'posixrules' and
		name:match('%.tab$') == nil
end

-- returns table of timezones
local function scan_timezones(tzmap, tzlist, path, prefix)
	for file in lfs.dir(path) do
		if is_valid_tz(file) then
			local f = path .. '/' .. file
			local attr = lfs.attributes(f)
			if attr.mode == 'directory' then
				scan_timezones(tzmap, tzlist, f, file .. '/')
			else
				local tz = prefix .. file
				table.insert(tzlist, tz)
				tzmap[tz] = true
			end
		end
	end
	return tzmap, tzlist
end

local function read_timezones()
	if not plpath.exists(timezone_path) then return end
	timezones_map, timezones_list = scan_timezones({}, {}, timezone_path, "")
	table.sort(timezones_list)
	local tz = posix.readlink("/etc/localtime")
	if tz and tz:sub(1, #timezone_path) == timezone_path then
		RAME.system.timezone(tz:sub(#timezone_path+1))
	end
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
			if rpi_resolutionfield_update[rpi_resolutions_rev[val]] then
				val = rpi_resolutionfield_update[rpi_resolutions_rev[val]]
			end
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

	local ntp_conf = plfile.read("/etc/ntp.conf")
	if ntp_conf then
		local servers = nil
		for w in string.gmatch(ntp_conf, "server ([^\n]+)") do
			servers = (servers and servers.."," or "") .. w
		end
		conf.ntpServerAddress = servers
	end

	conf.dateAndTimeInUTC = os.date("!%Y-%m-%d %T")
	conf.timezone = RAME.system.timezone()
	conf.timezones = timezones_list

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
		timezone = {typeof="string", choices=timezones_map, optional=true}
	})
	if err then return err, msg end


	if args.resolution ~= "" and rpi_resolutionfield_update[args.resolution] then
		local oldresolution = args.resolution
		args.resolution = rpi_resolutions_rev[rpi_resolutionfield_update[args.resolution]]
	end

	--
	-- RPi PARAMS RESOLUTION AND DISPLAY-ROTATION
	--
	table.insert(rpi_conf, "# NOTE: This file is auto-updated, don't edit!\n"
	                     .."#       (place customizations in SD card to user/config.txt)")
	--table.insert(rpi_conf, "hdmi_group=1")
	for resmatcher,hdmiline in pairs(rpi_resolution_string_match_to_hdmigroup) do
		if args.resolution:match(resmatcher) then
			table.insert(rpi_conf, hdmiline)
			break
		end
	end
	table.insert(rpi_conf, rpi_resolutions[args.resolution])
	table.insert(rpi_conf, rpi_display_rotation[args.displayRotation])

	local old_config = plutils.readfile(RAME.config.settings_path..ramecfg_txt)
	local new_config = table.concat(rpi_conf, "\n") .. "\n"
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
		local ntp_conf = plfile.read("/etc/ntp.conf")
		local new_conf = ""
		for _,w in pairs(plutils.split(args.ntpServerAddress, ',')) do
			new_conf = new_conf .. "server "..w.."\n"
		end

		if ntp_conf ~= new_conf then
			if not plfile.write("/etc/ntp.conf", new_conf) then
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
	local timezone = RAME.system.timezone()
	if args.timezone and timezone ~= args.timezone then
		RAME.log.info("prev. timezone: " .. timezone)
		RAME.log.info("Setting timezone: " .. args.timezone)
		RAME.system.timezone(args.timezone)
		plfile.delete("/etc/timezone")
		posix.link("/usr/share/zoneinfo/" .. args.timezone, "/etc/localtime", true)
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

	RAME.system.timezone:push_to(function(tz) posix.setenv("TZ", ":"..tz) end)
	read_timezones()

	ok, conf = SETTINGS.GET.system()
	if ok == 200 then activate_config(conf) end

	RAME.rest.settings = function(ctx, reply) return ctx:route(reply, SETTINGS) end
end

return Plugin
