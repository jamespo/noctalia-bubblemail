-- panel.luau
-- Bubblemail - mail panel (480x580).
--
-- Layout: header (totals + refresh + close), one row per configured account
-- showing unread count and connection state, then a scrollable list of pending
-- mails, newest first.
-- Reads state published by service.luau; sends commands via "bm.cmd".

local cmdSeq = 0
local function sendCmd(op)
	cmdSeq = cmdSeq + 1
	-- Wall-clock base keeps seq monotonic across hot-reloads; see service.luau.
	noctalia.state.set("bm.cmd", { op = op, seq = os.time() * 1000000 + cmdSeq })
end

-- Relative time, deliberately avoiding os.date: only os.time is needed, and
-- "20m" reads better than a wall-clock stamp in a list that is already sorted
-- newest first.
local function ago(epoch)
	local ts = tonumber(epoch)
	if not ts or ts <= 0 then return "-" end
	local d = os.time() - ts
	if d < 0 then d = 0 end
	if d < 60 then return "now" end
	if d < 3600 then return tostring(math.floor(d / 60)) .. "m" end
	if d < 86400 then return tostring(math.floor(d / 3600)) .. "h" end
	if d < 604800 then return tostring(math.floor(d / 86400)) .. "d" end
	return tostring(math.floor(d / 604800)) .. "w"
end

local function plural(n, one, many)
	return tostring(n) .. " " .. (n == 1 and one or many)
end

-- ── Header ──────────────────────────────────────────────────────────────────
local function headerRow(daemon, accounts, total, errors)
	local summary
	if daemon.checked ~= true then
		summary = "Checking..."
	elseif daemon.available ~= true then
		summary = "bubblemaild unreachable"
	else
		summary = plural(total, "unread", "unread") .. " / "
			.. plural(#accounts, "account", "accounts")
		if errors > 0 then
			summary = summary .. " / " .. plural(errors, "error", "errors")
		end
	end

	local glyph = "mail"
	if daemon.checked == true and daemon.available ~= true then
		glyph = "mail-off"
	elseif errors > 0 then
		glyph = "mail-exclamation"
	end

	local refreshing = noctalia.state.get("bm.refreshing") == true

	return ui.row({ gap = 8, align = "center" }, {
		ui.glyph({ name = glyph, size = 18,
			color = errors > 0 and "error" or "primary" }),
		ui.label({ text = summary, fontSize = 13, fontWeight = "medium",
			color = "on_surface", flexGrow = 1 }),
		ui.button({
			key = "refresh",
			glyph = "refresh",
			variant = "outline",
			controlSize = "sm",
			tooltip = "Check mail now",
			-- Disabled mid-refresh: the daemon coalesces checks anyway, and a
			-- greyed button is clearer feedback than a click that does nothing.
			enabled = not refreshing and daemon.available == true,
			onClick = function() sendCmd("refresh") end,
		}),
		ui.button({
			key = "close",
			glyph = "x",
			variant = "outline",
			controlSize = "sm",
			onClick = function() panel.close() end,
		}),
	})
end

-- ── Account rows ────────────────────────────────────────────────────────────
-- One row per configured account: name, state, unread badge. Colours follow
-- bubble-cli: green OK, yellow offline, red error, dim disabled.
local function accountRow(a)
	local code = tonumber(a.error_code) or 0
	local state = a.error_message
	if state == nil or state == "" then state = a.error_state or "" end

	local color = "primary"
	if a.enabled ~= true then
		state, color = "Disabled", "on_surface/0.4"
	elseif code > 0 then
		color = "error"
	elseif code < 0 then
		color = "on_surface_variant"
	end

	local unread = tonumber(a.unread) or 0
	local detail = state
	-- Only surface the last-error timestamp when there is a current failure;
	-- on a healthy account it is just the last time anything ever went wrong,
	-- which reads as alarming for no reason.
	if code > 0 and (tonumber(a.error_last) or 0) > 0 then
		detail = detail .. "  -  " .. ago(a.error_last) .. " ago"
	end

	return ui.row({ gap = 8, align = "center", padding = 8, radius = 8,
		fill = "surface/0.5" }, {
		ui.column({ gap = 2, flexGrow = 1, minWidth = 0 }, {
			ui.label({ text = a.name or a.uuid or "?", fontSize = 12,
				fontWeight = "medium", color = "on_surface", maxLines = 1 }),
			ui.label({ text = detail, fontSize = 10, color = color, maxLines = 1 }),
		}),
		ui.label({
			text = tostring(unread),
			fontSize = 13,
			fontWeight = "medium",
			color = unread > 0 and "primary" or "on_surface/0.4",
		}),
	})
end

-- ── Mail list ───────────────────────────────────────────────────────────────
local function mailRow(m)
	local sender = m.name
	if sender == nil or sender == "" then sender = m.address or "" end
	local subject = m.subject
	if subject == nil or subject == "" then subject = "(no subject)" end

	return ui.column({ gap = 2, padding = 8, radius = 8, fill = "surface/0.5" }, {
		ui.row({ gap = 6, align = "center" }, {
			ui.label({ text = sender, fontSize = 12, fontWeight = "medium",
				color = "on_surface", flexGrow = 1, maxLines = 1 }),
			ui.label({ text = ago(m.datetime), fontSize = 10,
				color = "on_surface_variant" }),
		}),
		ui.label({ text = subject, fontSize = 11, color = "on_surface_variant",
			maxLines = 2 }),
		ui.label({ text = m.accountName or m.account or "", fontSize = 9,
			color = "on_surface/0.45", maxLines = 1 }),
	})
end

-- ── Render ──────────────────────────────────────────────────────────────────
local function render()
	local daemon = noctalia.state.get("bm.daemon") or {}
	local accounts = noctalia.state.get("bm.accounts") or {}
	local mails = noctalia.state.get("bm.mails") or {}
	local total = tonumber(noctalia.state.get("bm.total")) or 0
	local errors = tonumber(noctalia.state.get("bm.errors")) or 0

	local body = { headerRow(daemon, accounts, total, errors) }

	if daemon.checked == true and daemon.available ~= true then
		local why = daemon.error
		if why == nil or why == "" then why = "Is bubblemaild running?" end
		if daemon.reason == "no-dbus" then
			why = "python3 dbus module not found - install python-dbus."
		end
		table.insert(body, ui.column({ gap = 6, padding = 12, radius = 8,
			fill = "surface/0.5" }, {
			ui.label({ text = "Cannot reach bubblemaild", fontSize = 12,
				fontWeight = "medium", color = "error" }),
			ui.label({ text = why, fontSize = 10, color = "on_surface_variant",
				maxLines = 4 }),
		}))
		panel.render(ui.column({ gap = 10, padding = 12 }, body))
		return
	end

	if #accounts > 0 then
		local rows = {}
		for _, a in ipairs(accounts) do
			table.insert(rows, accountRow(a))
		end
		table.insert(body, ui.column({ gap = 6 }, rows))
	end

	if #mails > 0 then
		local items = {}
		for _, m in ipairs(mails) do
			table.insert(items, mailRow(m))
		end
		table.insert(body, ui.label({ text = "Pending mail", fontSize = 10,
			fontWeight = "medium", color = "on_surface_variant" }))
		table.insert(body, ui.scroll({ flexGrow = 1, gap = 6, padding = 0 }, items))
	elseif daemon.checked == true then
		table.insert(body, ui.column({ gap = 4, padding = 16, radius = 8,
			fill = "surface/0.5", align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "mail-opened", size = 22, color = "on_surface/0.4" }),
			ui.label({ text = #accounts > 0 and "No unread mail"
				or "No accounts configured",
				fontSize = 11, color = "on_surface_variant" }),
		}))
	end

	panel.render(ui.column({ gap = 10, padding = 12 }, body))
end

function onOpen(_context)
	-- Refresh the view on open so a panel opened after a long idle does not
	-- show counts from the previous poll interval.
	sendCmd("poll")
	render()
end

function onClose() end

noctalia.state.watch("bm.daemon", render)
noctalia.state.watch("bm.accounts", render)
noctalia.state.watch("bm.mails", render)
noctalia.state.watch("bm.total", render)
noctalia.state.watch("bm.errors", render)
noctalia.state.watch("bm.refreshing", render)

render()
