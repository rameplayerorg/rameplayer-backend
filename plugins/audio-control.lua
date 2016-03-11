local RAME = require 'rame.rame'

-- REST API: /audio/
local AUDIO = { GET = {}, PUT = {} }


local audio_chs = {
	headphone = {
		prop = RAME.system.headphone_volume,
		min = 0,
		max = 100,
		-- db values are only used for sending to web as reference
		min_db = "-64.0",
		max_db = "0",
	},
	lineout = {
		prop = RAME.system.lineout_volume,
		min = 0,
		max = 110,
		-- db values are only used for sending to web as reference
		min_db = "-64.0",
		max_db = "6.4",
	}
}

function AUDIO.GET(ctx, reply)
	local temp = {}

	for k, v in pairs(audio_chs) do
		table.insert(temp,
			{
				id = k,
				volume = v.prop(),
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
		channel.prop(vol)
		RAME.log.debug("audio.put "..chn_name.."="..vol)
	end

	return 200
end

local Plugin = {}

function Plugin.init()
	RAME.rest.audio = function(ctx, reply) return ctx:route(reply, AUDIO) end
end

return Plugin
