# Per-Stage Prompts (when assigning a stage, paste the corresponding section)

> Prerequisite: the session has already been given `00-kickoff.md`, and the model has already read the spec.
> If it is a new session, paste `00-kickoff.md` first, then paste one of the sections here.

---

## Stage 0 · Safety archiving and preflight

```
Execute stage 0 of 03-runbook.md.

This stage only adds, never removes, and carries no risk: create three rollback tags, commit or set aside separately the changes already in the secuTG-macos working tree, report the stash in the submodule, and classify the backup-mac rescue patch file by file.

Pay special attention to four things:
1. Only report that stash; do not pop it and do not drop it. Its content is already entirely in HEAD and master; it is stale.
2. The build-number changes in the two Info.plist files must be handled separately and cannot be left in the working tree, otherwise a later git add will sweep them into the sync commit.
3. Classify the backup-mac patch by running git apply --check forward and in reverse file by file; do not just grep the core paths. spm.bzl and PeerInfoScreenPerformButtonAction.swift are known to be absent on dev-mac. List the complete inventory for me; do not apply anything on your own.
4. Tags are only created, never deleted.

When done, paste the output of the three verify commands to me verbatim, then stop.
```

---

## Stage 1 · Fix the dangling gitlink, tidy up the iOS working tree

```
Execute stage 1 of 03-runbook.md.

This stage fixes a fault that exists right now: a fresh clone of secuTG-macos cannot be set up. I have tested it myself; two causes stack up: one is that git by default forbids submodules from using local paths, the other is that the iOS repository does not contain the commit the gitlink points to at all. This stage fixes the second one.

Do not get the order wrong: first rename the stale secutg-mac branch in iOS to archive, then push the mac submodule's real secutg-mac into it. Doing it the other way round causes a name collision.

The 31 lines of watermark vectors in 1c go into master, not onto the 3.22 branch — they belong to 3.21.
The .gitignore pattern in 1d must be written with a leading slash as /bazel-secuTG-ios; writing it as bazel-* would also ignore the build-system/bazel-rules/ directory.
Only do 1e if I answered A to Q4 on the decision sheet.

The real acceptance test for this stage is that fresh-clone test; you must run it and paste the output to me. After testing, use mv to move the temporary directory into the scratchpad's _archive-*; do not rm.
```

---

## Stage 2 · Fill in the shared layer on master

```
Execute stage 2 of 03-runbook.md.

Before starting, confirm first: what are my answers to Q1 to Q5 on the decision sheet? If there are no answers, stop here and ask me; do not proceed with default values.

The goal of this stage is to make master's three mirrored paths the union of both lines' capabilities, so that mirroring does not cause mac to lose anything.

2b is the easiest item to miss; it was found by the adversarial review: mac's TextUtils.pullText is the funnel shared by the chat list, reply previews, notifications and search, and the source comment explicitly says it cannot get an account, so it uses a mac-only account-free read API. That API would be overwritten in the mirrored path, and master's only read-side API requires passing accountPeerId. mac has 7 call sites relying on it. If the account-free entry point is not upstreamed to master first, stage 4 is bound to get stuck.

For 2c①, do not use cherry-pick; that commit also changes three files on the mac side, which will inevitably conflict and leave sequencer state behind. Use the form given in the runbook, piping git diff into git apply --index; it has been verified to be clean.

For 2c④, when moving SecutgGuideData you must also change the generator's output path in the Web repository; otherwise the next regeneration will produce another type with the same name at the old path, and files that import both modules will get an ambiguous symbol.

One commit per item, and run swift test after each item. When done, show me the test case count compared with the stage 1 baseline.
```

---

## Stage 3 · Install scripts and guardrails

```
Execute stage 3 of 03-runbook.md.

Install secutg-repo-spec/scripts/secutg-sync-from-ios.sh into secuTG-macos/scripts/, install the pre-commit hook, and turn on two git config settings.

I have already run the script with --check on the real repository, and the output matches the survey (32 files +1434/-1516, 8 files will be deleted, the SECUTG-HOOK difference set is three known files). After installing, run it again to confirm it matches.

The acceptance test for the pre-commit hook must actually be tried once: create a file in the submodule, git add it, attempt to commit, and confirm it is rejected. Then git reset and mv the file into the scratchpad; do not rm.

The hook is not checked into the repository; this must be written into CLAUDE.md — fresh clones need to reinstall it.
```

---

## Stage 4 · First mirror plus one-time port

```
Execute stage 4 of 03-runbook.md. This is the only stage with substantial workload; budget 1 to 2 working days.

First run --check and paste the DELETED list to me for confirmation; only after I confirm do you run --apply --stage-only.

It is normal for mac not to compile partway through; do not roll back because of it. The first mirror must use --stage-only and be combined with the glue changes into a single commit. If partway through you change shared code on master again, just rerun --apply --stage-only to feed it back; the script's precondition check only looks at the mirrored paths and does not require the whole submodule to be clean.

These two items in the 4c list were found by the adversarial review; do not miss them:
- The switch at line 293 of ChatMessageItem.swift has 4 cases and no default; after mirroring, Kind gains one more sealed value and the switch becomes non-exhaustive, and both the main target and the TelegramShare target fail to compile. A branch must be added.
- The condition at line 73 of TextUtils.swift misses sealed; this does not raise an error but goes wrong at runtime: sealed messages cannot be displayed in the chat list and notifications.

SecutgGuideWindow and SecutgPhoneView are a rewrite of about 250 lines, not a dozen or so edits; estimate the effort accordingly.

Check uptime before compiling; if the load is above the core count, wait a bit. Record the error count of each round in stage9-mirror.md.

The git add in 4d must list files one by one; do not add the whole Telegram-Mac directory.

When done, run the four verify commands, where 90-drift-check.sh must be run with --phase 4; at this point layer 1 should have zero differences. Remember to delete the section "temporary registrations before the stage 4 merge design" from drift-allowlist.txt.
```

---

## Stage 5 · String table unification

```
Execute 06-strings-canonicalization.md. This stage is independent of the repository restructuring and can be done at any time.

Currently three sets of key names coexist: Web and Android use the canonical names produced by the generator, while the generated files of both iOS and Windows have been hand-edited. None of iOS's 34 hand-written keys is currently referenced by any UI code, so simply regenerating is enough. Windows has 15 self-invented names and 12 references in glue.cpp; the call sites need to be changed.

When changing the Windows call sites, change them one at a time; do not use a global sed replace — SecutgWipeListens is a prefix of SecutgWipeListensOn, and a global replace would break it.

First add the 8 missing keys to the canonical source JSON (copy the wording directly from the existing iOS and Windows tables; the document lists the mapping), verify the JSON parses, then run the generator.

The Windows side cannot compile Qt on dev-mac; after the changes, I will compile and confirm elsewhere. Both verification command blocks must be run; paste the output to me.
```

---

## Stage 6 · Verification and documentation

```
Execute stage 6 of 03-runbook.md.

The runtime verification part is my job; do not touch real accounts. Put together the verification checklist for me; I will run it myself and tell you the results, and you record them in stage9-mirror.md.

The documentation part is your job: create stage9-mirror.md, change the top of stage8-macos-status.md and the two inaccurate records in it, add a discipline section to the CLAUDE.md of each of the two repositories, and update the two memory files.

That CLAUDE.md section must include: hand-editing mirrored paths is forbidden; the shared directory uses only allowlisted APIs; new checkouts must use protocol.file.allow and never --recursive; .gitmodules keeps absolute paths, and when switching machines override with local config; the pre-commit hook is not checked into the repository and must be reinstalled; the guide generator's output path has been changed.
```
