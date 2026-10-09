# device_caps — per-plugin device-capability baseline for a HEADLESS x86_64 redroid.
#
# The bar for a hardware plugin on an emulator with no camera/GPS/biometric is
# "must not crash the BEAM / must degrade gracefully", NOT "feature works". This
# table records, per plugin:
#
#   :nif       — the Erlang NIF module (for P3 module-load + init checks); nil
#                for a pure-Elixir plugin.
#   :probe     — a SAFE, side-effect-free NIF export {fun, args} that still runs
#                native code, so P3 can confirm the NIF actually INITIALIZED (not
#                just that the stub loaded). `*_stop`/`*_cancel`/`*_available`/
#                `*_caps` exports are idempotent no-ops or read-only queries that
#                prove init without touching hardware/UI. `nil` when no safe probe
#                exists (only UI-triggering or stateful exports) — P3 then confirms
#                load but skips the init check (honest, not a failure).
#   :screen    — expectation for the plugin's declared screens on headless redroid:
#                  :emulator_ok       — must render normally,
#                  :hardware_degraded — may render an error/empty state; a *crash*
#                                       is then a finding, a graceful error a skip,
#                  nil                — ships no screen.
#   :buildable — false when the plugin cannot be built into the CI hosts on this
#                farm (x86_64 redroid, unmodified mob.new --blank host); the reason
#                is in :note and, when it is a defect, in FINDINGS.md.
#   :note      — rationale / what the discovery run observed and when.
#
# Refined by discovery runs (`scripts/discovery.exs`, `mix ci.device`), never guessed:
#   2026-06-22 — the sloppy_joe set on a headless redroid (mob_dev 0.6.x).
#   2026-10-08 — realism gate on sloppy_joe master (mob 0.9.14 / mob_dev 0.7.16,
#                `~/mob_ci_logs/realism7.log`, `realism8.log`) and the harness
#                discovery over the other 15 plugins (`~/mob_ci_logs/disco1.log`).
#   2026-10-09 — the self-test releases (MOB-418; mob 0.9.15 / mob_dev 0.7.17):
#                `singleton:<p>` cells on the `hex` row for mob_background and
#                mob_screencast (`~/mob_ci_logs/caps1.log`), then `all` and
#                `default` on `hex` (`~/mob_ci_logs/caps2.log`).
# P12 (each plugin's own self-test) now proves native init on the hex row; a
# :probe is the read-only export the self-test itself calls where one exists,
# and P3 skips (not errors) when a host's locked release predates that export.
%{
  # ── mob_ci fixtures (synthetic, emulator-native) ──────────────────────────
  mob_ci_haptic: %{nif: :mob_ci_haptic_nif, probe: {:ping, []}, screen: nil},

  # ── sloppy_joe's set (realism gate, 2026-10-08: all NIFs load, 5 screens render) ──
  mob_touch: %{
    nif: :mob_touch_nif,
    probe: {:touch_stop, []},
    screen: :emulator_ok,
    note: "touch event monitoring; stop/0 is a safe init probe (initialized 2026-10-08)"
  },
  mob_location: %{
    nif: :mob_location_nif,
    probe: {:location_stop, []},
    screen: :emulator_ok,
    note:
      "no GPS on headless redroid, but the DemoScreen renders an idle state " <>
        "gracefully (rendered 2026-06-22 and 2026-10-08); location_stop/0 safe probe"
  },
  mob_video: %{
    nif: :mob_video_nif,
    probe: {:video_probe, ["/nonexistent_ci_probe.mp4"]},
    screen: :emulator_ok,
    note: "file-based; probe of a missing file proves init (initialized 2026-10-08)"
  },
  mob_camera: %{
    nif: :mob_camera_nif,
    probe: {:camera_stop_preview, []},
    screen: :emulator_ok,
    note:
      "no camera, but the DemoScreen renders gracefully (rendered 2026-06-22 and " <>
        "2026-10-08); stop_preview safe probe. Host needs the FileProvider the " <>
        "mob.new template already declares"
  },
  mob_bluetooth: %{
    nif: :mob_bluetooth_nif,
    probe: {:bt_cancel_discovery, []},
    screen: nil,
    note: "no BT adapter; cancel_discovery safe probe (initialized 2026-10-08). Composes with mob_midi since mob_dev 0.7.19 (F9)"
  },
  mob_notify: %{
    nif: :mob_notify_nif,
    probe: {:notify_cancel, ["mob_ci_probe"]},
    screen: nil,
    note:
      "notify_cancel/1 takes a STRING id; cancelling a non-existent id is a safe " <>
        "no-op init probe (initialized 2026-10-08). FCM <service> host requirement is " <>
        "a build-time warning only (push is not exercised here)"
  },
  mob_screencast: %{
    nif: :mob_screencast_nif,
    probe: {:screencast_stop_stream, []},
    screen: nil,
    note:
      "F4 resolved: 0.1.3 builds and boots on the generated --blank host without the " <>
        "host's <service io.mob.screencast.ScreencastService> (a build warning; capture " <>
        "would throw at first use). MobScreencast.SelfTest skips there naming the " <>
        "missing <service>; stop_stream initialized (singleton:mob_screencast hex, 2026-10-09)"
  },
  mob_biometric: %{
    nif: :mob_biometric_nif,
    probe: {:biometric_availability, []},
    screen: :emulator_ok,
    note:
      "no biometric hw, but the DemoScreen renders gracefully (rendered 2026-06-22 " <>
        "and 2026-10-08); biometric_availability/0 is the read-only query " <>
        "MobBiometric.SelfTest makes (0.2.0+; older releases have only the UI " <>
        "biometric_authenticate/1, so P3 skips there)"
  },
  mob_photos: %{
    nif: :mob_photos_nif,
    probe: nil,
    screen: nil,
    note:
      "photos_pick/2 opens the picker, media_list/1 needs the media permission — no " <>
        "safe probe; loaded 2026-10-08. Expectations must come from the host's locked " <>
        "version (0.1.3 lacks ACCESS_MEDIA_LOCATION, 0.2.0 declares it)"
  },
  mob_scanner: %{
    nif: :mob_scanner_nif,
    probe: {:scanner_available, []},
    screen: nil,
    note:
      "scanner_available/0 is the read-only query MobScanner.SelfTest makes, no " <>
        "camera opened (0.1.6+; older releases have only scanner_scan/1, the camera " <>
        "UI, so P3 skips there)"
  },
  mob_wake: %{
    nif: :mob_wake_nif,
    probe: {:platform_signal, []},
    screen: nil,
    note: "platform_signal/0 is a read-only query; loaded via sloppy_joe 2026-10-08 (0.1.1)"
  },

  # ── the other 15 (harness discovery, mob.new --blank host, latest Hex) ────
  mob_midi: %{
    nif: :mob_midi_nif,
    probe: {:midi_list_devices, []},
    screen: :hardware_degraded,
    note:
      "no MIDI devices on redroid; list_devices/0 is read-only (initialized 2026-10-08). " <>
        "InputScreen renders; KeyboardScreen degrades gracefully (push leaves the host's " <>
        "HomeScreen showing, BEAM alive) — hardware_degraded, a crash would be a finding"
  },
  mob_nfc: %{
    nif: :mob_nfc_nif,
    probe: {:nfc_available, []},
    screen: nil,
    note: "no NFC on redroid; nfc_available/0 is read-only (initialized 2026-10-08)"
  },
  mob_sms: %{
    nif: :mob_sms_nif,
    probe: {:sms_available, []},
    screen: :emulator_ok,
    note:
      "sms_available/0 is the read-only query MobSms.SelfTest makes (0.2.4+; " <>
        "sms_compose/2 opens the composer, arm_one_time_code/0 registers a " <>
        "receiver); DemoScreen rendered 2026-10-08"
  },
  mob_speech: %{
    nif: :mob_speech_nif,
    probe: {:speech_available, []},
    screen: :emulator_ok,
    note: "no recognizer service on redroid; speech_available/0 is read-only (initialized, DemoScreen rendered 2026-10-08)"
  },
  mob_whisper: %{
    nif: :mob_whisper_nif,
    probe: {:nif_loaded, []},
    screen: nil,
    note: "nif_loaded/0 is the plugin's own init probe (initialized 2026-10-08); the model download is not exercised"
  },
  mob_nx_eigen: %{
    nif: :nx_eigen,
    probe: nil,
    screen: nil,
    buildable: false,
    note:
      "arm-only: mob_dev's native build installs the NxEigen OTP lib for arm64-v8a/" <>
        "armeabi-v7a only (x86_64 never got one, mob_dev native_build.ex), so on the " <>
        "x86_64 farm the NIF cannot load; covered by the arm64 lanes only (docs/budgets.md)"
  },
  mob_scene3d: %{
    nif: :mob_scene3d_nif,
    probe: {:scene3d_caps, []},
    screen: nil,
    note:
      "scene3d_caps/0 is read-only; ui component :scene3d has no showcase convention " <>
        "(P5 skip). Built and initialized on the mob.new 0.6.7 --blank host 2026-10-08 (its jvmTarget-17 host requirement did not bite)"
  },
  mob_doom: %{
    nif: :mob_doom_nif,
    probe: nil,
    screen: nil,
    note: "doom_nif_update/0 before doom_nif_init/1 is undefined behaviour — no safe probe; ui :mob_doom (P5 skip). Built into the discovery host 2026-10-08; its Hex manifest declares no nif/screen so P3 has no subject"
  },
  mob_in_app_purchase: %{
    nif: :mob_iap_nif,
    probe: nil,
    screen: :emulator_ok,
    note: "every export talks to Play Billing (absent on redroid) — no safe probe; built 2026-10-08 (the Hex release's manifest declares fewer screens than master)"
  },
  mob_audio_capture: %{
    nif: :mob_audio_capture_nif,
    probe: {:audio_capture_stop, []},
    screen: :emulator_ok,
    note: "audio_capture_stop/0 is an idempotent no-op (initialized, DemoScreen rendered 2026-10-08); host_requirement <service io.mob.audiocapture.AudioCaptureService> is a warning, the build passes without it"
  },
  mob_background: %{
    nif: :mob_background_nif,
    probe: {:background_status, []},
    screen: nil,
    note:
      "F10 resolved (MOB-423): 0.2.0 ships BeamForegroundService and contributes its " <>
        "<service>, so the --blank host builds. background_status/0 is the read-only " <>
        "query MobBackground.SelfTest makes (0.2.0+; background_stop/0 starts the " <>
        "service to stop it); the self-test passed on deploy and release " <>
        "(singleton:mob_background hex, 2026-10-09)"
  },
  mob_vision: %{
    nif: :mob_vision_nif,
    probe: nil,
    screen: nil,
    note: "recognize_text/1 needs an image — no safe probe; loaded 2026-10-08"
  },
  mob_deliver: %{nif: nil, probe: nil, screen: nil, note: "pure Elixir (deliver agent); nothing native to probe"},
  mob_ash: %{nif: nil, probe: nil, screen: nil, note: "pure Elixir (screens generator); nothing native to probe"},
  mob_mishka: %{nif: nil, probe: nil, screen: nil, note: "pure Elixir components; no ui_components manifest entry, nothing native to probe"}
}
