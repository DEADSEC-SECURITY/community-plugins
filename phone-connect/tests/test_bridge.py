import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).resolve().parents[1] / "bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class Variant:
    def __init__(self, value): self.value = value
    def unpack(self): return self.value


class BridgeTests(unittest.TestCase):
    def test_nested_message_and_attachments(self):
        value = Variant((1, "Hello 👋\n你好 — O'Brien", [Variant(("+1 (555) 010-0100",))],
                         123456789, 2, 0, 42, 7, 3, [Variant((1, "image/png", "", "x"))]))
        message = bridge.decode_message(value)
        self.assertEqual(message["thread"], "42")
        self.assertEqual(message["id"], "7")
        self.assertTrue(message["outgoing"])
        self.assertEqual(message["attachments"], 1)
        self.assertEqual(message["addresses"], ["+1 (555) 010-0100"])
        self.assertIn("你好", message["body"])

    def test_old_message_and_invalid_format(self):
        message = bridge.decode_message((1, "body", [("123",)], 1, 1, 1, 2, 3))
        self.assertFalse(message["outgoing"])
        self.assertEqual(message["subId"], "-1")
        with self.assertRaises(ValueError): bridge.decode_message(("unexpected",))

    def test_vcard_unicode_folding_multiple_numbers(self):
        contact = bridge.parse_vcard("BEGIN:VCARD\r\nFN:Zoë\\, Long\r\n Name\r\n"
                                    "TEL;TYPE=CELL:tel:%2B1-555-0100\r\n"
                                    "item1.TEL;TYPE=HOME:+1 (555) 0200\r\nTEL:+1 555 0100\r\nEND:VCARD", "7")
        self.assertEqual(contact["name"], "Zoë, LongName")
        self.assertEqual(contact["numbers"], ["+1-555-0100", "+1 (555) 0200"])
        self.assertIn("zoë", contact["search"])
        self.assertIsNone(bridge.parse_vcard("FN:No number", "8"))

    def test_contact_cache_is_device_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "kpeoplevcard" / "kdeconnect-phone_a"
            cache.mkdir(parents=True)
            (cache / "1.vcf").write_text("FN:Alex\nTEL:123", encoding="utf-8")
            (cache / "1.meta").write_text("FN:Ignore\nTEL:456", encoding="utf-8")
            self.assertEqual(len(bridge.read_contacts("phone_a", directory)), 1)
            self.assertEqual(bridge.read_contacts("phone_b", directory), [])

    def test_number_matching_does_not_guess_country(self):
        self.assertEqual(bridge.normalize_number("+1 (555) 010-1000"), "+15550101000")
        self.assertNotEqual(bridge.normalize_number("5550101000"), "+15550101000")

    def fake_bridge(self):
        obj = bridge.Bridge.__new__(bridge.Bridge)
        obj.available = lambda device: True
        obj.calls = []
        obj.call = lambda *args: obj.calls.append(args)
        return obj

    def test_pagination_and_existing_thread_reply(self):
        obj = self.fake_bridge()
        obj.request({"op": "history", "device": "phone", "thread": "42", "start": 50})
        self.assertEqual(obj.calls[-1][-1], (42, 50, 100))
        obj.request({"op": "sms_send", "device": "phone", "thread": "42", "text": "hello"})
        self.assertEqual(obj.calls[-1][2], "replyToConversation")
        self.assertEqual(obj.calls[-1][-1], (42, "hello", []))

    def test_expired_notification_and_offline_actions(self):
        obj = self.fake_bridge()
        obj.notification = lambda *_: {"id": "1", "replyId": "new", "dismissable": False}
        with self.assertRaisesRegex(ValueError, "no longer"):
            obj.request({"op": "notification_reply", "device": "phone", "notification": "1", "replyId": "old", "text": "hi"})
        with self.assertRaisesRegex(ValueError, "cannot be dismissed"):
            obj.request({"op": "notification_dismiss", "device": "phone", "notification": "1"})
        obj.available = lambda *_: False
        with self.assertRaisesRegex(ValueError, "disconnected"):
            obj.request({"op": "sms_send", "device": "phone", "text": "hi"})
        self.assertEqual(obj.calls, [])

    def test_error_does_not_expose_message_arguments(self):
        error = Exception("GDBus call failed sending private message text")
        self.assertNotIn("private", bridge.safe_error(error))
        self.assertIn("unknown", bridge.safe_error(Exception("operation timed out")))


if __name__ == "__main__": unittest.main()
