# mob_ci budgets — timings, disk, ABI (NUC farm, 2026-10-08)

Measured on the NUC (4 cores, 15 GB, redroid 13 x86_64 farm shared with
sloppy_joe staging) against **mob 0.9.14 / mob_dev 0.7.16 / mob_new 0.6.7**
(the `master` row: the harness uses path deps on `~/code/{mob,mob_dev}`) with
zig 0.17.0-dev.269+ebff43698. Every `mix ci.device` run writes its own
`timings.json` next to `junit.xml` (`MobCi.Run.timings/0`); the numbers below
are from `~/mob_ci_logs/*.log` on the NUC. Baseline: MOB-412.

## Per-step durations

| step | harness (fixtures, 5 plugins) | sloppy_joe (10 Hex plugins + mob_wake) | what it is |
|---|---|---|---|
| prepare | 77 s cold (`mob.new --blank` + deps.get + mob.icon), 0.02 s warm | 2.5–4.6 s (mob.exs/mix.exs swap + `deps.get`) | host app ready to build |
| boot | 11–12 s | 11–12 s | `ci-farm.sh boot`: docker run + adb connect + boot_completed |
| deploy | **358 s cold**, 97 s warm | **181 s cold** (first build after the lock bump), 47–48 s warm | `mix mob.deploy --native --device`: Elixir compile + zig per-ABI + gradle + install + OTP push |
| launch | 7–9 s | 9 s | relaunch with the CI node identity, wait for dist registration |
| probe (P2–P10) | 0.4 s | 0.8–1.0 s | the catalog over `:erpc` |
| release | 0.9 s (+0.03 s P11) | 0.8 s | `docker rm -f`, adb disconnect |
| **total wall** | **8.5 min cold, 118 s warm** | **4.5 min cold, 74–75 s warm** | `mix ci.device` end to end |

"Cold" = fresh harness dir or changed deps (no `_build`, no gradle/zig cache);
"warm" = same host dir, same deps, only `mob.exs`/showcase rewritten. The cold
numbers include the one-off Elixir compile of every dep; a nightly that keeps
the host dirs (`fixtures/_harness/<app>`, sloppy_joe's `_build`) runs at the
warm figures. Two runs on the box at once roughly double the deploy step
(builds contend for the 4 cores); run cells sequentially.

Budget rule of thumb for planning the nightly matrix: **~2 min per warm
cell, ~5–9 min per cold cell, plus ~3 min when the Hex lock changes**.

## Disk

| item | size | notes |
|---|---|---|
| `fixtures/_harness/mob_ci_harness` (built, warm) | 739 MB | `_build` + `deps` + gradle outputs; one per harness app name |
| `~/code/sloppy_joe` (built) | 2.1 GB | the realism host, built in place |
| `redroid/redroid:13.0.0_64only-latest` | 2.29 GB | the base image every CI instance boots |
| `~/.mob/cache/otp-android{,-arm32,-x86_64}-5c9c69fc` | shared with staging | the OTP runtime pushed to devices |
| free on `/` | 353 GB of 449 GB | no pressure |

A ci-redroid container adds ~1 GB while alive and is removed on release
(P11); none leaked across the runs above.

## Which ABI the farm exercises

`redroid/redroid:13.0.0_64only-latest` on this NUC is an **x86_64** image
(`docker image inspect … Architecture: amd64`, `uname -m` = x86_64; the
device reports `ro.product.cpu.abilist` = x86_64 only). There is no arm64
redroid lane: running an arm64 Android image on an x86_64 host needs
binfmt/QEMU user emulation that redroid does not support for a full system
image, and the box has no arm64 hardware.

Consequences:

- `mix mob.deploy --native --device <serial>` narrows the zig/gradle build to
  the device's ABI (F6 is fixed in mob_dev 0.7.16: the harness and sloppy_joe
  both built x86_64 only), so the farm **proves x86_64 native code and the
  x86_64 OTP runtime**, nothing else.
- Plugins whose NIFs ship **arm-only** entries are not exercised here:
  `mob_nx_eigen` (mob_dev installs its OTP lib for arm64-v8a/armeabi-v7a only,
  `native_build.ex` "NxEigen only ships 32/64-bit ARM builds"; its Elixir dep
  also failed to compile in the harness, see `~/mob_ci_logs/disco1.log`) is
  `buildable: false` in `priv/device_caps.exs`. Any NIF whose `mob.exs`
  `:archs` is `[:android_arm64]` only (mob_dev `arm_only/2`) is simply absent
  from an x86_64 build and P3 cannot see it.
- arm64 coverage comes from the Mac lane (MOB-415: iOS simulators are arm64,
  and the Android emulators on the Mac are arm64) and from physical phones;
  `COMPATIBILITY.md` must state the ABI per cell. The release path
  (`mix mob.release --android`) builds all three ABIs on the NUC — that cell
  proves arm64 *compiles*, not that it runs.

## MOB-378 (stale SELinux MCS label on redeploy to a rooted emulator)

Reproduction attempt on the farm: `mix ci.sweep --runs 4` deploys several
plugin subsets **to the same ci-redroid instance** (`Sweep.run_one/3`:
activate → `mob.deploy --native --device` → launch, repeated), i.e. a
redeploy over an existing `files/otp` as root; the 2026-06-23 sweep and the
2026-10-08 runs below redeploy the same way. See the sweep result recorded
in the MOB-412 Linear comment / `~/mob_ci_logs/sweep2.log` for whether
`OTP runtime missing on device` / `erl_child_setup failed` appeared. mob_dev
0.7.16 already runs `fix_erts_helper_labels/2` (chcon of the ERTS helper
`.so` files to `apk_data_file` on rooted builds) after install; redroid 13
is Android 13, while MOB-378 was filed against an Android 15 emulator where
the streaming installer relabels — so a clean sweep here rules it out for
the farm's Android version, not for Android 15.
