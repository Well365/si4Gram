# secuTG-macos · Project Constitution

This repository is a fork of the official Telegram macOS client (overtake/TelegramSwift) and is the macOS side of secuTG. It reuses Telegram-iOS's `TelegramCore` / `Postbox` through the submodule `submodules/telegram-ios`; secuTG points that submodule at the iOS-side fork `<workspace>/secuTG-ios`, therefore **the receive hook, the protocol core (`SecutgCore`) and the runtime (`SecutgRuntime`) all come from the iOS fork, and this repository only does the send hook, the render hook and the macOS UI**. The protocol, message format, key derivation and rekey flow follow exactly Section 3 of the Web A repository's `<workspace>/secuTG/PLAN.md`; changing the format is not allowed.

## Hard constraints

- Do not change MTProto, do not change any interaction with the server; only add hooks at the send entry point and render entry point of text messages
- This repository's plugin code goes in `Telegram-Mac/Secutg/`; every change in an upstream file must carry the comment `// SECUTG-HOOK`, and keep the change surface as small as possible
- Cryptography uses libsodium only (via `SecutgCore`'s `Clibsodium`); do not implement any cryptographic primitive yourself
- `api_id` / `api_hash` and plugin parameters may only be read from `secutg.json`: built-in default bundled resource < user override `~/Library/Application Support/secutg.json` < environment variables; the hard-coded values in `packages/ApiCredentials` are changed to read from `SecutgCore.SecutgConfigLoader`; `secutg.json` does not go into git, only commit `secutg.example.json`
- The keyring is persisted with `SecutgRuntime`'s Keychain wrapper, in the same format as iOS
- Each stage gets its own branch and must compile; under no circumstances crash or swallow messages
- Ciphertext that cannot be decrypted is **kept as-is in the storage layer** (this is PLAN.md 3.17 item 2: not a single byte of the ciphertext is touched, so it can be decrypted later once the key is obtained); the render layer does not display that base64 string, and instead shows a one-line explanation (no key / have a key but cannot open it / keyring not ready)
- **For chats with encryption enabled, what is written to disk is always `E1:` ciphertext; plaintext exists only in memory** (PLAN.md 3.19, toggle on by default): both entry points into the database are replaced — `transformIncoming` for received messages and `enqueueMessages` for sent messages; when read back, it is decrypted at the render exit (`ChatMessageItem` / `TextUtils.pullText`), and cached per session in `LocalCiphertext.PlaintextCache`. The cost is that database search no longer works for these chats, which is explicitly accepted. Ordinary chats are completely unchanged. The toggle only affects messages stored from then on; plaintext already stored is not batch-rewritten

## How to work

- Before changing anything, list the plan and the affected files, and get confirmation before changing
- When unsure of the source structure, read the source first and then change it; hook locations are as defined in `docs/secutg/stage1-hook-recon.md`
- Each render path you add is its own commit, and the commit message states where it was hooked
- After finishing a stage, output: which files were changed, how to verify, and known uncovered items
- Respond in Chinese

## Directories

```
Telegram-Mac/Secutg/              # send hook wiring, render hook wiring, menu, rekey panel, QR code, plaintext warning bar
submodules/telegram-ios/          # → secuTG-ios fork (SecutgCore / SecutgRuntime / TelegramCore receive hook)
docs/secutg/                      # recon tables, stage status
```
