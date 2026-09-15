-- tile.luau
-- Bubblemail - control-center tile (thin UI entry).
--
-- Compact summary: unread count, or the number of failing accounts when
-- something is wrong. Click opens the mail panel.
-- Reads state published by service.luau; no daemon logic here.

local PANEL = "jamespo/bubblemail:mails"

local function render()
	local daemon = noctalia.state.get("bm.daemon") or {}
	local total = tonumber(noctalia.state.get("bm.total")) or 0
	local errors = tonumber(noctalia.state.get("bm.errors")) or 0

	if daemon.checked ~= true then
		shortcut.setIcon("mail")
		shortcut.setLabel("Mail")
		shortcut.setActive(false)
		shortcut.setEnabled(false)
		return
	end

	if daemon.available ~= true then
		shortcut.setIcon("mail-off")
		shortcut.setLabel("No daemon")
		shortcut.setActive(false)
		-- Left enabled so the panel can still be opened to read why.
		shortcut.setEnabled(true)
		return
	end

	shortcut.setEnabled(true)
	if errors > 0 then
		shortcut.setIcon("mail-exclamation")
		shortcut.setLabel(errors == 1 and "1 account failing"
			or (tostring(errors) .. " accounts failing"))
		shortcut.setActive(true)
	elseif total > 0 then
		shortcut.setIcon("mail")
		shortcut.setLabel(total == 1 and "1 unread" or (tostring(total) .. " unread"))
		shortcut.setActive(true)
	else
		shortcut.setIcon("mail-opened")
		shortcut.setLabel("No unread")
		shortcut.setActive(false)
	end
end

function update()
	noctalia.setUpdateInterval(5000)
	render()
end

function onClick()
	noctalia.togglePanel(PANEL)
end

noctalia.state.watch("bm.daemon", render)
noctalia.state.watch("bm.total", render)
noctalia.state.watch("bm.errors", render)

render()
