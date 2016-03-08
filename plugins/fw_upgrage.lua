local posix = require 'posix'
local plfile = require 'pl.file'
local cqueues = require 'cqueues'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local UPGRADE = {}

function UPGRADE.GET(ctx, reply)
	local srv_fw_paths = {}
	local fws = {}
	local firmwares = {}

	local out = process.popen("rsync", srv_url)
	local str = out:read_all()
	out:close()

	-- firmware path must contain keyword "rameplayer" to be included
	for v, k in str:gmatch("(rameplayer[^\t]+)\t([^\n]+)") do
		srv_fw_paths[v]=k
	end

	if next(srv_fw_paths) == nil then
   		return 500, "parsing of available firmwares failed"
	end

	for i, v in pairs(srv_fw_paths) do
		local t = {}
		t.uri = i
	 	t.title = v
		-- firmware path must contain keyword "latest" to identify LATEST rel
		if i:match("(latest)") ~= nil then t.latest = true end
		-- firmware path must contain keyword "stable" to identify STABLE rel
		if i:match("(stable)") ~= nil then t.stable = true end
		table.insert(fws,t)
	end

	return 200, { firmwares = fws }
end

--todo implement check_fields() checking
function UPGRADE.PUT(ctx, reply)
	local uri = nil
	if ctx.args then uri = ctx.args.uri end
	print("Upgrade firmware from " .. (uri or "(default location)"))

	if RAME.system.firmware_upgrade() >= 0 then
		return 500, "Firmware upgrade already in progress"
	end

	RAME.system.firmware_upgrade(0)
	cqueues.running():wrap(function()
		local out = process.popen("/sbin/rame-upgrade-firmware", uri)
		while true do
			local data, errmsg, errnum = out:read(1024)
			if data == nil and errnum == posix.EAGAIN then
				cqueues.poll(self)
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
		RAME.system.reboot_required(true)
	end)

	return 200
end

local Plugin = {}

function Plugin.init()
	local str = plfile.read("/etc/rame-upgrade.conf")
	if not str then return nil, "file read failed" end

	RAME.rest.upgrade = function(ctx, reply) return ctx:route(reply, UPGRADE) end
end

return Plugin
