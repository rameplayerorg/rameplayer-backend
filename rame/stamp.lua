local Stamp = {
	next_ticket = math.tointeger(os.time() * 1000000),
}

function Stamp.next()
	local ticket = Stamp.next_ticket
	Stamp.next_ticket = ticket + 1
	return ticket
end

return Stamp
