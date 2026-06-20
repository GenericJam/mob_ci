defmodule MobCiGaugeTest do
  use ExUnit.Case, async: true

  # Structural checks that run with no extra deps. For the full pre-publish
  # validation (path/NIF/permission rules + cross-plugin collisions) run
  # `mix mob.validate_plugin` from a host app that has mob_dev. Grow this
  # suite alongside your plugin's pure logic (option builders, parsers, …).
  @plugin_dir Path.expand("..", __DIR__)
  @manifest_path Path.join(@plugin_dir, "priv/mob_plugin.exs")

  test "manifest evaluates to a map with the required keys" do
    assert {%{} = m, _} = Code.eval_file(@manifest_path)
    assert m.name == :mob_ci_gauge
    assert is_binary(m.mob_version)
    assert is_integer(m.plugin_spec_version)
  end

  test "every NIF entry has a loadable stub module and an existing native_dir" do
    {m, _} = Code.eval_file(@manifest_path)

    for %{module: nif_mod, native_dir: dir} <- Map.get(m, :nifs, []) do
      assert Code.ensure_loaded?(nif_mod), "src/#{nif_mod}.erl stub missing or broken"
      assert File.dir?(Path.join(@plugin_dir, dir)), "#{dir} missing"
    end
  end

  test "every screen module the manifest references compiles" do
    {m, _} = Code.eval_file(@manifest_path)

    for %{module: screen_mod} <- Map.get(m, :screens, []) do
      assert Code.ensure_loaded?(screen_mod)
    end
  end
end
