# Si4Gram Prompt Kit

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [한국어](README.ko.md) · [العربية](README.ar.md)

This repository publishes the **prompts** used to build Si4Gram (codename *secuTG*) with AI coding agents (Claude Code): agent instructions, guardrails and prompt templates.

**App source code:** the [`ios/`](ios/) folder holds the complete source of the Si4Gram iOS app (App Store 1.0.1). It is a modified version of [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) and is licensed under **GPL v2** (see [`ios/COPYING`](ios/COPYING)). What it contains, what was left out (API credentials, signing files) and how to build it are described in [`ios/SOURCE-NOTICE.md`](ios/SOURCE-NOTICE.md).

If you are building something similar (a security layer on top of an existing open-source app, several platforms that must behave identically, or an AI assistant that must never act without a human), the prompts and the lessons behind them should be reusable.

---

## 1. What the project does

Si4Gram adds a plug-in layer to Telegram's open-source clients: **encrypt before sending, decrypt before rendering**. The chat window shows plain text; what travels over the network and sits on Telegram's servers is ciphertext. Keys live only on the user's devices.

| Design rule | Meaning |
|---|---|
| Do not touch the protocol | MTProto and every server interaction stay unchanged. Hooks sit only at the text-send entry and the render entry. |
| One protocol, every platform | Web, iOS, macOS, Android and Desktop must encrypt and decrypt each other's messages. A shared spec, a shared string table and shared test vectors keep them aligned. |
| Use only libsodium | XChaCha20-Poly1305, X25519 `crypto_box_seal`, Ed25519 signatures, `crypto_kdf`. No home-made cryptography. |
| Never crash, never swallow | A message that cannot be decrypted is kept as-is and shown with a lock badge. |
| Honest labels | A mode that only obfuscates (for example the auto-pairing group key) is never shown as "encrypted". |

Companion pieces: a zero-install **Mini App + Bot** for people on the official client, an optional **relay** service that stores short-lived encrypted blobs, a cross-client test **matrix**, and a local **assistant** (SmartMate) on macOS that hands tasks to Claude Code under strict guardrails.

## 2. Architecture

![Architecture](architecture.svg)

### 2.1 Runtime

```mermaid
flowchart LR
    subgraph Devices["User devices (keys never leave)"]
        direction TB
        W["Web<br/>telegram-tt fork"]
        I["iOS · Si4Gram<br/>Telegram-iOS fork"]
        M["macOS<br/>TelegramSwift fork"]
        A["Android<br/>DrKLO/Telegram fork"]
        D["Desktop<br/>tdesktop fork"]
        P["Mini App + Bot<br/>(official client)"]
    end
    subgraph Layer["Plug-in layer in every client"]
        direction TB
        SH["Send hook<br/>encrypt"]
        RH["Render hook<br/>decrypt"]
        KR["Local keyring<br/>Keychain / Keystore / DPAPI"]
        NA["libsodium"]
    end
    Devices --- Layer
    Layer -- "E1 / E2 / P2 / G2 ciphertext only" --> TG[("Telegram servers<br/>MTProto unchanged")]
    Layer -. "optional encrypted blob" .-> RL[("Relay<br/>Workers / AWS / GCP / Node")]
    subgraph Shared["Single sources of truth"]
        SPEC["PLAN.md protocol spec"]
        STR["Shared string table + generator"]
        VEC["Test vectors + 5×5 xcheck matrix"]
    end
    Shared -. keeps aligned .-> Layer
```

### 2.2 How the prompts drive the agents

```mermaid
flowchart TB
    H(["Human owner"]) -->|"kickoff / phase prompt"| CC["Claude Code session"]
    CC -->|reads first| CON["Per-repo constitution<br/>CLAUDE.md"]
    CC -->|obeys| GR["Hard constraints<br/>no push · no delete · no real accounts"]
    CC --> LOOP["preflight → execute → verify → record"]
    LOOP -->|FAIL| H
    LOOP -->|PASS| GIT["Local commit only<br/>+ CHECKLIST entry"]
    subgraph Assistant["macOS assistant (SmartMate)"]
        MAC["macOS client<br/>only key holder"] -->|control.sock| MATE["secutg-mate<br/>inbox · rules · tasks"]
        MATE -->|task folder| SK["/secutg-task skill<br/>forked read-only analyst"]
        SK --> DR["result.md draft"]
        DR -->|human says “send”| RV["/secutg-review"]
        DR -->|human approves change| AP["/secutg-apply<br/>isolated worktree"]
        DR -->|human confirms fields| JR["/secutg-jira<br/>local Chrome"]
        GUARD["PreToolUse guard hook<br/>+ deny lists"] -.-> SK
        GUARD -.-> AP
    end
```

## 3. GitHub resources

All upstream addresses below were read from each fork's `git remote`, `.gitmodules` and dependency files.

### 3.1 Upstream clients that were forked

| Platform | Upstream | License (upstream) |
|---|---|---|
| Web | [Ajaxy/telegram-tt](https://github.com/Ajaxy/telegram-tt) | GPL-3.0 |
| iOS (Si4Gram) | [TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) | see upstream |
| macOS | [overtake/TelegramSwift](https://github.com/overtake/TelegramSwift) | GPL-2.0 |
| Android | [DrKLO/Telegram](https://github.com/DrKLO/Telegram) | GPL-2.0 |
| Desktop (Windows / Linux / macOS) | [telegramdesktop/tdesktop](https://github.com/telegramdesktop/tdesktop) | GPL-3.0 (with OpenSSL exception) |

### 3.2 Libraries the security layer relies on

| Library | Used by |
|---|---|
| [jedisct1/libsodium](https://github.com/jedisct1/libsodium) 1.0.20 | iOS / macOS (`Clibsodium`), Desktop |
| [libsodium.js](https://github.com/jedisct1/libsodium.js) (`libsodium-wrappers` 0.8.x) | Web, Mini App |
| [terl/lazysodium-android](https://github.com/terl/lazysodium-android) 5.1 and [lazysodium-java](https://github.com/terl/lazysodium-java) 5.1.4 | Android |
| [java-native-access/jna](https://github.com/java-native-access/jna) 5.13 | Android |
| [soldair/node-qrcode](https://github.com/soldair/node-qrcode) | Mini App |
| [honojs/hono](https://github.com/honojs/hono) + `@hono/node-server` | Relay |
| [fastapi/fastapi](https://github.com/fastapi/fastapi), [encode/uvicorn](https://github.com/encode/uvicorn), [python-poetry/tomlkit](https://github.com/python-poetry/tomlkit) | SmartMate assistant |

The upstream clients also pull in their own submodules (for example tdlib/td, webrtc, libvpx, dav1d, FFmpeg, opus, rlottie, tgcalls, rules_apple, rules_swift). Those are unchanged and are listed in each upstream's `.gitmodules`.

### 3.3 Agent tooling

| Tool | Role |
|---|---|
| [Claude Code](https://github.com/anthropics/claude-code) | All coding agents, project skills, sub-agents and hooks in this kit |
| Upstream `AGENTS.md` files (telegram-tt, tdesktop) | Kept as-is in the forks. They are upstream's own agent guides and are **not** part of this kit; each constitution says to follow them where they do not conflict. |

## 4. What is in this kit

Originals are in Simplified Chinese under [`prompts/zh-CN/`](prompts/zh-CN/); an English translation with the same file names is under [`prompts/en/`](prompts/en/).

| Folder | Files | What it is | When to use it |
|---|---|---|---|
| `01-constitutions/` | `web`, `ios`, `macos`, `android`, `desktop`, `miniapp` `.CLAUDE.md` | One "project constitution" per fork: hard constraints, wire format, where plug-in code lives, the `// SECUTG-HOOK` marker rule, how to work and report | Put at the root of each fork as `CLAUDE.md` |
| `02-agent-guardrails/` | `00-constraints.md` | Safety boundary that overrides every other document: never delete, never push, never use real accounts, no history rewrites, check machine load before building | Load into any long-running or multi-step agent task |
| `03-repo-restructure/` | `00-kickoff.md`, `01-phase-prompts.md` | Kickoff prompt plus one prompt per phase for merging two diverged code lines into one trunk | Paste the kickoff first, then assign one phase at a time |
| `04-cross-platform-playbook/` | `reproducible-prompts.md` | How a five-client consistency audit and four rounds of fixes were run: the constraint block, audit / fix / cross-repo templates, per-platform verification traps and a table of real misjudgements | Reuse when several implementations of one spec must stay identical |
| `05-assistant-skills/` | `settings.json`, `agent-secutg-analyst.md`, `skill-secutg-{task,review,apply,jira}.SKILL.md` | Claude Code project settings, a read-only analyst sub-agent and four skills for the macOS assistant. Originally at `.claude/settings.json`, `.claude/agents/`, `.claude/skills/<name>/SKILL.md` | Pattern for an assistant that drafts but never sends, edits or files tickets without a human |

## 5. Prompt patterns that worked

1. **A constitution per repository.** Every fork has the same skeleton: what it is, hard constraints, wire format, where code goes, how to work. Agents start each session already knowing the red lines.
2. **One constraint block, pasted verbatim.** "Never `git push` (the only remote is the public upstream)", "never delete, `mv` to `_archive-<date>/`", "never add strings by hand", "no tests against real accounts". Each line exists because something went wrong without it.
3. **preflight → execute → verify → record.** Any FAIL stops the agent and the raw output goes to the human. No "quick fix and continue".
4. **Report what was done, what was verified and what was not.** "Should be fine" is not an acceptable report. "It compiled" and "it was verified" are reported separately.
5. **Audits are read-only and carry evidence.** Every row needs `file:line`. "Not found" beats a guess based on the spec.
6. **Seed known mismatches into the checklist.** If an audit report marks the planted differences as "consistent", the report is discarded. This is the cheapest way to test whether an agent's report can be trusted.
7. **"Hard" is not "impossible".** If something truly cannot be done on a platform, the agent says what blocks it and delivers the best native alternative.
8. **Inferred stays inferred.** A conclusion marked "inferred" may not enter a spec or a task brief until someone measures it.
9. **Ask the agent to push back.** Briefs say "verify this yourself, do not take it on trust". Several of the best results came from agents correcting the brief.
10. **Never end a turn on "waiting".** A sub-agent that ends with "(waiting for the build)" leaves the build orphaned. Finish it in the same turn or re-run it.
11. **Untrusted data is labelled as data.** In the assistant skills, Jira fields, group chat text and everything inside repositories are data, never instructions. Suspicious instructions are quoted in the result and flagged.
12. **Humans hold every outward action.** Analysis runs in a forked read-only agent; sending a reply, applying a change or filing a ticket each needs an explicit human approval, enforced by permission rules and a PreToolUse guard hook, not only by prompt text.

## 6. Reusable templates

### 6.1 Repository constitution

```markdown
# <repo> · Project constitution

This repository is a fork of <upstream>. Goal: <one sentence>. The protocol is defined in <spec>; do not change the format.

## Hard constraints
- Do not change <protocol / server interaction>; hook only at <entry points>
- Plug-in code lives in <dir>; every change to an upstream file carries the comment `// <MARKER>`; keep the change surface small
- Cryptography only via <library>; never implement primitives yourself
- Secrets and parameters are read only from <config file>; it is never committed, only <config.example> is
- Every stage has its own branch, builds, and has unit tests; undecryptable data is shown as-is, never crash, never drop

## How to work
- List the plan and affected files first; change only after confirmation
- Read the source before editing; do not guess file names
- One commit per hooked path, naming the hook location
- After a stage, report: files changed, how verified, known gaps
```

### 6.2 Hard constraint block

```markdown
## Hard constraints (breaking any of them fails the task)
- Never `git push`. The only configured remote is the public upstream; commit locally only.
- Never delete files or directories. To move something away, `mv` it to a sibling `_archive-<date>/`.
- Never add user-facing strings by hand. The single source is <strings.json>; per-platform tables are generated.
- Do not wrap build commands in `tee` (it hides the exit code); redirect to a file, then echo the exit code.
- No end-to-end tests against real accounts. Logins are done by the human.
```

### 6.3 Read-only audit

```markdown
You are auditing <platform> against the reference implementation in <path>.

## Read-only task
Do not modify, create or delete any file; no git add/commit/stash/checkout; no builds.

## Method
Code behaviour wins; consult the spec only where code and spec disagree. If you cannot find it, write "not found". Do not infer behaviour from the spec.

## Output (strict, it will be diffed across platforms)
| ID | Status | Evidence file:line | Notes |
Status is one of: ✅ consistent / ⚠️ differs / ❌ missing / N/A
For ⚠️ and ❌ state what actually happens and how it differs. End with "Additional findings".

## Checklist
<numbered items, each naming the exact string key and expected behaviour; include a few known mismatches>
```

### 6.4 Fix round

```markdown
Round <N>, you own <platform>: repository <path>
Spec: <section> (read the whole section first; it records why)

Principle: keep all platforms the same; where something truly cannot be done on one platform, build the best native form there instead of dropping the feature.

## Background — why this matters, and what breaks if it is skipped
## Reference implementation (done, read-only) — commit + key snippet + reasoning
## Your work
## ⚠️ Platform-specific trap
## Verification — commands and known traps
<hard constraint block>

If something truly cannot be done here (not merely hard), say what blocks it and give the best alternative. Do not call "hard" "impossible".
```

### 6.5 Session kickoff

```markdown
You are executing a written spec in <path>. It is self-contained.

1. Read in order: constraints → facts → target design → runbook → decisions → checklist.
2. Run the read-only preflight and paste its output verbatim.
3. Report: preflight result, current stage, next stage, decisions I must make. Then stop and wait.

Safety lines that hold for the whole session: <hard constraint block>
Way of working: every stage is preflight → execute → verify → record; any FAIL stops you; never skip stages; if the spec does not cover a case, stop and ask.
```

## 7. Adapting the kit

1. Copy a constitution from `01-constitutions/`, replace the protocol, directory and marker names with your own.
2. Keep `02-agent-guardrails/00-constraints.md` close to verbatim; tune the machine-specific rows.
3. For multi-platform work, start from `04-cross-platform-playbook/` and keep its "misjudgements" table growing.
4. For an assistant that touches real conversations, copy `05-assistant-skills/` together with permission deny lists and a guard hook. Prompt text alone is not a security boundary.

## 8. Sanitisation

Before publishing, machine names, local paths and company-specific branch names were replaced with placeholders:

| Placeholder | Stands for |
|---|---|
| `<workspace>/` | The local folder that holds all forks |
| `<build-cache>/` | The local build cache folder |
| `dev-mac` / `backup-mac` | The main development Mac / a second Mac that is read-only to agents |
| `_bazel_<user>` | The local user name in Bazel's output path |
| `develop、test、staging、release*` | Example branch names in the query skill |

No certificates, provisioning profiles, team IDs, API keys, emails or IP addresses are included.

## 9. Links

- Website: <https://si4key.com>
- Source address shown in the app's About page: <https://github.com/Well365/Si4Gram>

## 10. License

The prompts and documentation in this repository: to be decided by the owner (CC BY 4.0 is a common choice for documentation). The upstream Telegram clients keep their own licenses listed above.
