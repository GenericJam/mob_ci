# mob_ci — orchestrator-first device CI for the mob ecosystem

- Date: 2026-06-19
- Status: accepted

## Context

The mob ecosystem ships three core repos (`mob` runtime, `mob_dev` tooling,
`mob_new` generator) plus apps (`sloppy_joe`, `sloppy_joe_server`). Each core
repo has GitHub Actions running on **hosted** runners: `mix test`, format,
credo, security scan, native formatters. None of them have a device. The entire
premise of mob — the BEAM running on-device, `Mob.Test` driving a real app,
`mob.deploy`/`connect`/`push` against real hardware — has **zero CI coverage**.

The plugin system makes this urgent. Plugins were excised from core into ~12
separate repos, each contributing into shared namespaces (NIF modules, screen
routes, component atoms, permissions, migrations, supervised workers,
notification matches). A host activates an arbitrary subset via
`config :mob, :plugins`. That is **2^N activation combinations** — the testing
surface multiplied exactly as core shrank. Static validation
(`MobDev.Plugin.Validator.cross_validate/1`) checks the manifests on paper; it
cannot catch a NIF that links but aborts in `nif_init`, two plugins whose
Kotlin compiles separately but not together, a stale runtime manifest, or a
screen that renders alone but crashes when another plugin's supervisor is up.

This box is the missing half: a redroid emulator farm (`~/code/.redroid-farm`)
already proven to build an x86_64 app, boot it in a container, dial the BEAM in,
and drive it over Erlang distribution. It is also **live**, serving
sloppyjoe.ca's staging pool. CI must share it.

## Decision

Build `mob_ci` as an **orchestrator-first** device-CI system. The orchestrator
is the product; triggers are thin, swappable adapters.

### Layers

```
L5  Triggers (swappable, thin)   local CLI · systemd timer · git hook · GH/Forgejo
L4  Property harness             StreamData over plugin subsets → run → assert → shrink
L3  On-device assertions         host BEAM <-> device node; Mob.Test + RPC probes
L2  Build matrix driver          set config :mob,:plugins → mix mob.deploy --native → APK
L1  Provisioning primitive       lease(profile)->{serial,node} / release (base redroid + test APK)
L0  Farm coordination            shared flock + index space with sloppy_joe staging; CI budget
```

L0–L3 are plain bash + BEAM. They run identically under any trigger or none.
That is what de-risks vendor lock-in: the brain lives in this repo, the YAML
(or timer, or hook) is ~20 disposable lines that just `checkout` and call
`mix ci.device`. Escape hatches, cheapest first: Forgejo/Gitea Actions
(runs the same YAML, self-hostable on this box), a systemd timer / git hook
(no vendor at all), Woodpecker/GitLab.

### Why not lean on GitHub Actions directly

A self-hosted runner still depends on GH's control plane (job dispatch, logs,
status) — if Actions has an outage this box sits idle though it is healthy.
That reintroduces exactly the reliability surface we are wary of, and is out of
step with a box that already self-hosts systemd units, a cloudflared tunnel,
and the farm. So: orchestrator the team owns; GH/Forgejo is one optional
trigger among several.

### The property model (the core technique)

The plugin-combination space cannot be enumerated, so generate it. A StreamData
generator yields a random subset `S` of compatible plugins (× screen profile ×
interaction sequence); each case is built, booted on a leased redroid, and
checked against an invariant catalog. On failure StreamData **shrinks** `S` to
the minimal subset (usually a pair) that reproduces — the bug report writes
itself: "mob_camera + mob_video crash on mount, seed 41723" + logcat/screenshot.

### Invariant catalog (P1–P11)

| # | Invariant | Catches |
|---|---|---|
| P1 | build(S) succeeds **or** fails at validate with a *named* cross-plugin conflict — never a silent linker failure | clobbered routes/atoms/NIF modules past `cross_validate` |
| P2 | for every S, APK installs, BEAM boots, node registers within timeout | dist/boot regressions |
| P3 | each NIF-bearing plugin's `*_nif` module loads on device | static-link / `--whole-archive` trap |
| P4 | each declared/generated screen pushes + renders without crashing the screen process | tier-3 screen breakage in combination |
| P5 | each `ui_components` tag renders (no missing-dispatch crash) | tier-2 native-view dispatch gaps |
| P6 | built APK's merged permissions == set-union of activated plugins' declared perms | over/under-merge |
| P7 | on-device `Mob.Plugins` view == S exactly (no inactive plugin leaks in) | stale `priv/generated/mob_plugins.exs` |
| P8 | tier-3 migrations all applied on device (tables exist) | migration namespace collisions |
| P9 | tier-4 supervised workers alive; `on_start` ran | lifecycle breakage when composed |
| P10 | a random tap/nav sequence across S's screens leaves the BEAM alive | runtime plugin interaction (stateful) |
| P11 | release → ephemeral teardown, slot freed | farm leaks |

### What's not shipped yet → sample plugins

The published plugins only populate NIFs, one DemoScreen each, and permissions.
**Nothing ships `ui_components`, `migrations`, `lifecycle`, `settings`, or
`notifications`.** So P5/P8/P9 have no real subject. We build sample plugins
(tiers 0–4, dogfooding `mix mob.new_plugin`, then fleshed beyond the TODO
stubs) under `fixtures/`, plus a deliberate clash pair, to put weight on every
manifest path *before users do*. These are unpublished — they exist to be
exercised by CI.

### Host under test

- **Sweep**: a minimal generated harness app per combo (fast builds, isolates
  plugin behavior from app behavior, also exercises `mob_new`).
- **Gate**: `sloppy_joe` as a fixed, realistic host (already declares 11
  plugins, x86_64-proven) with activation varied.

### Farm sharing

CI leases through the **same `farm.sh` flock + index space** the sloppy_joe
provisioner uses, so no collision by construction. Admission control on top:
concurrent *boots* are the ceiling (3 saturate the 4 cores; staging runs
warm=1/max=4), so CI holds a small budget, never boots while staging is
mid-boot, backs off when staging is saturated. Heavy sweeps run scheduled in
low-traffic windows; the per-PR gate takes one slot at smoke depth. CI boots a
**base** redroid + installs the freshly built test APK (not the sloppy_joe-baked
image).

### Hardware-dependent plugins

A headless x86_64 redroid has no camera/BT/GPS/biometric. Rather than
pre-classify, the invariant bar is "activating P must not crash the BEAM / must
render / must load its NIF" (graceful degradation). The first baseline sweep
populates a checked-in `device_caps.exs` (plugin → `:emulator_ok |
:hardware_degraded | :expected_skip + reason`); anything that *crashes* instead
of degrading is a real finding, not a flake.

## Consequences

- New repo, sibling to the farm. Depends on `mob_dev` (Validator/Manifest reuse,
  build/deploy tasks) and `stream_data` (the sweep).
- Milestone 1: the full P1–P11 catalog against a fixed sample set, driven by a
  local `mix ci.device`, validated against the live shared farm.
- Milestone 2: the StreamData generator + sweep + `device_caps.exs` baseline.
- Milestone 3: trigger adapters (local timer/hook first; Forgejo/GH optional).
- Risk: native rebuilds are ~minutes; aggressive build caching on this
  persistent box is load-bearing for sweep throughput.
</content>
</invoke>
