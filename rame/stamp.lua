local Stamp = {
	next_ticket = math.tointeger(os.time() * 1000000),
}

function Stamp.uuid()
	-- https://gist.github.com/jrus/3197011
	local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
	return string.gsub(template, '[xy]', function (c)
		local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
		return string.format('%x', v)
	end)
end

function Stamp.next()
	local ticket = Stamp.next_ticket
	Stamp.next_ticket = ticket + 1
	return ticket
end

math.randomseed(os.time())

return Stamp
