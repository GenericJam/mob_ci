defmodule MobCi.BuildTest do
  use ExUnit.Case, async: true

  alias MobCi.{Build, Plugins}

  test "plugins_config activates only manifest-bearing plugins (tier-0 omitted)" do
    body = Build.plugins_config(Plugins.sample_set())
    assert body =~ "config :mob, :plugins,"
    assert body =~ ":mob_ci_haptic"
    assert body =~ ":mob_ci_notes"
    # mob_ci_palette is tier-0 (no manifest) → not activated
    refute body =~ ":mob_ci_palette"
  end

  test "harness_deps emits a path dep per manifest-bearing fixture, relative to the harness" do
    deps = Build.harness_deps(Plugins.sample_set(), "/home/kevin/code/mob_ci/fixtures/_harness/app")
    assert Enum.any?(deps, &(&1 =~ "mob_ci_haptic" and &1 =~ "path:"))
    refute Enum.any?(deps, &(&1 =~ "mob_ci_palette"))
  end

  test "deploy_args targets a native x86_64 build" do
    assert Build.deploy_args() == ["mob.deploy", "--native", "--abi", "x86_64"]
  end

  test "parse_permissions reads aapt's uses-permission lines (P6 actual side)" do
    aapt = """
    package: name='com.example.app' versionCode='1'
    uses-permission: name='android.permission.CAMERA'
    uses-permission: name='android.permission.BLUETOOTH_CONNECT'
    application: label='App'
    """

    assert Build.parse_permissions(aapt) ==
             MapSet.new(["android.permission.CAMERA", "android.permission.BLUETOOTH_CONNECT"])
  end

  test "parse_permissions is empty for an APK declaring none" do
    assert Build.parse_permissions("package: name='x'\napplication: label='X'") == MapSet.new()
  end
end
