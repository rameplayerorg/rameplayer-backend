local RAME = require 'rame.rame'

-- REST API: /audio/
local AUDIO = { GET = {}, PUT = {} }

local function revtable(tbl)
	local rev={}
	for k, v in pairs(tbl) do rev[v] = k end
	return rev
end

local audio_chs = {
	headphone = "HPOUT1 Digital",
	lineout = "HPOUT2 Digital",
}
local audio_chs_rev = revtable(audio_chs)

function AUDIO.GET(ctx, reply)
	local temp = {}

	for k, v in pairs(audio_chs_rev) do
		table.insert(temp, { channel_name = { volume = 32 } })
		--table.insert(temp, k)
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
		volume
	})
	if err then return err, msg end

	if not #paths == 2 then
		return 404, "specify the channel"
	end

	--print(paths[path_pos])

	channel = audio_chs[paths[path_pos]]
	if channel then
 		print(channel)
	end

	-- todo do validy function
	--err, msg = RAME.check_val(, {typeof="string", choises=audio_chs}})
	--if err then return err, msg end
	-- todo check that range is 0-110!
	local volume = 50
	--process.run("amixer", "-Dhw:sndrpiwsp", "--", "sset", channel, ("%.2fdB"):format(64.0*volume/100 - 64.0))

	return 200--, return the set value in decibels
end

local Plugin = {}

function Plugin.init()
	RAME.rest.audio = function(ctx, reply) return ctx:route(reply, AUDIO) end
end

return Plugin
