#!/usr/bin/env python3
"""KDE Connect D-Bus adapter. JSON on stdout; no message/contact files written.

watch subscribes before taking snapshots. request performs one explicit operation.
The Luau service owns the UI model and consumes newline-delimited JSON events.
"""

import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import quopri
import re
import sys
import time
from urllib.parse import unquote
import xml.etree.ElementTree as ET

SERVICE = "org.kde.kdeconnect"
ROOT = "/modules/kdeconnect"
DEVICE = SERVICE + ".device"
PROPERTIES = "org.freedesktop.DBus.Properties"
PAGE_SIZE = 50


def unpack(value):
    """Recursively unwrap variants, including variants inside message structs."""
    if hasattr(value, "unpack"):
        return unpack(value.unpack())
    if isinstance(value, dict):
        return {str(k): unpack(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [unpack(v) for v in value]
    return value


def normalize_number(number):
    number = unquote(str(number).removeprefix("tel:"))
    # Do not guess country codes or match ambiguous number suffixes.
    return re.sub(r"[\s().-]", "", number).casefold()


def decode_message(value):
    record = unpack(value)
    if not isinstance(record, list) or len(record) not in (8, 9, 10):
        raise ValueError("Unsupported KDE Connect message format")
    event, body, addresses, date, kind, read, thread, uid = record[:8]
    if not isinstance(body, str) or not isinstance(addresses, list):
        raise ValueError("Invalid KDE Connect message")
    numbers = []
    for address in addresses:
        if isinstance(address, list) and address and isinstance(address[0], str):
            numbers.append(address[0])
    return {
        "id": str(uid), "thread": str(thread), "body": body,
        "addresses": numbers, "date": int(date), "type": int(kind),
        "read": bool(read), "outgoing": int(kind) in (2, 3, 4, 5, 6),
        "attachments": len(record[9]) if len(record) > 9 else 0,
        "subId": str(record[8]) if len(record) > 8 else "-1",
        "event": int(event),
    }


def vcard_text(value):
    return re.sub(r"\\([nN,;\\])", lambda m: "\n" if m[1].lower() == "n" else m[1], value)


def vcard_lines(text):
    """Unfold vCard lines, including v2.1 quoted-printable soft line breaks."""
    current = ""
    for line in text.splitlines():
        head = current.partition(":")[0].upper()
        quoted = "ENCODING=QUOTED-PRINTABLE" in head
        if current and quoted and current.endswith("="):
            current = current[:-1] + line.lstrip(" \t")
        elif current and line.startswith((" ", "\t")):
            current += line[1:]
        elif current and re.search(r";ENCODING=(?:B|BASE64)(?:;|$)", head) and line and ":" not in line:
            current += line.strip()
        else:
            if current:
                yield current
            current = line
    if current:
        yield current


def vcard_value(head, value):
    params = {}
    for param in head.split(";")[1:]:
        key, sep, item = param.partition("=")
        if sep:
            params[key.upper()] = item.strip('"')
    raw = value.encode("utf-8", errors="surrogateescape")
    encoding = params.get("ENCODING", "").upper()
    if encoding == "QUOTED-PRINTABLE":
        raw = quopri.decodestring(raw)
    elif encoding in ("B", "BASE64"):
        try:
            raw = base64.b64decode(re.sub(rb"\s", b"", raw), validate=True)
        except (ValueError, binascii.Error):
            return value  # A malformed contact must not discard the address book.
    try:
        return raw.decode(params.get("CHARSET", "utf-8"), errors="replace")
    except (LookupError, ValueError):
        return raw.decode("utf-8", errors="replace")


def parse_vcard(text, identifier):
    name, fallback, numbers = "", "", []
    for line in vcard_lines(text):
        head, sep, value = line.partition(":")
        if not sep:
            continue
        field = head.split(";", 1)[0].split(".")[-1].upper()
        if field not in ("FN", "N", "TEL"):
            continue
        value = vcard_value(head, value)
        if field == "FN":
            name = vcard_text(value)
        elif field == "N":
            fallback = " ".join(vcard_text(v) for v in value.split(";") if v)
        elif field == "TEL":
            number = unquote(value.removeprefix("tel:"))
            if number and normalize_number(number) not in {normalize_number(n) for n in numbers}:
                numbers.append(number)
    if not numbers:
        return None
    name = name or fallback or numbers[0]
    return {"id": identifier, "name": name, "numbers": numbers,
            "search": (name + " " + " ".join(numbers) + " " + " ".join(map(normalize_number, numbers))).casefold()}


def read_contacts(device, data_home=None):
    base = Path(data_home or os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    directory = base / "kpeoplevcard" / ("kdeconnect-" + device)
    contacts = []
    if directory.is_dir():
        for path in sorted(directory.iterdir()):
            if path.suffix not in (".vcf", ".vcard") or not path.is_file():
                continue
            try:
                contact = parse_vcard(path.read_text(encoding="utf-8", errors="surrogateescape"), path.stem)
                if contact:
                    contacts.append(contact)
            except OSError:
                continue  # A concurrent contact sync may replace a file.
    return sorted(contacts, key=lambda c: (c["name"].casefold(), c["id"]))


def emit(event):
    print(json.dumps(event, ensure_ascii=False, separators=(",", ":")), flush=True)


class Bridge:
    def __init__(self):
        try:
            from gi.repository import Gio, GLib
        except ImportError as exc:
            raise RuntimeError("Install Python 3 and PyGObject (python-gobject on Arch; python3-gi on Debian/Ubuntu).") from exc
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.loop = GLib.MainLoop()
        self.pending_snapshots = set()

    def call(self, path, interface, method, signature=None, args=()):
        params = self.GLib.Variant(signature, args) if signature else None
        return self.bus.call_sync(SERVICE, path, interface, method, params, None,
                                  self.Gio.DBusCallFlags.NONE, 10000, None)

    def properties(self, path, interface):
        return unpack(self.call(path, PROPERTIES, "GetAll", "(s)", (interface,)))[0]

    def path(self, device):
        if not re.fullmatch(r"[A-Za-z0-9_]+", device):
            raise ValueError("Invalid device ID")
        return ROOT + "/devices/" + device

    def interfaces(self, path):
        xml = unpack(self.call(path, "org.freedesktop.DBus.Introspectable", "Introspect"))[0]
        return {n.attrib["name"] for n in ET.fromstring(xml).findall("interface")}

    def available(self, device):
        props = self.properties(self.path(device), DEVICE)
        return bool(props.get("isPaired") and props.get("isReachable"))

    def notification(self, device, public_id):
        if not re.fullmatch(r"[A-Za-z0-9_]+", public_id):
            raise ValueError("Invalid notification ID")
        path = self.path(device) + "/notifications/" + public_id
        props = self.properties(path, DEVICE + ".notifications.notification")
        return {"id": public_id, "app": props.get("appName", ""),
                "title": props.get("title", ""), "text": props.get("text", ""),
                "replyId": props.get("replyId", ""), "dismissable": props.get("dismissable", False),
                "icon": props.get("iconPath", "")}

    def snapshot(self, device):
        path = self.path(device)
        if not self.available(device):
            return [{"type": "connection", "device": device, "connected": False}]
        interfaces = self.interfaces(path)
        loaded = unpack(self.call(path, DEVICE, "loadedPlugins"))[0]
        caps = {"messages": DEVICE + ".conversations" in interfaces,
                "contacts": "kdeconnect_contacts" in loaded,
                "notifications": "kdeconnect_notifications" in loaded,
                "calls": "kdeconnect_telephony" in loaded}
        events = [{"type": "capabilities", "device": device, "capabilities": caps, "connected": True}]
        if caps["contacts"]:
            events.append({"type": "contacts", "device": device, "items": read_contacts(device)})
        if caps["messages"]:
            records = unpack(self.call(path, DEVICE + ".conversations", "activeConversations"))[0]
            events.append({"type": "threads", "device": device, "items": [decode_message(m) for m in records]})
        if caps["notifications"]:
            ids = unpack(self.call(path + "/notifications", DEVICE + ".notifications", "activeNotifications"))[0]
            items = []
            for public_id in ids:
                try:
                    items.append(self.notification(device, public_id))
                except self.GLib.Error:
                    pass  # Dismissed between listing and reading.
            events.append({"type": "notifications", "device": device, "items": items})
        return events

    def request(self, command):
        device, op = command.get("device", ""), command.get("op")
        path = self.path(device)
        if not self.available(device):
            raise ValueError("Phone is disconnected or unpaired")
        conv = DEVICE + ".conversations"
        if op == "sync":
            events = self.snapshot(device)
            caps = events[0].get("capabilities", {})
            if caps.get("messages"):
                self.call(path, conv, "requestAllConversationThreads")
            return events
        if op == "contacts_sync":
            self.call(path + "/contacts", DEVICE + ".contacts", "synchronizeRemoteWithLocal")
        elif op == "history":
            start = max(0, int(command.get("start", 0)))
            self.call(path, conv, "requestConversation", "(xii)",
                      (int(command["thread"]), start, start + PAGE_SIZE))
        elif op in ("sms_send", "notification_reply"):
            text = command.get("text", "")
            if not isinstance(text, str) or not text.strip():
                raise ValueError("Message is empty")
            if op == "notification_reply":
                notification = self.notification(device, command["notification"])
                if not notification["replyId"] or notification["replyId"] != command.get("replyId"):
                    raise ValueError("Notification reply is no longer available")
                self.call(path + "/notifications", DEVICE + ".notifications", "sendReply", "(ss)",
                          (notification["replyId"], text))
            else:
                attachments = [self.GLib.Variant("s", command["attachment"])] if command.get("attachment") else []
                if command.get("thread"):
                    self.call(path, conv, "replyToConversation", "(xsav)", (int(command["thread"]), text, attachments))
                else:
                    number = command.get("destination", "").strip()
                    if not number:
                        raise ValueError("Choose a recipient")
                    self.call(path, conv, "sendWithoutConversation", "(avsav)",
                              ([self.GLib.Variant("(s)", (number,))], text, attachments))
        elif op == "notification_dismiss":
            notification = self.notification(device, command["notification"])
            if not notification["dismissable"]:
                raise ValueError("Notification cannot be dismissed")
            self.call(path + "/notifications/" + notification["id"],
                      DEVICE + ".notifications.notification", "dismiss")
        else:
            raise ValueError("Unsupported operation")
        return []

    def snapshot_later(self, device):
        if device in self.pending_snapshots:
            return
        self.pending_snapshots.add(device)
        def refresh():
            self.pending_snapshots.discard(device)
            try:
                for event in self.snapshot(device):
                    emit(event)
            except (self.GLib.Error, ValueError) as exc:
                emit({"type": "error", "device": device, "message": safe_error(exc)})
            return False
        self.GLib.timeout_add(250, refresh)

    def signal(self, _bus, _sender, path, interface, signal, params, _data=None):
        try:
            values = unpack(params)
            if path == ROOT:
                if signal in ("deviceAdded", "deviceVisibilityChanged") and values:
                    self.snapshot_later(values[0])
                elif signal == "deviceRemoved" and values:
                    emit({"type": "removed", "device": values[0]})
                return
            match = re.match(re.escape(ROOT) + r"/devices/([A-Za-z0-9_]+)(?:/|$)", path)
            if not match:
                return
            device = match[1]
            event = {"device": device}
            if interface == DEVICE + ".conversations":
                if signal in ("conversationCreated", "conversationUpdated"):
                    event.update(type="message", message=decode_message(values[0]))
                elif signal == "conversationRemoved":
                    event.update(type="thread_removed", thread=str(values[0]))
                elif signal == "conversationLoaded":
                    event.update(type="loaded", thread=str(values[0]), count=int(values[1]))
                else:
                    return
            elif interface == DEVICE + ".notifications":
                if signal in ("notificationPosted", "notificationUpdated"):
                    event.update(type="notification", notification=self.notification(device, values[0]))
                elif signal == "notificationRemoved":
                    event.update(type="notification_removed", id=values[0])
                elif signal == "allNotificationsRemoved":
                    event.update(type="notifications", items=[])
                else:
                    return
            elif interface == DEVICE + ".contacts" and signal == "localCacheSynchronized":
                event.update(type="contacts", items=read_contacts(device))
            elif interface == DEVICE + ".telephony" and signal == "callReceived":
                event.update(type="call", call={"event": values[0], "number": values[1],
                                                "name": values[2], "date": int(time.time())})
            elif interface == DEVICE and signal in ("reachableChanged", "pairStateChanged", "pluginsChanged"):
                self.snapshot_later(device)
                return
            else:
                return
            emit(event)
        except (self.GLib.Error, ValueError, IndexError, TypeError) as exc:
            emit({"type": "error", "message": safe_error(exc)})

    def initial(self):
        try:
            devices = unpack(self.call(ROOT, SERVICE + ".daemon", "devices", "(bb)", (False, True)))[0]
            for device in devices:
                self.snapshot_later(device)
            emit({"type": "ready"})
        except self.GLib.Error as exc:
            emit({"type": "error", "message": safe_error(exc)})

    def owner_changed(self, _bus, _sender, _path, _interface, _signal, params, _data=None):
        _name, _old, new = unpack(params)
        emit({"type": "reset"})
        if new:
            self.initial()

    def watch(self):
        self.bus.signal_subscribe(SERVICE, None, None, None, None,
                                  self.Gio.DBusSignalFlags.NONE, self.signal)
        self.bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                                  "/org/freedesktop/DBus", SERVICE, self.Gio.DBusSignalFlags.NONE,
                                  self.owner_changed)
        self.initial()
        def heartbeat():
            emit({"type": "heartbeat"})
            return True
        self.GLib.timeout_add_seconds(10, heartbeat)
        self.loop.run()


def safe_error(exc):
    # Do not include method arguments or message bodies in UI errors/logs.
    if isinstance(exc, (ValueError, RuntimeError)):
        return str(exc)
    text = str(exc)
    if "UnknownObject" in text or "UnknownMethod" in text:
        return "KDE Connect feature or notification is no longer available"
    if "ServiceUnknown" in text or "NameHasNoOwner" in text:
        return "KDE Connect is not running"
    if "Timeout" in text or "timed out" in text:
        return "KDE Connect did not respond; the outcome is unknown. Check the phone before retrying."
    return "KDE Connect request failed; check the connection and phone permissions"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("watch", "request", "check"))
    parser.add_argument("command", nargs="?")
    args = parser.parse_args()
    try:
        bridge = Bridge()
        if args.mode == "watch":
            bridge.watch()
        elif args.mode == "request":
            emit({"ok": True, "events": bridge.request(json.loads(args.command or "{}"))})
        else:
            emit({"ok": True})
        return 0
    except (Exception,) as exc:
        emit({"type": "error", "ok": False, "message": safe_error(exc)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
