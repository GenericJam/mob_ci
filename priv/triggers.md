# mob_ci L5 trigger adapters

The orchestrator (Layers 0–4) is the product. Triggers are **thin, swappable**
glue that just call into it — so we never depend on one CI vendor's control
plane (see `decisions/2026-06-19-mob-ci-design.md`). Everything here calls one
script, `priv/ci-run.sh`; swapping or deleting a trigger never touches CI logic.

## The canonical entry points

The orchestrator is reachable as plain Mix tasks (both self-start Erlang
distribution, so no `elixir --name` wrapper is needed):

| Command | What it does | Speed |
|---|---|---|
| `mix ci.device --static` | cross_validate + projection summary, no device | ~1s |
| `mix ci.sweep --static` | validator soundness over the subset space | ~1s |
| `mix ci.device` | full P1–P11 on the harness fixture set | ~minutes (build) |
| `mix ci.device --host sloppy_joe` | P1–P11 against the real app (realism gate) | ~minutes |
| `mix ci.sweep --runs N` | N sampled subsets through P1–P11 + shrink | ~minutes × N |

Exit codes: `0` pass · `1` an invariant/subset failed · `2` orchestration error
(boot/build/launch). That is what every trigger gates on.

## `priv/ci-run.sh` — the one script triggers call

Makes the orchestrator runnable from a bare environment (systemd unit, git hook,
cron, a Forgejo/GH step): puts the mise toolchain on `PATH`, fixes the locale,
cds to the repo, tees a timestamped log under `artifacts/ci-run/`, and propagates
the exit code.

```
priv/ci-run.sh static            # fast composability gate (no device)
priv/ci-run.sh device [host]     # full P1–P11 (host: harness | sloppy_joe)
priv/ci-run.sh realism           # P1–P11 against the real sloppy_joe app
priv/ci-run.sh sweep [runs]      # device property sweep over N subsets
```

## The triggers

- **git pre-push hook** (`priv/hooks/pre-push`) → `ci-run.sh static`. Catches
  cross-plugin conflicts cheaply before a push; the slow device run is *not* in
  the hook.
- **systemd timer** (`priv/systemd/mob-ci.{service,timer}`) → `ci-run.sh sweep 4`
  nightly at 04:30, the low-traffic window. The sweep cooperates with sloppy_joe
  staging via the farm's flock admit ceiling, so it yields when staging is busy.
- **Forgejo/GH (optional)** — not committed. A ~20-line YAML job whose only step
  is `priv/ci-run.sh static` (hosted) or, on a self-hosted runner on this box,
  `device`/`sweep`. The logic stays here; the YAML is disposable.

## Install

```
priv/install-triggers.sh            # wire the hook (core.hooksPath) + install the timer unit
priv/install-triggers.sh --enable   # also enable + start the nightly sweep timer
```

The plain form does **not** start the nightly sweep (it consumes a farm slot). To
enable it later:

```
systemctl --user enable --now mob-ci.timer
loginctl enable-linger "$USER"      # so the timer runs while logged out
systemctl --user list-timers mob-ci.timer
```
