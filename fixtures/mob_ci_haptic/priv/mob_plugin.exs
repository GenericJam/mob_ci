%{
  name: :mob_ci_haptic,
  mob_version: "~> 0.7",
  plugin_spec_version: 1,
  description: "CI fixture: tier-1 NIF plugin (haptics) — exercises P3 + P6.",
  nifs: [
    # :module is the C/Erlang NIF name (a valid C token), NOT an Elixir
    # module — ERL_NIF_INIT uses it as both the registered module name
    # and the static-init C symbol prefix.
    %{module: :mob_ci_haptic_nif, native_dir: "priv/native/jni"}
  ],
  # A haptic plugin genuinely needs VIBRATE — gives P6 a real permission to
  # verify reaches the merged APK (the only sample-set plugin with one).
  android: %{permissions: ["android.permission.VIBRATE"]}
}
