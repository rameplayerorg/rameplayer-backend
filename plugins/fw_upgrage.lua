local plfile = require 'pl.file'
local process = require 'cqp.process'
local RAME = require 'rame.rame'

local UPGRADE = {}
local srv_url, srv_path, str

function UPGRADE.GET(ctx, reply)
	local srv_fw_paths = {}
	local fws = {}
	local firmwares = {}

	local out = process.popen("rsync", srv_url)
	str = out:read_all()
	out:close()

	-- firmware path must contain keyword "rameplayer" to be included
	for v,k in str:gmatch("(rameplayer[^\t]+)\t([^\n]+)") do
		srv_fw_paths[v]=k
	end

	if next(srv_fw_paths) == nil then
   		return 500, "parsing of available firmwares failed"
	end

	for i,v in pairs(srv_fw_paths) do
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
	print(ctx.args.uri)
	srv_path = srv_url.."/"..ctx.args.uri.."/"
	print(srv_path)
	local out = process.popen("/sbin/rame-upgrade-firmware", srv_path)
	str = out:read_all()
	out:close()
	print(str)
	RAME.system.reboot_required(true)

	return 200
end

local Plugin = {}

function Plugin.init()
	str = plfile.read("/etc/rame-upgrade.conf")
	if not str then return nil, "file read failed" end

	srv_url, srv_path = str:match('(rsync://[^%/]+)([^"]+)')
	if srv_url == nil or srv_path == nil then
 		return nil, "rsync server and path parsing failed"
	end

	RAME.rest.upgrade = function(ctx, reply) return ctx:route(reply, UPGRADE) end
end

return Plugin
