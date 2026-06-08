#!/usr/bin/env python3
import json
import os
import sys


MODEL_NAME = os.environ.get("VOICELINK_WHISPER_MODEL", "base")
FORCED_LANGUAGE = os.environ.get("VOICELINK_WHISPER_LANGUAGE") or None


def load_backend():
    try:
        from faster_whisper import WhisperModel  # type: ignore

        model = WhisperModel(MODEL_NAME, device="auto", compute_type="auto")

        def transcribe(audio_path: str, language: str | None):
            segments, info = model.transcribe(
                audio_path,
                language=language or FORCED_LANGUAGE,
                vad_filter=True,
                beam_size=1,
                best_of=1
            )
            text = " ".join(segment.text.strip() for segment in segments if getattr(segment, "text", "").strip()).strip()
            return {
                "text": text,
                "language": getattr(info, "language", None)
            }

        return transcribe
    except Exception as error:
        print(f"[TranscriptionWorker] faster-whisper unavailable: {error}", file=sys.stderr, flush=True)

    try:
        import whisper  # type: ignore

        model = whisper.load_model(MODEL_NAME)

        def transcribe(audio_path: str, language: str | None):
            result = model.transcribe(audio_path, language=language or FORCED_LANGUAGE, fp16=False)
            return {
                "text": str(result.get("text", "")).strip(),
                "language": result.get("language")
            }

        return transcribe
    except Exception as error:
        print(f"[TranscriptionWorker] whisper unavailable: {error}", file=sys.stderr, flush=True)
        return None


TRANSCRIBE = load_backend()


def main() -> int:
    if TRANSCRIBE is None:
        print(json.dumps({
            "id": "startup",
            "error": "No Whisper backend available. Install faster-whisper or whisper."
        }), flush=True)
        return 1

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue

        job_id = str(payload.get("id") or "").strip()
        audio_path = str(payload.get("audioPath") or "").strip()
        language = payload.get("language")

        if not job_id or not audio_path:
            print(json.dumps({
                "id": job_id or "unknown",
                "error": "Missing audioPath"
            }), flush=True)
            continue

        try:
            result = TRANSCRIBE(audio_path, language)
            print(json.dumps({
                "id": job_id,
                "text": result.get("text", ""),
                "language": result.get("language")
            }), flush=True)
        except Exception as error:
            print(json.dumps({
                "id": job_id,
                "error": str(error)
            }), flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
