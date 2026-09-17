#!/usr/bin/env python3
"""Emit bubblemaild's mail status as a single JSON document.

Helper for the Noctalia bubblemail plugin. Noctalia plugin scripts run in a
Luau sandbox whose only way out is a shell command, and bubblemaild's D-Bus
replies contain free-form mail subjects (commas, quotes, embedded CRLF) that
are painful to parse out of `gdbus` text output. So we do the D-Bus call here
and hand back JSON, which the plugin decodes with noctalia.json.decode.

python3-dbus is not an extra dependency in practice: bubblemaild is itself a
python3 + dbus process, so any machine running the daemon already has it.

Usage:
    bubblemail-query.py                 # full status document
    bubblemail-query.py refresh         # ask the daemon to check mail now
    bubblemail-query.py launch [cmd]    # start the mail client, detached
    bubblemail-query.py notify SUMMARY [BODY] [ICON]   # desktop notification

Always exits 0 and always prints one JSON object, so the caller only has to
look at the "ok" field rather than juggling exit codes.
"""

import json
import os
import shutil
import shlex
import subprocess
import sys

BUS_NAME = 'bubblemail.BubblemailService'
OBJ_PATH = '/bubblemail/BubblemailService'

# The desktop's notification daemon (Noctalia itself, under a normal session).
NOTIFY_NAME = 'org.freedesktop.Notifications'
NOTIFY_PATH = '/org/freedesktop/Notifications'

# Mirrors bubblemail.account.AccountStatus. Duplicated locally so this script
# needs only `dbus`, not the bubblemail package itself.
ERROR_CODES = {
    -1: 'Offline',
    0: 'OK',
    1: 'Connection failed',
    2: 'Connection refused',
    3: 'Authentification failed',
    4: 'No credentials found',
    5: 'Connection error',
    6: 'Connection timeout',
    7: 'No valid local mail folder/file found',
    8: 'Unknown error',
}


def unwrap(obj):
    """Convert dbus types into plain JSON-serialisable Python types."""
    import dbus
    if isinstance(obj, (dbus.Dictionary, dict)):
        return {str(k): unwrap(v) for k, v in obj.items()}
    if isinstance(obj, (dbus.Array, list)):
        return [unwrap(v) for v in obj]
    if isinstance(obj, dbus.String):
        return str(obj)
    if isinstance(obj, (dbus.Int16, dbus.Int32, dbus.Int64,
                        dbus.UInt16, dbus.UInt32, dbus.UInt64)):
        return int(obj)
    if isinstance(obj, dbus.Boolean):
        return bool(obj)
    return obj


def to_int(value, default=0):
    """Coerce a D-Bus field to int; bubblemail sends some numbers as strings."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def accounts_from_config(iface):
    """Configured accounts, keyed by uuid. GetConfig returns a{ss} sections."""
    accounts = {}
    for section in iface.GetConfig():
        section = unwrap(section)
        if 'uuid' not in section:
            continue
        accounts[section['uuid']] = {
            'uuid': section['uuid'],
            'name': section.get('name', '') or section['uuid'],
            'backend': section.get('backend', ''),
            'type': section.get('type', ''),
            'enabled': section.get('enabled', '0') == '1',
        }
    return accounts


def build(iface, max_mails):
    accounts = accounts_from_config(iface)
    mails = [unwrap(m) for m in iface.GetContent()]

    counts = {}
    for mail in mails:
        acct = mail.get('account', '')
        counts[acct] = counts.get(acct, 0) + 1

    report = []
    for status in (unwrap(s) for s in iface.GetStatus()):
        uuid = status.get('uuid', '')
        account = accounts.get(uuid, {
            'uuid': uuid, 'name': uuid, 'backend': '', 'type': '',
            'enabled': True,
        })
        code = to_int(status.get('error_code', 0))
        report.append({
            **account,
            'error_code': code,
            'error_state': ERROR_CODES.get(code, 'Unknown (%d)' % code),
            'error_message': status.get('error_message', ''),
            'error_count': to_int(status.get('error_count', 0)),
            'error_last': to_int(status.get('error_last', 0)),
            'unread': counts.get(uuid, 0),
        })

    # Newest first, so the panel's "recent" list is genuinely recent.
    mails.sort(key=lambda m: to_int(m.get('datetime', 0)), reverse=True)
    if max_mails > 0:
        mails = mails[:max_mails]

    names = {uuid: a['name'] for uuid, a in accounts.items()}
    trimmed = [{
        'uuid': m.get('uuid', ''),
        'account': m.get('account', ''),
        # Resolve here so the UI never has to join across two tables.
        'accountName': names.get(m.get('account', ''), m.get('account', '')),
        'datetime': to_int(m.get('datetime', 0)),
        # Subjects arrive with hard-wrapped CRLF; collapse to one line.
        'subject': ' '.join((m.get('subject', '') or '').split()),
        'name': m.get('name', '') or '',
        'address': m.get('address', '') or '',
        'avatar': m.get('avatar', '') or '',
    } for m in mails]

    return {
        'ok': True,
        'accounts': report,
        'mails': trimmed,
        'total': sum(a['unread'] for a in report),
        'errors': sum(1 for a in report if a['error_code'] > 0),
    }


# ── Mail client launching ───────────────────────────────────────────────────
# None of this needs D-Bus; it is here rather than in the Luau side because
# resolving the desktop's mail handler means reading desktop entries, and the
# plugin sandbox can only reach the outside world through a shell command
# anyway.

# Exec= placeholders, stripped before spawning. There is nothing to substitute:
# we are opening the client itself, not handing it a file or a URL.
FIELD_CODES = {'%f', '%F', '%u', '%U', '%i', '%c', '%k',
               '%d', '%D', '%n', '%N', '%v', '%m'}


def data_dirs():
    """XDG data directories, most specific first."""
    home = os.environ.get('XDG_DATA_HOME') \
        or os.path.expanduser('~/.local/share')
    dirs = os.environ.get('XDG_DATA_DIRS') or '/usr/local/share:/usr/share'
    return [home] + [d for d in dirs.split(':') if d]


def config_dirs():
    """XDG config directories, most specific first."""
    home = os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config')
    dirs = os.environ.get('XDG_CONFIG_DIRS') or '/etc/xdg'
    return [home] + [d for d in dirs.split(':') if d]


def default_mailto_id():
    """Desktop-entry id handling mailto:, e.g. 'thunderbird.desktop'."""
    if shutil.which('xdg-mime'):
        try:
            out = subprocess.run(
                ['xdg-mime', 'query', 'default', 'x-scheme-handler/mailto'],
                capture_output=True, text=True, timeout=5)
            entry = out.stdout.strip().split('\n')[0].strip()
            if entry:
                return entry
        except (OSError, subprocess.SubprocessError):
            pass

    # xdg-utils may not be installed; mimeapps.list is the file it would read.
    for base in config_dirs():
        path = os.path.join(base, 'mimeapps.list')
        entry = mimeapps_default(path)
        if entry:
            return entry
    return ''


def mimeapps_default(path):
    """First x-scheme-handler/mailto entry in a mimeapps.list, if any."""
    section = ''
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            for line in handle:
                line = line.strip()
                if line.startswith('['):
                    section = line
                elif section == '[Default Applications]' \
                        and line.startswith('x-scheme-handler/mailto='):
                    # The value is a ';'-separated preference list.
                    for entry in line.split('=', 1)[1].split(';'):
                        if entry.strip():
                            return entry.strip()
    except OSError:
        pass
    return ''


def desktop_entry_paths(desktop_id):
    """Candidate paths for a desktop id, per the menu spec's '-' rule.

    'kde-foo.desktop' may live at either kde-foo.desktop or kde/foo.desktop.
    """
    names, name = [desktop_id], desktop_id
    while '-' in name:
        name = name.replace('-', '/', 1)
        names.append(name)
    for base in data_dirs():
        for name in names:
            yield os.path.join(base, 'applications', name)


def desktop_entry_argv(desktop_id):
    """argv from a desktop entry's Exec=, or None if it cannot be read.

    Path= and DBusActivatable= are ignored: mail clients do not rely on a
    working directory, and every such entry also carries a usable Exec=.
    """
    if not desktop_id.endswith('.desktop'):
        desktop_id += '.desktop'

    for path in desktop_entry_paths(desktop_id):
        section, exec_line = '', ''
        try:
            with open(path, encoding='utf-8', errors='replace') as handle:
                for line in handle:
                    line = line.rstrip('\n')
                    if line.startswith('['):
                        # Only the main group; later groups are actions.
                        if section == '[Desktop Entry]':
                            break
                        section = line.strip()
                    elif section == '[Desktop Entry]' \
                            and line.startswith('Exec=') and not exec_line:
                        exec_line = line.split('=', 1)[1].strip()
        except OSError:
            continue

        if exec_line:
            try:
                argv = shlex.split(exec_line)
            except ValueError:
                continue
            argv = [a for a in argv if a not in FIELD_CODES]
            if argv:
                return argv
    return None


def default_mail_argv():
    """How to start the desktop's mail client, or None if unknown."""
    desktop_id = default_mailto_id()
    if desktop_id:
        argv = desktop_entry_argv(desktop_id)
        if argv:
            return argv

    # No resolvable handler entry: let the portal/xdg-open chain decide. This
    # opens a compose window in some clients, which still beats doing nothing.
    if shutil.which('xdg-open'):
        return ['xdg-open', 'mailto:']
    return None


def launch(command=''):
    """Start the mail client detached, so it outlives this helper."""
    if command.strip():
        argv = ['sh', '-c', command]
    else:
        argv = default_mail_argv()
        if not argv:
            return {'ok': False, 'reason': 'no-client',
                    'error': 'no default mailto handler found'}

    try:
        subprocess.Popen(argv, start_new_session=True,
                         stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    except OSError as exc:
        return {'ok': False, 'reason': 'spawn-failed', 'error': str(exc)}
    return {'ok': True, 'launched': ' '.join(argv)}


def notify(summary, body='', icon=''):
    """Post a desktop notification via org.freedesktop.Notifications.

    Lives here rather than in the plugin because the only notification call
    Noctalia exposes to plugins is notifyError(), which renders as a failure --
    wrong shape for "you have mail". Going straight to the session's
    notification daemon costs nothing extra: this helper already needs dbus.
    """
    try:
        import dbus
    except ImportError:
        return {'ok': False, 'reason': 'no-dbus',
                'error': 'python3 dbus module not available'}

    if icon and not os.path.isfile(icon):
        # Avatars are cache files that may have been swept; fall back to the
        # themed icon rather than handing the daemon a dead path.
        icon = ''

    try:
        obj = dbus.SessionBus().get_object(NOTIFY_NAME, NOTIFY_PATH)
        iface = dbus.Interface(obj, NOTIFY_NAME)
        # Subjects and sender names are arbitrary text, so escape them when the
        # daemon parses the body as markup and leave them alone when it does
        # not (Noctalia does not, dunst and mako do).
        try:
            markup = 'body-markup' in [str(c) for c in iface.GetCapabilities()]
        except dbus.DBusException:
            markup = False
        if markup:
            for char, entity in (('&', '&amp;'), ('<', '&lt;'), ('>', '&gt;')):
                body = body.replace(char, entity)
        hints = {
            'urgency': dbus.Byte(1),          # normal; new mail is not critical
            'category': dbus.String('email.arrived'),
        }
        iface.Notify('Bubblemail', dbus.UInt32(0), icon or 'mail',
                     summary, body, dbus.Array([], signature='s'), hints,
                     dbus.Int32(-1))         # daemon's default timeout
    except dbus.DBusException as exc:
        return {'ok': False, 'reason': 'unreachable', 'error': str(exc)}
    except Exception as exc:  # pylint: disable=broad-except
        return {'ok': False, 'reason': 'error', 'error': str(exc)}
    return {'ok': True}


def main():
    args = sys.argv[1:]
    action = args[0] if args else 'status'

    if action == 'launch':
        # Deliberately before the dbus import: launching the client is useful
        # even when the daemon side is broken.
        print(json.dumps(launch(args[1] if len(args) > 1 else '')))
        return 0

    if action == 'notify':
        # Not a bubblemaild call, so it does not go through the connection
        # below: the notification daemon is a different bus name entirely.
        fields = (args[1:4] + ['', '', ''])[:3]
        print(json.dumps(notify(*fields)))
        return 0

    max_mails = to_int(args[1], 15) if len(args) > 1 else 15

    try:
        import dbus
    except ImportError:
        print(json.dumps({'ok': False, 'reason': 'no-dbus',
                          'error': 'python3 dbus module not available'}))
        return 0

    try:
        obj = dbus.SessionBus().get_object(BUS_NAME, OBJ_PATH)
        iface = dbus.Interface(obj, BUS_NAME)
        if action == 'refresh':
            iface.Refresh()
            print(json.dumps({'ok': True, 'refresh': 'requested'}))
        else:
            print(json.dumps(build(iface, max_mails)))
    except dbus.DBusException as exc:
        # Daemon not running is the common case here, not a bug worth raising.
        print(json.dumps({'ok': False, 'reason': 'unreachable',
                          'error': str(exc)}))
    except Exception as exc:  # pylint: disable=broad-except
        print(json.dumps({'ok': False, 'reason': 'error', 'error': str(exc)}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
