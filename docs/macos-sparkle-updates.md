# macOS Direct Download Updates

VoiceLink macOS updates use the normal Sparkle 2 pattern:

- ship one visible `VoiceLink.app` bundle;
- embed `Sparkle.framework` inside `VoiceLink.app/Contents/Frameworks`;
- sign the app with a consistent Apple code signing identity;
- publish a zip that contains exactly one top-level `.app`;
- publish an HTTPS appcast with Sparkle EdDSA signatures.

## Runtime Modes

When running from `/Applications/VoiceLink.app`, full Sparkle updates are enabled. Sparkle checks the appcast, verifies the EdDSA signature, downloads the zip, replaces the app safely, and relaunches.

When running from a mounted disk image, VoiceLink may still run and save settings in the normal user folders, but automatic replacement is disabled. The updater UI explains that the app is running from a disk image and offers a `Copy to Applications` button.

When running from another writable folder or external drive, VoiceLink runs in portable mode. Settings still use normal macOS user locations by default. Automatic self-replacement is disabled outside Applications.

## Required Release Values

- `CFBundleIdentifier`: `com.devinecreations.voicelink`
- `CFBundleExecutable`: `VoiceLink`
- `CFBundleShortVersionString`: user-facing version, for example `1.0.0`
- `CFBundleVersion`: numeric build, always increasing
- `SUFeedURL`: `https://voicelinkapp.app/downloads/voicelink/appcast.xml`
- `SUPublicEDKey`: public key matching the private Sparkle key used by `generate_appcast`

The private Sparkle EdDSA key must stay outside git and CI logs.

## Build

Use:

```bash
SPARKLE_PUBLIC_ED_KEY="..." \
SIGN_IDENTITY="Developer ID Application: ..." \
APP_VERSION="1.0.0" \
APP_BUILD="49" \
swift-native/VoiceLinkNative/scripts/macos_sparkle_release.sh
```

The script builds, bundles, embeds Sparkle, signs, zips, generates the appcast when Sparkle tools are available, and runs artifact checks.

## Verification

`swift-native/VoiceLinkNative/scripts/verify_macos_update_artifacts.sh` checks:

- bundle ID consistency;
- numeric and expected `CFBundleVersion`;
- non-empty short version;
- one executable in `Contents/MacOS`;
- HTTPS appcast URL;
- non-empty Sparkle public key;
- embedded Sparkle framework;
- code signature verification;
- zip layout with exactly one top-level `.app`;
- appcast contains an EdDSA signature and expected build when present.

Before publishing, also test a real update from build N to N+1 on Intel. Test Apple Silicon separately when available.
