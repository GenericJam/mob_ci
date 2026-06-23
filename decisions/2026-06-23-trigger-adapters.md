# trigger adapters — Layer 5, thin and swappable

- Date: 2026-06-23
- Status: accepted

## Context

The design (`2026-06-19-mob-ci-design.md`) puts the CI logic in this repo (L0–L4)
and treats triggers (L5) as thin, swappable adapters — the lock-in hedge: "the
brain lives in this repo, the YAML (or timer, or hook) is ~20 disposable lines
that just checkout and call `mix ci.device`." Milestones 1–2 built L0–L4 and a
realism gate; the entry points were real but awkward:

- `mix ci.device` (non-`--static`) still printed "the farm layer lands in
  milestone-1" and only ran the static checks — it never grew into the device run
  after the farm landed.
- The device run and the device sweep required a hand-typed distributed-node
  incantation (`elixir --name … --cookie mob_secret -S mix run -e '…'`), because a
  plain Mix task isn't a distributed node and the host must reach the device over
  dist. `mix ci.sweep --runs N` just printed that incantation and exited.

A trigger can't be "20 lines that call `mix ci.device`" if `mix ci.device`
doesn't actually run the catalog.

## Decision

**Make the Mix tasks the real canonical entry points, then layer thin triggers.**

- `MobCi.Dist.ensure!/1` self-starts EPMD + `net_kernel` with the shared
  `mob_secret` cookie. Idempotent — a no-op when already distributed (e.g.
  launched via `elixir --name`). Both device tasks call it, so `mix ci.device`
  and `mix ci.sweep --runs N` work as plain Mix invocations.
- `mix ci.device` default mode now runs the full P1–P11 via `MobCi.Run.run/2`,
  with `--host harness|sloppy_joe` and `--artifacts DIR`. Exit `0`/`1`/`2` =
  pass / invariant failure / orchestration error.
- `mix ci.sweep --runs N` runs the device sweep and exits non-zero if any sampled
  subset fails.
- `priv/ci-run.sh` is the single script every trigger calls: it makes the
  orchestrator runnable from a bare environment (mise toolchain on PATH, UTF-8
  locale, repo cwd, timestamped log, exit-code passthrough).
- Triggers, cheapest first: a **git pre-push hook** runs `ci-run.sh static` (the
  fast gate — the slow device run has no place in a hook); a **systemd user
  timer** runs `ci-run.sh sweep 4` nightly at 04:30 (the low-traffic window).
  Forgejo/GH stays an optional, uncommitted ~20-line YAML that also just calls
  `ci-run.sh`.

## Consequences

- One way in. A trigger is now genuinely disposable: it `cd`s and calls one
  script. Removing systemd or git-hooks changes nothing about CI behaviour.
- No vendor in the path for the default setup — git + systemd are already on the
  box; the farm's flock admit ceiling keeps the nightly sweep polite to the live
  staging pool sharing the machine.
- The timer is installed **disabled** by `install-triggers.sh`; enabling it (and
  `loginctl enable-linger`) is a deliberate, documented step, because each run
  consumes a farm slot.
- Self-distribution is environment-dependent (EPMD reachable, `127.0.0.1`
  longnames). Validated on this box; a different host may need a name/cookie
  override — hence `ensure!/1` takes the node name as an argument.
- Trade-off: exposing `parse_host/2`+`resolve_set/2` as `@doc false` public
  functions to unit-test the set/host resolution, rather than only black-box
  testing the task.

## Validation (2026-06-23)

The plumbing is validated end-to-end: the static gate exits 0 green under a bare
`env -i` environment (no profile, minimal PATH); `ci-run.sh` resolves the mise
toolchain + `arp` + `adb` and writes timestamped logs; the systemd units pass
`systemd-analyze verify`; `install-triggers.sh` wires `core.hooksPath` and the
(disabled) timer; and every device run came up distributed without raising and
mapped its outcome to the right exit code (2 on a build error, with guaranteed
teardown + `mob.exs` restore).

A fully green *device* run was not obtained — not because of the trigger code,
but because standing up CI under a bare environment surfaced fresh upstream
breakage that an interactive shell had masked: **F5** (mob_dev 0.6.12 crashes on
a missing `arp`) and **F6** (with `arp` present, 0.6.12 builds the wrong ABI for
an x86_64 device). The same `MobCi.Run.run/2` path was green as recently as the
2026-06-22 discovery run; the regression is in mob_dev's deploy narrowing. This
is the orchestrator doing its job — catching an ecosystem regression — rather
than a defect in L5. The static gate (what the pre-push hook runs) is unaffected.
