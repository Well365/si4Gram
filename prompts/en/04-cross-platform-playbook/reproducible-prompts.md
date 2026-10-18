# secuTG Reproducible Prompts

> This document records **how to do it again**: the prompt structure used for the five-client consistency audit and remediation, each client's verification commands and pitfalls,
> and the misjudgements we ran into. It is written for whoever takes over next (or the next agent).
>
> Compiled 2026-09-18, based on one complete audit finished that day + four remediation batches (219 commits across the five clients, 5×5 cross-client matrix with all 2300 cases passing).

---

## 0. General principle

**The one-sentence principle** (set by the user, applies to every task):

> Make the five clients as uniform as possible; if an approach genuinely cannot be implemented on one client, build **the form with the best experience for that platform** on that client,
> rather than leaving a piece of functionality out.

A matching line of defence that must be written into every task:

> **Do not call "hard" "impossible".** If you judge that something genuinely cannot be done, state honestly **what is blocking it**,
> and give the best alternative form for that platform.

Without this line, "platform differences" become an exit for laziness.

---

## 1. Hard-constraints block (paste into every agent task)

Copy this section in verbatim. Every time one of these was missing, something went wrong.

```
## Hard constraints (violating any one of them counts as task failure)
- **Never `git push`**. The only remote configured in these repositories is the official public upstream
  (TelegramMessenger/Telegram-iOS, overtake/TelegramSwift, Ajaxy/telegram-tt,
  DrKLO/Telegram, telegramdesktop/tdesktop); make local commits only.
- **Never delete any file or directory**. `rm` is blocked by a local hook. To move something out of the way, `mv` it into a sibling `_archive-<date>/`.
- **Never add new strings**. The single source of copy is `secuTG/src/secutg/i18n/secutg-strings.json`;
  every client's table is a generated artifact and is never edited by hand. If you truly need a new string, stop and report it, and go through
  `tools/gen-secutg-strings.py` to sync all five clients.
- The shell command line containing `git commit` **must not also contain** `-n` / `-not` / `grep -n`
  (the local hook misreads them as `--no-verify`). Use `git commit -F -` with a heredoc, as a **separate** call.
- **Do not wrap build commands in `tee`** (it swallows the exit code); redirect to a file, then `echo "EXIT=$?"`.
- Do no integration testing against real Telegram accounts. Wipe features are destructive by design; logging in is the user's own business.
```

### Per-client "never commit" lists

| Client | Never commit |
|---|---|
| Web | `vite.config.ts` (local port changes) |
| Android | `TMessagesProj_AppStandalone/build.gradle` (abiFilters) |
| iOS | `bazel-secuTG-ios` (symlink), `MODULE.bazel.lock` |
| macOS | `Package.resolved`, `Telegram-Mac/Info.plist`, `TelegramShare/Info.plist` |
| All | Any `secutg.json` / `secutg.json.bak-*` |

### Branches

All further work in the five client repositories happens on **`security-tg-branch`**.
Exception: `secuTG-macos/submodules/telegram-ios` is a different repository and stays on the **`secutg-mac`** branch.

---

## 2. Per-client verification commands and pitfalls

**Every one of these pitfalls actually happened.**

### Web — `<workspace>/secuTG`

```bash
source ~/.nvm/nvm.sh && nvm use 24     # the default shell's node is v15 and fails outright
npx tsc --noEmit -p tsconfig.json
npx vitest run src/secutg
```

- **Never run `npm run build`.**
- `src/secutg/hooks/hooks.test.ts` reports **4** unhandled errors coming from `src/util/schedulers.ts`;
  **these are pre-existing**, not newly introduced. Before judging, stash your changes and reproduce the baseline once.
- To see the rendering: `npm run dev:mocked` goes straight into a logged-in state (`IS_MOCKED_CLIENT`);
  **there is no need to, and you must not, touch a real account**. The self-signed certificate configured in `.env` makes the browser refuse to connect; override to http with
  `HTTPS_CERT_PATH= HTTPS_KEY_PATH=` (**do not edit `.env`**).

### Android — `<workspace>/secuTG-android`

```bash
./gradlew :secutg-core:test --rerun-tasks          # --rerun-tasks must not be omitted
./gradlew :TMessagesProj:compileDebugJavaWithJavac
```

- **Omitting `--rerun-tasks` produces false greens.** This is the easiest trap to fall into in this project.
- To judge "did it really compile", `BUILD SUCCESSFUL` alone is not enough: check whether the task lines **have an `UP-TO-DATE` suffix**,
  and **compare class file mtimes**.
- **`.DS_Store` breaking the build: fixed at the root in `build.gradle` on 2026-09-18** (a `gradle.taskGraph.beforeTask` guard);
  rationale and measurements in `secuTG-android/docs/secutg/build-dsstore.md`. Three things that are easy to take for granted:
  - **It is not something `exclude` / `ignoreAssetsPattern` can fix.** The AGP resource merger already filters `.DS_Store`;
    the real files are written by macOS directly into AGP output directories **after** the merge task has finished, where no `Copy` task has any say.
  - **Moving files away one by one does not win either.** What triggers the rebuild is Gradle's own recursive delete — every time it empties a subdirectory,
    macOS immediately puts one back. Measured: after moving 205 away, 4 came back as soon as Gradle started deleting, and the build still blew up.
    What works is to **`rename` the whole polluted task output directory** away (a single atomic rename, nothing can sneak in).
  - The hook must be attached to `beforeTask`, **not `doFirst`** — `doFirst` runs after Gradle has cleaned old outputs, which is already too late.
  - The guard only moves, never deletes, into `build/tmp/dsstore-quarantine/`; on a machine that keeps re-polluting it leaves about 150 MB per build.
- Any `.DS_Store` leftovers you run into get `mv`'d into `_archive-dsstore-<date>/`, **never `rm`**.
- Strings are referenced as `R.string.<key>`, **without quotes** — searching references with `git grep '"<key>"'` returns 0 and you misjudge it as unreferenced.

### Windows — `<workspace>/secuTG-desktop`

```bash
cd Telegram/SourceFiles/secutg/tests
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8 && ./build/secutg_tests
```

- **The main Qt target cannot be built on macOS.** The standalone target above **contains no Qt code at all**,
  and several of its checks are string/order scans over **source text**, not compilation.
  **Its pass count must not be read as "it compiles".**
- So Qt/UI changes must additionally get: a bracket-balance check + a one-by-one comparison of each API against existing call sites in the repository (list which ones you compared against),
  and an **explicit statement that it has not been really compiled**.
- Incremental builds on an external drive get fooled by same-second timestamps (`make` thinks `main.cpp` is up to date and skips compiling it).
  If you read inconsistent numbers when measuring the baseline, suspect this first.
- There are already two gates; don't run into them: `snapshot()` must not appear outside the keyring; every `Tr("…")` literal must be in the table.

### iOS — `<workspace>/secuTG-ios`

```bash
USE_BAZEL_VERSION=8.1.0 bazel build --define=secutgBuild=local \
  --cpu=ios_sim_arm64 --platforms=@build_bazel_apple_support//platforms:ios_sim_arm64 \
  --ios_minimum_os=13.0 //submodules/TelegramUI:TelegramUI
swift test --package-path submodules/SecutgCore
```

- **The version must be 8.1.0**: default bazelisk resolves to 9.x, which fails at `third-party/libsodium/BUILD`
  (9 removed native `cc_library`); 7.4.1 fails at `AsyncDisplayKit/BUILD` (`objc_library cxxopts` needs 8+).
- Progress can be read from `/private/var/tmp/_bazel_<user>/<hash>/command.log`.
- Occasional `input file was modified during the build`; just retry.

### macOS — `<workspace>/secuTG-macos`

```bash
xcodebuild -workspace Telegram-Mac.xcworkspace -scheme Telegram -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO \
  -skipPackagePluginValidation -skipMacroValidation build
```

- The `Validate` errors for three Firebase frameworks (Info.plist location of `GoogleAppMeasurement` / `FirebaseAnalytics` /
  `GoogleAppMeasurementIdentitySupport`) are **known and unavoidable**;
  `VALIDATE_PRODUCT=NO` does not fix them either. The criterion is "zero Swift errors apart from these three".
- Touching the submodule `submodules/telegram-ios` requires: commit inside the submodule → in the parent repository `git add submodules/telegram-ios`
  + **a separate pointer commit** → the parent repository's feature commit. Use `git submodule status` to confirm the line starts with a **space** (not `+`).

### Cross-client matrix — `<workspace>/xcheck`

```bash
source ~/.nvm/nvm.sh && nvm use 24     # must come before calling python; child processes inherit PATH
python3 xcheck.py                       # full 5×5
python3 xcheck.py --suite k1 --clients web,android
```

- `--suite` filters only **production**; consumers still look for files for the full suite and report a pile of `no vector file` —
  that is caused by how it was run, not a failure. **To judge the real result, run the full set.**
- When changing a **cross-client contract** such as `TransferSummary` / the state machine, the suite implementations on all five clients must be updated together,
  otherwise during the transition you get **red in both directions**. This is expected and self-healing — don't read it as a regression.

---

## 3. Prompt templates

### 3.1 Audit

Key points: **one numbered checklist shared by all clients** + **mandatory evidence** + **planted known inconsistencies**.

```
You are doing the secuTG five-client consistency audit, responsible for <client>: repository <path>
The reference baseline is Web (<workspace>/secuTG, source in src/secutg/).

## ⚠️ Read-only task
Absolutely do not modify, create or delete any file, do not git add/commit/stash/checkout, do not run builds.

## Method
Use `git grep -n` (fast) rather than `grep -r`. Go by **what the code actually does**; use PLAN.md only for comparison when code and spec
conflict. **If you can't find it, write "not found"; do not infer from the spec what the code does.**
The entire value of this report lies in whether it can be trusted.

## Output format (follow strictly; the five clients' reports will be diffed against each other)
`| ID | Status | Evidence file:line | Notes |`
Use only four statuses: ✅ consistent / ⚠️ differs / ❌ missing / N/A not applicable to platform
- For ⚠️ and ❌ you must state clearly **what it actually is** (paste the actual copy or behaviour) and **how it differs from the baseline**
- At the end, add a separate section "Additional findings"

## Checklist
<45 numbered items, each naming the specific string key and expected behaviour>
```

**Key technique**: **deliberately include a few known inconsistencies** in the checklist (for example "the dialog that should pop up when you lose the race" exists only on Windows).
If a client's report marks all of these as "consistent", that report is unusable. This is the only low-cost way to verify a report's trustworthiness.

### 3.2 Remediation

```
secuTG batch N, you are responsible for <client>: repository <path>
Spec: section <number> of PLAN.md (read that whole section first; it records why it was decided this way)

**General principle**: <the one-sentence principle from §0>

## Background
<Why this is a problem and not merely an inconsistency. Spell out "what happens if it's missed">

## Reference implementation (done, read-only reference)
<Web commit hash + key code snippets + the reasoning behind each decision>

## What you need to do
<concrete items>

## ⚠️ <pitfalls or counter-intuitive points specific to this client>
<e.g. "This time the 'device' is the opposite of last time": last time it used the local identity, this time it must use the one holding the pairing>

## Verification
<this client's commands + pitfalls>

<hard-constraints block>

**If something genuinely cannot be done on this client** (as opposed to being hard to do), state honestly what is blocking it and give the best
alternative form for that platform — but do not call "hard" "impossible".
```

**Three phrasings proven effective in practice**:

1. **Pass on pitfalls other clients have already hit as premises**, rather than letting every client run into them separately.
   Example: "Android found that offline keys are bound to a particular chat, so jumping there from a place with no chat context has no destination —
   confirm what the actual situation is on your client before you start."
2. **For suspicious existing code, require asking "why" before changing it**.
   Example: "What you're going to touch is very likely the place that 'filters out all entities', but **before changing it, find out why it was filtered in the first place**."
   — The answer that time: it was a defence; removing it would let the other side forge system lines pointing to arbitrary URLs.
3. **Explicitly distinguish "it compiled" from "it was verified"**, and require the unverified parts to be labelled honestly.

### 3.3 Cross-client coordination (shared files)

iOS and macOS share `SecutgRuntime.swift` / `SecutgCore`, but they live in **two different clones**
(macOS's is in a submodule whose URL points to `secuTG-ios`), **so the same change has different hashes on each side**.

```
**iOS is the baseline; copy it verbatim.**
- First look at the current state in the submodule: if the change has already come across, verify it and use it; **do not write another version**
- If it hasn't, take it as-is from the other checkout with `git format-patch` and apply it, then **diff file by file to confirm it is verbatim identical**
- In the report, **paste the raw hunks of the change** so the other client can align
```

When dispatching agents on both clients at the same time, **explicitly forbid one of them from touching the shared files**; if a new API is needed, it stops and reports.

---

## 4. Misjudgements we made

**This section is more useful than the templates.** Every one actually happened, and every one existed for a while looking "done".

| Misjudgement | Truth | How to avoid it |
|---|---|---|
| "Only Web has the plaintext notice bar" | Web's is **dead code** — the condition asks "has no secuTG marker", while the system marks exactly these plaintexts, so the condition is always false. **In fact none of the five clients has it** | An audit can check "is the code there", not "will it ever trigger". For features **no one has ever been seen using**, also ask "under what circumstances does it appear" |
| "Android uses a persistent event queue, the most robust of the three" | It is a purely in-memory static list, capped at 64, gone when the process is killed | Adjectives ("persistent", "most robust") must be backed by code, not inferred from comments or naming |
| "The dialog that should pop up on late acceptance was implemented only as a system line" (stated as common to all five clients) | That was Web's situation; **Windows really implemented it** | Drawing a "five clients" conclusion after looking at one client is the easiest mistake to make this time |
| "Turning off either of the two wipe switches should require confirmation" | The spec requires it for only one; the other was never required. And iOS/macOS did both anyway | Read the original text before citing the spec; don't go from memory |
| "PLAN 3.28's 🆘 button is implemented on all five clients" | Only three. On iOS/macOS, `🆘` appears only in emoji data files | Records from early in a session can also be wrong; grep again at wrap-up |
| Generator bug diagnosis "escaped quotes break parsing" | It was actually **semicolons in the English copy** — `readStrings.ts` first splits records on `;` | Label guesses made when opening a task card as guesses; once checked, if wrong, **withdraw the card** rather than leaving it to mislead |
| "That `E1` "🔒 Encryption is on" is sent by the accepter B" | **It is sent by the initiator A** (when A receives B's `P1` and completes binding). The comment on that line in the Web code literally says `the inviter sends the confirmation` | Who sends which message in a sequence diagram must be checked in the code at the **send site**, not inferred from "who finishes binding first". This was wrong for six whole versions |
| "There are **two** still-clickable [Accept]s on the ousted device" (written into the spec and three task briefs) | The one on the control line re-checks the live keyring **at click time**, so the button isn't drawn at all. The only one really open is the **invitation dialog** (checks when it pops up, not at click time) | The source verification labelled this "**inferred**", and I used it as measured. **A conclusion labelled inferred must not go into the spec or a task brief** — either measure it, or keep labelling it inferred downstream |
| "iOS and macOS SecutgCore are byte-for-byte identical" | `Rekey/*`, `Transfer/*`, `Crypto/*` are identical; `Keyring/KeyRing.swift`, `SnapshotCodec.swift`, `Config/*`, `Guide/*` differ, and 14 more files exist on only one side | "Shared code" is a claim that drifts over time. Before dispatching a port, `diff -rq` and have the agent report the result back |

### Two points of methodology

**① Let the agent push back on you.** Several of the most valuable outputs came from agents correcting premises in the brief:
Android pointed out that "control line text is stored, not rendered" (using entities would permanently bake button text into storage);
Windows pointed out that the real meaning of `isAdmin` makes the defect's scope larger than described;
a review agent rejected another agent's claim of "it's committed, look at that range", and accepted it only after verifying for itself.
**So write in the brief: "Re-check this yourself; do not take it on trust."**

**② Do not end a turn with "waiting".** If a subagent ends its turn with "(waiting for the build)",
nobody finishes that build — it either runs for nothing or stops with the turn. This happened twice in this session.
State in the task: either finish it within the same turn, or rerun it.

---

## 5. Order for a complete reproduction

1. **Audit**: five clients in parallel, read-only, the same numbered checklist, with planted known inconsistencies to verify report trustworthiness
2. **Cross-diff**: line the five reports up into one matrix, rank severity by "will users lose data or be misled because of this"
3. **Classify**: what Web should change / what other clients should add / platform conventions that should not be unified / what all five change together / what needs a decision
4. **Write "what needs a decision" into the spec** (that's how PLAN 3.30 came about) — **the reasoning matters more than the conclusion**;
   the next person who sees an inconsistency needs to know whether it was considered back then
5. **Remediate in batches**: small, high-value items first; cross-client contract items last, because they must land on all five clients at once
6. **Final verification**: each client's unit tests + **the full 5×5 cross-client matrix**. The latter is the only evidence that the five clients speak the same language

---

## Appendix: quick reference for key paths

| Thing | Location |
|---|---|
| Spec (sole authority) | `secuTG/PLAN.md` |
| Single source of copy | `secuTG/src/secutg/i18n/secutg-strings.json` |
| Copy generator | `secuTG/tools/gen-secutg-strings.py` (`--web --android <root> --swift <path> --cpp <path>`; **with no arguments it only validates and writes no files**) |
| Cross-client matrix | `xcheck/` (`xcheck.py`, `inputs.json`, `tools/gen-inputs.mjs`) |
| Repository reorganisation spec | `secutg-repo-spec/` |
| Build artifacts | `dist/` |
| This document | `secuTG-docs/` |
