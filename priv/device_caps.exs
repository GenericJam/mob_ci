# device_caps — per-plugin device-capability baseline for a HEADLESS x86_64 redroid.
#
# The bar for a hardware plugin on an emulator with no camera/GPS/biometric is
# "must not crash the BEAM / must degrade gracefully", NOT "feature works". This
# table records, per plugin:
#
#   :nif    — the Erlang NIF module (for P3 module-load + init checks).
#   :probe  — a SAFE, side-effect-free NIF export {fun, args} that still runs
#             native code, so P3 can confirm the NIF actually INITIALIZED (not
#             just that the stub loaded). The `*_stop`/`*_cancel` exports are
#             idempotent no-ops that prove init without touching hardware/UI.
#             `nil` when no safe probe exists (only UI-triggering exports) — P3
#             then confirms load but skips the init check (honest, not a failure).
#   :screen — expectation for the plugin's DemoScreen on headless redroid:
#               :emulator_ok       — should render normally,
#               :hardware_degraded — may render an error/empty state; a *crash*
#                                    is then a finding, but a graceful error is a
#                                    skip, not a P4 failure,
#               nil                — ships no DemoScreen.
#   :note   — rationale / what was observed.
#
# Refined by the discovery run (the full sloppy_joe set on a headless redroid).
%{
  # ── mob_ci fixtures (synthetic, emulator-native) ──────────────────────────
  mob_ci_haptic: %{nif: :mob_ci_haptic_nif, probe: {:ping, []}, screen: nil},

  # ── real first-party plugins ──────────────────────────────────────────────
  mob_touch: %{
    nif: :mob_touch_nif,
    probe: {:touch_stop, []},
    screen: :emulator_ok,
    note: "touch event monitoring; stop/0 is a safe init probe"
  },
  mob_location: %{
    nif: :mob_location_nif,
    probe: {:location_stop, []},
    screen: :emulator_ok,
    note:
      "no GPS on headless redroid, but the DemoScreen renders an idle state " <>
        "gracefully (discovery: rendered) so P4 holds it to :emulator_ok; " <>
        "location_stop/0 safe probe"
  },
  mob_video: %{
    nif: :mob_video_nif,
    probe: {:video_probe, ["/nonexistent_ci_probe.mp4"]},
    screen: :emulator_ok,
    note: "file-based; probe of a missing file proves init"
  },
  mob_camera: %{
    nif: :mob_camera_nif,
    probe: {:camera_stop_preview, []},
    screen: :emulator_ok,
    note:
      "no camera, but the DemoScreen renders gracefully (discovery: rendered) so " <>
        "P4 holds it to :emulator_ok; preview start fails gracefully; " <>
        "stop_preview safe probe"
  },
  mob_bluetooth: %{
    nif: :mob_bluetooth_nif,
    probe: {:bt_cancel_discovery, []},
    screen: nil,
    note: "no BT adapter; cancel_discovery safe probe"
  },
  mob_notify: %{
    nif: :mob_notify_nif,
    probe: {:notify_cancel, ["mob_ci_probe"]},
    screen: nil,
    note:
      "notify_cancel/1 takes a STRING id (String.t()); cancelling a non-existent " <>
        "id is a safe no-op init probe — integer args raise :badarg in the NIF"
  },
  mob_screencast: %{
    nif: :mob_screencast_nif,
    probe: {:screencast_stop_stream, []},
    screen: nil,
    buildable: false,
    note:
      "host_requirement: needs <service io.mob.screencast.ScreencastService> in the " <>
        "host AndroidManifest (hard build failure without it) — not buildable on an " <>
        "unmodified host, so excluded from the auto-discovery set"
  },
  mob_biometric: %{
    nif: :mob_biometric_nif,
    probe: nil,
    screen: :emulator_ok,
    note:
      "no biometric hw, but the DemoScreen renders gracefully (discovery: rendered) " <>
        "so P4 holds it to :emulator_ok; only authenticate/1 (triggers UI) — no safe probe"
  },
  mob_photos: %{
    nif: :mob_photos_nif,
    probe: nil,
    screen: nil,
    note: "only photos_pick/2 (picker UI) — no safe probe"
  },
  mob_scanner: %{
    nif: :mob_scanner_nif,
    probe: nil,
    screen: nil,
    note: "only scanner_scan/1 (camera UI) — no safe probe"
  }
}
