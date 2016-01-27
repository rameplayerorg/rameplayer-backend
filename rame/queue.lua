local condition = require 'cqueues.condition'

local Queue = {}
Queue.__index = Queue

function Queue:dequeue()
	while self.head == nil do
		self.cond:wait()
	end

	local item = self.head
	if self.queue[item] then
		self.head = self.queue[item]
	else
		self.head = nil
		self.tail = nil
	end

	return item
end

function Queue:enqueue(item)
	if item == nil then return end
	if self.tail then
		self.queue[self.tail] = item
	else
		self.head = item
	end
	self.tail = item
	self.cond:signal()
end

function Queue.new()
	return setmetatable({
		queue = {},
		cond  = condition.new(),
		head  = nil,
		tail  = nil,
	}, Queue)
end

return Queue
