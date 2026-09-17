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
--   "bm.cmd"      : { op="refresh"|"poll"|"launch", seq=int } written by UI
--                   entries; this service executes it. seq must strictly
--                   increase.

local function shellQuote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Build a helper invocation: "python3 <helper> <args...>", already quoted.
local function helperCmd(...)
	local dir = noctalia.pluginDir()
	if not dir then return nil end
	local parts = { "python3", shellQuote(dir .. "/bubblemail-query.py") }
	for _, arg in ipairs({ ... }) do
		table.insert(parts, arg)
	end
	return table.concat(parts, " ")
end

-- `action` is "status" or "refresh"; the mail cap is passed through so the
-- helper trims the list before it crosses the boundary.
local function queryCmd(action)
	local cap = tonumber(noctalia.getConfig("max_mails")) or 15
	return helperCmd(action, tostring(math.floor(cap)))
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

-- Mail uuids seen by an earlier poll, or nil before the first one. bubblemail
-- derives a mail's uuid from account+folder+sender+subject+date, so it is
-- stable across polls and identifies a single message.
local seenMails = nil

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
	if noctalia.getConfig("notifications") ~= true then
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

-- Post a normal-urgency desktop notification through the helper. The only
-- notification call the plugin API exposes is notifyError(), which renders as a
-- failure; new mail is not one. Failures here are swallowed on purpose -- a
-- notification that could not be shown does not deserve a second one, and a
-- broken helper is already reported by poll().
local function postNotification(summary, body, icon)
	local cmd = helperCmd("notify", shellQuote(summary), shellQuote(body or ""),
		shellQuote(icon or ""))
	if not cmd then return end
	noctalia.runAsync(cmd, function() end)
end

local function senderOf(m)
	local who = m.name
	if who == nil or who == "" then who = m.address end
	if who == nil or who == "" then who = "Unknown sender" end
	return who
end

local function subjectOf(m)
	local subject = m.subject
	if subject == nil or subject == "" then return "(no subject)" end
	return subject
end

-- Announce mails that were absent from the previous poll's list. `total` is the
-- untrimmed pending count; `mails` is capped by max_mails.
local function notifyNewMail(mails, total)
	local fresh = {}
	if seenMails == nil then
		-- First poll of this session: everything pending is pre-existing, not
		-- new. Seed the set silently rather than announcing the whole backlog
		-- on every shell start or plugin reload.
		seenMails = {}
	else
		for _, m in ipairs(mails) do
			local uuid = m.uuid
			if type(uuid) == "string" and uuid ~= "" and not seenMails[uuid] then
				table.insert(fresh, m)
			end
		end
	end

	if #mails >= total then
		-- The list is complete, so rebuild from it and let dismissed mail drop
		-- out of the set instead of accumulating for the life of the session.
		local current = {}
		for _, m in ipairs(mails) do
			if type(m.uuid) == "string" and m.uuid ~= "" then current[m.uuid] = true end
		end
		seenMails = current
	else
		-- Trimmed by max_mails: forgetting what we cannot see would re-announce
		-- an older mail the moment a newer one is dismissed and it reappears.
		for _, m in ipairs(mails) do
			if type(m.uuid) == "string" and m.uuid ~= "" then seenMails[m.uuid] = true end
		end
	end

	-- Checked after the bookkeeping above, so enabling the setting later does
	-- not replay mail that was already sitting there while it was off.
	if #fresh == 0 or noctalia.getConfig("notifications") ~= true then return end

	if #fresh == 1 then
		local m = fresh[1]
		-- bubblemail caches a per-sender avatar; the helper falls back to the
		-- themed mail icon when the path is gone.
		postNotification("New mail from " .. senderOf(m), subjectOf(m), m.avatar)
		return
	end

	-- Newest first, same order as the panel. Three lines is enough to tell what
	-- arrived without turning the toast into a mail client.
	local lines = {}
	for i, m in ipairs(fresh) do
		if i > 3 then
			table.insert(lines, "and " .. tostring(#fresh - 3) .. " more")
			break
		end
		table.insert(lines, senderOf(m) .. " - " .. subjectOf(m))
	end
	postNotification(tostring(#fresh) .. " new mails", table.concat(lines, "\n"))
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
	local mails = doc.mails or {}
	local total = tonumber(doc.total) or 0
	noctalia.state.set("bm.daemon", { available = true, reason = "", error = "",
		checked = true })
	noctalia.state.set("bm.accounts", accounts)
	noctalia.state.set("bm.mails", mails)
	noctalia.state.set("bm.total", total)
	noctalia.state.set("bm.errors", tonumber(doc.errors) or 0)
	noctalia.state.set("bm.updated", os.time())
	notifyNewErrors(accounts)
	notifyNewMail(mails, total)
end

local function poll()
	local cmd = queryCmd("status")
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
	local cmd = queryCmd("refresh")
	if not cmd then return end
	noctalia.state.set("bm.refreshing", true)
	noctalia.runAsync(cmd, function()
		noctalia.runAsync("sleep 1.5", function()
			noctalia.state.set("bm.refreshing", false)
			poll()
		end)
	end)
end

-- Start the user's mail client. The helper spawns it in a new session, so it
-- outlives both this command and the shell itself; an empty mail_client_command
-- means "whatever handles mailto: on this desktop".
local function launchClient()
	local custom = noctalia.getConfig("mail_client_command")
	if type(custom) ~= "string" or not custom:match("%S") then custom = nil end

	local cmd
	if custom then
		cmd = helperCmd("launch", shellQuote(custom))
	else
		cmd = helperCmd("launch")
	end
	if not cmd then return end

	noctalia.runAsync(cmd, function(res)
		local doc
		if res and not res.error then
			local ok, decoded = pcall(noctalia.json.decode, res.stdout or "")
			if ok and type(decoded) == "table" then doc = decoded end
		end
		if doc and doc.ok == true then return end
		-- Nothing visible happens on failure otherwise: the button would just
		-- look broken. Say which half failed.
		local why = doc and doc.error or (res and res.error) or "helper failed"
		noctalia.notifyError("Bubblemail", "Could not open mail client: " .. tostring(why))
	end)
end

local function handleCommand(cmd)
	if cmd.op == "refresh" then
		refresh()
	elseif cmd.op == "poll" then
		poll()
	elseif cmd.op == "launch" then
		launchClient()
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
--   noctalia msg plugin jamespo/bubblemail:daemon launch
function onIpc(event, _payload)
	if event == "refresh" then
		refresh()
	elseif event == "poll" or event == "status" then
		poll()
	elseif event == "launch" then
		launchClient()
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
