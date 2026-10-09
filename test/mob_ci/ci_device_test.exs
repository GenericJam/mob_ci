defmodule Mix.Tasks.Ci.DeviceTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ci.Device
  alias MobCi.{Build, DeviceCaps, Plugins}

  describe "parse_host/1" do
    test "defaults to :harness and accepts the two known hosts" do
      assert Device.parse_host(nil) == :harness
      assert Device.parse_host("harness") == :harness
      assert Device.parse_host("sloppy_joe") == :sloppy_joe
    end

    test "rejects an unknown host" do
      assert_raise Mix.Error, fn -> Device.parse_host("android") end
    end
  end

  describe "resolve_set/2" do
    test "no --plugins → the host's default set" do
      assert Device.resolve_set(nil, :harness) == Plugins.sample_set()
      # sloppy_joe default is the real buildable set (device_caps drops the unbuildable).
      assert Device.resolve_set(nil, :sloppy_joe) ==
               DeviceCaps.buildable(Build.sloppy_joe_plugins())
    end

    test "harness CSV gets the mob_ci_ prefix when unqualified" do
      assert Device.resolve_set("haptic,notes", :harness) == [:mob_ci_haptic, :mob_ci_notes]
      # already-qualified names are left alone (no double prefix)
      assert Device.resolve_set("mob_ci_haptic", :harness) == [:mob_ci_haptic]
    end

    test "sloppy_joe CSV gets the mob_ prefix when unqualified" do
      assert Device.resolve_set("touch,notify", :sloppy_joe) == [:mob_touch, :mob_notify]
      assert Device.resolve_set("mob_touch", :sloppy_joe) == [:mob_touch]
    end
  end

  test "the physical Android path goes to the Mac lane; the farm's paths stay on the farm" do
    assert Device.mac_lane_paths?("deploy:android_physical")
    assert Device.mac_lane_paths?("deploy, deploy:android_physical")
    refute Device.mac_lane_paths?("deploy,release")
    refute Device.mac_lane_paths?(nil)
  end
end
