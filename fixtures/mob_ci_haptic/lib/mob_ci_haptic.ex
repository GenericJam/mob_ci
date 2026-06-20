defmodule MobCiHaptic do
  @moduledoc """
  Tier-1 mob plugin: native NIF + Elixir wrapper.

  The NIF lives in `src/mob_ci_haptic_nif.erl` (Erlang stub with tolerant
  on_load) + `priv/native/jni/mob_ci_haptic_nif.c` (the C side, ERL_NIF_INIT
  under static linking). This Elixir wrapper delegates to it.

  Activate in your host's `mob.exs`:

      config :mob, :plugins, [:mob_ci_haptic]
  """

  defdelegate ping, to: :mob_ci_haptic_nif
end
