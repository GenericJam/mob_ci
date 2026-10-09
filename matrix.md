# mob_ci matrix

The latest result of every cell mob_ci has run, per version row: one
line per plugin set, one column per build path. Generated from the
mob_ci results store by `mix ci.report --publish`; do not edit. Verified
version combinations are in [COMPATIBILITY.md](COMPATIBILITY.md).

`✓ pass` · `✗ fail @ layer` · `! error @ layer` (the run could not
finish: build, boot, farm) · `– skip` · `·` never ran. Layers are
described in mob_ci's `decisions/2026-06-19-mob-ci-design.md`.

## hex

Latest run 2026-10-09T17:59:41Z. Core versions in this grid: mob 0.9.17 · mob_dev 0.7.21 · mob_new 0.6.8; mob 0.9.17 · mob_dev 0.7.20 · mob_new 0.6.8; mob 0.9.16 · mob_dev 0.7.19 · mob_new 0.6.7; mob 0.9.16 · mob_dev 0.7.18 · mob_new 0.6.7; mob 0.9.15 · mob_dev 0.7.17 · mob_new 0.6.7.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | deploy:android_physical | release:ios |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `all` | ✓ pass | ✓ pass | ✓ pass | · | ! error @ `build:deploy:ios_device` | · | · |
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

38 pass, 0 fail, 1 error, 0 skip.

## master

Latest run 2026-10-09T18:49:58Z. Core versions in this grid: mob 0.9.17 (git 5d85492) · mob_dev 0.7.21 (git 04feb5b) · mob_new 0.6.9 (git d03e4a3); mob 0.9.17 (git 5d85492) · mob_dev 0.7.21 (git 04feb5b) · mob_new 0.6.8 (git 1dc6ac2); mob 0.9.16 (git 1843423) · mob_dev 0.7.18 (git 65bdac9) · mob_new 0.6.7 (git 213ed49); mob 0.9.15 (git 19ca6e1) · mob_dev 0.7.17 (git 4e63c0d) · mob_new 0.6.7 (git 213ed49).

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `blank` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `default` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `all` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ! error @ `build:release:ios` |
| `selftest_pilots` | · | ✓ pass | ✓ pass | · | · | · |
| `singleton:mob_audio_capture` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_biometric` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_camera` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_deliver` | · | ✓ pass | ✓ pass | · | · | · |
| `singleton:mob_location` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_mishka` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_nfc` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_scene3d` | ✓ pass | ! error @ `build:deploy:android` | ✓ pass | ! error @ `mob_new` | ! error @ `mob_new` | ! error @ `mob_new` |
| `singleton:mob_sensors` | ✓ pass | ! error @ `mob_new` | ! error @ `mob_new` | ! error @ `mob_new` | ! error @ `mob_new` | ! error @ `mob_new` |
| `singleton:mob_sms` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_speech` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_touch` | ✓ pass | ✓ pass | ! error @ `build:release:android` | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_vision` | ✓ pass | ✓ pass | ! error @ `build:release:android` | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_whisper` | · | ✓ pass | ✓ pass | · | · | · |

64 pass, 0 fail, 22 error, 10 skip.

## rc:mob_camera@1935c2225a14f5c5867849305e23f6823b03ca8b

Latest run 2026-10-09T18:09:18Z. Core versions in this grid: mob 0.9.17 · mob_dev 0.7.21 · mob_new 0.6.8.

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
