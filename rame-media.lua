local json = require 'cjson'
local pldir = require 'pl.dir'
local plfile = require 'pl.file'
local plpath = require 'pl.path'

-- Media Libaries
local medialib = {}

-- REST API: /media/
local REST = function(ctx, reply)
	local libs = {}
	for name, obj in pairs(medialib) do table.insert(libs, obj) end
	reply.headers["Content-Type"] = "application/json"
	return 200, json.encode(libs)
end


-- Plugin Hooks
local Plugin = {}

function Plugin.init()
	RAME.rest.media = function(ctx, reply) return ctx:route(reply, REST, true) end
end

function Plugin.media_changed(mountpoint, name)
	print("media_changed", mountpoint, name)
	local data = {
		uri = "rameplayer://"..name,
		title = dirname,
		medias = {}
	}
	local files = pldir.getfiles(mountpoint, "*.mp4")
	table.sort(files)
	for track, f in pairs(files) do
		local basename = plpath.basename(f)
		table.insert(data.medias, {
			uri = ("rameplayer://%s/%s"):format(name, basename),
			filename = basename,
			title = basename,
			duration = 0,
			created = plfile.modified_time(f) * 1000,
		})
	end
	medialib[name] = #data.medias and data or nil
	print(("Scanned %s, %d found"):format(name, #data.medias))

	-- Autoplay
	if true then
		RAME:hook("set_playlist", data.medias)
	end
end

return Plugin
