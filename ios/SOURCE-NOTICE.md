# Si4Gram for iOS — corresponding source

This directory is the complete source of the Si4Gram iOS app as built for the App Store
(version 1.0.1), provided under the GNU General Public License, version 2 (see `COPYING`).

Si4Gram is a modified version of Telegram for iOS
(https://github.com/TelegramMessenger/Telegram-iOS), which is licensed under GPL v2.
Si4Gram is not affiliated with or endorsed by Telegram.
The Si4Gram changes (the `Secutg*` modules, `submodules/SecutgCore`, and the hooks marked
`SECUTG-HOOK` in upstream files) are © 2026 Si4Key and are released under the same license.

## What is not included

- Telegram API credentials. `build-system/secutg-appstore-configuration.json` contains
  placeholders; get your own `api_id` / `api_hash` at https://my.telegram.org/apps.
- `Telegram/Telegram-iOS/secutg.json` (runtime config). Copy `secutg.example.json` to that path.
- Signing certificates and provisioning profiles.
- Git submodules (rules_apple, rules_swift, tgcalls, webrtc, td, …) are referenced by
  `.gitmodules` at the same revisions as upstream Telegram-iOS and are unmodified.

## Building

Follow `README.md` (the upstream guide). The App Store build uses:

```
python3 build-system/Make/Make.py build \
  --configurationPath=build-system/secutg-appstore-configuration.json \
  --codesigningInformationPath=<your signing directory> \
  --configuration=release_arm64 --buildNumber=<n> --secutgStoreBuild
```

Requires Xcode 27 with the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
