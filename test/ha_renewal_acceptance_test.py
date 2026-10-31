"""Renewal acceptance must never advance before exact-leaf verification."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "acceptance", Path(__file__).resolve().parents[1] / "tools/ha_https_renewal_acceptance.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.state = Path(temporary.name) / "state.json"
        self.leaf = b"a" * 32
        self.fingerprint = patch.object(MODULE, "fingerprint", side_effect=lambda _: self.leaf)
        self.verification = patch.object(MODULE, "verify_served")
        self.fingerprint.start()
        self.verify = self.verification.start()
        self.addCleanup(self.fingerprint.stop)
        self.addCleanup(self.verification.stop)

    def check(self, initialize=False):
        return MODULE.check(Path("unused.pem"), self.state, initialize)

    def test_initialization_is_private_and_never_overwrites_baseline(self):
        self.assertFalse(self.check(True)["renewed"])
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        original = self.state.read_bytes()
        self.leaf = b"b" * 32
        with self.assertRaises(FileExistsError):
            self.check(True)
        self.assertEqual(self.state.read_bytes(), original)

    def test_unchanged_leaf_is_pending_and_still_verified(self):
        self.check(True)
        self.verify.reset_mock()
        result = self.check()
        self.assertFalse(result["renewed"])
        self.assertFalse(result["newly_verified"])
        self.verify.assert_called_once_with(self.leaf)

    def test_changed_leaf_is_recorded_once_after_verification(self):
        self.check(True)
        self.leaf = b"b" * 32
        self.verify.side_effect = lambda expected: self.assertEqual(
            json.loads(self.state.read_text())["last_verified"], (b"a" * 32).hex())
        self.assertTrue(self.check()["newly_verified"])
        self.verify.side_effect = None
        self.assertFalse(self.check()["newly_verified"])
        self.assertTrue(self.check()["renewed"])
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)

    def test_bad_served_leaf_or_expiry_preserves_previous_state(self):
        self.check(True)
        original = self.state.read_bytes()
        self.leaf = b"b" * 32
        self.verify.side_effect = ValueError("served certificate mismatch")
        with self.assertRaises(ValueError):
            self.check()
        self.assertEqual(self.state.read_bytes(), original)

    def test_missing_or_invalid_state_cannot_claim_a_renewal(self):
        with self.assertRaises(FileNotFoundError):
            self.check()
        self.state.write_text('{"baseline":"invalid", "last_verified":"invalid"}')
        with self.assertRaises(ValueError):
            self.check()


if __name__ == "__main__":
    unittest.main()
