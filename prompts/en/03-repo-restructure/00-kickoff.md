# Kickoff Prompt (paste this as the first message of every new session)

> Usage: copy the full text between the `---` lines below to the executing model. It will read the spec itself, run the health check, report status, and then stop and wait for you to assign a stage.
> Do not omit any section, especially the safety-boundary lines — they are there to prevent incidents.

---

You are going to execute a repository restructuring spec that has already been written. The spec is in `<workspace>/secutg-repo-spec/`; it is self-contained, and you do not need me to fill in background.

**Step 1: read these files in order, and only start acting after reading them.**

1. `00-constraints.md` — hard constraints. Where any later document conflicts with it, it takes precedence.
2. `01-facts.md` — fact ledger. The hashes in it are a snapshot from 2026-09-15; if the structural facts (§B §C §F §K) have changed, stop and tell me.
3. `02-target-topology.md` — target structure and the rationale for the choices, including the conclusions of the adversarial review.
4. `03-runbook.md` — execution runbook, your main basis for work.
5. `07-decisions.md` — decision sheet. **Until I have answered questions 1 to 4, do not start stage 2.**
6. `CHECKLIST.md` — how far things have already got.

**Step 2: run the read-only health check and report the results to me verbatim.**

```bash
zsh <workspace>/secutg-repo-spec/scripts/00-preflight.sh
```

**Step 3: report and stop.** Tell me: the health check results, which stage `CHECKLIST.md` shows we are at, what the next stage is, and whether there are decision points I need to settle first. **Then wait for me to assign; do not start on your own.**

---

**Safety boundaries that not a single one may be broken during this session:**

- **Never delete any file or directory**, on any machine. When something needs to be "moved out of the way", `mv` it into a sibling `_archive-<date>/` and state this in the report. `rm` on this machine is already blocked by a hook.
- **Never push to GitHub.** The only remote `upstream` of `secuTG-ios` and `secuTG-macos` is the **official public repository**; pushing there is equivalent to publishing all of the secuTG code. Every push in the spec targets only local paths.
- **backup-mac is read-only.** Only fetching or rsyncing from it is allowed; writing, modifying, deleting or committing on it is not allowed.
- **Do not do end-to-end testing with a real Telegram account.** The wipe feature really does clear the account's sessions. Logins and real-device verification are always done by me.
- **No rebasing, no rewriting existing branch history, no `reset --hard` (unless it is a rollback step explicitly written in the runbook), no `git clean`.**
- The shell command line containing `git commit` **must not also contain** `-n`, `-not` or `grep -n`; the local hook will misjudge it and reject the whole command. Split it into two lines.
- Do not initialize submodules with `--recursive`; it would pull down multiple GB of dependencies.

**How to work:**

- Each stage goes through four steps: **preflight → execute → verify → record**. If any verify item FAILs, stop and give me the FAIL verbatim; do not "fix it up and carry on" on your own.
- Do not skip between stages.
- After completing each stage, append the date, the commands actually run and the key hashes to `CHECKLIST.md`.
- Reports must clearly state "what was done, what was verified, what was not done". Do not write "should be fine".
- When you hit a situation the spec does not cover, stop and ask me; do not improvise.
