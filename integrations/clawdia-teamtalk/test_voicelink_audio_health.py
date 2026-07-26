import io
import json
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from voicelink_audio_health import discover


class Response:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return io.BytesIO(json.dumps(self.payload).encode())

    def __exit__(self, *_args):
        return False


class DiscoveryTests(unittest.TestCase):
    def test_missing_token_preserves_text_only(self):
        self.assertEqual(discover("http://localhost:3010", "")["reason"], "missing_internal_token")

    @patch("voicelink_audio_health.urlopen")
    def test_degraded_health_preserves_text_only(self, open_url):
        open_url.return_value = Response({
            "status": "degraded",
            "operations": {"tts": {"ready": False}, "stt": {"ready": False}},
        })
        result = discover("http://localhost:3010", "secret")
        self.assertTrue(result["textOnly"])
        self.assertEqual(result["reason"], "no_validated_adapter")

    @patch("voicelink_audio_health.urlopen")
    def test_ready_adapter_enables_audio(self, open_url):
        open_url.return_value = Response({
            "status": "ready",
            "operations": {"tts": {"ready": True}, "stt": {"ready": False}},
        })
        result = discover("http://localhost:3010", "secret")
        self.assertFalse(result["textOnly"])
        self.assertTrue(result["operations"]["tts"])

    @patch("voicelink_audio_health.urlopen", side_effect=URLError("offline"))
    def test_network_failure_preserves_text_only(self, _open_url):
        self.assertEqual(discover("http://localhost:3010", "secret")["reason"], "health_unavailable")

    @patch(
        "voicelink_audio_health.urlopen",
        side_effect=HTTPError("http://localhost", 401, "unauthorized", {}, None),
    )
    def test_auth_failure_preserves_text_only(self, _open_url):
        result = discover("http://localhost:3010", "secret")
        self.assertEqual(result["httpStatus"], 401)
        self.assertTrue(result["textOnly"])


if __name__ == "__main__":
    unittest.main()
