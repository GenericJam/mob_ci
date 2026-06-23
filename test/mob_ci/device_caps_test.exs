defmodule MobCi.DeviceCapsTest do
  use ExUnit.Case, async: true

  alias MobCi.{Context, DeviceCaps, Invariants, Result}

  test "table covers the real sloppy_joe plugins" do
    t = DeviceCaps.table()

    for p <- [:mob_touch, :mob_camera, :mob_location, :mob_biometric, :mob_video],
        do: assert(Map.has_key?(t, p))
  end

  test "nif_probes yields safe probes keyed by NIF module; UI-only plugins are omitted" do
    probes = DeviceCaps.nif_probes([:mob_touch, :mob_location, :mob_biometric, :mob_scanner])
    assert probes[:mob_touch_nif] == {:touch_stop, []}
    assert probes[:mob_location_nif] == {:location_stop, []}
    # biometric/scanner have only UI-triggering exports → no safe probe → omitted
    refute Map.has_key?(probes, :mob_biometric_nif)
    refute Map.has_key?(probes, :mob_scanner_nif)
  end

  test "buildable filters out plugins with a hard host_requirement (screencast)" do
    refute DeviceCaps.buildable?(:mob_screencast)
    assert DeviceCaps.buildable?(:mob_camera)
    refute :mob_screencast in DeviceCaps.buildable(MobCi.Build.sloppy_joe_plugins())
    assert :mob_camera in DeviceCaps.buildable(MobCi.Build.sloppy_joe_plugins())
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
