local url = require 'socket.url'
local plpath = require 'pl.path'

local UrlMatch = {}
UrlMatch.__index = UrlMatch

function UrlMatch:register(schemes, extensions, priority, func)
	if type(schemes) ~= "table" then schemes = {schemes or "*"} end
	if type(extensions) ~= "table" then extensions = {extensions or "*"} end
	for _, s in ipairs(schemes) do
		for _, e in ipairs(extensions) do
			local k = s..":"..e
			if self.funcs[k] == nil or self.prios[k] > priority then
				self.funcs[k] = func
				self.prios[k] = priority
			end
		end
	end
end

function UrlMatch:resolve(u)
	local p = url.parse(u)
	local s = p.scheme
	local e = plpath.extension(p.path):sub(2)
	return self.funcs[s..":"..e]
	    or self.funcs[s..":*"]
end

function UrlMatch.new()
	return setmetatable({funcs={}, prios={}}, UrlMatch)
end

return UrlMatch
