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

None yet: no version tuple has passed both `default` and `all` on every path. The candidates below show what each one is missing.

## Candidates

The 10 newest tuples that ran `default` or `all` but are not
verified: the newest outcome of each set on each path (`·` never ran).

### mob 0.9.17 (git 5d85492) · mob_dev 0.7.21 (git 04feb5b) · mob_new 0.6.8 (git 1dc6ac2)

Row master; newest result 2026-10-09T17:44:51Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | · | · | · | · | · |
| `all` | ✓ pass | · | · | · | · | · |

Plugins: mob_ash 0.1.3 (git 7af64eb), mob_audio_capture 0.2.0 (git 6d519bc), mob_background 0.2.0 (git a8d902a), mob_biometric 0.2.0 (git b616090), mob_bluetooth 0.5.0 (git 450418b), mob_camera 0.1.13 (git 1935c22), mob_deliver 0.3.2 (git 49fcab2), mob_location 0.2.0 (git 9fc8937), mob_midi 0.2.0 (git eb29efc), mob_mishka 0.1.4 (git 9b9bba9), mob_nfc 0.1.5 (git 7879a24), mob_notify 0.2.1 (git a2a6f26), mob_photos 0.2.1 (git a167da3), mob_scanner 0.1.6 (git 37c33c3), mob_scene3d 0.2.0 (git e802262), mob_screencast 0.1.3 (git 450a731), mob_sensors 0.2.0 (git 8eb7edd), mob_sms 0.2.4 (git 97a6fe1), mob_speech 0.1.1 (git baa9756), mob_touch 0.1.2 (git 04d6abf), mob_video 0.1.2 (git 48e181f), mob_vision 0.1.3 (git a91e391), mob_wake 0.1.2 (git 363a194), mob_whisper 0.1.1 (git 04590fc).

### mob 0.9.17 · mob_dev 0.7.20 · mob_new 0.6.8

Row rc:mob_location@9fc8937f03ac497dec4171da5b3282bb58057b71; newest result 2026-10-09T17:29:53Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | · | · | · | · | · | · |
| `all` | · | ✓ pass | ✓ pass | · | · | · |

Plugins: mob_ash 0.1.3, mob_audio_capture 0.2.0, mob_background 0.2.0, mob_biometric 0.2.0, mob_bluetooth 0.5.0, mob_camera 0.1.13, mob_deliver 0.3.2, mob_location 0.2.0 (git 9fc8937), mob_midi 0.2.0, mob_mishka 0.1.4, mob_nfc 0.1.5, mob_notify 0.2.1, mob_photos 0.2.1, mob_scanner 0.1.6, mob_scene3d 0.1.4, mob_screencast 0.1.3, mob_sensors 0.1.0, mob_sms 0.2.4, mob_speech 0.1.1, mob_touch 0.1.2, mob_video 0.1.2, mob_vision 0.1.3, mob_wake 0.1.2, mob_whisper 0.1.1.

### mob 0.9.17 · mob_dev 0.7.20 · mob_new 0.6.8

Row hex; newest result 2026-10-09T17:26:49Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | · | · | · | · | · | · |
| `all` | · | · | · | · | · | · |

Plugins: mob_biometric 0.2.0, mob_camera 0.1.13, mob_location 0.2.0, mob_mishka 0.1.4.

### mob 0.9.17 (git 5d85492) · mob_dev 0.7.20 (git 8f8a9be) · mob_new 0.6.8 (git 1dc6ac2)

Row master; newest result 2026-10-09T17:21:18Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | · | · | · | · | · |
| `all` | ✓ pass | · | · | · | · | · |

Plugins: mob_ash 0.1.3 (git 7af64eb), mob_audio_capture 0.2.0 (git 6d519bc), mob_background 0.2.0 (git a8d902a), mob_biometric 0.2.0 (git b616090), mob_bluetooth 0.5.0 (git 450418b), mob_camera 0.1.13 (git 1935c22), mob_deliver 0.3.2 (git 49fcab2), mob_location 0.2.0 (git 9fc8937), mob_midi 0.2.0 (git eb29efc), mob_mishka 0.1.4 (git 9b9bba9), mob_nfc 0.1.5 (git 7879a24), mob_notify 0.2.1 (git a2a6f26), mob_photos 0.2.1 (git a167da3), mob_scanner 0.1.6 (git 37c33c3), mob_scene3d 0.1.4 (git 7363c4d), mob_screencast 0.1.3 (git 450a731), mob_sensors 0.1.0 (git fac92ed), mob_sms 0.2.4 (git 97a6fe1), mob_speech 0.1.1 (git baa9756), mob_touch 0.1.2 (git 04d6abf), mob_video 0.1.2 (git 48e181f), mob_vision 0.1.3 (git a91e391), mob_wake 0.1.2 (git 363a194), mob_whisper 0.1.1 (git 04590fc).

### mob 0.9.17 · mob_dev 0.7.19 · mob_new 0.6.8

Row hex; newest result 2026-10-09T17:18:19Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | · | · | · | · | · | · |
| `all` | · | · | · | · | · | · |

Plugins: mob_biometric 0.2.0, mob_camera 0.1.13, mob_location 0.2.0, mob_mishka 0.1.4.

### mob 0.9.17 (git 5d85492) · mob_dev 0.7.19 (git 3ca3d32) · mob_new 0.6.8 (git 1dc6ac2)

Row master; newest result 2026-10-09T17:15:14Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | · | · | · | ! error | ! error | ! error |
| `all` | · | · | · | · | · | · |

Plugins: mob_biometric 0.2.0 (git b616090), mob_camera 0.1.13 (git 1935c22), mob_location 0.2.0 (git 9fc8937), mob_mishka 0.1.4 (git 9b9bba9).

### mob 0.9.17 · mob_dev 0.7.19 · mob_new 0.6.7

Row rc:mob_location@9fc8937f03ac497dec4171da5b3282bb58057b71; newest result 2026-10-09T17:11:57Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | · | ✓ pass | ✓ pass | · | · | · |
| `all` | · | · | · | · | · | · |

Plugins: mob_biometric 0.2.0, mob_camera 0.1.13, mob_location 0.2.0 (git 9fc8937), mob_mishka 0.1.4.

### mob 0.9.16 (git 9d1b7ad) · mob_dev 0.7.19 (git 85cb423) · mob_new 0.6.7 (git 213ed49)

Row master; newest result 2026-10-09T17:09:30Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | · | · | · | · | · | · |
| `all` | ✓ pass | · | · | · | · | · |

Plugins: mob_ash 0.1.3 (git 7af64eb), mob_audio_capture 0.2.0 (git 6d519bc), mob_biometric 0.2.0 (git b616090), mob_bluetooth 0.5.0 (git 450418b), mob_camera 0.1.13 (git 1935c22), mob_deliver 0.3.2 (git 49fcab2), mob_location 0.2.0 (git 9fc8937), mob_midi 0.2.0 (git eb29efc), mob_mishka 0.1.4 (git 9b9bba9), mob_nfc 0.1.5 (git 7879a24), mob_notify 0.2.1 (git a2a6f26), mob_photos 0.2.1 (git a167da3), mob_scanner 0.1.6 (git 37c33c3), mob_scene3d 0.1.4 (git 7363c4d), mob_sensors 0.1.0 (git fac92ed), mob_sms 0.2.4 (git 97a6fe1), mob_speech 0.1.1 (git baa9756), mob_touch 0.1.2 (git 04d6abf), mob_video 0.1.2 (git 48e181f), mob_vision 0.1.3 (git a91e391), mob_wake 0.1.2 (git 363a194), mob_whisper 0.1.1 (git 04590fc).

### mob 0.9.17 (git 5d85492) · mob_dev 0.7.19 (git 85cb423) · mob_new 0.6.7 (git 213ed49)

Row master; newest result 2026-10-09T17:09:27Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | · | · | · | · | · |
| `all` | ✓ pass | · | · | · | · | · |

Plugins: mob_ash 0.1.3 (git 7af64eb), mob_audio_capture 0.2.0 (git 6d519bc), mob_biometric 0.2.0 (git b616090), mob_bluetooth 0.5.0 (git 450418b), mob_camera 0.1.13 (git 1935c22), mob_deliver 0.3.2 (git 49fcab2), mob_location 0.2.0 (git 9fc8937), mob_midi 0.2.0 (git eb29efc), mob_mishka 0.1.4 (git 9b9bba9), mob_nfc 0.1.5 (git 7879a24), mob_notify 0.2.1 (git a2a6f26), mob_photos 0.2.1 (git a167da3), mob_scanner 0.1.6 (git 37c33c3), mob_scene3d 0.1.4 (git 7363c4d), mob_sensors 0.1.0 (git fac92ed), mob_sms 0.2.4 (git 97a6fe1), mob_speech 0.1.1 (git baa9756), mob_touch 0.1.2 (git 04d6abf), mob_video 0.1.2 (git 48e181f), mob_vision 0.1.3 (git a91e391), mob_wake 0.1.2 (git 363a194), mob_whisper 0.1.1 (git 04590fc).

### mob 0.9.16 · mob_dev 0.7.19 · mob_new 0.6.7

Row hex; newest result 2026-10-09T17:06:46Z.

| set | static | deploy:android | release:android | deploy:ios_sim | deploy:ios_device | release:ios |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | ✓ pass | · | · | · | · | · |
| `all` | ✓ pass | ✓ pass | ✓ pass | · | · | · |

Plugins: mob_ash 0.1.3, mob_audio_capture 0.2.0, mob_background 0.2.0, mob_biometric 0.2.0, mob_bluetooth 0.5.0, mob_camera 0.1.13, mob_deliver 0.3.2, mob_location 0.2.0, mob_midi 0.2.0, mob_mishka 0.1.4, mob_nfc 0.1.5, mob_notify 0.2.1, mob_photos 0.2.1, mob_scanner 0.1.6, mob_scene3d 0.1.4, mob_screencast 0.1.3, mob_sensors 0.1.0, mob_sms 0.2.4, mob_speech 0.1.1, mob_touch 0.1.2, mob_video 0.1.2, mob_vision 0.1.3, mob_wake 0.1.2, mob_whisper 0.1.1.

## Plugins

Which plugin versions have passed (a `singleton:<plugin>`, `default` or
`all` cell passed with the plugin in it) with which mob and mob_dev, on
which build paths.

| plugin | version | mob | mob_dev | passed on |
| --- | --- | --- | --- | --- |
| `mob_ash` | 0.1.3 (git 7af64eb) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_ash` | 0.1.3 (git 7af64eb) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_ash` | 0.1.3 (git 7af64eb) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_ash` | 0.1.3 (git 7af64eb) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_ash` | 0.1.3 (git 7af64eb) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_ash` | 0.1.3 (git 7af64eb) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_ash` | 0.1.3 (git 7af64eb) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_ash` | 0.1.3 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_ash` | 0.1.3 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_ash` | 0.1.3 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_audio_capture` | 0.2.0 (git 6d519bc) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_audio_capture` | 0.2.0 (git 6d519bc) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_audio_capture` | 0.2.0 (git 6d519bc) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_audio_capture` | 0.2.0 (git 6d519bc) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_audio_capture` | 0.2.0 (git 6d519bc) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_audio_capture` | 0.2.0 (git 6d519bc) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_audio_capture` | 0.2.0 (git 6d519bc) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_audio_capture` | 0.2.0 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_audio_capture` | 0.2.0 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_audio_capture` | 0.2.0 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_background` | 0.2.0 (git a8d902a) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_background` | 0.2.0 (git a8d902a) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_background` | 0.2.0 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_background` | 0.2.0 | 0.9.16 | 0.7.19 | `deploy:android`, `release:android` |
| `mob_background` | 0.2.0 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_background` | 0.2.0 | 0.9.15 | 0.7.17 | `deploy:android`, `release:android` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.16 (git 8d28641) | 0.7.18 (git 2491846) | `static`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.16 (git 8d28641) | 0.7.17 (git c80ee21) | `static` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.16 (git 1843423) | 0.7.18 (git 2491846) | `static` |
| `mob_biometric` | 0.2.0 (git b616090) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_biometric` | 0.2.0 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android`, `deploy:android_physical` |
| `mob_biometric` | 0.2.0 | 0.9.17 | 0.7.19 | `deploy:android`, `release:android` |
| `mob_biometric` | 0.2.0 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_biometric` | 0.2.0 | 0.9.16 | 0.7.18 | `deploy:android`, `release:android`, `deploy:ios_device` |
| `mob_biometric` | 0.2.0 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_biometric` | 0.2.0 | 0.9.15 | 0.7.17 | `static`, `deploy:ios_sim` |
| `mob_biometric` | 0.1.5 | 0.9.15 | 0.7.17 | `deploy:android`, `release:android`, `deploy:ios_sim`, `release:ios` |
| `mob_bluetooth` | 0.5.0 (git 450418b) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_bluetooth` | 0.5.0 (git 450418b) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_bluetooth` | 0.5.0 (git 450418b) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_bluetooth` | 0.5.0 (git 450418b) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_bluetooth` | 0.5.0 (git 450418b) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_bluetooth` | 0.5.0 (git 450418b) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_bluetooth` | 0.5.0 (git 450418b) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_bluetooth` | 0.5.0 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android`, `deploy:android_physical` |
| `mob_bluetooth` | 0.5.0 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_bluetooth` | 0.5.0 | 0.9.16 | 0.7.18 | `deploy:ios_device` |
| `mob_bluetooth` | 0.5.0 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.16 (git 8d28641) | 0.7.18 (git 2491846) | `static`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.16 (git 8d28641) | 0.7.17 (git c80ee21) | `static` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.16 (git 1843423) | 0.7.18 (git 2491846) | `static` |
| `mob_camera` | 0.1.13 (git 1935c22) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_camera` | 0.1.13 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android`, `deploy:android_physical` |
| `mob_camera` | 0.1.13 | 0.9.17 | 0.7.19 | `deploy:android`, `release:android` |
| `mob_camera` | 0.1.13 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_camera` | 0.1.13 | 0.9.16 | 0.7.18 | `deploy:android`, `release:android`, `deploy:ios_device` |
| `mob_camera` | 0.1.13 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_camera` | 0.1.13 | 0.9.15 | 0.7.17 | `static`, `deploy:ios_sim` |
| `mob_camera` | 0.1.12 | 0.9.15 | 0.7.17 | `deploy:android`, `release:android`, `deploy:ios_sim`, `release:ios` |
| `mob_deliver` | 0.3.2 (git 49fcab2) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_deliver` | 0.3.2 (git 49fcab2) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_deliver` | 0.3.2 (git 49fcab2) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_deliver` | 0.3.2 (git 49fcab2) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_deliver` | 0.3.2 (git 49fcab2) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_deliver` | 0.3.2 (git 49fcab2) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_deliver` | 0.3.2 (git 49fcab2) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_deliver` | 0.3.2 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_deliver` | 0.3.2 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_deliver` | 0.3.2 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_deliver` | 0.3.1 (git a9fde0a) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.17 | 0.7.19 | `deploy:android`, `release:android` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.16 (git 8d28641) | 0.7.18 (git 2491846) | `static`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.16 (git 8d28641) | 0.7.17 (git c80ee21) | `static` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.16 (git 1843423) | 0.7.18 (git 2491846) | `static` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_location` | 0.2.0 (git 9fc8937) | 0.9.15 | 0.7.17 | `static`, `deploy:ios_sim` |
| `mob_location` | 0.2.0 | 0.9.17 | 0.7.20 | `deploy:android_physical` |
| `mob_location` | 0.2.0 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_location` | 0.2.0 | 0.9.16 | 0.7.18 | `deploy:android`, `release:android`, `deploy:ios_device` |
| `mob_location` | 0.2.0 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_location` | 0.1.6 (git 4c3d93d) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_location` | 0.1.6 | 0.9.15 | 0.7.17 | `deploy:android`, `release:android`, `deploy:ios_sim`, `release:ios` |
| `mob_midi` | 0.2.0 (git eb29efc) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_midi` | 0.2.0 (git eb29efc) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_midi` | 0.2.0 (git eb29efc) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_midi` | 0.2.0 (git eb29efc) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_midi` | 0.2.0 (git eb29efc) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_midi` | 0.2.0 (git eb29efc) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_midi` | 0.2.0 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android`, `deploy:android_physical` |
| `mob_midi` | 0.2.0 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_midi` | 0.2.0 | 0.9.16 | 0.7.18 | `deploy:ios_device` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.16 (git 8d28641) | 0.7.18 (git 2491846) | `static`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.16 (git 8d28641) | 0.7.17 (git c80ee21) | `static` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.16 (git 1843423) | 0.7.18 (git 2491846) | `static` |
| `mob_mishka` | 0.1.4 (git 9b9bba9) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_mishka` | 0.1.4 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android`, `deploy:android_physical` |
| `mob_mishka` | 0.1.4 | 0.9.17 | 0.7.19 | `deploy:android`, `release:android` |
| `mob_mishka` | 0.1.4 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_mishka` | 0.1.4 | 0.9.16 | 0.7.18 | `deploy:android`, `release:android`, `deploy:ios_device` |
| `mob_mishka` | 0.1.4 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_mishka` | 0.1.4 | 0.9.15 | 0.7.17 | `static`, `deploy:ios_sim` |
| `mob_mishka` | 0.1.3 | 0.9.15 | 0.7.17 | `deploy:android`, `release:android`, `deploy:ios_sim`, `release:ios` |
| `mob_nfc` | 0.1.5 (git 7879a24) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_nfc` | 0.1.5 (git 7879a24) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_nfc` | 0.1.5 (git 7879a24) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_nfc` | 0.1.5 (git 7879a24) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_nfc` | 0.1.5 (git 7879a24) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_nfc` | 0.1.5 (git 7879a24) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_nfc` | 0.1.5 (git 7879a24) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_nfc` | 0.1.5 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android`, `deploy:android_physical` |
| `mob_nfc` | 0.1.5 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_nfc` | 0.1.5 | 0.9.16 | 0.7.18 | `deploy:ios_device` |
| `mob_nfc` | 0.1.5 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_notify` | 0.2.1 (git a2a6f26) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_notify` | 0.2.1 (git a2a6f26) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_notify` | 0.2.1 (git a2a6f26) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_notify` | 0.2.1 (git a2a6f26) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_notify` | 0.2.1 (git a2a6f26) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_notify` | 0.2.1 (git a2a6f26) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_notify` | 0.2.1 (git a2a6f26) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_notify` | 0.2.1 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_notify` | 0.2.1 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_notify` | 0.2.1 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_photos` | 0.2.1 (git a167da3) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_photos` | 0.2.1 (git a167da3) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_photos` | 0.2.1 (git a167da3) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_photos` | 0.2.1 (git a167da3) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_photos` | 0.2.1 (git a167da3) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_photos` | 0.2.1 (git a167da3) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_photos` | 0.2.1 (git a167da3) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_photos` | 0.2.1 | 0.9.17 | 0.7.21 | `deploy:android_physical` |
| `mob_photos` | 0.2.1 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_photos` | 0.2.1 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_photos` | 0.2.1 | 0.9.16 | 0.7.18 | `deploy:ios_device` |
| `mob_photos` | 0.2.1 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_scanner` | 0.1.6 (git 37c33c3) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_scanner` | 0.1.6 (git 37c33c3) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_scanner` | 0.1.6 (git 37c33c3) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_scanner` | 0.1.6 (git 37c33c3) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_scanner` | 0.1.6 (git 37c33c3) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_scanner` | 0.1.6 (git 37c33c3) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_scanner` | 0.1.6 (git 37c33c3) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_scanner` | 0.1.6 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android`, `deploy:android_physical` |
| `mob_scanner` | 0.1.6 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_scanner` | 0.1.6 | 0.9.16 | 0.7.18 | `deploy:ios_device` |
| `mob_scanner` | 0.1.6 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_scene3d` | 0.2.0 (git e802262) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_scene3d` | 0.1.4 (git 7363c4d) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_scene3d` | 0.1.4 (git 7363c4d) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_scene3d` | 0.1.4 (git 7363c4d) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_scene3d` | 0.1.4 (git 7363c4d) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_scene3d` | 0.1.4 (git 7363c4d) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_scene3d` | 0.1.4 (git 7363c4d) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_scene3d` | 0.1.4 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_scene3d` | 0.1.4 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_scene3d` | 0.1.4 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_screencast` | 0.1.3 (git 450a731) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_screencast` | 0.1.3 (git 450a731) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_screencast` | 0.1.3 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_screencast` | 0.1.3 | 0.9.16 | 0.7.19 | `deploy:android`, `release:android` |
| `mob_screencast` | 0.1.3 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_screencast` | 0.1.3 | 0.9.15 | 0.7.17 | `deploy:android`, `release:android` |
| `mob_sensors` | 0.2.0 (git 8eb7edd) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_sensors` | 0.1.0 (git fac92ed) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_sensors` | 0.1.0 (git fac92ed) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_sensors` | 0.1.0 (git fac92ed) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_sensors` | 0.1.0 (git fac92ed) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_sensors` | 0.1.0 (git fac92ed) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_sensors` | 0.1.0 (git fac92ed) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_sensors` | 0.1.0 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_sensors` | 0.1.0 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_sensors` | 0.1.0 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_sms` | 0.2.4 (git 97a6fe1) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_sms` | 0.2.4 (git 97a6fe1) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_sms` | 0.2.4 (git 97a6fe1) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_sms` | 0.2.4 (git 97a6fe1) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_sms` | 0.2.4 (git 97a6fe1) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_sms` | 0.2.4 (git 97a6fe1) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_sms` | 0.2.4 (git 97a6fe1) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_sms` | 0.2.4 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_sms` | 0.2.4 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_sms` | 0.2.4 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_speech` | 0.1.1 (git baa9756) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_speech` | 0.1.1 (git baa9756) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_speech` | 0.1.1 (git baa9756) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_speech` | 0.1.1 (git baa9756) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_speech` | 0.1.1 (git baa9756) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_speech` | 0.1.1 (git baa9756) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_speech` | 0.1.1 (git baa9756) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_speech` | 0.1.1 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android`, `deploy:android_physical` |
| `mob_speech` | 0.1.1 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_speech` | 0.1.1 | 0.9.16 | 0.7.18 | `deploy:ios_device` |
| `mob_speech` | 0.1.1 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_touch` | 0.1.2 (git 04d6abf) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_touch` | 0.1.2 (git 04d6abf) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_touch` | 0.1.2 (git 04d6abf) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_touch` | 0.1.2 (git 04d6abf) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_touch` | 0.1.2 (git 04d6abf) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_touch` | 0.1.2 (git 04d6abf) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_touch` | 0.1.2 (git 04d6abf) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_touch` | 0.1.2 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_touch` | 0.1.2 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_touch` | 0.1.2 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_video` | 0.1.2 (git 48e181f) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_video` | 0.1.2 (git 48e181f) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_video` | 0.1.2 (git 48e181f) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_video` | 0.1.2 (git 48e181f) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_video` | 0.1.2 (git 48e181f) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_video` | 0.1.2 (git 48e181f) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_video` | 0.1.2 (git 48e181f) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_video` | 0.1.2 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_video` | 0.1.2 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_video` | 0.1.2 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_vision` | 0.1.3 (git a91e391) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_vision` | 0.1.3 (git a91e391) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_vision` | 0.1.3 (git a91e391) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_vision` | 0.1.3 (git a91e391) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_vision` | 0.1.3 (git a91e391) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_vision` | 0.1.3 (git a91e391) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_vision` | 0.1.3 (git a91e391) | 0.9.16 (git 1843423) | 0.7.18 (git 65bdac9) | `deploy:android` |
| `mob_vision` | 0.1.3 (git a91e391) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `static`, `deploy:android`, `release:android`, `deploy:ios_sim` |
| `mob_vision` | 0.1.3 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_vision` | 0.1.3 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_vision` | 0.1.3 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_wake` | 0.1.2 (git 363a194) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_wake` | 0.1.2 (git 363a194) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_wake` | 0.1.2 (git 363a194) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_wake` | 0.1.2 (git 363a194) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_wake` | 0.1.2 (git 363a194) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_wake` | 0.1.2 (git 363a194) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_wake` | 0.1.2 (git 363a194) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_wake` | 0.1.2 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_wake` | 0.1.2 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_wake` | 0.1.2 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_whisper` | 0.1.1 (git 04590fc) | 0.9.17 (git 5d85492) | 0.7.21 (git 04feb5b) | `static` |
| `mob_whisper` | 0.1.1 (git 04590fc) | 0.9.17 (git 5d85492) | 0.7.20 (git 8f8a9be) | `static` |
| `mob_whisper` | 0.1.1 (git 04590fc) | 0.9.17 (git 5d85492) | 0.7.19 (git 85cb423) | `static` |
| `mob_whisper` | 0.1.1 (git 04590fc) | 0.9.16 (git f17bb11) | 0.7.19 (git 85cb423) | `static` |
| `mob_whisper` | 0.1.1 (git 04590fc) | 0.9.16 (git 9d1b7ad) | 0.7.19 (git 85cb423) | `static` |
| `mob_whisper` | 0.1.1 (git 04590fc) | 0.9.16 (git 1843423) | 0.7.19 (git 85cb423) | `static` |
| `mob_whisper` | 0.1.1 (git 04590fc) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
| `mob_whisper` | 0.1.1 | 0.9.17 | 0.7.20 | `deploy:android`, `release:android` |
| `mob_whisper` | 0.1.1 | 0.9.16 | 0.7.19 | `static`, `deploy:android`, `release:android` |
| `mob_whisper` | 0.1.1 | 0.9.16 | 0.7.17 | `release:android` |
| `mob_whisper` | 0.1.0 (git 53047d0) | 0.9.15 (git 19ca6e1) | 0.7.17 (git 4e63c0d) | `deploy:android`, `release:android` |
