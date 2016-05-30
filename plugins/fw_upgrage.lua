local posix = require 'posix'
local plfile = require 'pl.file'
local cqueues = require 'cqueues'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local UPGRADE = {}

local function get_rsync_base()
	local str = plfile.read("/etc/rame-upgrade.conf")
	if not str then return nil, "file read failed" end

	local srv_url, srv_path = str:match('(rsync://[^%/]+)([^"]+)')
	if srv_url == nil or srv_path == nil then
		return nil, "rsync server and path parsing failed"
	end
	return srv_url
end

-- splitByDot("a.bbc.d") == {"a", "bbc", "d"}
local function splitByDot(str)
	str = str or ""
	local t, count = {}, 0
	str:gsub("([^%.]+)", function(c)
		count = count + 1
		t[count] = c
	end)
	return t
end

local function comparever(a, b)
	local at = splitByDot(a or "")
	local bt = splitByDot(b or "")
	for i, ai in ipairs(at) do
		local av = tonumber(ai)
		local bv = tonumber(bt[i])
		if av == nil and bv == nil then return 0 end
		if av == nil then return -1 end
		if bv == nil then return 1 end
		if av > bv then return 1 end
		if av < bv then return -1 end
	end
	return 0
end

function UPGRADE.GET(ctx, reply)
	local base = get_rsync_base()
	if not base then return 500, { error="upgrade server not configured" } end

	local out = process.popen("rsync", base)
	local str = out:read_all()
	out:close()

	-- firmware path must contain keyword "rameplayer" to be included
	local fws, latest = {}, {}
	for version, title in str:gmatch("rameplayer%-([^\t]+)\t([^\n]+)") do
		local info = {
			uri = "rameplayer-"..version,
			title = title,
			version = version:match("^([0-9.]+)"),
			stable = version:match("(stable)") and true or nil,
		}
		if info.stable and comparever(info.version, latest.version) > 0 then
			latest = info
		end
		table.insert(fws, info)
	end
	if #fws == 0 then return 502, { error="no available firmwares" } end
	if latest then latest.latest = true end

	return 200, { firmwares = fws }
end

--todo implement check_fields() checking
function UPGRADE.PUT(ctx, reply)
	local uri = nil
	if ctx.args and ctx.args.uri then
		uri = get_rsync_base() .. "/" .. ctx.args.uri
	end
	RAME.log.warn("Upgrade firmware from " .. (uri or "(default location)"))

	if RAME.system.firmware_upgrade() ~= nil then
		return 500, { error="Firmware upgrade already in progress" }
	end

	RAME.system.firmware_upgrade(0)
	cqueues.running():wrap(function()
		local out = process.popen("/sbin/rame-upgrade-firmware", uri)
		while true do
			local data, errmsg, errnum = out:read(1024)
			if data == nil and errnum == posix.EAGAIN then
				cqueues.poll(out)
			elseif data == nil or #data == 0 then
				break
			else
				-- rsync output, parse just percentage
				-- 1,238,099 100%  146.38kB/s    0:00:08  (xfr#5, to-chk=169/396)
				for p in data:gmatch(" (%d)%%") do
					p = tonumber(p)
					if p then
						RAME.system.firmware_upgrade(p)
					end
				end
			end
		end
		out:close()
		RAME.system.firmware_upgrade(100)
		RAME.reboot_device()
	end)

	return 200
end

local Plugin = {}

function Plugin.init()
	RAME.rest.upgrade = function(ctx, reply) return ctx:route(reply, UPGRADE) end
end

return Plugin
