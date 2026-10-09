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

- **Resolved:** mob_screencast **0.1.3** (Hex, 2026-10-09). On the `hex` row
  `singleton:mob_screencast` builds, installs and boots on the generated
  `mix mob.new --blank` host with no `<service>` declared, on both the
  `deploy:android` and `release:android` paths; the missing `<service>` is a
  `host_requirements` build warning (capture would throw at first use), and
  `MobScreencast.SelfTest` skips naming it (P12 skip, `~/mob_ci_logs/caps1.log`
  on the NUC). `device_caps.exs` no longer marks it `buildable: false`, so it is
  back in `all`, the pairwise array and `demo`.
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
- **Workaround in mob_ci (removed 2026-10-09):** `priv/device_caps.exs` marked
  `mob_screencast` `buildable: false`, so `DeviceCaps.buildable/1` excluded it from
  auto-discovery sets. (sloppy_joe itself ships a `FileProvider`, so camera/photos/video are fine.)

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

  **Update (2026-10-08, MOB-412):** the self-test harness now uses *path deps on
  the ecosystem's mob + mob_dev checkouts* (`Build.core_deps/1`, the `master`
  row), so this pin is gone; `mix mob.deploy --native --device <x86_64 serial>`
  on mob_dev 0.7.16 narrows correctly (see `docs/budgets.md`, harness baseline).

## F7 — sloppy_joe master commits machine-absolute path deps

- **Upstream:** [MOB-420](https://linear.app/mobframework/issue/MOB-420) → fixed by
  [GenericJam/sloppy_joe#20](https://github.com/GenericJam/sloppy_joe/pull/20).
- **Found:** 2026-10-08, first realism-gate run after the revival.
- **Where:** `sloppy_joe/mix.exs` declares `{:mob_dev, path: "/Users/kevin/code/mob_dev"}`
  and `{:mob_wake, path: "/Users/kevin/code/mob_wake"}`.
- **Impact:** on any machine but one, `mix deps.get` stops with
  `* mob_wake (/Users/kevin/code/mob_wake) the dependency is not available`. The
  app that is supposed to be "the realistic host" could not be prepared at all on
  the CI box.
- **Fix:** Hex deps (`mob_dev ~> 0.7.16` supports mob 0.9; `mob_wake 0.1.1` is
  published and v2-signed), in #20.
- **Workaround in mob_ci:** `Build.prepare_sloppy_joe/1` rewrites any absolute
  `path:` that doesn't exist here to the sibling under `~/code` for the duration
  of the run (`Build.relocate_path_deps/3`), restoring `mix.exs` on cleanup.

## F8 — sloppy_joe master locks v1-signed plugin releases its own mob_dev refuses

- **Upstream:** [MOB-420](https://linear.app/mobframework/issue/MOB-420) → fixed by
  [GenericJam/sloppy_joe#20](https://github.com/GenericJam/sloppy_joe/pull/20).
- **Found:** 2026-10-08, realism gate (`mix ci.device --host sloppy_joe`, log
  `~/mob_ci_logs/realism4.log`, attributed `build:/home/kevin/code/sloppy_joe`).
- **Where:** `sloppy_joe/mix.lock` pins mob_biometric 0.1.4, mob_bluetooth 0.3.0,
  mob_camera 0.1.8, mob_location 0.1.3, mob_notify 0.1.2, mob_photos 0.1.2,
  mob_scanner 0.1.2, mob_screencast 0.1.1, mob_video 0.1.0, mob_touch 0.1.0 — every
  one a **v1 signature envelope**. mob_dev ≥ 0.7.4 (MOB-287, and the path dep at
  master) refuses v1:

  ```
  ** (Mix) plugin signature check failed — refusing to build
    - plugin :mob_biometric ships a legacy v1 signature, which mob_dev does not accept.
  ```

- **Impact:** the Android native build of sloppy_joe master cannot start; a user
  cloning master hits the same wall. Note also that before the gate fires the
  deploy prints `runtime plugin manifest (0 screens, …)` — failed-verification
  plugins are silently dropped from the manifest regen, so a partially-refused set
  would ship a host with *fewer* screens than activated. The gate catches it today
  because it refuses the whole build; worth a loud per-plugin line in that regen.
- **Fix:** lock the re-signed releases (MOB-287/MOB-336): #20 does
  `mix deps.update` within the existing constraints; `verify_plugin/1` → `:ok` for
  all 11.
- **Workaround in mob_ci:** none — the realism gate reports the app as it is;
  `Build.classify_failure/1` names the cause (`{:signature_gate, [per-plugin lines]}`)
  so the report says *which* plugins are v1 instead of "native build failed".

## F9 — `mob_bluetooth` + `mob_midi` both declare `NSBluetoothAlwaysUsageDescription` (differing values) — resolved

- **Upstream:** [MOB-421](https://linear.app/mobframework/issue/MOB-421) → fixed by
  [GenericJam/mob_dev#130](https://github.com/GenericJam/mob_dev/pull/130), released
  in **mob_dev 0.7.19** (with mob_bluetooth 0.5.0, mob_midi 0.2.0 unchanged).
- **Found:** 2026-10-08, static sweep over the `all` set (MOB-413); shrinks to
  `[:mob_bluetooth, :mob_midi]`.
- **Where:** `mob_bluetooth/priv/mob_plugin.exs` (`"Bluetooth access is required to
  discover and advertise to nearby devices."`) and `mob_midi/priv/mob_plugin.exs`
  (`"Bluetooth access is required to connect to wireless (BLE) MIDI devices."`) —
  the same iOS plist key with different strings, so
  `MobDev.Plugin.Validator.cross_validate/2` reports a collision.
- **Impact:** a host activating both (any app with BLE MIDI *and* general BLE) is
  rejected at validate with a plugin-vs-plugin conflict it cannot resolve by
  configuration — unless the author knows about the MOB-387 host exemption and sets
  the key in `ios/Info.plist` themselves.
- **Fix:** a usage description is the permission prompt, and an app using both
  plugins needs Bluetooth for both reasons. mob_dev 0.7.19 combines a
  `*UsageDescription` every declaring plugin gives as a string (distinct sentences in
  activation order: "…to nearby devices. …(BLE) MIDI devices.") instead of
  colliding, prints which plugins it combined, and the host's `ios/Info.plist` value
  still wins. Other Info.plist keys two plugins declare still collide (mob_dev ADR
  `decisions/2026-10-09-plugin-usage-descriptions-combine.md`; plugin guide
  GenericJam/mob#199).
- **Verified:** 2026-10-09 on the NUC, `mix ci.device --static --set all --versions
  master` (mob_dev 0.7.19 @ 85cb423, mob_bluetooth 0.5.0, mob_midi 0.2.0; 22 plugins,
  run 97): `conflicts: none`, "Static gate: set composes cleanly." Same on the hex
  row (`--versions hex`: mob_dev 0.7.19, mob_bluetooth 0.5.0, mob_midi 0.2.0 from
  Hex; run 101).
- **Workaround in mob_ci:** removed — `priv/sets/exclusions.exs` no longer parks
  `mob_midi`; `all` and the pairwise rows include it again.

## F10 — `mob_background` does not build on an unmodified host (bridge references a class the plugin doesn't ship)

- **Resolved:** mob_background **0.2.0** (Hex, 2026-10-09) ships
  `BeamForegroundService.kt` via `bridge_kt` and contributes its `<service>` via
  `manifest_application_snippets`. On the `hex` row `singleton:mob_background`
  builds on the `--blank` host and `MobBackground.SelfTest` passes on both
  `deploy:android` and `release:android` (`~/mob_ci_logs/caps1.log` on the
  NUC); `device_caps.exs` no longer marks it `buildable: false`.
- **Upstream:** [MOB-423](https://linear.app/mobframework/issue/MOB-423).
- **Found:** 2026-10-08, harness discovery over the 15 plugins sloppy_joe doesn't
  carry (`~/mob_ci_logs/disco2.log`, attributed `build:<harness>`).
- **Where:** `mob_background`'s Android bridge, copied into the host as
  `android/app/src/main/java/io/mob/background/MobBackgroundBridge.kt`, references
  `BeamForegroundService` (lines 39/40/52/53: `Unresolved reference`). The class is
  not part of the plugin's shipped Kotlin; the manifest's `host_requirements` only
  says the host must declare the `<service>` in `AndroidManifest.xml`.
- **Impact:** activating `mob_background` on a `mix mob.new --blank` host (or any
  host that followed the requirement literally) is an opaque Kotlin compilation
  failure, not a warning — the same shape as F4 for mob_screencast in June.
- **Fix:** ship `BeamForegroundService` in the plugin's Kotlin (and contribute the
  `<service>` via manifest merge), or document the class the host must provide
  and have the validator check for it.
- **Workaround in mob_ci (removed 2026-10-09):** `priv/device_caps.exs` marked it
  `buildable: false`; `nx_eigen` still is (arm-only, F-less: a documented platform
  limit, see `docs/budgets.md`).

## F11 — `mix mob.release --ios` leaves its ~90 MB build dir in the user temp dir

- **Upstream:** [MOB-425](https://linear.app/mobframework/issue/MOB-425).
- **Found:** 2026-10-09, first `release:ios` cell of the iOS lane (MOB-415) on the
  Mac mini: after teardown, a 92 MB `$TMPDIR/tmp.Wm8qifonVw/` holding
  `CiDefaultHex.app`, the linked binary and the `.o` files remained.
- **Where:** mob_dev 0.7.17 `ios/release_device.sh` (`MobDev.Release`):
  `BUILD_DIR=$(mktemp -d)` is never removed (`BUILD_DIR_TMP` and `IPA_STAGE`
  are). macOS `mktemp -d` without a template ignores `TMPDIR` and uses
  `DARWIN_USER_TEMP_DIR`, so a caller cannot redirect it.
- **Impact:** every iOS release leaks ~90 MB on a Mac that has single-digit GB
  free and is shared by several agents.
- **Fix:** `trap 'rm -rf "$BUILD_DIR"' EXIT`, and `mktemp -d
  "${TMPDIR:-/tmp}/mob_release.XXXXXX"` for the script's scratch dirs.
- **Workaround in mob_ci:** the iOS worker's teardown deletes
  `$(getconf DARWIN_USER_TEMP_DIR)/tmp.*` dirs that hold the cell's own
  `Ci<App>.app` (`MobCi.Lane.Ios.Worker.app_state_dirs/3`); nothing else there
  is touched.

## F12 — a wired iPhone's node is unreachable: no USB IP from ARP on macOS 27, node named after an off-LAN WiFi IP

- **Upstream:** [MOB-428](https://linear.app/mobframework/issue/MOB-428);
  GenericJam/mob_dev#128, GenericJam/mob_dev#129, GenericJam/mob#197
  (mob_dev 0.7.18, mob 0.9.16).
- **Found:** 2026-10-09, `deploy:ios_device` on Kevin's iPhone SE (iOS 26.5.2,
  USB) from the Mac mini (macOS 27.0.1): build, sign and install passed, P2
  failed at `boot` with `device usb ip: no device USB IP in ARP`. Reproduced by
  hand on a blank host (`mix mob.deploy --native --ios --device <udid>`, then
  the Connector), so mob_dev, not the lane.
- **Where:** two causes, one behind the other.
  1. mob_dev's `MobDev.Tunnel` read the phone's link-local address from `arp
     -a`. On macOS 27.0.1, `arp` spawned from the BEAM (or Python) prints an
     empty table and exits 0, while a shell — local or over ssh — lists
     `169.254.1.100 on en11`; TCP and mDNS to the phone work from the BEAM.
  2. With the address found, the connect timed out: mob's `mob_beam.m` names a
     device node after its WiFi IP first, and the phone's WiFi
     (`192.168.0.185`, from the app's `mob_diag_host_ip.txt`) is a network the
     Mac can't route to.
- **Fix:** mob_dev resolves the link-local address from the phone's own mDNS
  name (devicectl's `<name>.coredevice.local` for that UDID → `<name>.local`)
  and relaunches with `DEVICECTL_CHILD_MOB_NODE_HOST`: the phone's WiFi IP when
  the Mac reaches it, else the link-local IP; mob takes `MOB_NODE_HOST` when it
  is one of the phone's own IPv4s. Verified: the `hex` row (mob 0.9.16, mob_dev
  0.7.18) passes `deploy:ios_device` for `default` and the hardware singletons,
  nodes `…@169.254.1.100`.
- **Impact on the matrix:** iPhone cells on rows before mob 0.9.16 / mob_dev
  0.7.18 stay `fail @ boot` on this Mac while the phone's WiFi is off-LAN.

## F13 — mob_dev's Android deploy races the adbd restart its own `adb root` causes — resolved

- **Upstream:** [MOB-459](https://linear.app/mobframework/issue/MOB-459).
- **Found:** 2026-10-09 08:36 MDT, queue job 1, cell 7 (`singleton:mob_camera`
  × `master`, run 38): the deploy path errored after `BUILD SUCCESSFUL` with
  `✗ Android native build failed: Selected Android device(s) disconnected:
  127.0.0.1:5700` (`~/mob_ci_logs/queue/cell-7/deploy.log` line 208) and was
  recorded as `build:deploy:android` — a plugin build failure it wasn't.
- **Where:** mob_dev `NativeBuild.fix_erts_helper_labels/2` runs `adb root`
  after the APK install; on redroid that restarts adbd every time (the box's
  kernel log shows `init: Service 'adbd' … exited with status 1` → `starting
  service 'adbd'` once per deploy, 67 times that day). mob_dev sleeps a fixed
  800 ms and goes on; `push_otp_release_android/6` then runs `adb devices` and
  errors when the serial isn't listed. At 08:36:42 adbd went down at .256 (adb
  server: `connection terminated: read failed`), mob_dev raised at .298, adb's
  reconnect was still refused at .770; mob_ci's teardown removed the
  container at .393 (`docker events`: create 08:33:05, kill 08:36:42.39).
- **Not capacity in the memory sense:** no OOM or low-memory kill in the
  kernel log, 5 GB available of 15, one CI instance on the box (`docker
  events`: only `ci-redroid0`, plus staging's `redroid0`). The box is
  CPU-saturated while a cell builds (load 9–11 on 4 cores: gradle + zig + the
  lanes' and poller's BEAMs), which is what stretches the adbd restart past
  mob_dev's 800 ms. The queue already runs one Android cell at a time and the
  farm admit ceiling stays at 5; lowering either would not close a race whose
  window is a fixed sleep.
- **Fix (mob_dev):** after `adb root` answers `restarting adbd as root`, `adb
  -s <serial> wait-for-device` (bounded) instead of sleeping, there and before
  the OTP push.
- **In mob_ci:** a build, install or launch whose output says the device went
  away (`MobCi.Farm.lost_device?/1`), or any path after which `ci-farm.sh
  alive` finds the container stopped or adb without the device, is layer
  `farm`, not `build:*`/`boot`/the plugin; `mix ci.device` exits 3 and the
  trigger queue reruns the cell once on a fresh instance; the report never
  counts a `farm` cell as a regression (`decisions/2026-10-09-trigger-queue.md`).
- **Resolved:** mob_dev **0.7.22** (Hex, 2026-10-09; PR GenericJam/mob_dev#133).
  `MobDev.AdbRoot.root/2` replaces every fixed sleep after `adb root`
  (NativeBuild's ERTS relabel and OTP push, the Deployer's beams/priv/exqlite/
  dist pushes, `mob.battery_bench_android`): it waits with `adb -s <serial>
  wait-for-device` plus a `getprop sys.boot_completed; id -u` round trip until
  the new adbd answers as uid 0 (the old one still answered for ~50 ms on an
  emulator), bounded at 30 s (`MOB_ADB_RESTART_TIMEOUT_MS`), and fails naming
  the serial. On emulator-5554 the restart took 0.6–2.7 s, past the old 800 ms.
  Farm: two `singleton:mob_camera` × `rc:mob_dev@39005a3` deploy cells back to
  back on the NUC (load 3.8–5) both 9 passed / 0 errored, no lost device.

## F14 — a killed Android cell leaked its `ci-redroid` instance (mob_ci's own) — resolved

- **Issue:** [MOB-467](https://linear.app/mobframework/issue/MOB-467) (the
  Android twin of MOB-466).
- **Found:** 2026-10-09: with no Android cell running, `ci-redroid0`, `1` and
  `2` had been up from 15 min to 5 h, left by cells killed mid-run on purpose
  (farm-retry tests, a stale rc run); released by hand with `ci-farm.sh down`.
  Each held one of the 5 admission slots the farm shares with sloppy_joe
  staging, and about 1 GB. Reproduced the same afternoon: `ci-run.sh pause
  android` (a `systemctl stop`, SIGTERM) during job 25's cell left
  `ci-redroid0` up after the lane worker was gone.
- **Where:** `MobCi.Run` releases in `after` blocks, which run only for exits
  the cell's own process sees. SIGKILL, a reboot, and SIGTERM (the VM's
  default handler stops it without unwinding the Mix task) skip them, and
  nothing else knew the instance belonged to a dead cell.
- **Fix (mob_ci):** an ownership record per instance, written by `ci-farm.sh
  boot` (owner pid + start time, run, job, cell, boot time); a SIGTERM trap in
  the cell's BEAM (`ci-farm.sh down-owned`); and `ci-farm.sh reap`, run before
  every Android cell and after every poll cycle, which downs instances whose
  owner is dead and record-less ones older than 20 min, and nothing else.
  `ci-farm.sh status` names each owner. Design: the addendum in
  `decisions/2026-06-19-mob-ci-design.md` ("Farm sharing").
- **Verified on the NUC:** `mix ci.device --set blank --versions hex` killed
  with `kill -9` 51 s into `mix mob.deploy`: `status` showed `ci-redroid1 …
  owner: pid 511999 DEAD, run 1`, `reap` printed `down ci-redroid1: owner pid
  511999 DEAD` and admission went from 3/5 to 2/5. The same cell stopped with
  `systemctl --user stop` (SIGTERM) released its instance within a second
  (`SIGTERM received - shutting down`, no `ci-redroid1` left).

## F15 — mob_dev's "stale lock" cleanup crashed every concurrent Gradle JVM (SIGSEGV in ld-linux) — resolved

- **Issue:** [MOB-468](https://linear.app/mobframework/issue/MOB-468).
- **Found:** 2026-10-09: cells 23, 25 (`singleton:mob_touch`,
  `singleton:mob_vision` on master, `bundleRelease`) and 105
  (`singleton:mob_scene3d`, `assembleDebug`) died with the Gradle wrapper JVM
  at `SIGSEGV pc=0x2400`, frame `C [ld-linux-x86-64.so.2+0x10f2]`
  (Temurin-21.0.11+10), stored as `build:release:android` / `build:deploy:android`.
- **What the hs_err files say** (copies in `~/mob_ci_logs/mob-468/` on the
  NUC): every crash comes as a pair, 2 s apart. The Gradle daemon dies first,
  in native-platform JNI code (`PosixFileFunctions.stat`,
  `PosixProcessFunctions.getPid`) jumping to a tiny address (0x2246, 0x20a6);
  then the wrapper's VM thread dies in `exit()` → `_dl_fini` (libc+0x47a76 →
  ld.so+0x5578 → +0x10f2), running the destructors of the same library. Both
  map `~/.gradle/native/68d5…/linux-amd64/libnative-platform.so`, inode
  21265349, whose mtime was *today*: the mapped file had been rewritten in
  place, under running JVMs.
- **Cause:** mob_dev's `clear_stale_gradle_locks/0`, run before every
  `assembleDebug`, deleted `~/.gradle/native/**/*.lock`. native-platform's
  `NativeLibraryLocator` holds that lock only while it extracts, and its one
  byte says the extraction finished; with the file gone, the next Gradle JVM
  (any project's: a wrapper client is enough) truncates and rewrites the `.so`
  over the same inode, and every JVM that has it mapped crashes at its next
  call into it, or at exit. A plain `./gradlew --no-daemon help` does not touch
  the file; a `mix mob.deploy` (or a cell's deploy path) beside a running
  build does. The NUC runs such builds side by side: hand runs and agents'
  deploys beside the queue's lane. Which build rewrote the file at 10:40 and
  12:29 is not recorded (wrapper clients leave no log); no other mob_ci cell
  was running then.
- **Reproduced on the NUC** (`/tmp/jvmcrash-repro.sh`, android lane paused):
  build A `./gradlew --no-daemon assembleDebug --rerun-tasks` in one host; 20 s
  in, three times: delete `~/.gradle/native/**/*.lock`, run `./gradlew
  --no-daemon help` in another host. A crashed **3/3**, same frame
  (`SIGSEGV pc=0x2400`, `ld-linux-x86-64.so.2+0x10f2`). Without the deletion,
  the same loop: **0/3**.
- **Ruled out:** the JDK (Temurin 21.0.11 from mise, CDS sharing on; nothing
  Temurin-specific in the stacks), `LD_PRELOAD` (unset, no
  `/etc/ld.so.preload`), glibc (Pop!_OS 24.04, glibc 2.39; the faulting code
  is ld.so running a corrupted library's destructors), memory pressure
  (3.4–4.3 GB available at each crash, no OOM kill in the kernel log; load
  average 6–9 on 4 cores widens the window, it isn't the cause). `--no-daemon` (mob_dev 0.7.20+) is
  not the cause; it only means every build starts two fresh JVMs that map the
  library, where a warm daemon would have mapped it once.
- **Fix (mob_dev):** keep the native-platform locks (GenericJam/mob_dev#134).
  The wrapper, daemon-registry and cache locks mob_dev still deletes are real
  OS locks, and deleting one another Gradle holds breaks its exclusion
  (MOB-469).
- **Fix (mob_ci):** a JVM fatal error in a build's output (`A fatal error has
  been detected by the Java Runtime Environment`, or an `hs_err_pid<N>.log`
  path; read from the whole output, not mob_ci's 800-char tail, and kept as
  `{:jvm_crash, lines}`) is layer `toolchain`, an infra layer like
  `farm`: exit 3, one retry, shown in the report, never a regression, a
  baseline or the P12 singleton result.
