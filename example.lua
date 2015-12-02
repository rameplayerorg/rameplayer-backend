#!/usr/bin/lua5.2

local cqueues = require 'cqueues'
local notify = require 'cqueues.notify'
local push = require 'cqp.push'
local process = require 'cqp.process'
local httpd = require 'cqp.httpd'
local pldir = require 'pl.dir'
local plpath = require 'pl.path'
local plfile = require 'pl.file'
--local json = require 'cjson'
local json = require 'cjson.safe'
local posix = require 'posix'
local process = require 'cqp.process'

-- lists need date info as epoch
local os_time = require 'posix.sys.time'

-- nice way of printing lua tables
local inspect = require 'inspect'
local conf = require 'rame_config'
local jsonfile = require 'json_file'


-- Media API
local URI = {}
local file = push.property("", "Currently playing file")


-- todo add errorhandling
-- time is returned as ms from epoch
local function epoch_ms()
	local current_time = os_time.gettimeofday()
	return ((current_time.tv_sec * 1000) + (current_time.tv_usec / 1000))
end

URI["test"] = function(hdr, args, url_paths, method, body)
	local fp = conf.playlists_cache_path .. "/"
	local fp_root = fp .. conf.playlist_rootlist_basename .. conf.playlists_add_ext

	something = jsonfile(fp_root)
	something:print()
	print(something:count("playlists"))

	return 200, "OK"
end

URI["update"] = function(hdr, args, url_paths, method, body)
	local fp = conf.playlists_cache_path .. "/"
	local fp_root = fp .. conf.playlist_rootlist_basename .. conf.playlists_add_ext

	local temp_table = {}
	temp_table["title"] = "something"

	json_playlist_rootti = jsonfile(fp_root)
	json_playlist_rootti:insert("playlists", temp_table)
	json_playlist_rootti:print()
	print(json_playlist_rootti:count("playlists"))
	json_playlist_rootti:remove("playlists", 4)

	print(json_playlist_rootti:count("playlists"))
	json_playlist_rootti:update("modified", epoch_ms())
	json_playlist_rootti:print()

	--if not status then
	--	return 500, "Internal Server Error"
	--else
		return 200, "OK"
	--end
end

URI["lists"] = function(hdr, args, url_paths)
	-- converting the url path into filepath
	fp = conf.meta_cache_path .. "/" -- adding the base path

	if (#url_paths == 1) then
		if(url_paths.is_directory) then
			fp = fp .. conf.meta_folderlist_basename .. conf.meta_add_ext
		end
	else
		for i = 2, #url_paths do
			-- on a last index we check will it be directory or item request
			if (i == #url_paths) then
				if(url_paths.is_directory) then
					fp = fp .. url_paths[i] .. "/"
					.. conf.meta_folderlist_basename .. conf.meta_add_ext
				else
					fp = fp .. url_paths[i] .. conf.meta_add_ext
				end
			else
				fp = fp .. url_paths[i] .. "/"
			end
			--print(fp)
		end
	end

	data = plfile.read(fp)

	if not data then
		return 500, "Internal Server Error"
	else
		return 200, "OK", {
		"Access-Control-Allow-Origin: *",
		"Content-Type: application/json",
		}, data
	end
end

URI["playlists"] = function(hdr, args, url_paths, method, body)
	local status
	-- adding the base path
	local fp = conf.playlists_cache_path .. "/"
	local fp_root = fp .. conf.playlist_rootlist_basename .. conf.playlists_add_ext

	local json_playlist_root = jsonfile(fp_root)
	--json_playlist_root:print()

	-- root playlist
	if (#url_paths == 1) then

		if(method == "GET") then
			data = json_playlist_root:contents()
			if not data then
				return 500, "Internal Server Error"
			else
				return 200, "OK", {
				"Access-Control-Allow-Origin: *",
				"Content-Type: application/json",
				}, data
			end
		elseif (method == "POST") then -- accepting NEW playlist
			-- simple check for playlist json validity by decode & encode
			local new_playlist = json.decode(body)
			if not new_playlist then -- if decoding fails input data is faulty
				return 415, "Unsupported Media Type"
			else
				current_time_ms = epoch_ms()

				if not new_playlist.title then
					return 415, "Unsupported Media Type"
				else
					-- inserting the new playlist's title into ROOT playlist
					local temp_table = {}
					temp_table["title"] = new_playlist.title

					if not json_playlist_root:insert("playlists", temp_table) then
						return 500, "Internal Server Error"
					end
					if not json_playlist_root:update("modified",
											 current_time_ms) then
						return 500, "Internal Server Error"
					end
				end

				new_playlist.modified = current_time_ms
				-- writing the new playlist
				local data = json.encode(new_playlist)

				-- getting next free index
				-- note not checking if file with that id exists
				new_index = json_playlist_root:count("playlists")

				fp = fp .. new_index .. conf.playlists_add_ext

				if not data then
					return 500, "Internal Server Error"
				else
					if not plfile.write(fp, data) then
						return 500, "Internal Server Error"
					else
						return 200, "OK"
					end
				end
			end
		end
	elseif (#url_paths == 2) then 	-- 2nd item defines the index of the list
		-- 2nd item is the index of playlists
		fp = fp .. url_paths[2] .. conf.playlists_add_ext

		-- user can delete non-root list
		if(method == "DELETE") then
			-- removing the playlist from root playlist
			local status = json_playlist_root:remove("playlists", url_paths[2])
			if not status then
				return 500, "Internal Server Error"
			else
				-- updating the root timestamp
				status = json_playlist_root:update("modified", epoch_ms())
				if not status then
					return 500, "Internal Server Error"
				else
					-- deleting the json file
					status = plfile.delete(fp)
					if not status then
						return 500, "Internal Server Error"
					else
						return 200, "OK"
					end
				end
			end
 		end

		-- accepting UPDATES of playlist
		if(method == "POST") then
			-- simple check for playlist json validity by decode & encode
			playlist = json.decode(body)
			if not playlist then -- if decoding fails input data is faulty
				return 415, "Unsupported Media Type"
			else -- returning the settings to body (reusing it)

				body = json.encode(playlist)
				-- encoding should not fail if decode has succeed since
				-- data is not being touched but checking just in case
				if not body then
					return 500, "Internal Server Error"
				else
					if plfile.write(fp, body) then
						return 200, "OK"
					else
						return 500, "Internal Server Error"
					end
				end
			end
		end
	else
		return 404, "Not Found"
	end

	-- if not POST then GET
	if(method == "GET") then
		data = plfile.read(fp)

		if not data then
			return 500, "Internal Server Error"
		else
			return 200, "OK", {
			"Access-Control-Allow-Origin: *",
			"Content-Type: application/json",
			}, data
		end
	end
end

-- There is simple json validation (decoding/encoding) that ensures that webui
-- (or someone else accessing API) cannot (overwrite) settings non-json data
URI["settings"] = function(hdr, args, paths, method, body)

    -- client MUST specify user/system as 2nd path seqment
	if not (#paths == 2) then
		return 404, "Not Found"
	else
		if(paths[2] == "user") then
			if(method == "GET") then
				data = plfile.read(conf.settings_user_filepath)

				if not data then -- checking that file read was success
					return 500, "Internal Server Error"
				else
					return 200, "OK", {
						"Access-Control-Allow-Origin: *",
						"Content-Type: application/json",
								}, data
				end
			end
			if(method == "POST") then
				-- simple check for settings json validity by decode & encode
				settings = json.decode(body)
				if not settings then -- if decoding fails input data is faulty
					return 415, "Unsupported Media Type"
				else -- returning the settings to body (reusing it)
					body = json.encode(settings)
					-- encoding should not fail if decode has succeed since
					-- data is not being touched but checking just in case
					if not body then
						return 500, "Internal Server Error"
					else
						if plfile.write(conf.settings_user_filepath, body) then
							return 200, "OK"
						else
							return 500, "Internal Server Error"
						end
					end
				end
			end
		elseif(paths[2] == "system") then
			if(method == "GET") then
				data = plfile.read(conf.settings_system_filepath)

				if not data then
					return 500, "Internal Server Error"
				else
					return 200, "OK", {
						"Access-Control-Allow-Origin: *",
						"Content-Type: application/json",
								}, data
				end
			end
			if(method == "POST") then
				-- simple check for settings json validity by decode & encode
				settings = json.decode(body)
				if not settings then -- if decoding fails input data is faulty
					return 415, "Unsupported Media Type"
				else -- returning the settings to body (reusing it)
					body = json.encode(settings)
					-- encoding should not fail if decode has succeed since
					-- data is not being touched but checking just in case
					if not body then
						return 500, "Internal Server Error"
					else
						if plfile.write(conf.settings_system_filepath, body) then
							return 200, "OK"
						else
							return 500, "Internal Server Error"
						end
					end
				end
			end
		else -- if not system or user
			return 404, "Not Found"
    	end
	end
end

-- add json generation from different sources
URI["version"] = function(hdr, args, url_paths, method)

	-- on url path with only 1 parameter "version" is accepted
	if not (#url_paths == 1 and method == "GET") then
		return 404, "Not Found"
	else
		data = plfile.read(conf.version_filepath)

		if not data then -- checking that file read was success
			return 500, "Internal Server Error"
		else
			return 200, "OK", {
				"Access-Control-Allow-Origin: *",
				"Content-Type: application/json",
						}, data
		end
	end
end

-- Logic
local function setup()
	httpd.new{local_addr="0.0.0.0", port=8000, uri=URI}
end

local loop = cqueues.new()
loop:wrap(setup)
print(loop:loop())
