# plugins — the first-party mob plugins a version row resolves, with the GitHub
# repo each one lives in. A plugin is "first-party" when GenericJam publishes
# it on Hex AND it ships `priv/mob_plugin.exs` (a manifest the host activates).
# Libraries without a manifest (mob_push, mob_rapier, mob_themes's style
# package) are deps, not plugins, and are not listed.
#
# Order is the deterministic order every set and the pairwise array use. The
# 2026-10-08 decision record says "26"; as of that date Hex has 25 GenericJam
# packages that ship a manifest (checked tarball by tarball).
[
  mob_ash: "https://github.com/GenericJam/mob_ash",
  mob_audio_capture: "https://github.com/GenericJam/mob_audio_capture",
  mob_background: "https://github.com/GenericJam/mob_background",
  mob_biometric: "https://github.com/GenericJam/mob_biometric",
  mob_bluetooth: "https://github.com/GenericJam/mob_bluetooth",
  mob_camera: "https://github.com/GenericJam/mob_camera",
  mob_deliver: "https://github.com/GenericJam/mob_deliver",
  mob_location: "https://github.com/GenericJam/mob_location",
  mob_midi: "https://github.com/GenericJam/mob_midi",
  mob_mishka: "https://github.com/GenericJam/mob_mishka",
  mob_nfc: "https://github.com/GenericJam/mob_nfc",
  mob_notify: "https://github.com/GenericJam/mob_notify",
  mob_nx_eigen: "https://github.com/GenericJam/mob_nx_eigen",
  mob_photos: "https://github.com/GenericJam/mob_photos",
  mob_scanner: "https://github.com/GenericJam/mob_scanner",
  mob_scene3d: "https://github.com/GenericJam/mob_scene3d",
  mob_screencast: "https://github.com/GenericJam/mob_screencast",
  mob_sensors: "https://github.com/GenericJam/mob_sensors",
  mob_sms: "https://github.com/GenericJam/mob_sms",
  mob_speech: "https://github.com/GenericJam/mob_speech",
  mob_touch: "https://github.com/GenericJam/mob_touch",
  mob_video: "https://github.com/GenericJam/mob_video",
  mob_vision: "https://github.com/GenericJam/mob_vision",
  mob_wake: "https://github.com/GenericJam/mob_wake",
  mob_whisper: "https://github.com/GenericJam/mob_whisper"
]
