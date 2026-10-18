# 00 · Hard Constraints (not a single one may be broken while executing this spec)

> This file is the **safety boundary** for the executing model (Opus 5 or any later agent). Where any rule conflicts with a later document, this file takes precedence.
> These rules come from a real incident (data loss occurred on 2026-08-25) and from the nature of the project (the wipe feature is itself destructive).

## A. File system

| # | Rule | Notes |
|---|------|------|
| A1 | **Never delete** any file or directory on any machine | Including dev-mac, backup-mac and the external drive. `rm` is already blocked by a local hook. When something needs to be "moved out of the way", `mv` it into a sibling `_archive-<date>/` directory and state this in the report |
| A2 | Do not use `/usr/bin/trash` | Every "move out of the way" in this spec uses `mv` to `_archive-*`, so it can be rolled back |
| A3 | backup-mac (ssh alias `backup-mac`, hostname <hostname>) is **read-only** | Only `git fetch`/`rsync` **from** backup-mac is allowed; writing, modifying, deleting or committing on backup-mac is not allowed |
| A4 | The external drive path is fixed at `<workspace>/` | All development, builds and caches live here; do not create project copies in `~/Documents` or on the internal drive |
| A5 | Build caches go in `<build-cache>/` | Both bazel `--output_user_root` and DerivedData point there; do not put caches back on the internal drive |

## B. Git

| # | Rule | Notes |
|---|------|------|
| B1 | **Never push to GitHub** | The only remote `upstream` of `secuTG-ios` and `secuTG-macos` is the **official/upstream public repository** (TelegramMessenger/Telegram-iOS, overtake/TelegramSwift). Pushing there is equivalent to publishing the secuTG code. Every push in this spec may only target a local path or a repository inside dev-mac |
| B2 | No force pushes, no rebasing existing branches, no rewriting existing branches with filter-branch / filter-repo | Extract history only with `git subtree split` (it produces **new** commits and does not touch the original branch) |
| B3 | No `git reset --hard`, no `git checkout -- <file>`, no `git clean`, no `git stash drop` | Sole exception: rollback steps explicitly written in `03-runbook.md` |
| B4 | Do not initialize submodules with `--recursive` | It would pull down multi-GB nested submodules such as webrtc/tg_owt. Only **targeted** init of the paths specified by the spec is allowed |
| B5 | The shell line containing `git commit` **must not also contain** `-n`, `-not` or `grep -n` | The local hook misjudges it as a hook-bypass flag and rejects the whole command. Split the command into two lines |
| B6 | Do not bypass git hooks | The local hook blocks any hook-bypass flag (whether it appears in the command or in heredoc text). When writing documents, also do not put that flag's literal into a Bash command line; write the file with the Write tool |
| B7 | Commit messages use `<type>(secutg): <description>` | type ∈ feat/fix/refactor/docs/test/chore/build. No AI attribution lines |
| B8 | `git status` first, then act; if the working tree has uncommitted changes, handle them per the ledger first, do not overwrite | See `01-facts.md §G` |
| B9 | Do not commit these local changes | The port in Web `vite.config.ts`; the abiFilters in Android `TMessagesProj_AppStandalone/build.gradle`; any `secutg.json`, `watermark_key`, real api_id/api_hash |

## C. Testing and running

| # | Rule | Notes |
|---|------|------|
| C1 | End-to-end testing with a real Telegram account is **forbidden** | Wipe (3.22) really does clear the account's sessions. The user tests with a dedicated number themselves |
| C2 | All logins are performed by the user | Simulator, desktop, web — never log in on the user's behalf |
| C3 | Allowed automated verification: unit tests, compilation, `swift test`, `bazel test`, static checks | See each stage's verify section |
| C4 | Check load before compiling | `uptime`; if load is above the core count, wait first. The user cares about the machine becoming sluggish |

## D. Process

| # | Rule | Notes |
|---|------|------|
| D1 | Every stage: **preflight → execute → verify → record** | If any verify item FAILs, stop and report the FAIL verbatim to the user; do not "fix it up and carry on" on your own |
| D2 | Do not skip between stages | The stages in `03-runbook.md` have a dependency order |
| D3 | At points that need the user's decision (`02-target-topology.md §Decision points`), stop there until answered | Do not choose for the user |
| D4 | After completing each stage, append the result to `CHECKLIST.md` (date, commands, key hashes) | So the next executor can pick up from there |
| D5 | Reports must state "what was done, what was verified, what was not done" | Do not write "should be fine" |
