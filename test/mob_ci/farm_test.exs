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

  test "lost_device? recognises adb and mob_dev saying the device went away, and nothing else" do
    for text <- [
          "✗ Android native build failed: Selected Android device(s) disconnected: 127.0.0.1:5700",
          "adb: device offline",
          "error: device '127.0.0.1:5701' not found",
          "adb: no devices/emulators found",
          "error: closed",
          "adb: device still connecting"
        ] do
      assert Farm.lost_device?(text), text
    end

    # nested in an orchestration reason, as Run.error_layer sees it
    assert Farm.lost_device?({:native_build, "… Selected Android device(s) disconnected: 127.0.0.1:5700"})

    for text <- ["zig: error: undefined symbol", "BUILD FAILED", "Performing Streamed Install\nFailure [INSTALL_FAILED_NO_MATCHING_ABIS]", "device ok"] do
      refute Farm.lost_device?(text), text
    end
  end

  test "parse_alive reads ALIVE / LOST <why>; a check that couldn't run proves nothing" do
    assert Farm.parse_alive("ALIVE\n") == :alive
    assert Farm.parse_alive("LOST container ci-redroid0: missing\n") == {:lost, "container ci-redroid0: missing"}
    assert Farm.parse_alive("LOST adb 127.0.0.1:5700: offline") == {:lost, "adb 127.0.0.1:5700: offline"}
    assert Farm.parse_alive("sudo: a password is required\n") == :unknown
    assert Farm.parse_alive("* daemon started successfully\nLOST adb 127.0.0.1:5700: offline\n") == {:lost, "adb 127.0.0.1:5700: offline"}
  end

  describe "ci-farm.sh alive (stub sudo/docker and adb)" do
    setup do
      bin = Path.join(System.tmp_dir!(), "mob_ci_alive_#{System.unique_integer([:positive])}")
      File.mkdir_p!(bin)

      # `sudo docker inspect …` answers $STUB_RUNNING (or fails like a missing container)
      File.write!(Path.join(bin, "sudo"), """
      #!/usr/bin/env bash
      [ "$STUB_RUNNING" = missing ] && { echo; exit 1; }
      echo "$STUB_RUNNING"
      """)

      File.write!(Path.join(bin, "adb"), """
      #!/usr/bin/env bash
      echo "$STUB_ADB_OUT"; exit "$STUB_ADB_CODE"
      """)

      for f <- ~w(sudo adb), do: File.chmod!(Path.join(bin, f), 0o755)
      on_exit(fn -> File.rm_rf!(bin) end)
      %{bin: bin}
    end

    defp alive(bin, running, adb_out, adb_code) do
      {out, 0} =
        System.cmd("bash", [Farm.script(), "alive", "0"],
          env: [
            {"PATH", bin <> ":" <> System.get_env("PATH")},
            {"STUB_RUNNING", running},
            {"STUB_ADB_OUT", adb_out},
            {"STUB_ADB_CODE", to_string(adb_code)},
            {"MOB_CI_ALIVE_TRIES", "2"},
            {"MOB_CI_ALIVE_SLEEP", "0"}
          ],
          stderr_to_stdout: true
        )

      Farm.parse_alive(out)
    end

    test "a running container whose adb sees the device is alive", %{bin: bin} do
      assert alive(bin, "true", "device", 0) == :alive
    end

    test "adb without the device (exit 1) is a loss, after the grace", %{bin: bin} do
      assert alive(bin, "true", "error: device offline", 1) == {:lost, "adb 127.0.0.1:5700: error: device offline"}
    end

    test "a stopped or missing container is a loss", %{bin: bin} do
      assert alive(bin, "false", "device", 0) == {:lost, "container ci-redroid0: false"}
      assert alive(bin, "missing", "device", 0) == {:lost, "container ci-redroid0: missing"}
    end
  end

  test "parse_kv extracts INDEX/SERIAL past progress noise" do
    output = """
    >> waiting for boot_completed...
    INDEX=2
    SERIAL=127.0.0.1:5702
    """

    assert Farm.parse_kv(output, ["INDEX", "SERIAL"]) == %{index: 2, serial: "127.0.0.1:5702"}
  end

  test "dist_cookies dials the project's managed cookie first, then the legacy public one" do
    pkg = "com.example.mob_ci_test_#{System.unique_integer([:positive])}"
    path = MobDev.DistCookie.default_path(pkg)
    on_exit(fn -> File.rm(path) end)

    assert [managed, :mob_secret] = Farm.dist_cookies(pkg)
    assert managed != :mob_secret
    assert Atom.to_string(managed) =~ ~r/^[0-9a-f]{64}$/
    # the same project keeps the same cookie across runs (what deploy wrote is what we dial)
    assert [^managed, :mob_secret] = Farm.dist_cookies(pkg)
  end

  test "await_node never spins on a non-distributed host (no cookie can be tried)" do
    refute Node.alive?()
    refute Farm.await_node(:"nobody_mob_ci@127.0.0.1", 60_000, [:mob_secret, :other])
  end

  test "the ci-farm.sh script exists and is executable" do
    assert File.exists?(Farm.script())
    assert (File.stat!(Farm.script()).mode &&& 0o100) != 0
  end
end
