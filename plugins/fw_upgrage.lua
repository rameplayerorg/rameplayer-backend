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


function UPGRADE.GET(ctx, reply)
	local base = get_rsync_base()
	if not base then return 500, "upgrade server not configured" end

	local out = process.popen("rsync", base)
	local str = out:read_all()
	out:close()

	-- firmware path must contain keyword "rameplayer" to be included
	local fws = {}
	for uri, title in str:gmatch("(rameplayer[^\t]+)\t([^\n]+)") do
		table.insert(fws, {
			uri = uri,
			title = title,
			latest = uri:match("(latest)") and true or nil,
			stable = uri:match("(stable)") and true or nil,
		})
	end
	if #fws == 0 then return 500, "no available firmwares" end

	return 200, { firmwares = fws }
end

--todo implement check_fields() checking
function UPGRADE.PUT(ctx, reply)
	local uri = nil
	if ctx.args and ctx.args.uri then
		uri = get_rsync_base() .. "/" .. ctx.args.uri
	end
	print("Upgrade firmware from " .. (uri or "(default location)"))

	if RAME.system.firmware_upgrade() ~= nil then
		return 500, "Firmware upgrade already in progress"
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
				local p = data:match(".* (%d)%%")
				p = tonumber(p)
				if p then
					RAME.system.firmware_upgrade(p)
				end
			end
		end
		out:close()
		RAME.system.firmware_upgrade(100)
		process.run("reboot", "now")
	end)

	return 200
end

local Plugin = {}

function Plugin.init()
	RAME.rest.upgrade = function(ctx, reply) return ctx:route(reply, UPGRADE) end
end

return Plugin
