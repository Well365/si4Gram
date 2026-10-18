# secuTG · Project Constitution

This project is a fork of an open-source Telegram client (starting side: telegram-tt / Web A). Goal: add an "encrypt before sending, decrypt before displaying" plugin layer inside the client, so the chat window is all plaintext and everything on the wire is ciphertext. The detailed plan is in `PLAN.md`; the protocol and data formats are as defined in Section 3 of `PLAN.md`, and the formats must not be changed without authorization.

## Hard constraints

- Do not change the MTProto protocol, do not change any interaction with the server; only add hooks at the send entry point and render entry point of text messages
- All plugin code goes under `src/secutg/`; every change in an upstream file must carry the comment `// SECUTG-HOOK`, and keep the change surface as small as possible
- Cryptography uses libsodium only (web: `libsodium-wrappers`): XChaCha20-Poly1305 / X25519 `crypto_box_seal` / Ed25519 `crypto_sign` / `crypto_kdf_derive_from_key`; do not implement any cryptographic primitive yourself
- Ciphertext format `E1:<key_id>:<nonce_b64url>:<ct_b64url>`, plaintext JSON `{v, t, e}`, AAD = key_id
- Rekey message `R1:<type>:<new_key_id>:<payload>:<sig>`, public key registration `P1:...`, see `PLAN.md` 3.4 / 3.5
- In **in-person pairing mode**, the group key (master_key) never passes through Telegram in plaintext; the first key and the admin public key can only be entered offline via QR code.
  **In auto-pairing mode the group key is sent into the group in plaintext** (`G2`, PLAN.md 3.35, decided by the user on 2026-09-20) — the trust root of that mode is Telegram's
  member list to begin with: whoever can add someone to the group can let them read it, so it provides no confidentiality against the platform, and does not claim to. Private-chat keys still never travel in plaintext.
- `api_id` / `api_hash` and all plugin parameters may only be read from `secutg.json`; hard-coding is forbidden; load order: environment variables > user override file > bundled built-in default; the schema must be identical on all sides
- `secutg.json` does not go into git; only commit `secutg.example.json`
- Each stage gets its own branch, must compile, and comes with unit tests (vitest); `src/secutg/crypto/` must not import any telegram-tt internal module
- Ciphertext that cannot be decrypted is displayed as-is with a lock badge; under no circumstances crash or swallow messages

## How to work

- Before changing anything, list the plan and the affected files, and get confirmation before changing
- When unsure of the telegram-tt source structure, read the source first and then change it; do not guess file names from memory
- Each render path you add is its own commit, and the commit message states where it was hooked
- After finishing a stage, output: which files were changed, how to verify, and known uncovered items
- Respond in Chinese

## Common commands

```bash
npm install
npm run dev          # local development
npm run test         # vitest
git fetch upstream && git merge upstream/master   # sync with upstream
```

## Directories

```
src/secutg/
├── config/    # secutg.json loading
├── crypto/    # encrypt / decrypt / isEncrypted (pure functions)
├── keyring/   # store/fetch by key_id, per-day derivation, IndexedDB persistence
├── rekey/     # R1 / P1 generation, parsing, signature verification, in-order catch-up
├── hooks/     # send hook, render hook wiring
└── ui/        # encryption toggle, rekey button, QR code
```

## Upstream code style

Upstream telegram-tt's code style, Teact/SCSS conventions and API generation workflow are in `AGENTS.md`; where it conflicts with this file, this file takes precedence.
