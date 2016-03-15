local RAME = require 'rame.rame'
local json = require 'cjson.safe'

-- persistant storage for audio volume levels
local audio_json = "audio.json"

-- REST API: /audio/
local AUDIO = { GET = {}, PUT = {} }

local audio_chs = {
	headphone = {
		volume = RAME.system.headphone_volume(),
		min = 0,
		max = 100,
		-- db values are only used for sending to web as reference
		min_db = "-64.0",
		max_db = "0",
		func = RAME.system.headphone_volume
	},
	lineout = {
		volume = RAME.system.lineout_volume(),
		min = 0,
		max = 110,
		-- db values are only used for sending to web as reference
		min_db = "-64.0",
		max_db = "6.4",
		func = RAME.system.lineout_volume
	}
}

function AUDIO.GET(ctx, reply)
	local temp = {}

	for k, v in pairs(audio_chs) do
		table.insert(temp,
			{
				id = k,
				volume = v.volume,
				min = v.min,
				max = v.max,
				minDb = v.min_db,
				maxDb = v.max_db
			})
	end

	return 200, {
	  channels = temp
	}
end

function AUDIO.PUT(ctx, reply)
	local args = ctx.args
	local paths = ctx.paths
	local path_pos = ctx.path_pos

	-- add check function for volume
	err, msg = RAME.check_fields(args, {
		volume = {typeof="number"}
	})
	if err then return err, msg end

	if not #paths == 2 then
		return 404, "specify the channel"
	end

	local chn_name = paths[path_pos]
	local channel = audio_chs[chn_name]
	if channel then
		local vol = args.volume
		if vol < channel.min then vol = channel.min end
		if vol > channel.max then vol = channel.max end
		channel.volume = vol
		RAME.log.debug("audio.put "..chn_name.."="..vol)
		channel.func(vol)
	end

	-- Store the new audio levels - writing the whole table
	if not RAME.write_settings_file(audio_json, json.encode(audio_chs)) then
		return 500, "file write error"
	end

	return 200
end

local Plugin = {}

function Plugin.init()
	-- Read the stored values (or in case of 1st boot "")
	local audio_conf = json.decode(RAME.read_settings_file(audio_json) or "")
	if audio_conf ~= nil then
		for k, v in pairs(audio_chs) do
			audio_chs[k].volume = audio_conf[k].volume
		end
	else RAME.log.info("No audio info stored - going with defaults") end


	RAME.rest.audio = function(ctx, reply) return ctx:route(reply, AUDIO) end
end

return Plugin
