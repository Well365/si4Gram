# secuTG-desktop · Project Constitution

This repository is a fork of Telegram Desktop (telegramdesktop/tdesktop, C++/Qt) and is the Windows side of secuTG; the same code also produces the Linux and macOS desktop builds. The protocol, message format, key derivation and rekey flow **follow exactly** Section 3 of the Web A repository's `<workspace>/secuTG/PLAN.md` and its "implementation conventions" notes; changing the format is not allowed. Web A (`src/secutg/`), Android (`secutg-core`) and iOS/macOS (`SecutgCore`) are the behavioral references; all sides must be able to send to and decrypt each other, and the vector files `Telegram/SourceFiles/secutg/tests/vectors/*.json` are identical to those of the other sides.

## Hard constraints

- Do not change MTProto / `Telegram/SourceFiles/mtproto`, do not change any interaction with the server; only add hooks at the send entry point and render entry point of text messages
- Plugin code goes in `Telegram/SourceFiles/secutg/` (`config/ crypto/ keyring/ rekey/ hooks/ ui/`); `crypto/` depends only on libsodium and the standard library and does not include any `history/`, `data/`, `mtproto/` header; every change in an upstream file must carry the comment `// SECUTG-HOOK`, and keep the change surface as small as possible
- Cryptography uses libsodium only (`third_party/libsodium`; Windows uses the official MSVC prebuilt static library, Linux/macOS use the system library or a source build): XChaCha20-Poly1305 / X25519 `crypto_box_seal` / Ed25519 `crypto_sign` / `crypto_kdf_derive_from_key` / `crypto_generichash`; do not implement any primitive yourself
- Ciphertext `E1:<key_id>:<nonce_b64url>:<ct_b64url>`, plaintext JSON `{v,t,e}`, AAD = key_id; `R1` / `P1` follow the implementation conventions in PLAN.md 3.4 / 3.5
- In **in-person pairing mode**, the group key never passes through Telegram in plaintext; the first key and the admin public key can only be entered offline via QR code / paste.
  **In auto-pairing mode the group key is sent into the group in plaintext** (`G2`, PLAN.md 3.35, decided by the user on 2026-09-20) — the trust root of that mode is Telegram's
  member list to begin with: whoever can add someone to the group can let them read it, so it provides no confidentiality against the platform, and does not claim to. The payload is wrapped in a layer using a hard-coded shared passphrase
  (`G2Obfuscation`, PLAN.md 3.35.8): that is **obfuscation, not encryption**; the passphrase ships with the installer package, the code always calls it `obfuscate`,
  and the UI must never show "Encrypted" because of it. Private-chat keys still never travel in plaintext.
- `api_id` / `api_hash` and plugin parameters may only be read from `secutg.json`: built-in default `secutg.json` in the executable's directory or the working directory < override `secutg.json` in the user data directory (next to `tdata`) < environment variables; parse before the MTP instance is created; the compile-time `TDESKTOP_API_ID/HASH` is only the last fallback; the schema matches the other sides (snake_case)
- `secutg.json` does not go into git; only commit `secutg.example.json`
- Keyring persistence: the JSON snapshot is wrapped with a local machine key (Windows DPAPI / macOS Keychain / Linux libsecret, degrading to file permission 600) and then written to `secutg/keyring.bin` in the user data directory
- Each stage gets its own branch, must compile, and comes with unit tests (Catch2 or tdesktop's built-in test framework, against the shared vectors); ciphertext that cannot be decrypted is displayed as-is with a lock badge; under no circumstances crash or swallow messages

## How to work

- Before changing anything, list the plan and the affected files, and get confirmation before changing
- When unsure of the source structure, read the source first and then change it; hook locations are as defined in `docs/secutg/stage1-hook-recon.md`
- Each render path you add is its own commit, and the commit message states where it was hooked
- After finishing a stage, output: which files were changed, how to verify, and known uncovered items
- Respond in Chinese
- Windows builds are done on a remote machine (see `docs/secutg/build-windows.md`); this machine only does reconnaissance and coding

## Directories

```
Telegram/SourceFiles/secutg/
├── config/    # secutg.json loading
├── crypto/    # E1 encode/decode (pure C++ + libsodium)
├── keyring/   # derivation, keyring, local-machine-wrapped persistence
├── rekey/     # R1 / P1 generation, parsing, signature verification, in-order catch-up
├── hooks/     # send hook, render hook wiring
└── ui/        # floating lock button, menu, QR code
docs/secutg/   # recon tables, build instructions, stage status
```
