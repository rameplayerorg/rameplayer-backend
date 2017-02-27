-- cURL using cqueues
--
-- Credit: Timo Teräs <timo.teras@iki.fi>

local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local curl = require 'cURL'
local RAME = require 'rame.rame'

local cqcurl = {}
local fdobjs = {}

local function curl_check_multi_info()
	while true do
		local easy, ok, err = cqcurl.multi:info_read(true)
		if not easy then
			cqcurl.multi:close()
			RAME.log.error(("cURL multi info could not read: %s"):format(err))
			error(err)
		end
		if easy == 0 then break end

		if not ok then
			RAME.log.error(("cURL error on '%s': %s"):format(easy:getinfo_effective_url(), err))
		--else
			--RAME.log.debug(("cURL response %d from %s"):format(easy:getinfo_response_code(), easy:getinfo_effective_url()))
		end

		easy.data.effective_url = easy:getinfo_effective_url()
		easy.data.response_code = easy:getinfo_response_code()
		easy.data.finishedcond:signal()
	end
end

local timeout, timercond

local function curl_timerfunction(ms)
	timeout = ms >= 0 and ms / 1000 or nil
	if not timercond then
		-- Start timer if not yet running
		timercond = condition.new()
		cqueues.running():wrap(function()
			while timeout ~= nil do
				local reason = cqueues.poll(timercond, timeout)
				if reason ~= timercond or timeout == 0 then
					timeout = nil
					cqcurl.multi:socket_action()
					curl_check_multi_info()
				end
			end
			timercond = nil
		end)
	else
		-- Wake up timer thread
		timercond:signal()
	end
end

local function curl_socketfunction_act(easy, fd, action)
	local ACTION_NAMES = {
		[curl.POLL_IN     ] = "POLL_IN",
		[curl.POLL_INOUT  ] = "POLL_INOUT",
		[curl.POLL_OUT    ] = "POLL_OUT",
		[curl.POLL_NONE   ] = "POLL_NONE",
		[curl.POLL_REMOVE ] = "POLL_REMOVE",
	}
	--RAME.log.debug(("CURL_SOCKETFUNCTION %s"):format(ACTION_NAMES[action] or action))

	local fdobj = fdobjs[fd] or {pollfd=fd}
	if action == curl.POLL_IN then
		fdobj.events = 'r'
		fdobj.flags = curl.CSELECT_IN
	elseif action == curl.POLL_INOUT then
		fdobj.events = 'rw'
		fdobj.flags = curl.CSELECT_INOUT
	elseif action == curl.POLL_OUT then
		fdobj.events = 'w'
		fdobj.flags = curl.CSELECT_OUT
	elseif action == curl.POLL_REMOVE then
		fdobj.events = nil
		fdobj.flags = nil
	else
		RAME.log.debug(("cURL socket function, empty action: %s"):format(ACTION_NAMES[action] or action))
		return
	end

	if fdobj.socketcond then
		-- Worker running, signal it
		fdobj.socketcond:signal()
		if fdobj.events == nil then
			cqueues.running():cancel(fd)
			fdobjs[fd] = nil
		end
	elseif fdobj.events then
		-- Worker needed
		fdobjs[fd] = fdobj
		fdobj.socketcond = condition.new()
		cqueues.running():wrap(function()
			while fdobj.events do
				local rc = cqueues.poll(fdobj, fdobj.socketcond)
				if rc == fdobj and fdobj.flags then
					cqcurl.multi:socket_action(fd, fdobj.flags)
					curl_check_multi_info()
				end
			end
		end)
	end
end

local function curl_socketfunction(easy, fd, action)
	local ok, err = pcall(curl_socketfunction_act, easy, fd, action)
	if not ok then
		RAME.log.error(("cURL socket error: %s"):format(err))
		error(err)
	end
end

cqcurl.multi = curl.multi {
	timerfunction = curl_timerfunction,
	socketfunction = curl_socketfunction,
}

function cqcurl.perform(opt)
	--RAME.log.debug(("cURL request to %s"):format(opt.url))

	local handle = curl.easy()
	handle:setopt(opt)
	handle.data = {
		finishedcond = condition.new()
	}
	cqcurl.multi:add_handle(handle)
	handle.data.finishedcond:wait()

	local response_code = handle.data.response_code
	handle:close()
	return response_code
end

return cqcurl
