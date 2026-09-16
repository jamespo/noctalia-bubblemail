# noctalia-bubblemail

A [Noctalia](https://noctalia.dev) v5 plugin that shows mail status from a running [`bubblemaild`](https://framagit.org/razer/bubblemail) — unread counts, per-account connection state and the pending mail list.

## What you get

| Surface                 | Shows                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------- |
| **Bar widget**          | Envelope glyph + unread count. Left-click opens the panel, right-click checks mail now.                 |
| **Control-center tile** | `N unread`, or `N accounts failing` when something is wrong.                                            |
| **Panel**               | Totals, one row per account (unread count + connection state), and the pending mail list, newest first. |
| **Notifications**       | Optional alert when an account enters an error state.                                                   |

Colours indicate status: normal when healthy, dimmed when offline or idle,
error red when an account is failing.

## Requirements

- Noctalia v5 (plugin API 16+)
- A running `bubblemaild`
- `python3` with the `dbus` module — already present on any machine running
  bubblemail, since `bubblemaild` is itself a python3 + dbus process.

## Install

Firstly, ensure bubblemail is installed, your accounts are set up & the daemon is running.

Clone this repository, then register this directory as a local plugin source, then enable the plugin:

```console
$ noctalia msg plugins source add bubblemail-dev path /path/to/noctalia-bubblemail
$ noctalia msg plugins enable jamespo/bubblemail
```

The source path is the **repository root**, not the `bubblemail/` subdirectory:
Noctalia scans a source as a directory of plugin subdirectories, matching the
layout of the official and community plugin repos.

Then add the bar widget by putting `jamespo/bubblemail:bar` in a bar's widget
list in `~/.local/state/noctalia/settings.toml` and running
`noctalia msg config-reload`, or add it from Noctalia's own settings UI.

To remove it again:

```console
$ noctalia msg plugins disable jamespo/bubblemail
```

## Settings

| Setting                  | Default        | Meaning                                                                  |
| ------------------------ | -------------- | ------------------------------------------------------------------------ |
| Poll interval            | 30s            | Seconds between daemon checks (5–600).                                   |
| Bar display              | Icon and count | Icon and count / count only / icon only.                                 |
| Hide when empty          | off            | Drop the bar widget entirely when there is no unread mail and no errors. |
| Mails in panel           | 15             | Cap on the pending mail list (1–50).                                     |
| Notify on account errors | on             | Notify when an account enters an error state.                            |

## Layout

```
bubblemail/
  plugin.toml           manifest: settings + the four entries
  service.luau          background service; the only entry that talks to the daemon
  widget.luau           bar widget      (reads state)
  tile.luau             control-center tile (reads state)
  panel.luau            mail panel      (reads state, sends commands)
  bubblemail-query.py   D-Bus -> JSON helper
  translations/en.json  setting labels
```

### Why a Python helper

Noctalia plugin scripts run in a Luau sandbox with no `require` and no native
D-Bus binding; the only way out is a shell command. The obvious route is
`gdbus`, but bubblemail's `GetContent` returns mail subjects containing commas,
apostrophes and hard-wrapped CRLF, which makes `gdbus`' text output genuinely
ambiguous to parse with Lua patterns. `bubblemail-query.py` does the D-Bus call
and returns a single JSON document instead, which the service decodes with
`noctalia.json.decode`.

It provides three methods (`GetConfig`, `GetStatus`, `GetContent`),  defines `AccountStatus` as an error-code table and uses mail pending in bubblemail's notification list as a definition of "unread"; not a raw IMAP `UNSEEN` count.

You can run it standalone:

```console
$ ./bubblemail/bubblemail-query.py status 5   # JSON status, 5 most recent mails
$ ./bubblemail/bubblemail-query.py refresh    # ask the daemon to check mail now
```

It always exits 0 and always prints one JSON object, so callers check the `ok`
field rather than an exit code.

### State contract

`service.luau` owns all daemon traffic and publishes to `noctalia.state`; the
three UI entries only read it. Swapping the transport touches that one file.

| Key                      | Value                                                                                                                                          |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `bm.daemon`              | `{ available, reason, error, checked }` — `checked` stays false until the first poll returns, so the UI doesn't flash "unavailable" at startup |
| `bm.accounts`            | per-account records (uuid, name, enabled, error code/state/message, unread)                                                                    |
| `bm.mails`               | pending mails, newest first, capped by `max_mails`                                                                                             |
| `bm.total` / `bm.errors` | unread total, count of failing accounts                                                                                                        |
| `bm.updated`             | epoch of last successful poll                                                                                                                  |
| `bm.cmd`                 | `{ op = "refresh" \| "poll", seq }` written by UI entries                                                                                      |

## Scripting

```console
$ noctalia msg plugin jamespo/bubblemail:daemon all refresh   # check mail now
$ noctalia msg plugin jamespo/bubblemail:daemon all poll      # re-read state
$ noctalia msg panel-toggle jamespo/bubblemail:mails
```

## Development

```console
$ noctalia plugins lint .
```

Entries hot-reload on save while the plugin is enabled.

noctalia-bubblemail is developed with AI assistance.
