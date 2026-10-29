--!nonstrict
local Model = require("./messaging-model.luau")
local M = {}

function M.start(api)
	local data, pending, results = {}, {}, {}
	local generation, lastHeartbeat, starting = 0, 0, false
	local ready, deferred, command = false, {}, nil
	local bridgeError = ""
	local dirty = false
	local chunks, chunkCount = {}, 0
	local helper = api.pluginDir() .. "/bridge.py"
	local function now() return os.time() end
	local function publish()
		dirty = false
		api.state.set("pc.messaging", { devices = data, pending = pending, results = results, error = bridgeError })
	end
	local function get(id)
		if not data[id] then data[id] = Model.device() end
		return data[id]
	end
	local function event(e)
		if type(e) ~= "table" then return end
		lastHeartbeat = now()
		if e.type == "heartbeat" then return end
		if e.type == "ready" then
			bridgeError = ""; ready = true
			local waiting = deferred; deferred = {}
			for target, item in pairs(waiting) do pending[target] = nil; command(item.cmd) end
		elseif e.type == "reset" then
			ready = false
			generation = generation + 1
			for _, d in pairs(data) do d.connected = false end
		elseif e.type == "removed" then data[e.device] = nil
		elseif e.device then
			local d = get(e.device)
			if e.type == "notification" or e.type == "notification_removed" or e.type == "notifications" then
				d.notificationRevision = (d.notificationRevision or 0) + 1
			end
			if e.type == "connection" and not e.connected then
				d.epoch = (d.epoch or 0) + 1
			end
			Model.reduce(d, e)
			if e.type == "message" then
				local thread = e.message.thread
				local h = d.history[thread]
				if h and h.loading and #Model.sorted(d.messages[thread]) >= (h.start or 0) + 50 then
					h.loading = false; h.incomplete = false
				end
			end
		elseif e.type == "error" then bridgeError = e.message or "Bridge failed" end
		-- Conversation sync can emit hundreds of signals. Publish their latest
		-- combined state on the service tick, rather than serializing and making
		-- every panel decode the entire history once per message. Commands still
		-- publish pending/results immediately so sends cannot be duplicated.
		dirty = true
	end
	local function decode(raw)
		local ok, value = pcall(api.json.decode, raw or "")
		if ok and type(value) == "table" then return value end
		return nil
	end
	local function launch()
		if starting then return end
		starting = true; ready = false
		chunks = {}; chunkCount = 0
		local launched = api.runAsync({ "python3", helper, "check" }, function(res)
			starting = false
			local result = decode(res and res.stdout)
			if not res or res.exitCode ~= 0 or not result or not result.ok then
				bridgeError = result and result.message or "Install Python 3 and PyGObject to use messages and notifications."
				lastHeartbeat = now(); publish(); return
			end
			local quoted = "'" .. helper:gsub("'", "'\\''") .. "'"
			local ok = api.runStream("exec python3 -u " .. quoted .. " watch", function(line)
				local e = decode(line)
				if e and e.type == "chunk" then
					if e.index == 1 then chunks = {}; chunkCount = e.count end
					if e.index ~= #chunks + 1 or e.count ~= chunkCount or type(e.data) ~= "string" then
						chunks = {}; chunkCount = 0; return
					end
					table.insert(chunks, e.data)
					if #chunks < chunkCount then return end
					e = decode(table.concat(chunks))
					chunks = {}; chunkCount = 0
				end
				if e then event(e) end
			end)
			if not ok then bridgeError = "Could not start the KDE Connect bridge" end
			lastHeartbeat = now(); publish()
		end)
		if not launched then
			starting = false; lastHeartbeat = now()
			bridgeError = "Install Python 3 and PyGObject to use messages and notifications."; publish()
		end
	end
	local function finish(target, command, ok, message)
		pending[target] = nil
		results[target] = { ok = ok, message = message, requestId = command.requestId }
		if ok and (command.op == "sms_send" or command.op == "notification_reply") then
			local drafts = api.state.get("pc.drafts") or {}
			local draft = drafts[target]
			if draft and draft.text == command.text then
				draft.text = ""; draft.rev = (draft.rev or 0) + 1
				api.state.set("pc.drafts", drafts)
			end
		end
		publish()
	end
	command = function(cmd)
		local id = cmd.device
		if not id or id == "" then return end
		local d = get(id)
		local target = cmd.target or (id .. ":" .. cmd.op)
		if pending[target] then return end
		cmd.requestId = cmd.requestId or tostring(api.nowMs())
		pending[target] = { requestId = cmd.requestId, since = now() }
		results[target] = nil
		-- The watcher announces ready only after subscribing. A panel can open
		-- while the helper is starting, so defer reads that depend on its signals.
		if not ready and (cmd.op == "history" or cmd.op == "sync" or cmd.op == "contacts_sync") then
			deferred[target] = { cmd = cmd, deadline = now() + 15 }; publish(); return
		end
		if cmd.op == "sync" then d.status.messages = "loading"; d.syncDeadline = now() + 12 end
		if cmd.op == "contacts_sync" then d.status.contacts = "loading"; d.contactsDeadline = now() + 12 end
		if cmd.op == "history" then
			local h = d.history[cmd.thread] or {}
			h.loading = true; h.deadline = now() + 12; h.start = cmd.start or 0; h.error = nil
			d.history[cmd.thread] = h
		end
		publish()
		local epoch, gen, notificationRevision = d.epoch or 0, generation, d.notificationRevision or 0
		local launched = api.runAsync({ "python3", helper, "request", api.json.encode(cmd) }, function(res)
			if generation ~= gen or (d.epoch or 0) ~= epoch or data[id] ~= d then
				finish(target, cmd, false, "Connection changed; check the phone before retrying.")
				return
			end
			local reply = decode(res and res.stdout)
			local ok = res and res.exitCode == 0 and reply and reply.ok == true
			if ok then
				for _, e in ipairs(reply.events or {}) do
					-- A notification can be dismissed while a snapshot is in flight.
					if e.type ~= "notifications" or (d.notificationRevision or 0) == notificationRevision then event(e) end
				end
				if cmd.op == "sync" and d.capabilities.messages and not next(d.threads) then
					d.status.messages = "loading"
				end
			else
				if cmd.op == "sync" then d.status.messages = "failed"; d.syncDeadline = nil end
				if cmd.op == "contacts_sync" then d.status.contacts = "failed"; d.contactsDeadline = nil end
				if cmd.op == "history" then
					d.history[cmd.thread].loading = false; d.history[cmd.thread].error = true
				end
			end
			finish(target, cmd, ok == true, ok and "accepted" or
				(reply and reply.message or "Request timed out or failed; check the phone before retrying."))
		end, 15000)
		if not launched then finish(target, cmd, false, "Could not start Python 3") end
	end
	local function tick()
		local changed = false
		for target, item in pairs(deferred) do
			if now() >= item.deadline then
				deferred[target] = nil
				finish(target, item.cmd, false, "KDE Connect bridge is not ready. Refresh after it reconnects.")
			end
		end
		for _, d in pairs(data) do
			for _, pair in ipairs({ { "syncDeadline", "messages" }, { "contactsDeadline", "contacts" } }) do
				if d[pair[1]] and now() >= d[pair[1]] then
					d[pair[1]] = nil
					if d.status[pair[2]] == "loading" then d.status[pair[2]] = "empty" end
					changed = true
				end
			end
			for thread, h in pairs(d.history) do
				if h.loading and now() >= h.deadline then
					h.loading = false
					local count = #Model.sorted(d.messages[thread])
					h.loaded = count
					-- A short page may be a slow phone, so keep Load older available.
					h.incomplete = count < (h.start or 0) + 50
					changed = true
				end
			end
		end
		if changed or dirty then publish() end
		if now() - lastHeartbeat > 35 and not starting then
			lastHeartbeat = now()
			api.processMatches(function(running)
				if not running then launch() end
			end, helper, "watch")
		end
	end
	launch()
	return { command = command, tick = tick }
end

return M
