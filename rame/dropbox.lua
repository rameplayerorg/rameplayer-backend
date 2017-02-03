-- Dropbox API v2
-- https://dropbox.github.io/dropbox-api-v2-explorer/
--
-- Synchronizes only one-way: Dropbox -> client
-- Does not change any files in Dropbox

local posix = require 'posix'
local lfs = require 'lfs'
local json = require 'cjson.safe'
local cqueues = require 'cqueues'
local cqcurl = require 'rame.cqueues-curl'
local RAME = require 'rame.rame'

local BASE_URL = 'https://api.dropboxapi.com'
local CONTENT_URL = 'https://content.dropboxapi.com'

local Dropbox = {
	running = false,
	access_token = "",
	local_path = "",
	writing_start_callback = function()
		return true
	end,
	writing_end_callback = function()
		return true
	end,
	writing = false,
}
Dropbox.__index = Dropbox

local LOG = {}

function LOG.debug(...)
	local msg = ''
	for _,v in ipairs{...} do
		msg = msg .. tostring(v) .. "\t"
	end
	RAME.log.debug("Dropbox: " .. msg)
end

function LOG.err(...)
	local msg = ''
	for _,v in ipairs{...} do
		msg = msg .. tostring(v) .. "\t"
	end
	RAME.log.error("Dropbox: " .. msg)
end

local function split_lines(str)
	local t = {}
	local function helper(line) table.insert(t, line) return "" end
	helper((str:gsub("(.-)\r\n", helper)))
	return t
end

local http_client = {}

function http_client.POST(url, data, headers)
	local body_buf = {}
	local hdr_buf = {}
	local opt = {
		url = url;
		writefunction = function(buf)
			table.insert(body_buf, buf)
			return #buf
		end;
		headerfunction = function(buf)
			table.insert(hdr_buf, buf)
			return #buf
		end;
	}
	if headers then
		opt.httpheader = headers
	end
	if type(data) == 'table' then
		opt.postfields = json.encode(data)
	elseif type(data) == 'string' then
		opt.postfields = data
	end

	-- perform http request
	local code = cqcurl.perform(opt)
	local body = table.concat(body_buf)

	-- handle headers
	local hdrs = split_lines(table.concat(hdr_buf))
	local is_json = false
	for _, h in ipairs(hdrs) do
		if h:match("^Content.[Tt]ype: application/json") then
			is_json = true
		end
	end

	if is_json then
		body = json.decode(body)
	end

	return {
		status = code,
		headers = hdrs,
		data = body,
	}
end

function http_client.download(url, headers, target)
	local hdr_buf = {}
	LOG.debug('Downloading to file ' .. target)
	local file, err = io.open(target, 'w')
	if file == nil then
		LOG.err('Could not write file ' .. err)
		return {}
	end

	local opt = {
		url = url;
		writefunction = function(buf)
			file:write(buf)
			return #buf
		end;
		headerfunction = function(buf)
			table.insert(hdr_buf, buf)
			return #buf
		end;
	}
	if headers then
		opt.httpheader = headers
	end

	-- perform http request
	local code = cqcurl.perform(opt)
	file:close()

	LOG.debug('Download finished to file ' .. target)

	-- handle headers
	local hdrs = split_lines(table.concat(hdr_buf))

	return {
		status = code,
		headers = hdrs,
	}
end

function Dropbox:writing_start_event()
	return self.writing_start_callback()
end

function Dropbox:writing_end_event()
	return self.writing_end_callback()
end

function Dropbox:get_default_headers()
	return {
		'Authorization: Bearer ' .. self.access_token,
		'Content-Type: application/json',
	}
end

-- https://www.dropbox.com/developers/documentation/http/documentation#files-create_folder
function Dropbox:create_folder(path)
	local url = BASE_URL .. '/2/files/create_folder'
	return http_client.POST(url, { path = path }, self:get_default_headers())
end

-- https://www.dropbox.com/developers/documentation/http/documentation#files-delete
function Dropbox:delete_path(path)
	local url = BASE_URL .. '/2/files/delete'
	return http_client.POST(url, { path = path }, self:get_default_headers())
end

-- https://www.dropbox.com/developers/documentation/http/documentation#files-download
function Dropbox:download(path, target)
	local url = CONTENT_URL .. '/2/files/download'
	local headers = {
		'Authorization: Bearer ' .. self.access_token,
		'Dropbox-API-Arg: ' .. json.encode({ path = path }),
	}
	return http_client.download(url, headers, target)
end

-- https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder
function Dropbox:list_folder(path, recursive)
	local url = BASE_URL .. '/2/files/list_folder'
	return http_client.POST(url, {
		path = path,
		recursive = recursive
	}, self:get_default_headers())
end

-- https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder-continue
function Dropbox:list_folder_continue(cursor)
	local url = BASE_URL .. '/2/files/list_folder/continue'
	return http_client.POST(url, { cursor = cursor }, self:get_default_headers())
end

-- https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder-longpoll
function Dropbox:poll_folder(path, cursor)
	self.running = true
	local url = 'https://notify.dropboxapi.com/2/files/list_folder/longpoll'
	local response = {}
	repeat
		LOG.debug('polling changes on ' .. path)
		response = http_client.POST(url,
			{ cursor = cursor },
			{ 'Content-Type: application/json' }
		)
		if self.running and response.data then
			if response.data.error and response.data.error['.tag'] == 'reset' then
				-- cursor has been invalidated, get a new cursor
				cursor = callback()
			elseif response.data.changes then
				-- change detected
				LOG.debug('change detected on folder ' .. path)
				local entries = {}
				cursor, entries = self:get_entries_by_cursor(cursor)
				self:sync_entries(path, entries)
			end
			if response.data.backoff then
				-- wait until start polling again
				LOG.info('server asked to back off for ' .. response.data.backoff .. ' seconds')
				cqueues.poll(response.data.backoff)
			end
		end
	until not self.running or response.status ~= 200 or cursor == nil
	LOG.debug('end of poll_folder', path)
end

-- https://www.dropbox.com/developers/documentation/http/documentation#users-get_current_account
function Dropbox:get_current_account()
	local url = BASE_URL .. '/2/users/get_current_account'
	return http_client.POST(url, 'null', self:get_default_headers())
end

-- https://www.dropbox.com/developers/documentation/http/documentation#users-get_account
function Dropbox:get_account(account_id)
	local url = BASE_URL .. '/2/users/get_account'
	return http_client.POST(url, { account_id = account_id }, self:get_default_headers())
end

-- https://www.dropbox.com/developers/documentation/http/documentation#files-get_metadata
function Dropbox:get_metadata(path)
	local url = BASE_URL .. '/2/files/get_metadata'
	return http_client.POST(url, { path = path }, self:get_default_headers())
end

function Dropbox:handle_error(resp)
	local msg = "HTTP error " .. resp.status
	if resp.data then
		msg = msg .. ' ' .. resp.data.error_summary .. ' - ' .. json.encode(resp.data.error)
	end
	LOG.err(msg)
end

function Dropbox:remove_missing(path, entries)
	for file in lfs.dir(path) do
		-- ignore directories and files starting with dot
		if file:sub(1,1) ~= '.' then
			local f = path .. '/' .. file
			local attr = lfs.attributes(f)
			if attr.mode == 'directory' then
				self:remove_missing(f, entries)
			elseif attr.mode == 'file' then
				if not self:file_in_entries(f, entries) then
					LOG.debug('removing file ' .. f)
					if not self.writing then
						self:writing_start_event()
						self.writing = true
					end
					local success, err = os.remove(f)
					if not success then
						LOG.err('Removing file ' .. f .. ' failed: ' .. err)
					end
				end
			end
		end
	end
	if not self:folder_in_entries(path, entries) and path ~= self.local_path then
		LOG.debug('removing folder ' .. path)
		if not self.writing then
			self:writing_start_event()
			self.writing = true
		end
		lfs.rmdir(path)
	end
end

function Dropbox:file_in_entries(path, entries)
	for i, entry in ipairs(entries) do
		if entry['.tag'] == 'file' and path:lower() == string.lower(self.local_path .. entry.path_display) then
			return true
		end
	end
	return false
end

function Dropbox:folder_in_entries(path, entries)
	for i, entry in ipairs(entries) do
		if entry['.tag'] == 'folder' and path:lower() == string.lower(self.local_path .. entry.path_lower) then
			return true
		end
	end
	return false
end

local function path_exists(path)
	return lfs.attributes(path) ~= nil
end

-- returns true if given file entry exists
local function file_entry_exists(entry, real_path)
	local attr = lfs.attributes(real_path)
	-- file sizes must match
	return attr ~= nil and attr.size == entry.size
end

-- Returns table of all subdirectories under given path
function Dropbox.walk_subdirs(path)
	local dirs = {}
	for file in lfs.dir(path) do
		if file ~= '.' and file ~= '..' then
			local f = path .. '/' .. file
			local attr = lfs.attributes(f)
			if attr.mode == 'directory' then
				table.insert(dirs, f)
				local subdirs = Dropbox.walk_subdirs(f)
				for i, subdir in ipairs(subdirs) do
					table.insert(dirs, subdir)
				end
			end
		end
	end
	return dirs
end

-- returns existing dir matching given path (incase-sensitive)
function Dropbox.find_matching_dir(path, dirs)
	for i, dir in ipairs(dirs) do
		if path:lower() == dir:lower() then
			return dir
		end
	end
	return nil
end

-- works like dirname command
-- returns directory part from given path
function Dropbox.dirname(path)
	-- find last occurrence of slash
	local s = path:find("/[^/]*$") or 1
	local dirname = path:sub(1, s - 1)
	return dirname
end

function Dropbox:get_real_path(entry, dirs)
	local path = self.dirname(self.local_path .. entry['path_lower'])
	path = self.find_matching_dir(path, dirs)
	if path == nil then
		-- no existing dir found
		return self.local_path .. entry['path_display']
	end
	return path .. '/' .. entry['name']
end

function Dropbox:sync_entries(path, entries)
	local local_subdirs = self.walk_subdirs(self.local_path)

	-- add/update folders/files
	for i, entry in ipairs(entries) do
		local real_path = self:get_real_path(entry, local_subdirs)
		local tag = entry['.tag']
		if tag == 'folder' then
			if not path_exists(real_path) then
				LOG.debug('creating directory ' .. real_path)
				-- create directory
				if not self.writing then
					self:writing_start_event()
					self.writing = true
				end
				local success, err = lfs.mkdir(real_path)
				if success then
					table.insert(local_subdirs, real_path)
				else
					local msg = 'ERROR: Could not create directory ' .. real_path .. ' ' .. err
					LOG.err(msg)
				end
			else
				LOG.debug('matching folder exists already: ' .. real_path)
			end
		elseif tag == 'file' then
			if not file_entry_exists(entry, real_path) then
				-- download new/changed file
				LOG.debug('download to ' .. real_path)
				if not self.writing then
					-- callback
					self:writing_start_event()
					self.writing = true
				end
				self:download(entry.id, real_path)
			else
				LOG.debug('matching file exists already: ' .. real_path)
			end
		elseif tag == 'deleted' then
			if path_exists(real_path) then
				if not self.writing then
					self:writing_start_event()
					self.writing = true
				end
				local success, err = os.remove(real_path)
				if success then
					LOG.debug('removed ' .. real_path)
				else
					LOG.err('Could not remove ' .. real_path .. ' ' .. err)
				end
			end
		end
	end
	if self.writing then
		-- callback
		self:writing_end_event()
		self.writing = false
	end
end

function Dropbox:get_entries_by_cursor(cursor)
	-- make a total list of all entries
	local entries = {}
	local resp = {}
	repeat
		-- get more entries
		resp = self:list_folder_continue(cursor)
		if resp.status ~= 200 then
			self:handle_error(resp)
			return nil
		end
		-- append entries
		for k, v in ipairs(resp.data.entries) do table.insert(entries, v) end
		cursor = resp.data.cursor
		--LOG.debug(json.encode(resp))
	until resp.data.has_more == false
	return cursor, entries
end

function Dropbox:sync_folder(path)
	--self.running = true
	local resp = self:list_folder(path, true)
	if resp.status ~= 200 then
		LOG.debug(json.encode(resp))
		self:handle_error(resp)
		return nil
	end

	local cursor = resp.data.cursor

	-- make a total list of all entries
	local entries = {}
	for k, v in ipairs(resp.data.entries) do table.insert(entries, v) end

	if resp.data.has_more then
		local more_entries = {}
		cursor, more_entries = self:get_entries_by_cursor(cursor)
		if cursor == nil then
			return nil
		end
		for k, v in ipairs(more_entries) do table.insert(entries, v) end
	end

	self:remove_missing(self.local_path, entries)
	self:sync_entries(path, entries)
	return cursor
end

function Dropbox:start_sync()
	self.running = true
	LOG.debug("start sync")
	local dropbox_cursor = self:sync_folder(self.dropbox_path)
	LOG.debug(("cursor: %s"):format(dropbox_cursor))
	self:poll_folder(self.dropbox_path, dropbox_cursor)
end

function Dropbox:stop_sync()
	self.running = false
	LOG.debug('stop sync')
end

function Dropbox.new(obj)
	return setmetatable(obj or {}, Dropbox)
end

return Dropbox
