# mob_ci L5 trigger adapters

The orchestrator (Layers 0–4) is the product. Triggers are **thin, swappable**
glue that just call into it — so we never depend on one CI vendor's control
plane (see `decisions/2026-06-19-mob-ci-design.md`). Everything here calls one
script, `priv/ci-run.sh`; swapping or deleting a trigger never touches CI logic.
Device work goes through the trigger queue (`MobCi.Queue`,
`decisions/2026-10-09-trigger-queue.md`), drained one cell at a time per lane.

## The canonical entry points

The orchestrator is reachable as plain Mix tasks (both self-start Erlang
distribution, so no `elixir --name` wrapper is needed):

| Command | What it does | Speed |
|---|---|---|
| `mix ci.device --static` | cross_validate + projection summary, no device | ~1s |
| `mix ci.sweep --static` | validator soundness over the subset space | ~1s |
| `mix ci.device` | full P1–P12 on the harness fixture set | ~minutes (build) |
| `mix ci.device --set S --versions R [--platform ios]` | one cell on a generated host | ~minutes |
| `mix ci.device --host sloppy_joe` | P1–P11 against the real app (realism gate) | ~minutes |
| `mix ci.sweep --runs N` | N sampled subsets through P1–P11 + shrink | ~minutes × N |
| `mix ci.queue …` | the queue: status, nightly, rc, enqueue, push, drain | seconds (drain: hours) |
| `mix ci.poll` | one git-remote poll cycle | seconds + the static gate |

Exit codes: `0` pass · `1` an invariant/subset failed · `2` orchestration error
(boot/build/launch). That is what every trigger gates on.

## `priv/ci-run.sh` — the one script triggers call

Makes the orchestrator runnable from a bare environment (systemd unit, git hook,
cron, an ssh command from the Mac): puts the mise toolchain on `PATH`, fixes
the locale, cds to the repo, tees a timestamped log under `artifacts/ci-run/`
(a week of the frequent modes is kept), and propagates the exit code.

```
priv/ci-run.sh static                     # fast composability gate (no device)
priv/ci-run.sh device [host]              # full P1–P11 (host: harness | sloppy_joe)
priv/ci-run.sh realism                    # P1–P11 against the real sloppy_joe app
priv/ci-run.sh sweep [runs]               # device property sweep over N subsets (manual)

priv/ci-run.sh nightly                    # queue tonight's hex + master sets, Android + iOS
priv/ci-run.sh poll                       # one poll cycle: static gate + queue master cells
priv/ci-run.sh rc <repo>@<sha>            # static gate + queue the rc:<repo>@<sha> row
priv/ci-run.sh push <repo> <sha> [<ref>]  # a pre-push notice (from the Mac)
priv/ci-run.sh confirm                    # wait for noticed pushes to land, then poll
priv/ci-run.sh drain android|ios          # run one lane's queued cells until it is empty
priv/ci-run.sh pause|resume android|ios   # keep a lane quiet for hand runs (its cell is requeued)
priv/ci-run.sh queue [show <id> | enqueue --versions R --sets a,b [--platforms android]]
```

Every queueing mode then starts both lane workers
(`mob-ci-drain@{android,ios}.service`; a no-op for a lane already draining).
A finished job runs `mix ci.report --publish` (or `mix ci.report`) once.
Cell logs: `~/mob_ci_logs/queue/cell-<id>.log` (and `cell-<id>/` for an
Android cell's artifacts), report logs `job-<id>-report.log`.

## The triggers

- **Nightly timer** (`priv/systemd/mob-ci-nightly.{service,timer}`, 22:00
  local) → `ci-run.sh nightly`: every `Sets.nightly/0` set on `master`, the
  same minus the pairwise rows on `hex`, Android and iOS; pairwise rows run
  the deploy path only; cells not started by 07:00 expire. The budget and the
  pruning: `decisions/2026-10-09-trigger-queue.md`, `docs/budgets.md`.
- **Poller timer** (`priv/systemd/mob-ci-poll.{service,timer}`, every 10 min)
  → `ci-run.sh poll`: `git ls-remote` (no forge API) over mob, mob_dev,
  mob_new and every plugin; a moved default branch runs the static gate and
  queues `blank` + `default` + `all` (core repo) or `default` +
  `singleton:<plugin>` + `all` (plugin) on `master`. Last-seen shas are the
  store's `heads` table: `mix ci.poll --heads`, `mix ci.poll --reset
  <repo>@<sha>`.
- **Lane workers** (`priv/systemd/mob-ci-drain@.service`, instances
  `android` and `ios`) → `ci-run.sh drain <lane>`: started by the modes
  above, exit when the lane is empty.
- **git pre-push hook, this repo** (`priv/hooks/pre-push`) → `ci-run.sh
  static`. Catches cross-plugin conflicts cheaply before a push.
- **pre-push notice, mob-family repos (optional, Mac)** →
  `worker/mac/enqueue-push.sh` (see below).
- **rc on demand** → `ci-run.sh rc <repo>@<sha>` before cutting a release.
- **Forgejo/GH (optional)** — not committed. A ~20-line YAML job whose only step
  is `priv/ci-run.sh static` (hosted) or, on a self-hosted runner on this box,
  `rc <repo>@<sha>`. The logic stays here; the YAML is disposable.

## Install (the NUC)

```
priv/install-triggers.sh            # hook + units, timers not started
priv/install-triggers.sh --enable   # also enable + start the nightly and poll timers, enable lingering
systemctl --user list-timers 'mob-ci-*'
priv/ci-run.sh queue                # what is queued / ran
```

Idempotent: a re-run with nothing changed rewrites nothing. The units are
rendered for the checkout the script runs from; the retired
`mob-ci.{service,timer}` (the June sweep timer) is disabled and removed.

## The pre-push notice from the Mac (optional)

`worker/mac/enqueue-push.sh <local_sha> <remote_ref>` backgrounds
`ssh nuc code/mob_ci/priv/ci-run.sh push <repo> <sha> <ref>` and always exits
0 (log: `~/mob_ci_logs/enqueue-push.log`; `MOB_CI_ENQUEUE=0` turns it off,
`MOB_CI_NUC` / `MOB_CI_NUC_REPO` override host and checkout). The NUC runs
nothing until the sha is on the remote: a default-branch push is then covered
by the poller's job (just sooner); a branch push runs as
`rc:<repo>@<sha>`; a push that never lands expires after an hour.

To use it from a mob-family repo, add one line inside the `while read …`
loop of its `.githooks/pre-push`:

```bash
    "$HOME/code/mob_ci/worker/mac/enqueue-push.sh" "$local_sha" "$remote_ref" </dev/null || true
```
