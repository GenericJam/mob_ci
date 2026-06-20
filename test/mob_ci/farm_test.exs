defmodule MobCi.FarmTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias MobCi.Farm

  test "node_name follows Mob.Dist's <app>_android_<suffix>@host shape" do
    assert Farm.node_name(:mob_ci_h_haptic, "ci0") == :"mob_ci_h_haptic_android_ci0@127.0.0.1"
    assert Farm.node_name("sloppy_joe", "ci3") == :"sloppy_joe_android_ci3@127.0.0.1"
  end

  test "parse_admit reads the OK/BUSY verdict" do
    assert Farm.parse_admit("OK 1/5\n")
    refute Farm.parse_admit("BUSY 5/5\n")
  end

  test "parse_lease extracts the KEY=value result lines past progress noise" do
    output = """
    >> [ci-redroid0] waiting for boot_completed...
    >> [ci-redroid0] installing APK
    INDEX=0
    SERIAL=127.0.0.1:5700
    SUFFIX=ci0
    DIST_PORT=9300
    """

    assert Farm.parse_lease(output) == %{
             index: 0,
             serial: "127.0.0.1:5700",
             suffix: "ci0",
             dist_port: 9300
           }
  end

  test "the ci-farm.sh script exists and is executable" do
    assert File.exists?(Farm.script())
    stat = File.stat!(Farm.script())
    assert (stat.mode &&& 0o100) != 0, "ci-farm.sh should be executable"
  end
end
