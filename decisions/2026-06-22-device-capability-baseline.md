# device-capability baseline — per-plugin expectations for a headless emulator

- Date: 2026-06-22
- Status: accepted

## Context

The realism gate (`MobCi.Run.run(set, host: :sloppy_joe)`) builds the real app
with a plugin subset activated and runs the P1–P11 catalog on a headless x86_64
ci-redroid. That emulator has **no camera, GPS, biometric, or BT hardware**. Two
invariants need a per-plugin notion of "what counts as correct here", because a
flat rule is wrong for hardware plugins:

- **P3 (every activated NIF loads)** — `Probe.module_loaded?` only proves the
  Erlang stub loaded. A NIF whose `.so` failed to link, or that aborts in
  `nif_init`, would still report "loaded". To prove the native code actually
  *initialized* we must call into it — but the obvious exports (`*_start`,
  `authenticate`, `scan`) touch hardware / pop UI.
- **P4 (every screen renders)** — a hardware plugin's DemoScreen *might* fail to
  mount with no device behind it. A graceful "no device" empty state is fine; a
  BEAM crash is a real finding. A flat "must render" rule would false-fail the
  former; a flat "may fail" rule would miss the latter.

## Decision

A data table, `priv/device_caps.exs` (`MobCi.DeviceCaps`), records per plugin:

- `:nif` — the Erlang NIF module (for P3 load + init checks).
- `:probe` — a **safe, side-effect-free** export `{fun, args}` that still runs
  native code (idempotent `*_stop`/`*_cancel` no-ops), so P3 can confirm init
  without touching hardware. `nil` when a plugin exports only UI/hardware-
  triggering functions — P3 then confirms load but **skips** the init check
  (honest, not a failure).
- `:screen` — `:emulator_ok` (must render), `:hardware_degraded` (graceful
  non-render is a skip, a crash is a finding), or `nil` (no DemoScreen).
- `:buildable` — `false` for a plugin with a hard host_requirement the CI host
  can't satisfy (mob_screencast's manifest `<service>`, see FINDINGS F4);
  `DeviceCaps.buildable/1` filters it out of auto-discovery sets.

The table is **refined by a discovery run**, not guessed. `scripts/discovery.exs`
runs the full buildable sloppy_joe set through the catalog and prints per-result
detail; the `:screen`/`:probe` fields are set to match what the emulator actually
does. The 2026-06-22 discovery run surfaced two real bugs (see Consequences) and
came back fully green (P1–P11: 8 pass, 3 honest skips).

## Consequences

- P3 turns from "loaded, unconfirmed → skip" into a real pass for plugins with a
  safe probe (bluetooth/camera/location/notify/video/touch all confirmed
  *initialized*); biometric/photos/scanner honestly skip the init check (UI-only,
  no safe export).
- The discovery run is the validation mechanism, so the table can't silently rot
  into fiction — re-running it re-checks every expectation against the device.
- Observed > hypothesized: every screen-bearing plugin rendered gracefully on the
  headless redroid, so the table holds them all to the stronger `:emulator_ok`.
  The `:hardware_degraded` escape hatch stays in `Invariants.degrade_or_fail` (and
  is unit-tested via explicit caps) for a screen that genuinely can't render
  without hardware.
- Two upstream bugs the discovery run caught: **F3 update** — first-party plugins
  are signed with *different* keys (a single pinned trust fingerprint trips the
  gate's non-suppressible key-rotation path), so `Build.sloppy_joe_mob_exs` now
  derives each plugin's real fingerprint from its shipped pubkey; **F4** —
  mob_screencast's undeclared host `<service>` requirement is a hard build failure
  (marked `buildable: false`).

## Addendum 2026-10-09 — refreshed against the self-test releases (MOB-418)

All 24 published plugins now ship a `Mob.Plugin.SelfTest` (Hex, 2026-10-09),
which P12 runs, so `device_caps.exs` keeps only what a plugin can't say about
itself:

- `:probe` is the read-only export the plugin's own self-test calls where one
  exists (`scanner_available/0`, `biometric_availability/0`, `sms_available/0`
  are new; mob_background's `background_status/0` replaces `background_stop/0`,
  which starts the service to stop it). Existing read-only probes that also
  work on older releases stay. A host can
  lock a release older than the export (sloppy_joe locks mob_biometric 0.1.5
  and mob_scanner 0.1.5), so `Probe.nif_initialized?/3` reports `:no_export`
  when the probe function itself is undefined, and P3 records a skip for it,
  the same as a plugin with no probe. An `undef` raised deeper in the call
  stays an error.
- `buildable: false` is gone for mob_screencast (F4, 0.1.3) and
  mob_background (F10, 0.2.0). Both `singleton:<p>` cells on the `hex` row
  built and ran on the generated `--blank` host. Only mob_nx_eigen (arm-only
  NIF) is still marked unbuildable.
