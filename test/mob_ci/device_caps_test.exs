defmodule MobCi.DeviceCapsTest do
  use ExUnit.Case, async: true

  alias MobCi.{Context, DeviceCaps, Invariants, Result}

  @first_party ~w(mob_camera mob_location mob_biometric mob_photos mob_notify mob_scanner
    mob_bluetooth mob_midi mob_nfc mob_sms mob_speech mob_whisper mob_nx_eigen mob_scene3d
    mob_doom mob_in_app_purchase mob_video mob_touch mob_screencast mob_audio_capture
    mob_background mob_vision mob_wake mob_deliver mob_ash mob_mishka)a

  test "the table loads and covers every current first-party plugin (26)" do
    t = DeviceCaps.table()
    assert is_map(t)
    missing = Enum.reject(@first_party, &Map.has_key?(t, &1))
    assert missing == [], "uncovered plugins: #{inspect(missing)}"
  end

  test "every entry has the required keys with well-formed values" do
    for {plugin, entry} <- DeviceCaps.table() do
      assert is_map(entry), "#{plugin} entry must be a map"
      for k <- [:nif, :probe, :screen], do: assert(Map.has_key?(entry, k), "#{plugin} lacks #{k}")
      assert is_nil(entry.nif) or is_atom(entry.nif)
      assert is_nil(entry.probe) or match?({f, args} when is_atom(f) and is_list(args), entry.probe)
      assert entry.screen in [nil, :emulator_ok, :hardware_degraded], "#{plugin} screen=#{inspect(entry.screen)}"
      assert Map.get(entry, :buildable, true) in [true, false]
      # a probe needs a NIF module to be called on
      if entry.probe, do: assert(is_atom(entry.nif) and not is_nil(entry.nif), "#{plugin} probe without nif")
    end
  end

  test "every entry names a real plugin: a mob_ci fixture or a sibling repo with a manifest" do
    for {plugin, _} <- DeviceCaps.table() do
      assert File.exists?(MobCi.Plugins.manifest_path(plugin)), "#{plugin} has no manifest at #{MobCi.Plugins.manifest_path(plugin)}"
    end
  end

  test "a plugin's :nif matches the NIF module its manifest declares" do
    for {plugin, %{nif: nif}} <- DeviceCaps.table(), not is_nil(nif) do
      assert nif in MobCi.Plugins.expected_nif_modules([plugin]), "#{plugin}: #{nif} not in its manifest"
    end
  end

  test "nif_probes yields safe probes keyed by NIF module; UI-only plugins are omitted" do
    probes = DeviceCaps.nif_probes([:mob_touch, :mob_location, :mob_biometric, :mob_scanner])
    assert probes[:mob_touch_nif] == {:touch_stop, []}
    assert probes[:mob_location_nif] == {:location_stop, []}
    # biometric/scanner have only UI-triggering exports → no safe probe → omitted
    refute Map.has_key?(probes, :mob_biometric_nif)
    refute Map.has_key?(probes, :mob_scanner_nif)
  end

  test "buildable filters out exactly the plugins marked buildable: false; unknown plugins pass" do
    refute DeviceCaps.buildable?(:mob_screencast)
    refute DeviceCaps.buildable?(:mob_nx_eigen)
    assert DeviceCaps.buildable?(:mob_camera)
    assert DeviceCaps.buildable?(:mob_not_in_table)
    assert DeviceCaps.buildable([:mob_camera, :mob_screencast, :mob_nx_eigen, :mob_midi]) == [:mob_camera, :mob_midi]
    excluded = for {p, %{buildable: false}} <- DeviceCaps.table(), do: p
    assert DeviceCaps.buildable(@first_party) == @first_party -- excluded
  end

  test "screen_caps maps a plugin's DemoScreen module to its expectation" do
    # Discovery observed every screen-bearing plugin render gracefully on the
    # headless redroid, so the table holds them all to :emulator_ok. The
    # :hardware_degraded escape hatch is exercised via explicit caps below.
    caps = DeviceCaps.screen_caps([:mob_touch, :mob_camera])
    assert caps[MobTouch.DemoScreen] == :emulator_ok
    assert caps[MobCamera.DemoScreen] == :emulator_ok
  end

  describe "P4 honors screen_caps" do
    test "a non-rendering :hardware_degraded screen is a skip, not a fail" do
      # No node → push_and_read errors; with a degraded cap the item should skip.
      ctx = %Context{
        set: [:mob_camera],
        host: :sloppy_joe,
        node: :"nonexistent@127.0.0.1",
        screen_caps: %{MobCamera.DemoScreen => :hardware_degraded}
      }

      assert %Result{status: status} = Invariants.p4(ctx)
      # rollup of one skipped item → skip (not fail/error from the dead node)
      assert status == :skip
    end

    test "a non-rendering :emulator_ok screen stays a fail" do
      ctx = %Context{
        set: [:mob_touch],
        host: :sloppy_joe,
        node: :"nonexistent@127.0.0.1",
        screen_caps: %{MobTouch.DemoScreen => :emulator_ok}
      }

      assert %Result{status: :fail} = Invariants.p4(ctx)
    end
  end
end
