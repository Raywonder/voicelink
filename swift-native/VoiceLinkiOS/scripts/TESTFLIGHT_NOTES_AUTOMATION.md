# TestFlight Notes Automation

This automation updates the App Store Connect TestFlight "What to Test" text after a build upload.

Why this exists:
- `xcrun iTMSTransporter` uploads the binary.
- It does not update the TestFlight build localization notes by itself.
- `TestFlight/WhatToTest.en-US.txt` must be pushed separately through the App Store Connect API for manual upload flows.

## Required environment

Set:

```bash
export ASC_KEY_ID="YOUR_KEY_ID"
export ASC_ISSUER_ID="YOUR_ISSUER_ID"
export ASC_PRIVATE_KEY_PATH="/absolute/path/to/AuthKey_XXXX.p8"
```

Optional:

```bash
export ASC_APP_BUNDLE_ID="com.devinecreations.voicelink"
export ASC_LOCALE="en-US"
export ASC_WAIT_ATTEMPTS="30"
export ASC_WAIT_SECONDS="20"
```

## Run

From `swift-native/VoiceLinkiOS`:

```bash
./scripts/update_testflight_notes.sh --version 1.0.0 --build-number 27
```

The script will:
1. Generate an App Store Connect JWT with the API key.
2. Look up the app by bundle ID.
3. Wait for the uploaded build to appear in App Store Connect.
4. Create or update the `betaBuildLocalization` for `en-US`.
5. Push the contents of `TestFlight/WhatToTest.en-US.txt` into TestFlight.

## Notes

- If you omit `--version` or `--build-number`, the script falls back to values in `VoiceLinkiOS.xcodeproj/project.pbxproj`.
- This is intended to be run after `xcrun iTMSTransporter` or Xcode upload completes.
- If App Store Connect API access has not been requested/enabled yet, Apple will reject the API authentication step.
