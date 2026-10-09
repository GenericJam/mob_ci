defmodule MobCi.Lane.Ios.WorkerTest do
  # Not async: a cell sets TMPDIR for its children while it runs.
  use ExUnit.Case, async: false

  alias MobCi.Lane.Ios.{Spec, Worker}

  @moduletag :tmp_dir

  @resolved %{
    row: :hex,
    repos: %{
      mob: %{version: "0.9.15", sha: nil, source: :hex, dir: nil},
      mob_dev: %{version: "0.7.17", sha: nil, source: :hex, dir: nil},
      mob_new: %{version: "0.6.7", sha: nil, source: :hex, dir: "/hex/mob_new-0.6.7"},
      mob_camera: %{version: "0.1.12", sha: nil, source: :hex, dir: nil},
      mob_location: %{version: "0.1.6", sha: nil, source: :hex, dir: nil}
    }
  }

  defp spec(path, plugins \\ [:mob_camera, :mob_location]) do
    udid = if Spec.device?(path), do: "UDID-1"
    cell = %{set: "default", plugins: plugins, resolved: @resolved}
    {:ok, spec} = Spec.from_cell(cell, path, stamp: "T1", udid: udid)
    spec
  end

  # Every dep succeeds and reports what it was asked to do; a test overrides
  # the one it is about.
  defp deps(overrides \\ %{}) do
    me = self()

    base = %{
      log: fn _ -> :ok end,
      free_kb: fn -> {:ok, 20 * 1024 * 1024} end,
      resolve: fn _spec -> {:ok, @resolved} end,
      generate: fn _set, _plugins, _resolved, opts ->
        send(me, {:generate, opts})
        dir = Path.join(opts[:root], "ci_default_hex")
        File.mkdir_p!(Path.join(dir, "_build"))
        {:ok, %{dir: dir, app: :ci_default_hex}}
      end,
      mix: fn args, _dir ->
        send(me, {:mix, args})
        {"", 0}
      end,
      simulators: fn -> [%{"udid" => "UDID-1", "name" => "iPhone 17", "runtime" => "27.0"}] end,
      physical_devices: fn ->
        [%{"udid" => "UDID-1", "name" => "Kevin's iPhone", "runtime" => "26.5.2", "attached" => true}]
      end,
      lease: fn session, udid ->
        send(me, {:lease, session, udid})
        :ok
      end,
      release: fn session ->
        send(me, {:release, session})
        {"", 0}
      end,
      uninstall: fn _path, udid, bundle ->
        send(me, {:uninstall, udid, bundle})
        {"", 0}
      end,
      probe: fn _dir, _udid, _out -> {:ok, facts()} end,
      inspect_ipa: fn ipa -> {:ok, %{"name" => Path.basename(ipa), "bytes" => 3, "sha256" => "x", "app" => "A.app"}} end,
      rm_rf: fn path ->
        send(me, {:rm_rf, path})
        File.rm_rf!(path)
      end,
      # No staged app state unless a test makes some.
      mob_home: "/nonexistent/mob_home",
      darwin_tmp: nil
    }

    Map.merge(base, overrides)
  end

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        "found" => true,
        "alive" => true,
        "node" => "ci_default_hex_ios@127.0.0.1",
        "entries" => [
          %{"plugin" => "mob_camera", "status" => "pass", "ms" => 12},
          %{"plugin" => "mob_location", "status" => "skip", "reason" => "no selftest in manifest", "ms" => 0}
        ],
        "findings" => []
      },
      overrides
    )
  end

  defp run(spec, root, deps), do: Worker.run(spec, root: root, deps: deps)

  defp step_names(result), do: Enum.map(result["steps"], &{&1["name"], &1["status"]})

  describe "the disk guard" do
    test "parses df -k / and refuses under 5 GB" do
      df = """
      Filesystem     1024-blocks      Used Available Capacity iused    ifree %iused  Mounted on
      /dev/disk3s1s1   482797652  13338992   6908024    66%  484019 69080240    1%   /
      """

      assert Worker.parse_df(df) == {:ok, 6_908_024}
      assert {:error, _} = Worker.parse_df("df: /: No such file")

      assert Worker.disk_guard(5 * 1024 * 1024) == :ok
      assert {:refuse, "5.0 GB free on /, a cell needs 5.0 GB"} = Worker.disk_guard(5 * 1024 * 1024 - 1)
    end

    test "a cell under the threshold builds nothing and is an error at error:disk", %{tmp_dir: root} do
      r = run(spec("deploy:ios_sim"), root, deps(%{free_kb: fn -> {:ok, 4 * 1024 * 1024} end}))

      assert {r["outcome"], r["layer"]} == {"error", "error:disk"}
      assert r["reason"] =~ "4.0 GB free"
      assert step_names(r) == [{"disk", "error"}]
      refute_received {:generate, _}
      refute_received {:lease, _, _}
    end
  end

  describe "simulator selection" do
    @simctl ~S"""
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
        {"udid": "OLD", "name": "iPhone 17e", "state": "Booted", "isAvailable": true}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        {"udid": "MID", "name": "iPhone 17", "state": "Booted", "isAvailable": true},
        {"udid": "OFF", "name": "iPhone Air", "state": "Shutdown", "isAvailable": true}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
        {"udid": "NEW", "name": "iPhone 18 Pro", "state": "Booted", "isAvailable": true}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [
        {"udid": "WATCH", "name": "Watch", "state": "Booted", "isAvailable": true}
      ]
    }}
    """

    test "reads the booted iOS simulators and their runtimes from simctl's JSON" do
      sims = Worker.parse_simulators(@simctl)

      assert Enum.sort(Enum.map(sims, &{&1["udid"], &1["runtime"]})) ==
               [{"MID", "27.0"}, {"NEW", "27.1"}, {"OLD", "26.5"}]
    end

    test "prefers the newest runtime and never goes below the minimum" do
      sims = Worker.parse_simulators(@simctl)

      assert {:ok, picked} = Worker.pick_simulators(sims, "26.0", nil)
      assert Enum.map(picked, & &1["udid"]) == ["NEW", "MID", "OLD"]

      assert {:ok, picked} = Worker.pick_simulators(sims, "27.0", nil)
      assert Enum.map(picked, & &1["udid"]) == ["NEW", "MID"]

      assert {:error, msg} = Worker.pick_simulators(sims, "28.0", nil)
      assert msg =~ "no booted simulator runs iOS >= 28.0"
      assert msg =~ "iPhone 17e (iOS 26.5)"
    end

    test "a pinned simulator below the minimum is refused, not silently used" do
      sims = Worker.parse_simulators(@simctl)

      assert {:error, "iPhone 17e OLD runs iOS 26.5, below the lane's minimum 27.0"} =
               Worker.pick_simulators(sims, "27.0", "OLD")

      assert {:ok, [%{"udid" => "MID"}]} = Worker.pick_simulators(sims, "27.0", "MID")
      assert {:error, "simulator OFF is not booted"} = Worker.pick_simulators(sims, "27.0", "OFF")
    end

    test "runtime comparison is numeric, not textual" do
      assert Worker.runtime_at_least?("27.10", "27.9")
      assert Worker.runtime_at_least?("26.5.2", "26.5")
      refute Worker.runtime_at_least?("9.3", "27.0")
      refute Worker.runtime_at_least?(nil, "27.0")
    end

    test "an unpinned cell leases the newest free simulator and records its runtime", %{tmp_dir: root} do
      me = self()
      cell = %{set: "default", plugins: [:mob_camera], resolved: @resolved}
      {:ok, auto} = Spec.from_cell(cell, "deploy:ios_sim", stamp: "T1")
      assert auto.udid == nil and auto.min_runtime == "27.0"

      d =
        deps(%{
          simulators: fn -> Worker.parse_simulators(@simctl) end,
          # The newest is held by another agent: the next newest is used.
          lease: fn _session, udid ->
            send(me, {:lease_try, udid})
            if udid == "NEW", do: {:error, "DEVICE_IN_USE"}, else: :ok
          end
        })

      r = run(auto, root, d)

      assert r["outcome"] == "pass"
      assert r["device"] == %{"udid" => "MID", "name" => "iPhone 17", "runtime" => "27.0"}
      assert r["udid"] == "MID"
      assert_received {:lease_try, "NEW"}
      assert_received {:lease_try, "MID"}
      refute_received {:lease_try, "OLD"}
      assert_received {:mix, ["mob.deploy", "--native", "--ios", "--device", "MID"]}
      assert_received {:uninstall, "MID", _}
    end

    test "the iPhone's identity and OS come from devicectl's JSON" do
      json = ~S"""
      {"result": {"devices": [
        {"hardwareProperties": {"reality": "physical", "udid": "00008110-X"},
         "deviceProperties": {"name": "Kevin's iPhone", "osVersionNumber": "26.5.2"},
         "connectionProperties": {"tunnelState": "disconnected"}},
        {"hardwareProperties": {"reality": "physical", "udid": "OTHER"},
         "deviceProperties": {"name": "iPad", "osVersionNumber": "27.0"},
         "connectionProperties": {"tunnelState": "unavailable"}},
        {"hardwareProperties": {"reality": "simulated", "udid": "SIM"},
         "deviceProperties": {"name": "iPhone 17"}, "connectionProperties": {}}
      ]}}
      """

      assert Worker.parse_physical(json) == [
               # An idle wired iPhone's tunnel is "disconnected" until used: still attached.
               %{"udid" => "00008110-X", "name" => "Kevin's iPhone", "runtime" => "26.5.2", "attached" => true},
               %{"udid" => "OTHER", "name" => "iPad", "runtime" => "27.0", "attached" => false}
             ]
    end

    test "a command tail cut inside a multibyte character is still valid UTF-8 (it goes into the result JSON)" do
      tee = Enum.into(["✓", String.duplicate("a", 1998)], %MobCi.Lane.Ios.Tee{echo: false})
      assert String.valid?(tee.tail)
      assert tee.tail == String.duplicate("a", 1998)
      assert JSON.encode!(%{"detail" => tee.tail}) =~ "aaa"
    end

    test "a lease release that exits non-zero is recorded as such, not as ok", %{tmp_dir: root} do
      r = run(spec("deploy:ios_sim"), root, deps(%{release: fn _ -> {"no such session\n", 3} end}))
      assert %{"result" => "exited 3: no such session"} = Enum.find(r["teardown"], &(&1["name"] == "release_lease"))
    end
  end

  describe "a deploy:ios_sim cell" do
    test "passes through every step, leases, uninstalls and deletes its scratch dir", %{tmp_dir: root} do
      r = run(spec("deploy:ios_sim"), root, deps())

      assert r["outcome"] == "pass"

      assert step_names(r) ==
               Enum.map(~w(disk resolve generate doctor device lease build probe), &{&1, "ok"})

      assert_received {:generate, opts}
      assert opts[:platform] == :ios
      assert opts[:mob_exs][:ios_bundle_id] == "com.genericjam.mobci"
      assert_received {:mix, ["mob.doctor"]}
      assert_received {:mix, ["mob.deploy", "--native", "--ios", "--device", "UDID-1"]}
      assert_received {:uninstall, "UDID-1", "com.genericjam.mobci"}
      assert_received {:release, "mob_ci_ios_default-hex-deploy_ios_sim-t1"}

      scratch = Path.join(root, r["cell_id"])
      assert_received {:rm_rf, ^scratch}
      refute File.exists?(scratch)

      assert Enum.map(r["invariants"], &{&1["id"], &1["status"]}) == [
               {"p2", "pass"},
               {"p12:mob_camera", "pass"},
               {"p12:mob_location", "skip"},
               {"health", "pass"}
             ]

      assert r["disk"]["before_kb"] == 20 * 1024 * 1024
    end

    test "children get the cell's own TMPDIR, and the worker's is restored after", %{tmp_dir: root} do
      before = System.get_env("TMPDIR")
      me = self()

      d = deps(%{mix: fn _args, _dir -> send(me, {:tmpdir, System.get_env("TMPDIR")}) && {"", 0} end})
      r = run(spec("release:ios"), root, d)

      assert_received {:tmpdir, tmp}
      assert tmp == Path.join([root, r["cell_id"], "tmp"])
      assert System.get_env("TMPDIR") == before
    end

    test "a step that raises is an error at its own layer, and teardown still deletes the host", %{tmp_dir: root} do
      crash = fn _set, _plugins, _resolved, opts ->
        File.mkdir_p!(Path.join([opts[:root], "ci_default_hex", "_build"]))
        raise "boom"
      end

      r = run(spec("deploy:ios_sim"), root, deps(%{generate: crash}))

      assert {r["outcome"], r["layer"]} == {"error", "mob_new"}
      assert r["reason"] =~ "generate crashed: boom"
      refute File.exists?(Path.join(root, r["cell_id"]))
      assert Enum.map(r["teardown"], & &1["name"]) == ["delete_app_state", "delete_scratch"]
    end

    test "a crash after the lease still uninstalls, releases and deletes", %{tmp_dir: root} do
      crash = fn ["mob.deploy" | _], _dir -> raise "xcodebuild vanished" end
      mix = fn
        ["mob.doctor"], _ -> {"", 0}
        args, dir -> crash.(args, dir)
      end

      r = run(spec("deploy:ios_sim"), root, deps(%{mix: mix}))

      assert {r["outcome"], r["layer"]} == {"error", "build:deploy:ios_sim"}
      assert Enum.map(r["teardown"], & &1["name"]) ==
               ["uninstall", "release_lease", "delete_app_state", "delete_scratch"]
      refute File.exists?(Path.join(root, r["cell_id"]))
    end

    test "a failing teardown action does not stop the next one", %{tmp_dir: root} do
      d = deps(%{uninstall: fn _, _, _ -> raise "simctl hung" end})
      r = run(spec("deploy:ios_sim"), root, d)

      assert [%{"name" => "uninstall", "result" => "simctl hung"} | rest] = r["teardown"]
      assert Enum.map(rest, & &1["result"]) == ["ok", "ok", "ok"]
      refute File.exists?(Path.join(root, r["cell_id"]))
    end

    test "the app's staged BEAMs and mob_dev's leaked release build dir go too; nothing else does", %{tmp_dir: root} do
      home = Path.join(root, "mob_home")
      darwin_tmp = Path.join(root, "T")

      ours = [
        Path.join(home, "cache/otp-ios-sim-5c9c69fc/ci_default_hex"),
        Path.join(home, "runtime/ios-sim/ci_default_hex"),
        # release_device.sh's BUILD_DIR=$(mktemp -d), never removed
        Path.join(darwin_tmp, "tmp.Wm8qifonVw/CiDefaultHex.app")
      ]

      kept = [
        Path.join(home, "runtime/ios-sim/erts-17.0"),
        Path.join(home, "runtime/ios-sim/other_app"),
        Path.join(darwin_tmp, "tmp.Other123/OtherApp.app"),
        Path.join(darwin_tmp, "mob_ios_sim_1_2/CiDefaultHex.app")
      ]

      Enum.each(ours ++ kept, &File.mkdir_p!/1)

      r = run(spec("deploy:ios_sim"), Path.join(root, "cells"), deps(%{mob_home: home, darwin_tmp: darwin_tmp}))

      assert r["outcome"] == "pass"
      refute Enum.any?(ours, &File.exists?/1)
      refute File.exists?(Path.join(darwin_tmp, "tmp.Wm8qifonVw"))
      assert Enum.all?(kept, &File.dir?/1)
    end
  end

  describe "attribution: each failing step names its layer" do
    test "every pre-probe step and the probe stop the cell at their own layer, and the host is deleted", %{tmp_dir: root} do
      cases = [
        {"resolve", %{resolve: fn _ -> {:error, {:mob_new, :offline}} end}, "error", "error:worker"},
        {"generate", %{generate: fn _, _, _, _ -> {:error, {:mob_new, :no_project}} end}, "fail", "mob_new"},
        {"generate", %{generate: fn _, _, _, _ -> {:error, {:elixir, {"deps.get", 1, "x"}}} end}, "fail", "elixir"},
        {"doctor", %{mix: fn ["mob.doctor"], _ -> {"✗ Xcode", 1} end}, "fail", "doctor"},
        {"device", %{simulators: fn -> [] end}, "error", "boot"},
        {"lease", %{lease: fn _, _ -> {:error, "DEVICE_IN_USE"} end}, "error", "boot"},
        {"build",
         %{
           mix: fn
             ["mob.deploy" | _], _ -> {"zig: error", 1}
             _, _ -> {"", 0}
           end
         }, "fail", "build:deploy:ios_sim"},
        {"probe", %{probe: fn _, _, _ -> {:error, "probe exited 1"} end}, "error", "error:worker"}
      ]

      for {step, override, outcome, layer} <- cases do
        r = run(spec("deploy:ios_sim"), root, deps(override))

        assert {step, r["outcome"], r["layer"]} == {step, outcome, layer}
        assert List.last(r["steps"])["name"] == step
        refute File.exists?(Path.join(root, r["cell_id"]))
      end
    end

    test "the node not coming up is p2 at boot; a self-test failure names the plugin; a health rise is health", %{tmp_dir: root} do
      down = facts(%{"alive" => false, "node" => nil, "connect_error" => ":timeout"})
      r = run(spec("deploy:ios_sim"), root, deps(%{probe: fn _, _, _ -> {:ok, down} end}))
      assert {r["outcome"], r["layer"]} == {"fail", "boot"}
      assert r["reason"] =~ "p2: node did not come up: :timeout"

      failing =
        facts(%{
          "entries" => [
            %{"plugin" => "mob_camera", "status" => "fail", "reason" => "nif not loaded", "ms" => 3}
          ]
        })

      r = run(spec("deploy:ios_sim"), root, deps(%{probe: fn _, _, _ -> {:ok, failing} end}))
      # In company the plugin is only provisionally to blame (the NUC compares
      # with its singleton cell).
      assert {r["outcome"], r["layer"]} == {"fail", "plugin:mob_camera?"}

      r =
        run(spec("deploy:ios_sim", [:mob_camera]), root, deps(%{probe: fn _, _, _ -> {:ok, failing} end}))

      assert r["layer"] == "plugin:mob_camera"

      sick = facts(%{"findings" => [%{"kind" => "failure", "message" => "store :x lost rose 0 → 2"}]})
      r = run(spec("deploy:ios_sim"), root, deps(%{probe: fn _, _, _ -> {:ok, sick} end}))
      assert {r["outcome"], r["layer"]} == {"fail", "health"}
    end
  end

  describe "a deploy:ios_device cell" do
    test "an iPhone that is not attached is a skip: device_absent, and nothing is touched", %{tmp_dir: root} do
      r = run(spec("deploy:ios_device"), root, deps(%{physical_devices: fn -> [] end}))

      assert r["outcome"] == "skip"
      assert r["reason"] =~ "device_absent"
      refute_received {:lease, _, _}
      refute_received {:uninstall, _, _}
    end

    test "an iPhone another session holds is a skip: device_absent, and is not uninstalled", %{tmp_dir: root} do
      r = run(spec("deploy:ios_device"), root, deps(%{lease: fn _, _ -> {:error, "DEVICE_IN_USE"} end}))

      assert r["outcome"] == "skip"
      assert r["reason"] =~ ~r/^device_absent: UDID-1 is not leasable \(.*DEVICE_IN_USE\)$/
      refute_received {:uninstall, _, _}
      assert_received {:release, _}
    end
  end

  describe "a release:ios cell" do
    test "builds the driver table then the release, with the App Store bundle id, and records the .ipa", %{tmp_dir: root} do
      me = self()

      mix = fn args, dir ->
        send(me, {:mix, args})

        if hd(args) == "mob.release" do
          File.mkdir_p!(Path.join(dir, "_build/mob_release"))
          File.write!(Path.join(dir, "_build/mob_release/CiDefaultHex.ipa"), "zip")
        end

        {"", 0}
      end

      r = run(spec("release:ios"), root, deps(%{mix: mix}))

      assert r["outcome"] == "pass"
      assert step_names(r) == Enum.map(~w(disk resolve generate doctor build artifact), &{&1, "ok"})
      assert_received {:generate, opts}
      assert opts[:mob_exs][:ios_bundle_id] == "com.genericjam.io"
      assert_received {:mix, ["mob.regen_driver_tab", "--format", "c"]}
      assert_received {:mix, ["mob.release", "--ios"]}
      assert r["artifacts"]["ipa"]["name"] == "CiDefaultHex.ipa"
      refute_received {:lease, _, _}
      refute File.exists?(Path.join(root, r["cell_id"]))
    end

    test "a release that exits 0 without an .ipa is a build:release:ios failure", %{tmp_dir: root} do
      r = run(spec("release:ios"), root, deps())
      assert {r["outcome"], r["layer"]} == {"fail", "build:release:ios"}
      assert r["reason"] =~ "wrote no _build/mob_release/*.ipa"
    end
  end

  describe "inspect_ipa/1" do
    test "accepts a signed Payload/*.app archive and rejects an unsigned one or a non-zip", %{tmp_dir: dir} do
      signed = zip(dir, "S.ipa", ["Payload/A.app/A", "Payload/A.app/_CodeSignature/CodeResources"])
      unsigned = zip(dir, "U.ipa", ["Payload/A.app/A"])
      File.write!(Path.join(dir, "N.ipa"), "not a zip")

      assert {:ok, %{"name" => "S.ipa", "app" => "A.app", "bytes" => bytes, "sha256" => sha}} =
               Worker.inspect_ipa(signed)

      assert bytes == File.stat!(signed).size
      assert sha == :crypto.hash(:sha256, File.read!(signed)) |> Base.encode16(case: :lower)

      assert {:error, "Payload/A.app is not signed" <> _} = Worker.inspect_ipa(unsigned)
      assert {:error, "not a zip" <> _} = Worker.inspect_ipa(Path.join(dir, "N.ipa"))
    end
  end

  defp zip(dir, name, files) do
    path = Path.join(dir, name)
    entries = for f <- files, do: {String.to_charlist(f), "x"}
    {:ok, _} = :zip.create(String.to_charlist(path), entries)
    path
  end
end
