# The trigger queue: nightly timer, git-remote poller, pre-push notices, rc rows

- Date: 2026-10-09
- Status: accepted
- Linear: MOB-416 (under MOB-410)
- Amends: `2026-06-23-trigger-adapters.md` (the nightly sweep timer is
  replaced; the pre-push static gate and `priv/ci-run.sh` as the one entry
  point stand)

## Context

`2026-10-08-revived-version-rows-ios-selftests-matrix.md` §5 asked for three
triggers on top of `priv/ci-run.sh`: a git-remote poller that runs the static
gate on a new master sha and queues `default` + the changed plugin's
singleton + `all` on `master`; an optional pre-push enqueue from the Mac;
and the nightly timer, installed disabled since June, enabled for both
version rows. `rc:<repo>@<sha>` rows already parse (MOB-413) but nothing
ran them on demand.

Every one of those triggers wants device time, and the device time is two
scarce, serial resources: the redroid farm, shared with sloppy_joe staging
(cells run one at a time; two builds at once double the deploy step,
`docs/budgets.md`), and the Mac mini, which builds one iOS host at a time.
Two cells of the same set and row would also share one generated host
directory (`fixtures/_hosts/<app>`). A trigger that just ran `mix ci.device`
from a timer or an ssh command would race the others.

## Decision

### A durable queue in the results store, one worker per lane

The queue is two tables in the existing SQLite store (schema 2,
`priv/schema.sql`), not a spool directory: the store is already the one
file every run writes, it gives atomic claims (`UPDATE … RETURNING` inside a
`BEGIN IMMEDIATE` transaction) and dedup by query, and the job id can go on
the run rows (`runs.job_id`). `MobCi.Queue` owns `jobs` and `job_cells`;
`MobCi.Poller` owns `heads` and `pushes`.

- A **job** is one trigger's request: `{trigger, versions_row, sets,
  platforms, reason}` plus a priority and an optional `not_after`.
- `enqueue/3` expands it into one **cell** per (set, platform), in the job's
  set order. A cell identical to one still *queued* (row, set, platform,
  paths) is stored as a `duplicate` of it, provided that cell's job runs at
  least as soon (priority) and cannot expire sooner (`not_after`): a
  `master` cell resolves the default-branch shas when it starts, so the
  queued one already covers the newer commit, but a poll cell folded into a
  nightly one would wait at nightly priority and vanish with it at 07:00. A
  running cell has resolved its shas and is never a target.
- A **lane** is a platform. `android` runs on the farm, `ios` on the Mac via
  `mix ci.device --platform ios`; the lanes share no machine, so they run
  side by side, each strictly one cell at a time (`flock` on
  `~/.local/share/mob_ci/locks/drain-<lane>.lock`, plus systemd's
  one-instance-per-unit). Order: job priority (poll, pre-push, rc, manual =
  10; nightly = 0), then the oldest job, then the job's set order.
- Each cell is its own `mix ci.device` process (a crash can't take the
  worker down) under coreutils `timeout` (90 min), with `MOB_CI_TRIGGER` and
  `MOB_CI_JOB_ID` in its environment; `MobCi.Store.record_run/2` records
  them as the run's `trigger` and `job_id`. Android cells write their
  artifacts to `~/mob_ci_logs/queue/cell-<id>/` so a later cell never
  overwrites the build logs the store points at; the cell's console output
  is `~/mob_ci_logs/queue/cell-<id>.log`.
- A job is **done** when none of its cells is queued or running and every
  cell it deferred to (a duplicate) is done. The worker that completes it
  runs `mix ci.report --publish` once (`mix ci.report` where the task has no
  `--publish`, detected from its moduledoc), logs the exit code on the job
  and never retries (MOB-417's contract: non-zero only when writing
  `matrix.md` / `COMPATIBILITY.md` failed; the Muster post covers every
  summary cell since the previous publish). A nightly is two jobs (hex,
  master), so two publishes a night; a poll batch is one.
- A worker that starts cleans up after a dead worker of its lane (the lock
  admits one per lane, so nothing it finds is live): `running` cells are
  requeued, and jobs the lane completed (`jobs.publish_lane`) but never
  published get their report run.
- **A lost instance is retried once** (amended 2026-10-09, FINDINGS F13). A
  path whose redroid went away mid-path — mob_dev or adb saying so
  (`Selected Android device(s) disconnected`, `device offline`, `device '…'
  not found`, `no devices/emulators found`, `error: closed`, `device still
  connecting`), or a failed
  path after which `ci-farm.sh alive` finds the container stopped or adb
  without the device — is layer `farm`, never `build:*`, `boot` or a plugin.
  `mix ci.device` then exits 3 (it takes precedence over 1 and 2), and
  `finish/5` queues one retry of the cell (`job_cells.retry_of`, schema 3),
  claimed before anything else of its priority, on a fresh instance (every
  path boots its own). Cells that deferred to the lost one defer to the
  retry, so no job completes on the lost attempt. Both attempts stay: as
  cells (`ci-run.sh queue show <job>`) and as runs in the store. A retry that
  loses its instance too is recorded as is, not retried again. The report
  never counts a `farm` cell as a regression, nor as the pass/fail a later
  cell is compared with (`MobCi.Matrix.regressions/2`, `Store.retained/2`).
- **A crashed toolchain is infrastructure too** (amended 2026-10-09, MOB-468,
  FINDINGS F15). A build whose output carries a JVM fatal error (`A fatal
  error has been detected by the Java Runtime Environment`, or the
  `hs_err_pid<N>.log` path when mob_dev kept only the tail) is layer
  `toolchain`, never `build:*` or a plugin. It is treated exactly like
  `farm`: exit 3, one retry, shown in the report, never a regression, a
  regression baseline or the P12 singleton result (`Store.infra?/1`).

### Triggers

`MobCi.Triggers` is the pure trigger → job mapping; `priv/ci-run.sh` stays
the single entry point and starts both lane workers after every queueing
mode (`systemctl --user start --no-block mob-ci-drain@{android,ios}`, a
no-op for a lane already draining).

| trigger | entry | row | sets | platforms |
|---|---|---|---|---|
| nightly | `mob-ci-nightly.timer` 22:00 → `ci-run.sh nightly` | `hex`, then `master` | `Sets.nightly/0`; pairwise rows only on `master` | android, ios |
| poll | `mob-ci-poll.timer` every 10 min → `ci-run.sh poll` | `master` | core repo: `blank` `default` `all`; plugin: `default` `singleton:<p>` `all` | android, ios |
| pre-push | Mac hook → `ssh nuc ci-run.sh push` → `confirm` | `master` (default branch) or `rc:<repo>@<sha>` (another branch) | as poll | android, ios |
| rc | `ci-run.sh rc <repo>@<sha>` | `rc:<repo>@<sha>` | as poll, for `<repo>` | android, ios |
| manual | `ci-run.sh queue enqueue --versions … --sets …` | any | any | any |

**Poller.** `git ls-remote <url> HEAD` per repo (mob, mob_dev, mob_new,
every plugin in `priv/plugins.exs`), eight at a time, 45 s cap each: plain
git, so any host works. The first sighting of a repo is a baseline (nothing
queued); a moved sha is a change. All changes of a cycle become one
`master` job; the static gate (`mix ci.device --static --set <s> --versions
master`, recorded in the store as path `static`) runs for each of its sets
before it is queued. A static failure does not hold the device cells back:
`all` is statically red on purpose while F9 is parked, and the device cells
say which layer breaks. An unreachable repo keeps its stored sha and is
retried next cycle. An unbuildable plugin (`device_caps.exs`) has no
singleton to run; its change still queues `default` + `all`.

**Pre-push.** `worker/mac/enqueue-push.sh <local_sha> <remote_ref>` (the
one-line hook addition is proposed in MOB-416, not committed to other repos)
backgrounds `ssh nuc ci-run.sh push <repo> <sha> <ref>` and always exits 0.
The NUC records a `pending` push and starts `mob-ci-confirm` (transient,
`systemd-run`), which ls-remotes the pushed repo every 15 s for up to
15 minutes and, as soon as the sha is on the remote, runs a poll cycle. Every
cycle — the timer's and confirm's — holds `~/.local/share/mob_ci/locks/poll.lock`
(the timer skips a cycle while confirm's runs; confirm waits for the timer's),
so two cycles never see the same change and queue it twice. The
cycle settles it: the sha is the default branch's `HEAD` → `covered` by the
poll job (the poller dedups the push; the job's trigger says `pre-push`); on
another ref → its own `rc:<repo>@<sha>` job; not there an hour after the
notice → `expired` (the hook or the remote refused the push). Nothing runs
for a sha the remote doesn't have.

**rc.** `ci-run.sh rc <repo>@<sha>` runs the static gate for the repo's sets
on that row and queues them on both platforms.

### The nightly budget, and how it is pruned

The window is 22:00 → 07:00 local, 540 minutes; staging traffic picks up
after. Per-cell costs come from the first queued runs on the NUC (jobs 1
and 2, 2026-10-09; `docs/budgets.md` "The nightly"): an Android `master`
cell is cold — some repo moves nearly every day, and a `mob` move
recompiles every dep — at 480–510 s with both build paths (1000 s for
`all`); a `hex` cell reuses its host, 140–180 s; a deploy-only pairwise row
costs about a cold singleton. The Mac rebuilds every iOS host: ~185 s a cell
today (device path skipped, release path failing at signing), budgeted at
360 s with all three paths working, 150 s for `deploy:ios_sim` alone.
`Sets.nightly/0` is 37 sets (blank, default, 22 singletons, all, 10
pairwise rows, demo, selftest_pilots).

Unpruned — every set on both rows with every path — the Android lane needs
about 437 minutes on a normal night, but 646 after a Hex release (every
`hex` cell cold as well), and the iOS lane 456. Pruned deliberately:

1. The pairwise rows run on `master` only: the covering array is about
   interactions that change with the code, and `hex` changes only on a
   release, which the `rc:` row checks first and the next nightly's
   `master` row already ran.
2. The pairwise rows run the deploy path only (`deploy:android`,
   `deploy:ios_sim`): the release build adds nothing to a pairwise
   interaction (`2026-10-08-p12-release-cell-results-store.md`).
3. `hex` runs first, so if anything overruns it is the `master` pairwise
   tail, the least informative cells.
4. Every nightly cell not started by 07:00 local expires (`not_after`) and
   the farm goes back to staging; the job still publishes what ran.

After pruning: Android **402** minutes on a normal night (84 `hex` + 318
`master`), iOS **361**, both within 540
(`MobCi.Triggers.estimate_minutes/1`; `test/mob_ci/triggers_test.exs` fails
when a new plugin or set pushes a lane over, so the next prune is a
decision, not a surprise). A night after a Hex release costs the Android
lane ~556 minutes: the last `master` pairwise rows expire at 07:00 and run
the next night.

The fixture-harness StreamData sweep (`ci-run.sh sweep 4`, the June timer)
is not scheduled any more: it would compete with the Android lane for the
farm, and it has no budget left in the window.
It stays a manual mode; a failing seed still becomes a committed regression
set that the nightly runs.

`priv/sets/exclusions.exs` was listed by `Sets.nightly/0` as a regression
set (it resolved to no plugins, a second `blank`); it is config, and is no
longer a set name.

## Consequences

- Triggers stay disposable: the units only call `priv/ci-run.sh`, and the
  queue is data — `ci-run.sh queue` prints it, `ci-run.sh queue show <id>`
  one job with its cells, exit codes and logs.
- Every run in the store says what caused it (`trigger`, `job_id`), so the
  matrix (MOB-417) can tell a nightly result from a poll or rc one.
- A busy day of pushes (MOB-418 adds self-tests to 23 plugins) queues one
  job per poll cycle; the shared `default` and `all` cells collapse into
  whichever is still queued, so the farm runs each singleton once and the
  big sets once per drain, not once per push.
- The poller's ls-remote is ~5 s for 28 repos; the static gate is the
  cycle's cost (seconds to a minute per set). A cycle still running when the
  timer fires delays the next one (oneshot units don't overlap).
- Pausing a lane (`ci-run.sh pause ios`: a pause file the worker checks on
  start, so the poller's kicks don't restart it, then `systemctl --user
  stop`) kills its running cell; `ci-run.sh resume ios` requeues it. A
  worker killed mid-cell can leave a farm lease or a Mac host behind until
  their own staleness rules clear them.
- Install: `priv/install-triggers.sh --enable` (idempotent; renders the
  units for the checkout it runs from, removes the retired `mob-ci.{service,
  timer}`, enables lingering).
