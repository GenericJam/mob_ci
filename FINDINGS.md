# mob_ci findings — bugs the CI surfaced before users hit them

Running log of real defects found by building/exercising the ecosystem. Each is
the kind of thing that previously only surfaced when a user (or an agent) hit it.

## F1 — `mix mob.new_plugin` scaffolds plugins pinned to `mob ~> 0.6`, incompatible with mob 0.7

- **Upstream:** [GenericJam/mob_dev#21](https://github.com/GenericJam/mob_dev/issues/21)
- **Found:** 2026-06-19, first harness build.
- **Where:** `MobDev.Plugin.Scaffold` (mob_dev 0.6.5) emits `mob_version: "~> 0.6"`
  in the manifest and `{:mob, "~> 0.6"}` in `mix.exs` for every tier.
- **Impact:** the current published mob is **0.7.1**. A freshly scaffolded plugin
  fails activation — `Validator.validate_plugin/3` reports `installed :mob 0.7.1
  does not satisfy mob_version "~> 0.6"`, and `mix deps.get` resolves an old mob.
  A user running `mix mob.new_plugin` today gets a plugin that won't build against
  current mob.
- **Fix:** bump the scaffold templates to `~> 0.7` (or derive from the installed
  mob version at scaffold time so this can't lag again).
- **Workaround in mob_ci:** fixtures bumped to `~> 0.7`.

## F2 — `mix mob.new_plugin --tier 2` generates a plugin that does not compile

- **Upstream:** [GenericJam/mob_dev#22](https://github.com/GenericJam/mob_dev/issues/22)
- **Found:** 2026-06-19, first harness build.
- **Where:** `MobDev.Plugin.Scaffold.tier2_lib/2`. The generated `lib/<name>.ex`
  `@moduledoc """ … """` contains an example that nests a `~MOB""" … """`
  heredoc. The inner `"""` **terminates the moduledoc heredoc early**, so the
  prose after it is parsed as code:

  ```
  ** (SyntaxError) unexpected token: "`" (column 16)
     15 │   The matching `MobCiGauge.View` (`use Mob.Component`) owns Elixir-side state.
  ```

- **Impact:** `mix mob.new_plugin --tier 2 <name>` produces a project that fails
  `mix compile` out of the box. Every tier-2 plugin author hits this immediately.
- **Fix:** in `tier2_lib/2`, use `@moduledoc ~S"""…"""` and avoid nesting a `"""`
  heredoc inside it (the fixture inlines the example instead). The scaffold's own
  doc claims "a freshly scaffolded plugin compiles + activates" — tier-2 does not.
- **Workaround in mob_ci:** `fixtures/mob_ci_gauge/lib/mob_ci_gauge.ex` moduledoc
  rewritten to not nest a triple-quote.

## F3 — first-party plugins are inconsistently signed (mob_touch signed, mob_notify not)

- **Found:** 2026-06-20, sloppy_joe realism gate.
- **Where:** the published first-party plugins. `mob_touch` ships signed with the
  release key (`ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=`); `mob_notify`
  is **unsigned** (`mix mob.plugin.sign` never run).
- **Impact:** a host activating both can't satisfy the signature gate with one
  mechanism — signed plugins need `config :mob, :trusted_plugins`, unsigned ones
  need `config :mob, :acknowledge_unsafe_plugins`. A user adding two official
  plugins hits a confusing "one is trusted, the other refuses to build" wall.
- **Fix:** sign all first-party plugins in the release pipeline (or document the
  split). The gate works around it by listing every activated plugin in BOTH
  config keys.
- **Update (2026-06-22, discovery run over the full sloppy_joe set):** the signed
  first-party plugins are **not all signed with the same key**. `mob_touch` and
  `mob_video` share `ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=`, but
  `mob_bluetooth` is signed with a **different** key
  (`ed25519:iIGSryZyTiwFp8a6kUpUd8nIt6Ble3k+pnY6+6AMsZQ=`). Pinning one constant
  fingerprint in `trusted_plugins` trips the gate's **key-rotation** path for the
  odd one out (`{:untrusted, name, actual, trusted}`) — and unlike a missing
  signature, key-rotation is **not** suppressible via `acknowledge_unsafe_plugins`,
  so the build hard-fails. The realism gate only caught this once the full set
  (incl. bluetooth) was activated; the earlier two-plugin gate never hit it.
- **Fix in mob_ci:** `Build.sloppy_joe_mob_exs` now derives each signed plugin's
  real fingerprint from its shipped `priv/mob_plugin.pub` (mirroring
  `MobDev.Plugin.{Verify.load_pubkey, Crypto.fingerprint}`) instead of pinning a
  constant, so multiple keys / future rotations are handled automatically; unsigned
  plugins ship no pubkey, drop out of `trusted_plugins`, and are cleared via
  `acknowledge_unsafe_plugins`.

## F4 — `mob_screencast` has an undeclared hard host_requirement (manifest `<service>`)

- **Found:** 2026-06-22, device_caps discovery run.
- **Where:** `mob_screencast` requires `<service android:name="io.mob.screencast.ScreencastService">`
  in the **host** app's `AndroidManifest.xml`. Without it the **Android build fails**
  (not a runtime degradation) — the plugin can't be activated on an unmodified host.
- **Impact:** activating `mob_screencast` on any host that hasn't hand-edited its
  manifest is an immediate, opaque build failure. There's no scaffold step or
  validator check that surfaces the requirement before the build breaks.
- **Fix:** have the plugin's manifest-merge contribute the `<service>` entry (so it
  composes like other plugins' manifest fragments), or have the validator flag the
  missing host `<service>` with an actionable message.
- **Workaround in mob_ci:** `priv/device_caps.exs` marks `mob_screencast`
  `buildable: false`, so `DeviceCaps.buildable/1` excludes it from auto-discovery
  sets. (sloppy_joe itself ships a `FileProvider`, so camera/photos/video are fine.)

## F5 — `mix mob.deploy` (mob_dev 0.6.12) crashes on a host without `arp`

- **Found:** 2026-06-23, milestone-3 trigger validation (the harness device run).
- **Where:** `MobDev.Discovery.IOS.scan_lan_for_physical/0` runs
  `System.cmd("arp", ["-a"])` to scan the LAN for physical iOS devices. It is
  reached from `MobDev.NativeBuild.narrow_platforms_for_device/3` →
  `Mix.Tasks.Mob.Deploy.run/1` — i.e. on **every** `mix mob.deploy`, including a
  deploy to an explicit **Android** `--device <serial>`. If `arp` (net-tools) is
  not installed/on PATH, `System.cmd` raises `** (ErlangError) :enoent` and the
  whole deploy aborts. (New in 0.6.12; mob_dev was 0.6.5 in the 2026-06-19 runs.)
- **Impact:** a clean Linux host without `net-tools` (common on minimal servers /
  containers) can't `mob.deploy` to Android at all — an opaque `:enoent` from a
  spurious iOS-discovery probe. CI runners and headless build boxes are exactly
  the environments that lack `arp`.
- **Fix (upstream):** guard the `System.cmd("arp", …)` with `System.find_executable`
  (treat a missing `arp` as "no iOS LAN devices found"), and/or skip the iOS LAN
  scan entirely when an explicit Android device serial is given.
- **Workaround in mob_ci:** install `net-tools` on the CI host and ensure `/usr/sbin`
  is on PATH; `priv/ci-run.sh` now prepends `/usr/sbin:/sbin` so the runner finds
  `arp` even under a minimal systemd/git environment.

## F6 — `mix mob.deploy --native --device <x86_64 serial>` (mob_dev 0.6.12) builds the wrong ABI

- **Found:** 2026-06-23, milestone-3 trigger validation (the harness device run,
  once F5's `arp` was installed).
- **Where:** the same `MobDev.NativeBuild.narrow_platforms_for_device/3` as F5.
  Given an explicit **x86_64** redroid serial, the deploy attempts an
  **arm64-v8a** zig native build (`zig build for arm64-v8a exited 1`) instead of
  narrowing to the device's `x86_64` ABI. The identical command
  (`mix mob.deploy --native --device <serial>`) built **x86_64-only** and ran
  green on mob_dev 0.6.5 (2026-06-19, commit history); 0.6.12 regressed it.
- **Cause (confirmed):** the regression is in mob_dev's 0.6.12 platform
  narrowing. The gradle scaffold lists all ABIs (`abiFilters 'arm64-v8a',
  'armeabi-v7a', 'x86_64'`); `narrow_platforms_for_device/3` is supposed to
  restrict the `--native` build to the connected device's ABI. On 0.6.12 it
  fails to narrow (likely the same iOS-LAN-scan path as F5 misclassifying `arp`
  entries as physical arm64 devices), so all ABIs build and arm64-v8a fails.
  **Proven by bisection:** a fresh harness pinned to **mob_dev 0.6.5** narrows to
  x86_64 and goes fully green (P1–P11, 2026-06-23); the only change was the
  mob_dev version.
- **Impact:** even on a correctly provisioned host, `mob.deploy` to an x86_64
  emulator/device can't complete on 0.6.12 — it builds an ABI the device doesn't
  need and fails. Blocks any x86_64-emulator workflow.
- **Fix (upstream):** when an explicit `--device <serial>` is given, narrow to
  THAT device's reported ABI and skip LAN/iOS discovery entirely (it is
  irrelevant to an already-chosen Android target).
- **Workaround in mob_ci:** the SELF-TEST harness (`Build.deps_block`) pins
  `mob_dev == 0.6.5` (`@mob_dev_req`), so `mix ci.device`/`ci.sweep` are
  deterministically green again. The REALISM gate (`host: :sloppy_joe`)
  deliberately stays on the app's live deps, so it still surfaces F5/F6 against
  whatever mob_dev the app pins. Bump `@mob_dev_req` once 0.6.x ships the fix.
