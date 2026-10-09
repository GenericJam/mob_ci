# The `demo` set: mob_plugin_demo's activation list (its mob.exs,
# `config :mob, :plugins`, copied 2026-10-08). The mob_demo_* entries and
# mob_palette_demo are prototypes that live inside that repo and have no Hex
# package, so a generated host activates only the first-party part — the
# intersection with priv/plugins.exs minus what device_caps marks unbuildable.
# Kept whole so the list can be diffed against the demo app.
%{
  source: "~/code/mob_plugin_demo/mob.exs",
  plugins: [
    :mob_palette_demo,
    :mob_demo_signature_pad,
    :mob_bluetooth,
    :mob_demo_zig_extras,
    :mob_demo_haptic_extras,
    :mob_demo_perm,
    :mob_location,
    :mob_camera,
    :mob_photos,
    :mob_biometric,
    :mob_notify,
    :mob_scanner,
    :mob_ash,
    :mob_screencast,
    :mob_demo_kv_browser,
    :mob_demo_subapp,
    :mob_demo_gen_screens,
    :mob_demo_kit
  ]
}
