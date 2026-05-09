# VoiceLink IVR Prompt Script

This prompt set is the canonical recording script for:

- VoiceLink mini IVR call flows
- FlexPBX / Asterisk OTP voice verification calls
- Main PBX IVR fallback when a call is escalated from VoiceLink

## Recording Notes

- Record a clean master first.
- Best master format: `48 kHz`, `24-bit`, mono.
- Export telephony copies later for PBX use:
  - `16 kHz` mono WAV
  - `8 kHz` mono WAV if an older trunk or IVR path needs it
- Keep pacing calm and direct.
- Leave a short pause before and after each read.
- Digits should be recorded as isolated files so OTP codes can be assembled dynamically.

## Delivery Style

- Friendly, short, and neutral
- Clear digit pronunciation
- No long marketing phrasing
- Suitable for repeated verification calls

## Prompt Families

- Core greeting and explanation
- OTP delivery and repeat prompts
- Personalized name prompts
- Waiting loop, acceptance, and expiry prompts
- Wrong-person suppression and support prompts
- Digits `0` through `9`
- Error and retry prompts
- Completion and goodbye prompts

## Dynamic Voice Rules

- Recorded prompts are preferred whenever available.
- Piper voices are the default fallback for:
  - dynamic caller-name announcement
  - mini IVR prompts
  - server-side bot speech in rooms
- Do not fall back to eSpeak.
- An uploaded cloned voice may be selected in admin settings and used for:
  - personalized verification calls
  - menu trees
  - VoiceLink room bots such as Sapphire and Sophia
- A user may optionally upload a recorded name clip; admin settings may prefer:
  - recorded name first
  - cloned voice first
  - random choice when both exist

See [prompt-manifest.json](./prompt-manifest.json) for the exact filenames and script lines.
