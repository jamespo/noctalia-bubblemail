-- widget.luau
-- Bubblemail - bar widget (thin UI entry).
--
-- Shows an envelope glyph plus the unread count, coloured by state: error when
-- an account is failing, primary when mail is waiting, dimmed when the inbox is
-- clear or the daemon is down. Left-click opens the mail panel, right-click
-- asks the daemon to check mail now.
-- Reads state published by service.luau; no daemon logic here.

local PANEL = "jamespo/bubblemail:mails"

local cmdSeq = 0
local function sendCmd(op)
	cmdSeq = cmdSeq + 1
	-- Wall-clock base keeps seq monotonic across hot-reloads; see service.luau.
	noctalia.state.set("bm.cmd", { op = op, seq = os.time() * 1000000 + cmdSeq })
end

local function render()
	local daemon = noctalia.state.get("bm.daemon") or {}
	local total = tonumber(noctalia.state.get("bm.total")) or 0
	local errors = tonumber(noctalia.state.get("bm.errors")) or 0
	local mode = noctalia.getConfig("display_mode") or "icon_and_count"
	local hideWhenEmpty = noctalia.getConfig("hide_when_empty") == true

	local children

	if daemon.checked ~= true then
		-- First poll still in flight: show a neutral glyph rather than briefly
		-- claiming the daemon is unavailable.
		children = { ui.glyph({ name = "mail", size = 14, color = "on_surface/0.4" }) }
	elseif daemon.available ~= true then
		children = { ui.glyph({ name = "mail-off", size = 14, color = "on_surface/0.4" }) }
	elseif total == 0 and errors == 0 and hideWhenEmpty then
		-- Nothing to say: render an empty row so the widget collapses out of
		-- the bar instead of sitting there as dead space.
		children = {}
	else
		local glyph, color
		if errors > 0 then
			glyph, color = "mail-exclamation", "error"
		elseif total > 0 then
			glyph, color = "mail", "primary"
		else
			glyph, color = "mail-opened", "on_surface/0.5"
		end

		local kids = {}
		if mode == "icon_and_count" or mode == "icon" then
			table.insert(kids, ui.glyph({ name = glyph, size = 14, color = color }))
		end
		if mode == "icon_and_count" or mode == "count" then
			table.insert(kids, ui.label({
				text = tostring(total), fontSize = 11, fontWeight = "medium",
				color = color,
			}))
		end
		children = kids
	end

	local container = barWidget.isVertical() and ui.column or ui.row
	barWidget.render(container({ gap = 5, align = "center" }, children))
end

function update()
	-- The service owns polling; this only repaints in case a state watch was
	-- missed, so it can tick slowly.
	noctalia.setUpdateInterval(5000)
	render()
end

function onClick()
	noctalia.togglePanel(PANEL)
end

function onRightClick()
	sendCmd("refresh")
end

noctalia.state.watch("bm.daemon", render)
noctalia.state.watch("bm.total", render)
noctalia.state.watch("bm.errors", render)

render()
