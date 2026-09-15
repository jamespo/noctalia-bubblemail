-- service.luau
-- Bubblemail - background service; the single owner of all daemon traffic.
--
-- Noctalia plugin scripts run in an isolated sandbox with no `require`, so the
-- UI entries (widget/tile/panel) cannot share code with this file. Instead this
-- entry does every query and publishes plain data to `noctalia.state`, and the
-- UI entries only read it. Swapping the transport (say, native D-Bus if the
-- plugin API ever grows it) would touch this file alone.
--
-- Talking to bubblemaild goes through bubblemail-query.py rather than `gdbus`:
-- mail subjects routinely contain commas, apostrophes and hard-wrapped CRLF,
-- which makes gdbus' text output genuinely ambiguous to parse with Lua
-- patterns. The helper returns one JSON document instead. python3-dbus is not
-- a real extra dependency -- bubblemaild is itself a python3 + dbus process.
--
-- ── State contract (read by UI entries) ─────────────────────────────────────
--   "bm.daemon"   : { available=bool, reason=string, error=string,
--                     checked=bool }  -- checked=false until the first poll
--                     returns, so the UI can stay quiet instead of flashing
--                     "unavailable" during startup
--   "bm.accounts" : { { uuid, name, backend, type, enabled, error_code,
--                       error_state, error_message, error_count, error_last,
--                       unread }, ... }
--   "bm.mails"    : { { uuid, account, accountName, datetime, subject, name,
--                       address, avatar }, ... } newest first, capped by the
--                     max_mails setting
--   "bm.total"    : int  unread across all accounts
--   "bm.errors"   : int  accounts currently in an error state
--   "bm.updated"  : int  epoch seconds of the last successful poll
--   "bm.cmd"      : { op="refresh"|"poll", seq=int } written by UI entries;
--                   this service executes it. seq must strictly increase.

local function shellQuote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Build a helper invocation. `action` is "status" or "refresh"; the mail cap is
-- passed through so the helper trims the list before it crosses the boundary.
local function helperCmd(action)
	local dir = noctalia.pluginDir()
	if not dir then return nil end
	local cap = tonumber(noctalia.getConfig("max_mails")) or 15
	return table.concat({
		"python3",
		shellQuote(dir .. "/bubblemail-query.py"),
		action,
		tostring(math.floor(cap)),
	}, " ")
end

local function intervalMs()
	local secs = tonumber(noctalia.getConfig("poll_interval")) or 30
	if secs < 5 then secs = 5 end
	return secs * 1000
end

-- Previous per-account error codes, so we notify only on the transition into a
-- failure rather than on every poll while it stays broken.
local prevErrorCodes = {}
local notifiedUnavailable = false

local function markUnavailable(reason, err)
	noctalia.state.set("bm.daemon", {
		available = false,
		reason = reason or "unreachable",
		error = err or "",
		checked = true,
	})
	noctalia.state.set("bm.accounts", {})
	noctalia.state.set("bm.mails", {})
	noctalia.state.set("bm.total", 0)
	noctalia.state.set("bm.errors", 0)
end

-- Notify on accounts that have just entered an error state. Codes <= 0 are
-- healthy (0 = OK, -1 = offline), so only a positive code is a real failure.
local function notifyNewErrors(accounts)
	if noctalia.getConfig("notify_errors") ~= true then
		-- Still track codes while notifications are off, so re-enabling the
		-- setting doesn't replay every pre-existing error as "new".
		for _, a in ipairs(accounts) do prevErrorCodes[a.uuid] = a.error_code end
		return
	end
	for _, a in ipairs(accounts) do
		local prev = prevErrorCodes[a.uuid]
		if a.error_code > 0 and (prev == nil or prev <= 0) then
			local detail = a.error_message
			if detail == nil or detail == "" then detail = a.error_state end
			noctalia.notifyError("Bubblemail: " .. tostring(a.name), tostring(detail))
		end
		prevErrorCodes[a.uuid] = a.error_code
	end
end

local function applyStatus(doc)
	if doc.ok ~= true then
		markUnavailable(doc.reason, doc.error)
		if not notifiedUnavailable and doc.reason == "no-dbus" then
			-- A missing python3-dbus is a setup problem the user must fix, and
			-- unlike a stopped daemon it will not resolve on its own; say so
			-- once rather than silently showing an empty widget forever.
			notifiedUnavailable = true
			noctalia.notifyError("Bubblemail",
				"python3 dbus module not found; the plugin cannot reach bubblemaild")
		end
		return
	end

	notifiedUnavailable = false
	local accounts = doc.accounts or {}
	noctalia.state.set("bm.daemon", { available = true, reason = "", error = "",
		checked = true })
	noctalia.state.set("bm.accounts", accounts)
	noctalia.state.set("bm.mails", doc.mails or {})
	noctalia.state.set("bm.total", tonumber(doc.total) or 0)
	noctalia.state.set("bm.errors", tonumber(doc.errors) or 0)
	noctalia.state.set("bm.updated", os.time())
	notifyNewErrors(accounts)
end

local function poll()
	local cmd = helperCmd("status")
	if not cmd then
		markUnavailable("no-plugin-dir", "cannot locate plugin directory")
		return
	end
	noctalia.runAsync(cmd, function(res)
		if not res or res.error then
			markUnavailable("spawn-failed", res and res.error or "command failed")
			return
		end
		local ok, doc = pcall(noctalia.json.decode, res.stdout or "")
		if not ok or type(doc) ~= "table" then
			-- The helper always prints one JSON object, so this means python3
			-- itself is missing or failed before running our code.
			markUnavailable("bad-output", "helper returned unparseable output")
			return
		end
		applyStatus(doc)
	end)
end

-- Ask the daemon to check mail now, then re-poll. The daemon's check is
-- asynchronous, so a short delay before the follow-up poll gives it time to
-- update its content list; the regular interval poll corrects it either way.
local function refresh()
	local cmd = helperCmd("refresh")
	if not cmd then return end
	noctalia.state.set("bm.refreshing", true)
	noctalia.runAsync(cmd, function()
		noctalia.runAsync("sleep 1.5", function()
			noctalia.state.set("bm.refreshing", false)
			poll()
		end)
	end)
end

local function handleCommand(cmd)
	if cmd.op == "refresh" then
		refresh()
	elseif cmd.op == "poll" then
		poll()
	end
end

function update()
	noctalia.setUpdateInterval(intervalMs())
	poll()
end

function onConfigChanged()
	noctalia.setUpdateInterval(intervalMs())
	-- max_mails changes the helper's trim, so re-poll to honour it immediately
	-- instead of leaving a stale-length list until the next tick.
	poll()
end

-- IPC hook for scripting and testing:
--   noctalia msg plugin jamespo/bubblemail:daemon refresh
--   noctalia msg plugin jamespo/bubblemail:daemon poll
function onIpc(event, _payload)
	if event == "refresh" then
		refresh()
	elseif event == "poll" or event == "status" then
		poll()
	end
end

-- ── Init ────────────────────────────────────────────────────────────────────
noctalia.state.set("bm.daemon", { available = false, reason = "", error = "",
	checked = false })
noctalia.state.set("bm.refreshing", false)
poll()

-- Command channel. seq is wall-clock based so it keeps increasing across a UI
-- hot-reload; a plain counter would restart at 1 and have its commands dropped
-- by the guard below.
local lastCmdSeq = 0
noctalia.state.watch("bm.cmd", function(cmd)
	if type(cmd) ~= "table" then return end
	local seq = tonumber(cmd.seq) or 0
	if seq <= lastCmdSeq then return end
	lastCmdSeq = seq
	handleCommand(cmd)
end)
