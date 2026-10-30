# mob_ci matrix

## Lane health

- **Android lane (redroid farm, NUC)**: up
- **iOS lane (Mac mini)**: down since 2026-10-30 05:17Z, `error:worker` on deploy:ios_device

The latest result of every cell mob_ci has run, per version row: one
line per plugin set, one column per build path. Generated from the
mob_ci results store by `mix ci.report --publish`; do not edit. Verified
version combinations are in [COMPATIBILITY.md](COMPATIBILITY.md).

`✓ pass` · `✗ fail @ layer` · `! error @ layer` (the run could not
finish: build, boot, or an infrastructure layer: `farm`, `toolchain`,
the Mac worker's `error:disk` / `error:ssh` / `error:worker`) · `– skip`
· `·` never ran. A lane is down when its last cells of a path all
stopped at an infrastructure layer, or a nightly ran none of its cells
there. Layers are described in mob_ci's
`decisions/2026-06-19-mob-ci-design.md`.

## hex

Latest run 2026-10-30T06:27:39Z. Core versions in this grid: mob 0.9.27 · mob_dev 0.7.31 · mob_new 0.6.17; mob 0.9.17 · mob_dev 0.7.23 · mob_new 0.6.9; mob 0.9.17 · mob_dev 0.7.21 · mob_new 0.6.8; mob 0.9.17 · mob_dev 0.7.20 · mob_new 0.6.8.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | deploy:android_physical | release:ios |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `blank` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `default` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `all` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass | ✓ pass |
| `demo` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `selftest_pilots` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `singleton:mob_ash` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_audio_capture` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_background` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_biometric` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_bluetooth` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_camera` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_deliver` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_location` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_midi` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_mishka` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_nfc` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_notify` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_photos` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_scanner` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_scene3d` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `singleton:mob_screencast` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `singleton:mob_sensors` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass | ✓ pass |
| `singleton:mob_sms` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `singleton:mob_speech` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass | ✓ pass |
| `singleton:mob_touch` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `singleton:mob_video` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `singleton:mob_vision` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `singleton:mob_wake` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |
| `singleton:mob_whisper` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | · | ✓ pass |

86 pass, 0 fail, 72 error, 0 skip.

## master

Latest run 2026-10-30T09:03:15Z. Core versions in this grid: mob 0.9.27 (git 66fe71c) · mob_dev 0.7.31 (git 0f67685) · mob_new 0.6.17 (git a8a3b38); mob 0.9.25 (git 49daaf1) · mob_dev 0.7.30 (git cc03ceb) · mob_new 0.6.16 (git f05f627); mob 0.9.24 (git 6526769) · mob_dev 0.7.29 (git f179e66) · mob_new 0.6.15 (git f9a20ba); mob 0.9.24 (git 6526769) · mob_dev 0.7.29 (git f179e66) · mob_new 0.6.14 (git b0de51f); mob 0.9.21 (git d25090b) · mob_dev 0.7.29 (git f179e66) · mob_new 0.6.13 (git 53702ba); mob 0.9.19 (git c3cabf4) · mob_dev 0.7.26 (git 36045e7) · mob_new 0.6.11 (git ba277b1); mob 0.9.17 (git 5d85492) · mob_dev 0.7.23 (git 6efa92b) · mob_new 0.6.9 (git d03e4a3); mob 0.9.17 (git 5d85492) · mob_dev 0.7.23 (git 8091656) · mob_new 0.6.9 (git d03e4a3); mob 0.9.17 (git 5d85492) · mob_dev 0.7.21 (git 04feb5b) · mob_new 0.6.8 (git 1dc6ac2); mob 0.9.15 (git 19ca6e1) · mob_dev 0.7.17 (git 4e63c0d) · mob_new 0.6.7 (git 213ed49).

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `blank` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `default` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `all` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass |
| `demo` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass |
| `pairwise:1` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:10` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:2` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:3` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:4` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:5` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:6` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:7` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:8` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `pairwise:9` | · | ! error @ `build:deploy:android` | · | ✓ pass | · | · |
| `selftest_pilots` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_ash` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_audio_capture` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_background` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_biometric` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_bluetooth` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_camera` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_deliver` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_location` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_midi` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_mishka` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_nfc` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_notify` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_photos` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_scanner` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_scene3d` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_screencast` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_sensors` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_sms` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_speech` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_touch` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_video` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_vision` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_wake` | · | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |
| `singleton:mob_whisper` | ✓ pass | ! error @ `build:deploy:android` | ! error @ `build:release:android` | ✓ pass | ! error @ `error:worker` | ✓ pass |

91 pass, 0 fail, 94 error, 0 skip.

## rc:mob_dev@134a88e3a3fc3dc92e81a2d8f292ad0dc936262f

Latest run 2026-10-13T20:21:00Z. Core versions in this grid: mob 0.9.17 · mob_dev 0.7.23 (git 134a88e) · mob_new 0.6.9.

| set | deploy:android | release:android |
| --- | --- | --- |
| `default` | ✓ pass | ✓ pass |
| `all` | ✓ pass | ✓ pass |
| `singleton:mob_camera` | ✓ pass | ✓ pass |

6 pass, 0 fail, 0 error, 0 skip.

## rc:mob_dev@39005a35298fbced4194dfc9a9b000a8ea9b0351

Latest run 2026-10-09T20:58:17Z. Core versions in this grid: mob 0.9.17 · mob_dev 0.7.21 (git 39005a3) · mob_new 0.6.9.

| set | deploy:android |
| --- | --- |
| `singleton:mob_camera` | ✓ pass |

1 pass, 0 fail, 0 error, 0 skip.

## rc:mob_camera@1935c2225a14f5c5867849305e23f6823b03ca8b

Latest run 2026-10-09T19:10:51Z. Core versions in this grid: mob 0.9.17 · mob_dev 0.7.21 · mob_new 0.6.9.

| set | deploy:android | release:android |
| --- | --- | --- |
| `singleton:mob_camera` | ✓ pass | ✓ pass |

2 pass, 0 fail, 0 error, 0 skip.

## rc:mob_location@9fc8937f03ac497dec4171da5b3282bb58057b71

Latest run 2026-10-09T17:29:53Z. Core versions in this grid: mob 0.9.17 · mob_dev 0.7.20 · mob_new 0.6.8; mob 0.9.17 · mob_dev 0.7.19 · mob_new 0.6.7; mob 0.9.15 · mob_dev 0.7.17 · mob_new 0.6.7.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ! error @ `build:deploy:ios_device` | ! error @ `build:release:ios` |
| `all` | ✗ fail @ `static` | ✓ pass | ✓ pass | ! error @ `build:deploy:ios_sim` | ! error @ `build:deploy:ios_device` | ! error @ `build:release:ios` |
| `singleton:mob_location` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ! error @ `build:deploy:ios_device` | ! error @ `build:release:ios` |

10 pass, 1 fail, 7 error, 0 skip.
