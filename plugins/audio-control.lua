local RAME = require 'rame.rame'
local json = require 'cjson.safe'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'

-- persistant storage for audio volume levels
local audio_json = "audio.json"

-- REST API: /audio/
local AUDIO = { GET = {}, PUT = {} }

local audio_chs = {
	headphone = {
		min = 0,
		max = 100,
		-- db values are only used for sending to web as reference
		min_db = "-64.0",
		max_db = "0",
		property = RAME.system.headphone_volume
	},
	lineout = {
		min = 0,
		max = 110,
		-- db values are only used for sending to web as reference
		min_db = "-64.0",
		max_db = "6.4",
		property = RAME.system.lineout_volume
	}
}

function AUDIO.GET(ctx, reply)
	local temp = {}

	for k, v in pairs(audio_chs) do
		table.insert(temp, {
			id = k,
			volume = v.property(),
			min = v.min,
			max = v.max,
			minDb = v.min_db,
			maxDb = v.max_db
		})
	end

	return 200, { channels = temp }
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
		RAME.log.error("Specify the channel!")
		return 404, { error= "Specify the channel!" }
	end

	local chn_name = paths[path_pos]
	local channel = audio_chs[chn_name]
	if channel then
		local vol = args.volume
		if vol < channel.min then vol = channel.min end
		if vol > channel.max then vol = channel.max end
		RAME.log.debug("audio.put "..chn_name.."="..vol)
		channel.property(vol)
	end

	return 200, {}
end

local Plugin = {}

Plugin.settings_changed = condition.new()

function Plugin.init()
	-- Read the stored values (or in case of 1st boot "")
	local audio_conf = json.decode(RAME.read_settings_file(audio_json) or "")
	if audio_conf ~= nil then
		for k, v in pairs(audio_chs) do
			if audio_conf[k] ~= nil then
				v.property(audio_conf[k].volume)
			end
		end
	else RAME.log.info("No audio info stored - going with defaults.") end

	for k, v in pairs(audio_chs) do
		v.property:push_to(function() Plugin.settings_changed:signal() end)
	end

	RAME.rest.audio = function(ctx, reply) return ctx:route(reply, AUDIO) end
end

function Plugin.main()
	local timeout = nil
	while true do
		local ret = cqueues.poll(Plugin.settings_changed, timeout)
		if ret == timeout then
			timeout = nil
			RAME.log.info("Storing changed audio levels to disk")

			-- Store the new audio levels - writing the whole table
			local saved = {}
			for k, v in pairs(audio_chs) do
				saved[k] = { volume = v.property() }
			end
			local saved_json, err = json.encode(saved)
			if saved_json == nil or
			   not RAME.write_settings_file(audio_json, saved_json) then
				RAME.log.error("Failed to write audio settings: " .. (err or "nil"))
			end
		else
			-- Trigger timeout to write to disk
			timeout = 10.0
		end
	end
end

return Plugin
