%{
  name: :mob_ci_haptic,
  mob_version: "~> 0.7",
  plugin_spec_version: 1,
  description: "TODO: describe your plugin",
  nifs: [
    # :module is the C/Erlang NIF name (a valid C token), NOT an Elixir
    # module — ERL_NIF_INIT uses it as both the registered module name
    # and the static-init C symbol prefix.
    %{module: :mob_ci_haptic_nif, native_dir: "priv/native/jni"}
  ]
}
