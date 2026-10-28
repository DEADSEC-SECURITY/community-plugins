--!nonstrict
-- Messages-first panel. Drafts and preferences live in shared memory, never on disk.
local Model = require("./messaging-model.luau")
local preview = nil -- Read-only synthetic data, only set by the preview IPC event.
-- state.get decodes a fresh copy. Read translations once per render, not once
-- per label: doing that for a phone's contact list exhausts the host CPU budget.
local translations = {}
local function t(key) return translations[key] or key end
local function send(cmd)
	if preview then return end
	local seq = math.max(noctalia.nowMs() * 1000, (noctalia.state.get("pc.sequence") or 0) + 1)
	noctalia.state.set("pc.sequence", seq)
	cmd.seq = seq; cmd.requestId = tostring(seq)
	noctalia.state.set("pc.cmd", cmd)
end
local mediaView = require("./media-view.luau").new({ ui = ui, api = noctalia, t = t, send = send })
local opened = false
local preferences = noctalia.state.get("pc.view") or { tab = "messages", compact = false, devices = {} }
local previewPreferences = nil
local confirmUnpair, editingName, nameValue, details = nil, nil, "", false
local function saveView() noctalia.state.set("pc.view", preferences) end
local function viewFor(id)
	if not preferences.devices[id] then preferences.devices[id] = { search = "", contactSearch = "" } end
	return preferences.devices[id]
end
local function draftFor(target)
	local drafts = noctalia.state.get("pc.drafts") or {}
	if not drafts[target] then drafts[target] = { text = "", rev = 0 }; noctalia.state.set("pc.drafts", drafts) end
	return drafts[target]
end
local function setDraft(target, value)
	local drafts = noctalia.state.get("pc.drafts") or {}
	local draft = drafts[target] or { rev = 0 }
	draft.text = value; drafts[target] = draft
	noctalia.state.set("pc.drafts", drafts)
end
local function label(text, props)
	props = props or {}; props.text = text; props.color = props.color or "on_surface"
	return ui.label(props)
end
local function button(key, glyph, action, props)
	props = props or {}; props.text = t(key); props.glyph = glyph; props.onClick = action
	props.controlSize = props.controlSize or "sm"; props.variant = props.variant or "outline"
	return ui.button(props)
end
local function icon(glyph, tooltip, action)
	return ui.button({ glyph = glyph, tooltip = t(tooltip), onClick = action, variant = "ghost", controlSize = "sm", width = 34 })
end
local function note(text, error)
	return label(text, { fontSize = 12, maxLines = 8, color = error and "error" or "on_surface_variant" })
end
local function timeText(date)
	return noctalia.formatTime("%b %d · %H:%M", math.floor((date or 0) / 1000))
end
local function empty(glyph, title, body)
	return ui.column({ gap = 12, padding = 24, flexGrow = 1, justify = "center", align = "center" }, {
		ui.glyph({ name = glyph, size = 32, color = "primary" }),
		label(t(title), { fontSize = 16, fontWeight = "medium", textAlign = "center", maxLines = 3 }), note(t(body)),
	})
end
local function stateNote(d, feature)
	if not d.connected then return note(t("chat.offline")) end
	local status = d.status[feature]
	if status == "unsupported" then return note(t("chat.unsupported")) end
	if status == "loading" then return note(t("chat.loading")) end
	if status == "failed" then return note(t("chat.failed"), true) end
	return nil
end
local function sync(id) send({ op = "sync", device = id }) end
local function selectThread(id, thread)
	local view = viewFor(id)
	view.thread = thread; view.recipient = nil; view.composing = false; view.showThread = true
	view.messageOffset = 0
	preferences.tab = "messages"; saveView()
	send({ op = "history", device = id, thread = thread, start = 0 }); render()
end
local function compose(id, number, name)
	local view = viewFor(id)
	view.thread = nil; view.recipient = number; view.recipientName = name
	view.composing = true; view.showThread = true
	preferences.tab = "messages"; saveView(); render()
end

local function pageRange(view, field, count, size)
	local page = math.min(view[field] or 1, math.max(1, math.ceil(count / size)))
	local controls
	if count > size then controls = ui.row({ gap = 8, align = "center" }, {
		button("chat.previous", "chevron-left", function() view[field] = page - 1; saveView(); render() end,
			{ enabled = page > 1, variant = "ghost" }),
		label(page .. " / " .. math.ceil(count / size), { flexGrow = 1, textAlign = "center", fontSize = 12 }),
		button("chat.next", "chevron-right", function() view[field] = page + 1; saveView(); render() end,
			{ enabled = page * size < count, variant = "ghost" }),
	}) end
	return (page - 1) * size + 1, math.min(page * size, count), controls, page
end

local function header(devices, order, d)
	local aliases = noctalia.state.get("pc.aliasMap") or {}
	local names, selected = {}, 1
	for index, id in ipairs(order) do
		local device = devices[id]
		table.insert(names, aliases[id] or (device and device.name) or id)
		if d and id == d.id then selected = index end
	end
	local kids = { ui.glyph({ name = "device-mobile", size = 22, color = "primary" }) }
	if #names > 1 then
		table.insert(kids, ui.select({ options = names, selectedIndex = selected - 1, flexGrow = 1,
			onChange = function(index)
				local id = order[tonumber(index) + 1]
				if id then send({ op = "select", device = id }); sync(id) end
			end }))
	else
		table.insert(kids, label(names[1] or t("panel.title"), { fontSize = 17, fontWeight = "bold", flexGrow = 1, maxLines = 1 }))
	end
	if d then
		local status = d.isPaired and d.isReachable and "status.connected" or "status.offline"
		local info = t(status)
		if type(d.batteryCharge) == "number" and d.batteryCharge >= 0 then info = info .. " · " .. d.batteryCharge .. "%" end
		if d.networkType and d.networkType ~= "" and not preferences.compact then info = info .. " · " .. d.networkType end
		table.insert(kids, label(info, { fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
	end
	table.insert(kids, icon(preferences.compact and "layout-columns" or "layout-list", "chat.toggle_compact", function()
		preferences.compact = not preferences.compact; saveView(); render()
	end))
	table.insert(kids, icon("refresh", "action.refresh", function() send({ op = "refresh" }); if d then sync(d.id) end end))
	table.insert(kids, icon("x", "panel.close", function() panel.close() end))
	return ui.row({ gap = 10, align = "center" }, kids)
end

local function composer(id, target, state, command, allowed)
	local draft = draftFor(target)
	local pending, result = state.pending[target] ~= nil, state.results[target]
	local lines = 0
	for line in (draft.text .. "\n"):gmatch("(.-)\n") do
		lines = lines + math.max(1, math.ceil((utf8.len(line) or #line) / (preferences.compact and 80 or 40)))
	end
	local height = math.min(106, 40 + math.max(0, lines - 1) * 18)
	local controls = { ui.input({ key = target .. ":input:" .. tostring(draft.rev), value = draft.text,
		placeholder = t("chat.write"), multiline = true, submitOnEnter = false, height = height, flexGrow = 1,
		enabled = not pending, onChange = function(value) setDraft(target, value); render() end }) }
	table.insert(controls, button("panel.sms_send", "send", function()
		local current = draftFor(target)
		if state.pending[target] or not allowed or current.text:match("^%s*$") then return end
		command.device = id; command.text = current.text; command.target = target; send(command)
	end, { enabled = allowed and not pending and draft.text:match("%S") ~= nil, variant = "primary", width = 90, height = 40 }))
	local kids = { ui.row({ gap = 8, align = "end" }, controls) }
	if pending then table.insert(kids, note(t("chat.sending")))
	elseif result then table.insert(kids, note(result.ok and t("chat.accepted") or result.message, not result.ok)) end
	return ui.column({ key = "composer-row:" .. target, gap = 6, padding = 0, align = "stretch",
		height = height + ((pending or result) and 54 or 0), fill = "surface/0" }, kids)
end

local function contactPicker(id, d, pick)
	local view, rows = viewFor(id), {}
	local query = (view.contactSearch or ""):lower()
	local matches = {}
	for _, contact in ipairs(d.contacts) do
		if query == "" or (contact.search or contact.name:lower()):find(query, 1, true) then
			table.insert(matches, contact)
		end
	end
	-- Keep native tree creation bounded even for large address books. Search
	-- still covers every contact; page changes replace rows instead of accumulating.
	local first, last, pager, page = pageRange(view, "contactPage", #matches, 25)
	for i = first, last do
		local contact = matches[i]
		local children = { label(contact.name, { fontSize = 14, fontWeight = "medium", maxLines = 2 }) }
		for _, number in ipairs(contact.numbers) do
			local actions = {
				label(number, { flexGrow = 1, fontSize = 12, maxLines = 1 }),
				button(pick and "chat.choose" or "chat.message", "message", function() compose(id, number, contact.name) end),
			}
			if not pick then table.insert(actions, icon("copy", "chat.copy_number", function() noctalia.copyToClipboard(number, "text/plain") end)) end
			table.insert(children, ui.row({ gap = 8, align = "center" }, actions))
		end
		table.insert(rows, ui.column({ key = "contact:" .. id .. ":" .. contact.id, gap = 6, padding = 12,
			fill = "surface/0.65", radius = 8 }, children))
	end
	if #rows == 0 then table.insert(rows, note(t(#d.contacts == 0 and "chat.no_contacts" or "chat.no_results"))) end
	local kids = { ui.row({ gap = 8 }, {
		ui.input({ key = "contacts-search:" .. id, value = view.contactSearch or "", placeholder = t("chat.search_contacts"), width = 280, flexGrow = 1,
			onChange = function(value) view.contactSearch = value; view.contactPage = 1; saveView(); render() end }),
		icon("refresh", "chat.refresh_contacts", function() send({ op = "contacts_sync", device = id }) end),
	}) }
	local status = stateNote(d, "contacts"); if status then table.insert(kids, status) end
	if pick then table.insert(kids, ui.row({ gap = 8 }, {
		ui.input({ key = "manual-number:" .. id, value = view.manual or "", placeholder = t("panel.sms_dest"), flexGrow = 1,
			onChange = function(value) view.manual = value; saveView(); render() end }),
		button("chat.choose", "arrow-right", function()
			if view.manual and view.manual:match("%S") then compose(id, view.manual, view.manual) end
		end, { enabled = (view.manual or ""):match("%S") ~= nil }),
	})) end
	table.insert(kids, ui.scroll({ key = "contacts:" .. id .. ":" .. page .. ":" .. query, flexGrow = 1, gap = 8 }, rows))
	if pager then table.insert(kids, pager) end
	return ui.column({ flexGrow = 1, gap = 10, minWidth = 0 }, kids)
end

local function threadView(id, d, state)
	local view = viewFor(id)
	local message = view.thread and d.threads[view.thread]
	local kids = {}
	if preferences.compact then table.insert(kids, button("chat.back", "arrow-left", function()
		view.showThread = false; saveView(); render()
	end, { variant = "ghost" })) end
	if view.composing and not view.recipient then
		table.insert(kids, label(t("chat.new_message"), { fontSize = 17, fontWeight = "medium" }))
		table.insert(kids, contactPicker(id, d, true))
	elseif message or (view.composing and view.recipient) then
		local title = message and Model.title(d, message) or view.recipientName
		local addresses = message and table.concat(message.addresses or {}, ", ") or view.recipient
		table.insert(kids, label(title or addresses, { fontSize = 17, fontWeight = "medium", maxLines = 2 }))
		table.insert(kids, ui.row({ gap = 8, align = "center" }, {
			label(addresses, { fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }),
			icon("copy", "chat.copy_number", function() noctalia.copyToClipboard(addresses, "text/plain") end),
			icon("external-link", "chat.open_sms", function() send({ op = "launch_sms_app", device = id }) end),
		}))
		local bubbles, h = {}, view.thread and d.history[view.thread]
		if message then
			local messages = Model.sorted(d.messages[view.thread])
			if #messages == 0 then messages = { message } end
			local offset = math.min(view.messageOffset or 0, math.floor((#messages - 1) / 50) * 50)
			table.insert(bubbles, button(h and h.loading and "chat.loading" or "chat.load_older", "history", function()
				view.messageOffset = offset + 50; saveView()
				if #messages <= offset + 50 then
					send({ op = "history", device = id, thread = view.thread, start = #Model.sorted(d.messages[view.thread]) })
				end
				render()
			end, { enabled = d.connected and not (h and h.loading), variant = "ghost" }))
			if h and (h.error or h.incomplete) then table.insert(bubbles, note(t("chat.history_hint"), h.error)) end
			for i = math.min(offset + 50, #messages), offset + 1, -1 do
				local item = messages[i]
				local content = {
					label(item.body or "", { fontSize = 13, maxLines = 0 }),
					label(timeText(item.date) .. " · " .. t(item.outgoing and "chat.outgoing" or "chat.incoming"),
						{ fontSize = 10, color = "on_surface_variant" }),
				}
				if (item.attachments or 0) > 0 then table.insert(content, button("chat.attachment", "paperclip", function()
					send({ op = "launch_sms_app", device = id })
				end, { variant = "ghost" })) end
				table.insert(bubbles, ui.column({ key = "message:" .. id .. ":" .. item.thread .. ":" .. item.id,
					gap = 6, padding = 12, radius = 10, fill = item.outgoing and "primary/0.12" or "surface/0.65" }, content))
			end
			if offset > 0 then table.insert(bubbles, button("chat.newer_messages", "arrow-down", function()
				view.messageOffset = math.max(0, offset - 50); saveView(); render()
			end, { variant = "ghost" })) end
		end
		table.insert(kids, ui.scroll({ key = "history:" .. id .. ":" .. tostring(view.thread or view.recipient),
			flexGrow = 1, gap = 10, stickToBottom = true }, bubbles))
		local target = id .. ":sms:" .. (view.thread or ("new:" .. view.recipient))
		table.insert(kids, composer(id, target, state, { op = "sms_send", thread = view.thread, destination = view.recipient },
			d.connected and d.capabilities.messages == true))
	else table.insert(kids, empty("messages", "chat.select_thread", "chat.select_hint")) end
	return ui.column({ gap = 8, flexGrow = 1, minWidth = 0 }, kids)
end

local function messagesView(id, d, state)
	local view, rows = viewFor(id), {}
	local matches = {}
	for _, thread in ipairs(Model.sorted(d.threads)) do
		if Model.matches(d, thread, view.search) then table.insert(matches, thread) end
	end
	local first, last, pager, page = pageRange(view, "threadPage", #matches, 50)
	for i = first, last do
		local thread = matches[i]
		table.insert(rows, ui.column({
			key = "thread:" .. id .. ":" .. thread.thread, gap = 5, padding = 12, radius = 9,
			fill = view.thread == thread.thread and "primary/0.13" or "surface/0.5",
			onClick = function() selectThread(id, thread.thread) end }, {
			label(Model.title(d, thread), { fontSize = 14, fontWeight = "medium", maxLines = 1 }),
			label(thread.body or "", { fontSize = 12, maxLines = 2, color = "on_surface_variant" }),
			label(timeText(thread.date), { fontSize = 10, color = "on_surface_variant" }),
		}))
	end
	if #rows == 0 then table.insert(rows, note(t(next(d.threads) and "chat.no_results" or "chat.no_threads"))) end
	local list = {
		ui.input({ key = "thread-search:" .. id, value = view.search or "", placeholder = t("chat.search_threads"),
			onChange = function(value) view.search = value; view.threadPage = 1; saveView(); render() end }),
		note(t("chat.search_scope")),
		button("chat.new_message", "plus", function()
			view.thread = nil; view.recipient = nil; view.composing = true; view.showThread = true; saveView(); render()
		end, { variant = "primary", enabled = d.connected and d.capabilities.messages == true }),
	}
	local status = stateNote(d, "messages"); if status then table.insert(list, status) end
	table.insert(list, ui.scroll({ key = "threads:" .. id .. ":" .. page .. ":" .. (view.search or ""), flexGrow = 1, gap = 8 }, rows))
	if pager then table.insert(list, pager) end
	if preferences.compact then
		if view.showThread then return threadView(id, d, state) end
		return ui.column({ flexGrow = 1, gap = 10 }, list)
	end
	return ui.row({ flexGrow = 1, gap = 16, align = "stretch" }, {
		ui.column({ width = 260, gap = 10 }, list), ui.separator({ orientation = "vertical" }), threadView(id, d, state),
	})
end

local function notificationsView(id, d, state)
	local rows = {}
	local status = stateNote(d, "notifications"); if status then table.insert(rows, status) end
	for _, call in ipairs(d.calls) do table.insert(rows, ui.column({ gap = 5, padding = 12, radius = 8, fill = "primary/0.08" }, {
		label(t(call.event == "missedCall" and "chat.missed_call" or "chat.call_event"), { fontWeight = "medium" }),
		label((call.name ~= "" and call.name or Model.name(d.contacts, call.number)) .. " · " .. call.number, { maxLines = 2 }),
		note(timeText(call.date * 1000)),
	})) end
	local notifications = {}
	for _, item in pairs(d.notifications) do table.insert(notifications, item) end
	table.sort(notifications, function(a, b) return tostring(a.id) > tostring(b.id) end)
	local first, last, pager, page = pageRange(viewFor(id), "notificationPage", #notifications, 25)
	for i = first, last do
		local item = notifications[i]
		local target = id .. ":notification:" .. item.id
		local kids = {
			ui.row({ gap = 8, align = "center" }, {
				label(item.app, { fontSize = 11, color = "primary", flexGrow = 1 }),
				button("chat.dismiss", "x", function()
					send({ op = "notification_dismiss", device = id, notification = item.id, target = target .. ":dismiss" })
				end, { variant = "ghost", enabled = d.connected and item.dismissable and not state.pending[target .. ":dismiss"] }),
			}),
			label(item.title, { fontSize = 15, fontWeight = "medium", maxLines = 4 }), label(item.text, { fontSize = 13, maxLines = 0 }),
		}
		local result = state.results[target .. ":dismiss"]
		if result and not result.ok then table.insert(kids, note(result.message, true)) end
		if item.replyId and item.replyId ~= "" then table.insert(kids, composer(id, target .. ":" .. item.replyId, state,
			{ op = "notification_reply", notification = item.id, replyId = item.replyId }, d.connected)) end
		table.insert(rows, ui.column({ key = "notification:" .. id .. ":" .. item.id, gap = 8, padding = 14,
			radius = 10, fill = "surface/0.6" }, kids))
	end
	if #notifications == 0 then table.insert(rows, empty("bell", "chat.no_notifications", "chat.notifications_hint")) end
	table.insert(rows, note(t("chat.calls_hint")))
	local kids = { ui.scroll({ key = "notifications:" .. id .. ":" .. page, flexGrow = 1, gap = 12 }, rows) }
	if pager then table.insert(kids, pager) end
	return ui.column({ flexGrow = 1, gap = 8 }, kids)
end

local function deviceView(d)
	local id, reachable = d.id, d.isPaired and d.isReachable
	local name = (noctalia.state.get("pc.aliasMap") or {})[id] or d.name
	local image = (noctalia.state.get("pc.imageMap") or {})[id]
	local identity = {}
	if image and image ~= "" then table.insert(identity, ui.image({ path = image, width = 48, height = 48, radius = 24, fit = "cover",
		onClick = function() send({ op = "pick_image", device = id }) end })) end
	if editingName == id then
		table.insert(identity, ui.input({ key = "alias:" .. id, value = name, flexGrow = 1,
			onChange = function(value) nameValue = value end,
			onSubmit = function(value) send({ op = "set_alias", device = id, alias = value }); editingName = nil; render() end }))
		table.insert(identity, icon("check", "chat.save", function()
			send({ op = "set_alias", device = id, alias = nameValue }); editingName = nil; render()
		end))
	else
		table.insert(identity, label(name, { fontSize = 18, fontWeight = "medium", flexGrow = 1, maxLines = 2 }))
		table.insert(identity, icon("pencil", "chat.rename", function() editingName = id; nameValue = name; render() end))
	end
	table.insert(identity, button("chat.photo", "photo", function() send({ op = "pick_image", device = id }) end))
	local rows = { ui.row({ gap = 10, align = "center" }, identity) }
	if not d.isPaired then
		table.insert(rows, button("action.pair", "link", function() send({ op = "pair", device = id }) end, { variant = "primary" }))
	else
		local actions = { { "chat.find_phone", "bell-ringing", "ring" }, { "action.ping", "message", "ping" },
			{ "chat.browse_files", "folder", "browse" }, { "action.share", "share", "pick_share" } }
		if noctalia.getConfig("enable_clipboard_action") then table.insert(actions, { "chat.send_clipboard", "clipboard", "clipboard" }) end
		for i = 1, #actions, 2 do
			local pair = {}
			for j = i, math.min(i + 1, #actions) do
				local action = actions[j]
				table.insert(pair, button(action[1], action[2], function() send({ op = action[3], device = id }) end,
					{ flexGrow = 1, enabled = reachable, controlSize = "md" }))
			end
			table.insert(rows, ui.row({ gap = 10 }, pair))
		end
		table.insert(rows, mediaView(d))
	end
	table.insert(rows, button("chat.connection_details", details and "chevron-up" or "chevron-down", function() details = not details; render() end, { variant = "ghost" }))
	if details then
		for _, field in ipairs({ { "IPv4", d.ipv4 }, { "IPv6", d.ipv6 }, { t("panel.type"), d.type } }) do
			table.insert(rows, label(field[1] .. ": " .. (field[2] or "—"), { fontSize = 12, maxLines = 3 }))
		end
	end
	if d.isPaired then
		if confirmUnpair == id then
			table.insert(rows, note(t("chat.confirm_unpair")))
			table.insert(rows, ui.row({ gap = 10 }, {
				button("chat.cancel", "x", function() confirmUnpair = nil; render() end, { flexGrow = 1 }),
				button("action.unpair", "link-off", function() send({ op = "unpair", device = id }); confirmUnpair = nil; render() end,
					{ flexGrow = 1, variant = "destructive" }),
			}))
		else table.insert(rows, button("action.unpair", "link-off", function() confirmUnpair = id; render() end, { variant = "ghost" })) end
	end
	return ui.scroll({ flexGrow = 1, gap = 16 }, rows)
end

function render()
	if not opened then return end
	translations = noctalia.state.get("pc.trTable") or {}
	local devices, order = noctalia.state.get("pc.devices") or {}, noctalia.state.get("pc.order") or {}
	local id = noctalia.state.get("pc.selected")
	if preview then devices = preview.devices; order = preview.order; id = preview.selected end
	if not id or not devices[id] then id = order[1] end
	local device = id and devices[id]
	local state = noctalia.state.get("pc.messaging") or { devices = {}, pending = {}, results = {} }
	if preview then state = preview.messaging end
	local d = (id and state.devices[id]) or Model.device()
	local body, tabs = { header(devices, order, device) }, {}
	if preview then table.insert(body, note(t("chat.preview"))) end
	local count = 0; for _ in pairs(d.notifications) do count = count + 1 end
	for _, tab in ipairs({ "messages", "notifications", "contacts", "device" }) do
		local text = t("chat.tab_" .. tab)
		if tab == "notifications" and count > 0 then text = text .. " (" .. count .. ")" end
		table.insert(tabs, ui.button({ text = text, flexGrow = 1, controlSize = "sm",
			variant = preferences.tab == tab and "primary" or "ghost", selected = preferences.tab == tab,
			onClick = function() preferences.tab = tab; saveView(); render() end }))
	end
	table.insert(body, ui.row({ gap = 6 }, tabs)); table.insert(body, ui.separator({}))
	if not device then table.insert(body, empty("device-mobile", "panel.title", "panel.empty"))
	else
		if state.error and state.error ~= "" then table.insert(body, note(state.error, true)) end
		if d.error and d.error ~= "" then table.insert(body, note(d.error, true)) end
		if not d.connected and preferences.tab ~= "device" then table.insert(body, note(t("chat.offline"))) end
		if preferences.tab == "contacts" then table.insert(body, contactPicker(id, d, false))
		elseif preferences.tab == "notifications" then table.insert(body, notificationsView(id, d, state))
		elseif preferences.tab == "device" then table.insert(body, deviceView(device))
		else table.insert(body, messagesView(id, d, state)) end
	end
	panel.render(ui.column({ key = "panel:" .. preferences.tab .. ":" .. tostring(preferences.compact),
		gap = 12, padding = 16, flexGrow = 1, align = "stretch" }, body))
end

function onOpen(_context)
	opened = true; preferences.tab = "messages"
	local id = noctalia.state.get("pc.selected") or (noctalia.state.get("pc.order") or {})[1]
	if id then sync(id) end
	render()
end
function onClose()
	opened = false; confirmUnpair = nil; preview = nil
	if previewPreferences then preferences = previewPreferences; previewPreferences = nil end
	saveView()
end
-- View IPC drives native layout tests without simulating desktop input.
-- Preview data never enters the service, and all phone commands are blocked.
function onIpc(event, payload)
	local ok, value = pcall(noctalia.json.decode, payload or "{}")
	if not ok or type(value) ~= "table" then return end
	if event == "preview" and type(value.devices) == "table" and type(value.order) == "table"
		and type(value.messaging) == "table" then
		if not preview then
			previewPreferences = preferences
			preferences = { tab = "messages", compact = false, devices = {} }
		end
		preview = value
		if value.thread then viewFor(value.selected).thread = value.thread; viewFor(value.selected).showThread = true end
	elseif event == "view" then
		if value.tab == "messages" or value.tab == "contacts" or value.tab == "notifications" or value.tab == "device" then
			preferences.tab = value.tab
		end
		if type(value.compact) == "boolean" then preferences.compact = value.compact end
	end
	render()
end
for _, key in ipairs({ "pc.devices", "pc.order", "pc.selected", "pc.backend", "pc.messaging", "pc.trTable", "pc.aliasMap", "pc.imageMap" }) do
	noctalia.state.watch(key, render)
end
