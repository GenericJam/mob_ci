# mob_ci matrix

The latest result of every cell mob_ci has run, per version row: one
line per plugin set, one column per build path. Generated from the
mob_ci results store by `mix ci.report --publish`; do not edit. Verified
version combinations are in [COMPATIBILITY.md](COMPATIBILITY.md).

`✓ pass` · `✗ fail @ layer` · `! error @ layer` (the run could not
finish: build, boot, farm, toolchain) · `– skip` · `·` never ran. Layers are
described in mob_ci's `decisions/2026-06-19-mob-ci-design.md`.

## hex

Latest run 2026-10-10T00:12:57Z. Core versions in this grid: mob 0.9.17 · mob_dev 0.7.23 · mob_new 0.6.9; mob 0.9.17 · mob_dev 0.7.22 · mob_new 0.6.9; mob 0.9.17 · mob_dev 0.7.21 · mob_new 0.6.8; mob 0.9.17 · mob_dev 0.7.20 · mob_new 0.6.8; mob 0.9.16 · mob_dev 0.7.19 · mob_new 0.6.7; mob 0.9.16 · mob_dev 0.7.18 · mob_new 0.6.7; mob 0.9.15 · mob_dev 0.7.17 · mob_new 0.6.7.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | deploy:android_physical | release:ios |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `all` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_background` | · | ✓ pass | ✓ pass | · | · | · | · |
| `singleton:mob_biometric` | · | · | · | · | ✓ pass | ✓ pass | · |
| `singleton:mob_bluetooth` | · | · | · | · | ✓ pass | ✓ pass | · |
| `singleton:mob_camera` | · | · | · | · | ✓ pass | ✓ pass | · |
| `singleton:mob_midi` | · | · | · | · | ✓ pass | ✓ pass | · |
| `singleton:mob_nfc` | · | · | · | · | ✓ pass | ✓ pass | · |
| `singleton:mob_photos` | · | · | · | · | ✓ pass | ✓ pass | · |
| `singleton:mob_scanner` | · | · | · | · | ✓ pass | ✓ pass | · |
| `singleton:mob_scene3d` | · | ✓ pass | ✓ pass | ✓ pass | ✓ pass | · | ✓ pass |
| `singleton:mob_screencast` | · | ✓ pass | ✓ pass | · | · | · | · |
| `singleton:mob_sensors` | · | ✓ pass | ✓ pass | · | · | ✓ pass | · |
| `singleton:mob_speech` | · | · | · | · | ✓ pass | ✓ pass | · |
| `singleton:mob_whisper` | · | · | · | ✓ pass | ✓ pass | · | ✓ pass |

44 pass, 0 fail, 0 error, 0 skip.

## master

Latest run 2026-10-10T00:18:17Z. Core versions in this grid: mob 0.9.17 (git 5d85492) · mob_dev 0.7.23 (git 8091656) · mob_new 0.6.9 (git d03e4a3); mob 0.9.17 (git 5d85492) · mob_dev 0.7.21 (git 04feb5b) · mob_new 0.6.9 (git d03e4a3); mob 0.9.17 (git 5d85492) · mob_dev 0.7.21 (git 04feb5b) · mob_new 0.6.8 (git 1dc6ac2); mob 0.9.15 (git 19ca6e1) · mob_dev 0.7.17 (git 4e63c0d) · mob_new 0.6.7 (git 213ed49).

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `blank` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `default` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `all` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `selftest_pilots` | · | ✓ pass | ✓ pass | · | · | · |
| `singleton:mob_audio_capture` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_biometric` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_camera` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_deliver` | · | ✓ pass | ✓ pass | · | · | · |
| `singleton:mob_location` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_mishka` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_nfc` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_scene3d` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_sensors` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_sms` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_speech` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_touch` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_vision` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_whisper` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |

80 pass, 0 fail, 10 error, 10 skip.

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
