--!nonstrict
-- Pure model shared by the service, panel and regression tests.
local M = {}

function M.device()
	return { connected = false, capabilities = {}, contacts = {}, threads = {},
		messages = {}, notifications = {}, calls = {}, history = {},
		status = { messages = "loading", contacts = "loading", notifications = "loading" }, error = "" }
end

function M.number(value)
	return tostring(value or ""):gsub("^tel:", ""):gsub("[%s%(%)%.%-]", ""):lower()
end

function M.name(contacts, number)
	local normalized = M.number(number)
	local found
	for _, contact in ipairs(contacts or {}) do
		for _, candidate in ipairs(contact.numbers or {}) do
			if normalized ~= "" and M.number(candidate) == normalized then
				if found and found ~= contact.name then return number end
				found = contact.name
			end
		end
	end
	return found or number
end

function M.title(d, message)
	if not d.contactNames then
		d.contactNames = {}
		for _, contact in ipairs(d.contacts or {}) do
			for _, number in ipairs(contact.numbers or {}) do
				local key = M.number(number)
				local old = d.contactNames[key]
				if old == nil then d.contactNames[key] = contact.name
				elseif old ~= contact.name then d.contactNames[key] = false end
			end
		end
	end
	local names = {}
	for _, number in ipairs(message.addresses or {}) do
		table.insert(names, d.contactNames[M.number(number)] or number)
	end
	return table.concat(names, ", ")
end

function M.sorted(map, ascending)
	local items = {}
	for _, item in pairs(map or {}) do table.insert(items, item) end
	table.sort(items, function(a, b)
		if a.date == b.date then return tostring(a.id) < tostring(b.id) end
		if ascending then return (a.date or 0) < (b.date or 0) end
		return (a.date or 0) > (b.date or 0)
	end)
	return items
end

function M.reduce(d, event)
	local kind = event.type
	if kind == "connection" then
		d.connected = event.connected == true
	elseif kind == "capabilities" then
		if not d.connected then
			-- A reloaded KDE plugin has a new history cache; old offsets are invalid.
			d.messages = {}; d.history = {}; d.threads = {}
		end
		d.connected = event.connected == true
		d.capabilities = event.capabilities or {}
		d.error = ""
		for _, key in ipairs({ "messages", "contacts", "notifications" }) do
			if not d.capabilities[key] then d.status[key] = "unsupported" end
		end
	elseif kind == "contacts" then
		d.contacts = event.items or {}
		d.contactNames = nil
		d.status.contacts = #d.contacts > 0 and "ready" or "empty"
	elseif kind == "threads" then
		-- Signals can overtake a snapshot subprocess. Merge instead of erasing a
		-- newly arrived thread; removals have their own signal. Reconnect starts fresh.
		local threads = d.threads
		for _, message in ipairs(event.items or {}) do
			local old = d.threads[message.thread]
			threads[message.thread] = old and old.date > message.date and old or message
		end
		d.threads = threads
		d.status.messages = next(threads) and "ready" or "empty"
	elseif kind == "message" then
		local message = event.message
		if not message or not message.thread or not message.id then return end
		local id = message.thread
		d.messages[id] = d.messages[id] or {}
		d.messages[id][message.id] = message
		local latest = d.threads[id]
		if not latest or message.date >= latest.date then d.threads[id] = message end
		d.status.messages = "ready"
	elseif kind == "thread_removed" then
		d.threads[event.thread] = nil; d.messages[event.thread] = nil; d.history[event.thread] = nil
		d.status.messages = next(d.threads) and "ready" or "empty"
	elseif kind == "loaded" then
		local h = d.history[event.thread] or {}
		h.knownCount = event.count
		d.history[event.thread] = h
	elseif kind == "notifications" then
		d.notifications = {}
		for _, item in ipairs(event.items or {}) do d.notifications[item.id] = item end
		d.status.notifications = next(d.notifications) and "ready" or "empty"
	elseif kind == "notification" then
		d.notifications[event.notification.id] = event.notification
		d.status.notifications = "ready"
	elseif kind == "notification_removed" then
		d.notifications[event.id] = nil
		d.status.notifications = next(d.notifications) and "ready" or "empty"
	elseif kind == "call" then
		table.insert(d.calls, 1, event.call)
		if #d.calls > 20 then table.remove(d.calls) end
	elseif kind == "error" then
		d.error = event.message or ""
	end
end

function M.matches(d, thread, query)
	query = (query or ""):lower()
	if query == "" then return true end
	local haystack = M.title(d, thread) .. " " .. table.concat(thread.addresses or {}, " ") .. " " .. (thread.body or "")
	if haystack:lower():find(query, 1, true) then return true end
	for _, message in pairs(d.messages[thread.thread] or {}) do
		if (message.body or ""):lower():find(query, 1, true) then return true end
	end
	return false
end

return M
