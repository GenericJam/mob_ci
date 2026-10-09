# mob_ci matrix

The latest result of every cell mob_ci has run, per version row: one
line per plugin set, one column per build path. Generated from the
mob_ci results store by `mix ci.report --publish`; do not edit. Verified
version combinations are in [COMPATIBILITY.md](COMPATIBILITY.md).

`✓ pass` · `✗ fail @ layer` · `! error @ layer` (the run could not
finish: build, boot, farm) · `– skip` · `·` never ran. Layers are
described in mob_ci's `decisions/2026-06-19-mob-ci-design.md`.

## hex

Latest run 2026-10-09T15:44:19Z. Core versions in this grid: mob 0.9.15 · mob_dev 0.7.17 · mob_new 0.6.7.

| set | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | ✓ pass | ✓ pass | ✗ fail @ `boot` | ✓ pass |
| `singleton:mob_background` | ✓ pass | ✓ pass | · | · | · |

6 pass, 1 fail, 0 error, 0 skip.

## master

Latest run 2026-10-09T16:00:34Z. Core versions in this grid: mob 0.9.16 (git 8d28641) · mob_dev 0.7.17 (git c80ee21) · mob_new 0.6.7 (git 213ed49); mob 0.9.15 (git 19ca6e1) · mob_dev 0.7.17 (git 4e63c0d) · mob_new 0.6.7 (git 213ed49).

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `blank` | ✓ pass | · | · | · | · | · |
| `default` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `all` | ✗ fail @ `static` | ✓ pass | ✓ pass | ! error @ `build:deploy:ios_sim` | – skip | ! error @ `build:release:ios` |
| `selftest_pilots` | · | ✓ pass | ✓ pass | · | · | · |
| `singleton:mob_audio_capture` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_biometric` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_camera` | ✓ pass | ! error @ `build:deploy:android` | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_deliver` | · | ✓ pass | ✓ pass | · | · | · |
| `singleton:mob_location` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_mishka` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_nfc` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_sms` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_speech` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_touch` | ✓ pass | ✓ pass | ! error @ `build:release:android` | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_vision` | ✓ pass | · | · | ✓ pass | – skip | ! error @ `build:release:ios` |
| `singleton:mob_whisper` | · | ✓ pass | ✓ pass | · | · | · |

49 pass, 1 fail, 15 error, 12 skip.

## rc:mob_location@9fc8937f03ac497dec4171da5b3282bb58057b71

Latest run 2026-10-09T15:54:41Z. Core versions in this grid: mob 0.9.15 · mob_dev 0.7.17 · mob_new 0.6.7.

| set | static | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- |
| `default` | ✓ pass | ✓ pass | ! error @ `build:deploy:ios_device` | ! error @ `build:release:ios` |
| `all` | ✗ fail @ `static` | ! error @ `build:deploy:ios_sim` | ! error @ `build:deploy:ios_device` | ! error @ `build:release:ios` |
| `singleton:mob_location` | ✓ pass | ✓ pass | ! error @ `build:deploy:ios_device` | ! error @ `build:release:ios` |

4 pass, 1 fail, 7 error, 0 skip.
