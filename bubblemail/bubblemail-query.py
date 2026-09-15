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
    bubblemail-query.py            # full status document
    bubblemail-query.py refresh    # ask the daemon to check mail now

Always exits 0 and always prints one JSON object, so the caller only has to
look at the "ok" field rather than juggling exit codes.
"""

import json
import sys

BUS_NAME = 'bubblemail.BubblemailService'
OBJ_PATH = '/bubblemail/BubblemailService'

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


def main():
    args = sys.argv[1:]
    action = args[0] if args else 'status'
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
