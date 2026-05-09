#!/usr/bin/env python3
import argparse
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Generate VoiceLink IVR fallback prompts with Piper.")
    parser.add_argument("--manifest", default=str(Path(__file__).with_name("prompt-manifest.json")))
    parser.add_argument("--output-dir", default=str(Path(__file__).with_name("generated")))
    parser.add_argument("--piper-bin", default="piper")
    parser.add_argument("--model", required=True, help="Path to Piper voice model")
    parser.add_argument("--config", default=None, help="Optional Piper config JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest = json.loads(manifest_path.read_text())
    prompts = manifest.get("prompts", [])

    for prompt in prompts:
        text = str(prompt.get("text", "")).strip()
        filename = str(prompt.get("file", "")).strip()
        category = str(prompt.get("category", "")).strip().lower()
        if not text or not filename or category == "utility":
            continue

        target = output_dir / filename
        cmd = [
            args.piper_bin,
            "--model",
            args.model,
            "--output_file",
            str(target)
        ]
        if args.config:
            cmd.extend(["--config", args.config])

        print(f"Generating {target.name}")
        subprocess.run(cmd, input=text.encode("utf-8"), check=True)


if __name__ == "__main__":
    main()
