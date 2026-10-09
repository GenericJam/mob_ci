# mob_ci

Orchestrator-first device CI for the mob ecosystem: builds host apps with
plugin sets, runs them on the redroid farm (Android, this NUC) and on the Mac
mini (iOS, over ssh), and publishes a generated compatibility matrix. Read
`decisions/2026-06-19-mob-ci-design.md` (layers L0–L5, invariants P1–P11) and
`decisions/2026-10-08-revived-version-rows-ios-selftests-matrix.md` (what is
being added) before changing anything. Findings go in `FINDINGS.md`.

## Conventions

- Follow `~/AGENTS.md` on the Mac: worktrees, Codex review first, watch CI
  after every push, Muster `#mob`, Linear MOB-410 and its sub-issues.
- This repo runs on the NUC. From the Mac: `ssh nuc` (key auth, BatchMode).
  Long runs go through `priv/ci-run.sh` under `tmux` or
  `systemd-run --user`, never in a foreground ssh session.
- The core checkouts in `~/code/{mob,mob_dev,mob_new}` on the NUC track
  origin/master; never commit there, and keep `.tool-versions` local.
- The farm is shared with sloppy_joe staging: lease only through
  `priv/ci-farm.sh`, respect the admit ceiling, and always release.
- Every failure is attributed to a layer. A result that cannot say which
  layer failed is a bug in mob_ci.
- Sets are deterministic and committed under `priv/sets/`; results are data
  (SQLite) and `matrix.md` / `COMPATIBILITY.md` are generated from them.
