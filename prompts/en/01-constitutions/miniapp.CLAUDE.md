# secuTG-miniapp · Project Constitution

This is secuTG's "zero-install" entry point: a Mini App running inside the **official Telegram client** plus a Bot that only relays. It is for people who have not installed a secuTG fork client: they manually encrypt text and send it via inline mode, and paste received ciphertext to decrypt it. The protocol, message format, key derivation and rekey flow **follow exactly** Section 3 of the Web A repository's `<workspace>/secuTG/PLAN.md`; `web/src/secutg/` is a pure module (crypto / keyring / rekey / config) copied verbatim from Web A's `src/secutg/`; changing the format is not allowed; when upgrading, re-copy the whole directory.

## Hard constraints

- Plaintext exists only in the WebView on the user's device; the Bot only receives and echoes inline queries that are already ciphertext (E1 / R1 / P1), and plaintext must never be sent to the Bot or any server
- The keyring is stored in the WebView's IndexedDB (the `secutg-miniapp` database); using Telegram CloudStorage or any cloud sync for master keys is **forbidden**
- Cryptography uses libsodium only (`libsodium-wrappers`); do not implement any primitive yourself
- The Mini App has no chat context, so keys are managed by user-defined labels; decryption looks up the key_id across all known master keys, regardless of label
- `BOT_TOKEN` and `WEBAPP_URL` are read only from environment variables; only commit `.env.example`
- The tests and vectors of `web/src/secutg/` (`web/tests/vectors`) must keep passing; this is the evidence of interoperability with the other sides

## Directories

```
web/            # Vite + TypeScript Mini App (index.html, src/main.ts, src/app/*, src/secutg/* copied from Web A)
bot/            # Node 20+ long-polling Bot (index.mjs), no framework, no database
docs/           # deployment and usage instructions
```

## Common commands

```bash
cd web && npm install && npm test && npm run build     # output in web/dist, any static HTTPS hosting
cd bot && BOT_TOKEN=… WEBAPP_URL=… node index.mjs
```
