# Si4Gram for iOS — corresponding source

This directory is the complete source of the Si4Gram iOS app as built for the App Store
(version 1.0.1), provided under the GNU General Public License, version 2 (see `COPYING`).

Si4Gram is a modified version of Telegram for iOS
(https://github.com/TelegramMessenger/Telegram-iOS), which is licensed under GPL v2.
Si4Gram is not affiliated with or endorsed by Telegram.
The Si4Gram changes (the `Secutg*` modules, `submodules/SecutgCore`, and the hooks marked
`SECUTG-HOOK` in upstream files) are © 2026 Si4Key and are released under the same license.

## Upstream base

| | |
|---|---|
| Upstream repository | https://github.com/TelegramMessenger/Telegram-iOS |
| Branch | `master` |
| Base commit | `6ad963e5b62d354da79040f388ae2b9132fb17b8` (2026-07-18, "Merge branch 'master' into beta") |
| Si4Gram changes on top | 366 commits, 809 files, +86,019 / −944 lines (history not published; this is a snapshot) |
| Snapshot of | Si4Gram `si4gram-appstore` at `966672c0` |

To see every Si4Gram change, check out the base commit of upstream and compare it with this directory:

```
git clone https://github.com/TelegramMessenger/Telegram-iOS.git upstream
git -C upstream checkout 6ad963e5b62d354da79040f388ae2b9132fb17b8
diff -ruN upstream ios    # or copy ios/ over the checkout and run `git -C upstream diff --stat`
```

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
