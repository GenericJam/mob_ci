# Verified combinations

Which versions of mob, mob_dev, mob_new and the first-party plugins work
together, as proven on devices by [mob_ci](https://github.com/GenericJam/mob_ci).
Generated from the mob_ci results store by `mix ci.report --publish`; do
not edit.

A combination is **verified** when, with exactly these versions, both the
`default` set (what `mix mob.new` activates) and the `all` set (every
buildable first-party plugin) passed on every build path below. Hex
versions are plain (`0.9.15`); a git checkout is `version (git sha)`.
Newest first.

| path | what runs | ABI on the device |
| --- | --- | --- |
| `static` | the manifest gate (`cross_validate`): the set composes | none (no build) |
| `deploy:android` | `mix mob.deploy --native`, P1–P12 on a redroid emulator | x86_64 |
| `release:android` | `mix mob.release --android` as a universal APK on a fresh redroid, P2/P10–P12 | x86_64 runs; arm64 and armv7 only compile |
| `deploy:ios_sim` | `mix mob.deploy --native` on an iOS simulator, P2/P12/health | arm64 (simulator) |
| `deploy:ios_device` | the same on a physical iPhone | arm64 |
| `release:ios` | `mix mob.release --ios`: a signed .ipa, not run | arm64 (build only) |

## Verified

### mob 0.9.15 · mob_dev 0.7.17 · mob_new 0.6.8

Row hex; newest result 2026-10-08T06:00:00Z.

Plugins: mob_camera 0.3.1, mob_location 0.2.0, mob_whisper 0.1.4.

## Candidates

The 10 newest tuples that ran `default` or `all` but are not
verified: the newest outcome of each set on each path (`·` never ran).

### mob 0.9.17 (git abcdef1) · mob_dev 0.7.17 · mob_new 0.6.8

Row rc:mob@abcdef1; newest result 2026-10-08T04:00:00Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | · | ✓ pass | · | · | · | · |
| `all` | · | · | · | · | · | · |

Plugins: mob_camera 0.3.1, mob_location 0.2.0.

### mob 0.9.17 (git aaaaaaa) · mob_dev 0.7.18 (git bbbbbbb) · mob_new 0.6.9 (git ccccccc)

Row master; newest result 2026-10-08T03:00:00Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | · | ✓ pass | · | · | · | · |
| `all` | · | · | · | · | · | · |

Plugins: mob_location 0.2.1 (git ddddddd).

### mob 0.9.16 · mob_dev 0.7.17 · mob_new 0.6.8

Row hex; newest result 2026-10-08T02:00:00Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | ✓ pass | ✗ fail | ✓ pass | – skip | ! error |
| `all` | ✗ fail | · | · | · | · | · |

Plugins: mob_camera 0.3.1, mob_location 0.2.0, mob_whisper 0.1.4.

## Plugins

Which plugin versions have passed (a `singleton:<plugin>`, `default` or
`all` cell passed with the plugin in it) with which mob and mob_dev, on
which build paths.

| plugin | version | mob | mob_dev | passed on |
| --- | --- | --- | --- | --- |
| `mob_camera` | 0.3.1 | 0.9.17 (git abcdef1) | 0.7.17 | `deploy:android` |
| `mob_camera` | 0.3.1 | 0.9.16 | 0.7.17 | `static`, `deploy:android`, `deploy:ios_sim` |
| `mob_camera` | 0.3.1 | 0.9.15 | 0.7.17 | `static`, `deploy:android`, `release:android`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_location` | 0.2.1 (git ddddddd) | 0.9.17 (git aaaaaaa) | 0.7.18 (git bbbbbbb) | `deploy:android` |
| `mob_location` | 0.2.0 | 0.9.17 (git abcdef1) | 0.7.17 | `deploy:android` |
| `mob_location` | 0.2.0 | 0.9.16 | 0.7.17 | `static`, `deploy:android`, `deploy:ios_sim` |
| `mob_location` | 0.2.0 | 0.9.15 | 0.7.17 | `static`, `deploy:android`, `release:android`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_whisper` | 0.1.4 | 0.9.15 | 0.7.17 | `static`, `deploy:android`, `release:android`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
