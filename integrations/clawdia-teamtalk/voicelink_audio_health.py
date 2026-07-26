#!/usr/bin/env python3
"""Authenticated VoiceLink Audio discovery for the Clawdia TeamTalk bridge."""

from __future__ import annotations

import json
import os
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


HEALTH_PATH = "/api/internal/audio/health"


def text_only(reason: str, *, status: int | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "audioReady": False,
        "textOnly": True,
        "reason": reason,
    }
    if status is not None:
        result["httpStatus"] = status
    return result


def discover(
    base_url: str,
    token: str,
    caller: str = "clawdia-teamtalk",
    timeout: float = 3.0,
) -> dict[str, Any]:
    if not token:
        return text_only("missing_internal_token")

    url = base_url.rstrip("/") + HEALTH_PATH
    request = Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "X-VoiceLink-Caller": caller,
            "Accept": "application/json",
        },
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except HTTPError as error:
        return text_only("health_http_error", status=error.code)
    except (URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError):
        return text_only("health_unavailable")

    operations = payload.get("operations") if isinstance(payload, dict) else None
    tts = operations.get("tts", {}) if isinstance(operations, dict) else {}
    stt = operations.get("stt", {}) if isinstance(operations, dict) else {}
    ready = payload.get("status") == "ready" and bool(tts.get("ready") or stt.get("ready"))
    if not ready:
        return text_only("no_validated_adapter", status=200)

    return {
        "audioReady": True,
        "textOnly": False,
        "reason": "ready",
        "httpStatus": 200,
        "operations": {
            "tts": bool(tts.get("ready")),
            "stt": bool(stt.get("ready")),
        },
    }


def main() -> int:
    result = discover(
        os.environ.get("VOICELINK_AUDIO_BASE_URL", "http://127.0.0.1:3010"),
        os.environ.get("VOICELINK_AUDIO_INTERNAL_TOKEN", ""),
        os.environ.get("VOICELINK_AUDIO_CALLER", "clawdia-teamtalk"),
    )
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
