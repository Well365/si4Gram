# secuTG-android · Project Constitution

This repository is a fork of the official Telegram Android client (DrKLO/Telegram) and is the Android side of secuTG. The protocol, message format, key derivation and rekey flow **follow exactly** Section 3 of the Web A repository's `<workspace>/secuTG/PLAN.md` and its "implementation conventions" notes; changing the format is not allowed. The Web A implementation (`src/secutg/`) is the behavioral reference; both sides must be able to send to and decrypt each other.

## Hard constraints

- Do not change the MTProto / tgnet protocol, do not change any interaction with the server; only add hooks at the send entry point and render entry point of text messages
- All plugin code goes under `TMessagesProj/src/main/java/org/telegram/secutg/`; every change in an upstream file must carry the comment `// SECUTG-HOOK`, and keep the change surface as small as possible
- Cryptography uses lazysodium (libsodium bindings) only: XChaCha20-Poly1305 / X25519 `crypto_box_seal` / Ed25519 `crypto_sign` / `crypto_kdf_derive_from_key` / `crypto_generichash`; do not implement any cryptographic primitive yourself
- Ciphertext `E1:<key_id>:<nonce_b64url>:<ct_b64url>`, plaintext JSON `{v,t,e}`, AAD = key_id; the signature strings and payload encoding of `R1` / `P1` follow the implementation conventions in Web A PLAN.md 3.4 / 3.5
- In **in-person pairing mode**, the group key never passes through Telegram in plaintext; the first key and the admin public key can only be entered offline via QR code.
  **In auto-pairing mode the group key is sent into the group in plaintext** (`G2`, PLAN.md 3.35, decided by the user on 2026-09-20) — the trust root of that mode is Telegram's
  member list to begin with: whoever can add someone to the group can let them read it, so it provides no confidentiality against the platform, and does not claim to. The payload is wrapped in a layer using a hard-coded shared passphrase
  (`G2Obfuscation`, PLAN.md 3.35.8): that is **obfuscation, not encryption**; the passphrase ships with the installer package, the code always calls it `obfuscate`,
  and the UI must never show "Encrypted" because of it. Private-chat keys still never travel in plaintext.
- `APP_ID` / `APP_HASH` and plugin parameters may only be read from `secutg.json`: built-in default `assets/secutg.json` < user override `filesDir/secutg.json`; assign them to `BuildVars.APP_ID/APP_HASH` in `ApplicationLoader`, before `ConnectionsManager` is initialized; the schema matches Web A (snake_case)
- `secutg.json` does not go into git; only commit `secutg.example.json`
- Keyring persistence is wrapped with Android Keystore (the master key is encrypted with an AES key held in the Keystore before being written to disk)
- Each stage gets its own branch, must compile, and comes with JUnit unit tests; `org.telegram.secutg.crypto` must not import any `org.telegram.messenger` / `org.telegram.tgnet` class
- Ciphertext that cannot be decrypted is displayed as-is with a lock badge; under no circumstances crash or swallow messages

## How to work

- Before changing anything, list the plan and the affected files, and get confirmation before changing
- When unsure of the source structure, read the source first and then change it; do not guess file names from memory
- Each render path you add is its own commit, and the commit message states where it was hooked
- After finishing a stage, output: which files were changed, how to verify, and known uncovered items
- Always verify with `./gradlew … --rerun-tasks` (leaving it out gives false greens); if a macOS `.DS_Store` breaks the build, first read
  [docs/secutg/build-dsstore.md](docs/secutg/build-dsstore.md); the root `build.gradle` already has a guard, do not move files by hand again
- Respond in Chinese

## Directories

```
TMessagesProj/src/main/java/org/telegram/secutg/
├── config/    # secutg.json loading
├── crypto/    # encrypt / decrypt / isEncrypted (pure Java, no Android dependencies)
├── keyring/   # store/fetch by key_id, per-day derivation, Keystore persistence
├── rekey/     # R1 / P1 generation, parsing, signature verification, in-order catch-up
├── hooks/     # send hook, render hook wiring
└── ui/        # encryption toggle, rekey button, QR code
```
