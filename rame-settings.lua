-- Must be safe version of cjson-lib for errohandling
local json = require 'cjson.safe'
local plfile = require 'pl.file'
local RAME = require 'rame'

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
	local json_data = json.decode(data)
	if not json_data then return 500 end

	local body = json.encode(json_data)
	if not body then return 500 end

	local status = plfile.write(file, body)
	if not status then return 500 else return 200 end
end

function Settings.GET.user(ctx, reply)
	return read_json(RAME.settings_path .. "settings-user.json")
end

function Settings.POST.user(ctx, reply)
	return write_json(RAME.settings_path .. "settings-user.json", ctx.body)
end

function Settings.GET.system(ctx, reply)
	return read_json(RAME.settings_path .. "settings-system.json")
end

function Settings.POST.system(ctx, reply)
	return write_json(RAME.settings_path .. "settings-system.json", ctx.body)
end


-- REST API: /version/
local Version = {
	GET  = { },
}

function Version.GET(ctx, reply)
	return read_json(RAME.settings_path .. "version-rame.json")
end

-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	RAME.rest.settings = function(ctx, reply)
		reply.headers["Content-Type"] = "application/json"
		return ctx:route(reply, Settings)
	end
	RAME.rest.version = function(ctx, reply)
		reply.headers["Content-Type"] = "application/json"
		return ctx:route(reply, Version)
	end
end

return Plugin
