# The physical-device lane: the iPhone and the Motos on the Mac lane

- Date: 2026-10-09
- Status: accepted
- Linear: MOB-419 (under MOB-410), MOB-428

## Context

Every redroid cell and every simulator cell reports hardware plugins'
self-tests as `{:skip, :needs_hardware}` (no NFC, no BLE radio, no biometric
sensor, no camera). MOB-419 runs `default`, `all` and the hardware singletons
(nfc, bluetooth, midi, biometric, camera, scanner, speech, photos) on real
phones so those skips become passes or real failures.

The phones: Kevin's iPhone SE (`00008110-001E1C3A34F8401E`, USB) and two
Motorola phones (moto g power 2021 `ZY22DP6HFL`, Android 11; moto g power 5G
2024 `ZY22K6BSJM`, Android 15). All three are plugged into the Mac mini, where
other agents use them too, through `agent-lease`. The farm lane
(`MobCi.Farm`, `MobCi.Run`) is redroid-only and runs on the NUC.

## Decision

### The Motos stay on the Mac and run through the Mac lane

The phones are leased on the Mac (`agent-lease` is a Mac service), Kevin
develops on them there, and the NUC has no USB devices. Moving them would
take them from the other agents and put two lease systems in play. The iOS
lane already ships a spec to the Mac over ssh, builds there, probes the
device and returns a result line the NUC records, so the Motos take the same
road: a fourth Mac lane path, `deploy:android_physical`
(`MobCi.Lane.Ios.Spec.paths(:android)`).

    mix ci.device --platform android --paths deploy:android_physical --set singleton:mob_nfc --versions hex
    mix ci.ios_cell --path deploy:android_physical --set default --versions hex   # on the Mac, by hand

The worker (`MobCi.Lane.Ios.Worker`) runs it like `deploy:ios_device`:

- **host** — `MobCi.Host.generate/4` with `platform: :android` (package
  `com.example.ci_*`, mob_ci's alone).
- **device** — `adb devices -l`: serials in state `device` on a `usb:`
  transport (emulators, `host:port` redroids, unauthorized and offline
  phones are not candidates), each described by one `getprop` call
  (manufacturer, model, Android release, SDK), newest Android first, or
  exactly the `--serial` given. None: `skip: device_absent`.
- **lease** — `agent-lease acquire <session> --serial <serial>`, first free
  candidate wins; none free: `skip: device_absent` (as for the iPhone).
- **build** — `MobCi.Build.deploy_args/1`, the farm's `mix mob.deploy
  --native --device <serial>` (mob_dev picks the ABI from the phone).
- **probe** — `worker/mac/probe.exs android <serial> …`: grant every runtime
  permission the manifests declare with `adb shell pm grant` (mob_dev's
  `grant_permissions/4` issues it only for emulators; it works on any
  adb-attached phone, as the farm uses it), relaunch and attach through
  `MobDev.Connector`, then P2, P12 and health as on iOS.
- **teardown** — `adb -s <serial> uninstall <package>`, release the lease,
  delete the host and the app's staged BEAMs (`~/.mob/cache/otp-*/<app>`,
  `~/.mob/runtime/*/<app>`).

Results are stored with platform `android`, path `deploy:android_physical`,
so the grid gets a column of its own next to the farm's, and a P12 failure
is settled against the same plugin's singleton on the same phone path.

### Every physical cell records the device

A worker result's `"device"` carries id, name, model and OS (`parse_physical/1`
now reads the iPhone's marketing name; `parse_android_props/2` the Moto's).
`MobCi.Lane.Ios.record/4` passes it as `meta.device`, and `MobCi.Store` keeps
it on every row of the cell under `detail.device` — the matrix can say which
phone and OS a pass or a failure happened on without a schema change.

### Permissions

Android phones are pre-granted (`pm grant`). The iPhone cannot be: there is no
`simctl privacy` for a device and a TCC grant needs the user, so a
permission-gated self-test on the iPhone meets the OS prompt and reports
`{:skip, :needs_user}`, which the matrix keeps as an honest skip.

### The iPhone needed MOB-428 first

`deploy:ios_device` installed but never reached the node: on macOS 27.0.1
`arp` run from the BEAM sees no neighbours, so mob_dev found no USB address,
and the phone named its node after a WiFi address the Mac can't route to
(FINDINGS F12). Fixed in mob_dev 0.7.18 (address from the phone's mDNS name;
`MOB_NODE_HOST` on relaunch) and mob 0.9.16 (`mob_beam.m` honours it). iPhone
cells are meaningful from those versions.

## Alternatives considered

- **Motos on the NUC** (plug them in there, a `Farm`-like instance for a USB
  serial, the full P1–P11 catalog). Takes the phones away from the Mac's
  other users and its lease service; the hardware question MOB-419 asks is
  answered by P12, which the Mac lane already runs.
- **Drive the Mac's adb from the NUC** (ssh-forwarded adb server or `adb
  tcpip`). `adb forward`/`reverse` would bind on the Mac, not the NUC, so
  distribution would need more tunnels; `adb tcpip` resets on reboot.

## Consequences

- The Mac lane is no longer iOS-only; the module keeps its `Lane.Ios` name
  (`mix ci.ios_cell`, `mob_ci_ios_cell.sh`) to avoid churn under the NUC
  triggers, and its docs say "Mac lane".
- A Moto held by another agent, or unplugged, records `skip: device_absent`,
  never red.
- Physical-Android cells cover P2, P12 and health, not P3–P11: those stay on
  the farm, where the same set runs on the same row.
