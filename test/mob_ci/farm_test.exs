defmodule MobCi.FarmTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias MobCi.Farm

  test "node_name follows Mob.Dist's <app>_android_<suffix>@host shape" do
    assert Farm.node_name(:mob_ci_harness, "ci0") == :"mob_ci_harness_android_ci0@127.0.0.1"
    assert Farm.node_name("sloppy_joe", "ci3") == :"sloppy_joe_android_ci3@127.0.0.1"
  end

  test "CI port/suffix bands are disjoint from staging's" do
    # staging: dist 9101+i, suffix redroid<i>. CI must not overlap.
    assert Farm.dist_port(0) == 9300
    assert Farm.dist_port(3) == 9303
    assert Farm.suffix(2) == "ci2"
  end

  test "parse_admit reads the OK/BUSY verdict" do
    assert Farm.parse_admit("OK 1/5\n")
    refute Farm.parse_admit("BUSY 5/5\n")
  end

  test "parse_kv extracts INDEX/SERIAL past progress noise" do
    output = """
    >> waiting for boot_completed...
    INDEX=2
    SERIAL=127.0.0.1:5702
    """

    assert Farm.parse_kv(output, ["INDEX", "SERIAL"]) == %{index: 2, serial: "127.0.0.1:5702"}
  end

  test "the ci-farm.sh script exists and is executable" do
    assert File.exists?(Farm.script())
    assert (File.stat!(Farm.script()).mode &&& 0o100) != 0
  end
end
