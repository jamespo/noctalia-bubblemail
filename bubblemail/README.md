# noctalia-bubblemail

A [Noctalia](https://noctalia.dev) v5 plugin that shows mail status from a running [`bubblemaild`](https://framagit.org/razer/bubblemail) — unread counts, per-account connection state and the pending mail list.

## What you get

| Surface                 | Shows                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------- |
| **Bar widget**          | Envelope glyph + unread count. Left-click opens the panel, right-click checks mail now.                 |
| **Control-center tile** | `N unread`, or `N accounts failing` when something is wrong.                                            |
| **Panel**               | Totals, one row per account (unread count + connection state), and the pending mail list, newest first, and a button that opens your mail client. |
| **Notifications**       | Optional alert when new mail arrives, and when an account enters an error state.                        |

Colours indicate status: normal when healthy, dimmed when offline or idle,
error red when an account is failing.

## Requirements

- Noctalia v5 (plugin API 16+)
- A running `bubblemaild`
- `python3` with the `dbus` module — already present on any machine running
  bubblemail, since `bubblemaild` is itself a python3 + dbus process.

## Install

Firstly, ensure bubblemail is installed, your accounts are set up & the daemon is running.

Register the repository as a plugin source, then enable the plugin. Pick the
source kind by whether you want Noctalia to own the files (git) or to read them
from a checkout you manage yourself (path).

### From git — installs and uninstalls like a store plugin

```console
$ noctalia msg plugins source add jamespo git https://github.com/jamespo/noctalia-plugins-jp
$ noctalia msg plugins enable jamespo/bubblemail
```

Noctalia clones the repo into its own cache and exports the plugin to
`~/.local/state/noctalia/plugins/materialized/jamespo/bubblemail`. Because those
files belong to Noctalia, Settings → Plugins shows the trash icon next to
Bubblemail and can uninstall it, exactly like the community plugins; it also
picks up new versions via `noctalia msg plugins update jamespo` and the
auto-update cycle. This is the recommended way to install.

### From a local path — for hacking on the plugin

```console
$ noctalia msg plugins source add bubblemail-dev path /path/to/noctalia-plugins-jp
$ noctalia msg plugins enable jamespo/bubblemail
```

A path source is a directory Noctalia treats as read-only: it runs the plugin
straight out of your working tree (handy — edits are picked up by the file
watcher), but it never writes to or deletes from it. That means **no trash icon
in Settings → Plugins** for plugins from a path source; removing one means
disabling it and dropping the source:

```console
$ noctalia msg plugins disable jamespo/bubblemail
$ noctalia msg plugins source remove bubblemail-dev
```

Either way the source location is the **repository root**, not the `bubblemail/`
subdirectory: Noctalia scans a source as a directory of plugin subdirectories,
matching the layout of the official and community plugin repos.

Then add the bar widget by putting `jamespo/bubblemail:bar` in a bar's widget
list in `~/.local/state/noctalia/settings.toml` and running
`noctalia msg config-reload`, or add it from Noctalia's own settings UI.

## Settings

| Setting                  | Default        | Meaning                                                                  |
| ------------------------ | -------------- | ------------------------------------------------------------------------ |
| Poll interval            | 30s            | Seconds between daemon checks (5–600).                                   |
| Bar display              | Icon and count | Icon and count / count only / icon only.                                 |
| Hide when empty          | off            | Drop the bar widget entirely when there is no unread mail and no errors. |
| Mails in panel           | 15             | Cap on the pending mail list (1–50).                                     |
| Mail client button       | on             | Show a button in the panel header that opens your mail client.          |
| Mail client command      | *(empty)*      | Command that button runs; empty means the desktop's default.            |
| Notifications            | on             | Notify on new mail and on account errors (see below).                    |

### Notifications

One toggle covers both kinds. Account errors fire on the transition into a
failure, not on every poll while it stays broken.

For new mail, each poll compares the pending list against the previous one and
announces what is new: one mail gets `New mail from <sender>` with the subject
as the body and the sender's bubblemail avatar as the icon, several get a
`N new mails` summary listing the first three. Turn the setting off if
bubblemail's own notification plugins already cover this.

The first poll after the shell starts or the plugin reloads seeds the list
silently, so you are not greeted by your existing backlog. The same bookkeeping
runs while the setting is off, so turning it on does not replay mail that
arrived earlier.

Mails are identified by bubblemail's own uuid (a hash of account, folder,
sender, subject and date), so the same message is never announced twice, and
dismissing mail elsewhere does not re-trigger it. Detection is limited to the
**Mails in panel** cap: if more than that many arrive between two polls, only
the most recent ones are announced.

### Opening the mail client

With **Mail client command** empty, the button resolves the desktop's
`mailto:` handler (`xdg-mime`, falling back to `mimeapps.list`) and runs that
desktop entry's `Exec=` with its field codes stripped — so you get the client's
normal window, not a compose window. If no handler can be resolved it falls
back to `xdg-open mailto:`.

Set the command explicitly to override that: it is run with `sh -c`, so
`thunderbird`, `flatpak run org.mozilla.Thunderbird` or
`kitty -e neomutt` all work. A command that fails does so in the detached
child, where the plugin cannot see it — only failures to start anything at all
are reported as a notification.

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
$ ./bubblemail/bubblemail-query.py launch     # start the default mail client
$ ./bubblemail/bubblemail-query.py launch 'thunderbird'   # ...or a given command
$ ./bubblemail/bubblemail-query.py notify 'Summary' 'Body' # desktop notification
```

`launch` needs no D-Bus at all; it lives here because resolving the desktop's
mail handler means reading desktop entries, and because spawning the client in
its own session keeps it alive when the shell restarts.

`notify` talks to `org.freedesktop.Notifications`, not to bubblemaild. It lives
here because the only notification call Noctalia exposes to plugins is
`notifyError()`, which renders as a failure — the wrong shape for "you have
mail" — and because this helper already has D-Bus in hand.

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
| `bm.cmd`                 | `{ op = "refresh" \| "poll" \| "launch", seq }` written by UI entries                                                                          |

## Scripting

```console
$ noctalia msg plugin jamespo/bubblemail:daemon all refresh   # check mail now
$ noctalia msg plugin jamespo/bubblemail:daemon all poll      # re-read state
$ noctalia msg plugin jamespo/bubblemail:daemon all launch    # open mail client
$ noctalia msg panel-toggle jamespo/bubblemail:mails
```

## Development

```console
$ noctalia plugins lint .
```

Entries hot-reload on save while the plugin is enabled.

noctalia-bubblemail is developed with AI assistance.
