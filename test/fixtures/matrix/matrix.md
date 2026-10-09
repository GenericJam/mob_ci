# mob_ci matrix

The latest result of every cell mob_ci has run, per version row: one
line per plugin set, one column per build path. Generated from the
mob_ci results store by `mix ci.report --publish`; do not edit. Verified
version combinations are in [COMPATIBILITY.md](COMPATIBILITY.md).

`✓ pass` · `✗ fail @ layer` · `! error @ layer` (the run could not
finish: build, boot, farm) · `– skip` · `·` never ran. Layers are
described in mob_ci's `decisions/2026-06-19-mob-ci-design.md`.

## hex

Latest run 2026-10-08T02:00:00Z. Core versions in this grid: mob 0.9.16 · mob_dev 0.7.17 · mob_new 0.6.8; mob 0.9.15 · mob_dev 0.7.17 · mob_new 0.6.8.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | ✓ pass | ✗ fail @ `build:release:android/mob_camera` | ✓ pass | – skip | ! error @ `build:release:ios` |
| `all` | ✗ fail @ `static` | ✓ pass | ✓ pass | ✓ pass | ✓ pass | ✓ pass |
| `singleton:mob_location` | · | ✓ pass | · | · | · | · |
| `sweep:all` | ✓ pass | · | · | · | · | · |

10 pass, 2 fail, 1 error, 1 skip.

Sampled sets whose latest cell failed (`mix ci.replay <cell>` reruns one;
`--promote` commits it under `priv/sets/` as a regression set):

| cell | set | path | result |
| --- | --- | --- | --- |
| 47 | `sweep:mob_location,mob_whisper` | deploy:android | ! error @ `build:ci_x` |
| 45 | `random:7` | deploy:android | ✗ fail @ `conflict:mob_location,mob_camera` |

## master

Latest run 2026-10-08T03:00:00Z. Core versions in this grid: mob 0.9.17 (git aaaaaaa) · mob_dev 0.7.18 (git bbbbbbb) · mob_new 0.6.9 (git ccccccc).

| set | deploy:android |
| --- | --- |
| `default` | ✓ pass |

1 pass, 0 fail, 0 error, 0 skip.

## rc:mob@abcdef1

Latest run 2026-10-08T04:00:00Z. Core versions in this grid: mob 0.9.17 (git abcdef1) · mob_dev 0.7.17 · mob_new 0.6.8.

| set | deploy:android |
| --- | --- |
| `default` | ✓ pass |

1 pass, 0 fail, 0 error, 0 skip.
