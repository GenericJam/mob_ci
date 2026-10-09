defmodule MobCi.Lane.IosTest do
  use ExUnit.Case, async: true

  alias MobCi.Lane.Ios
  alias MobCi.Lane.Ios.Spec
  alias MobCi.Result

  @moduletag :tmp_dir

  @sha String.duplicate("c", 40)

  @resolved %{
    row: :hex,
    repos: %{
      mob: %{version: "0.9.15", sha: nil, source: :hex, dir: nil},
      mob_dev: %{version: "0.7.17", sha: nil, source: :hex, dir: nil},
      mob_new: %{version: "0.6.7", sha: nil, source: :hex, dir: "/hex/mob_new-0.6.7"},
      mob_camera: %{version: "0.1.12", sha: nil, source: :hex, dir: nil}
    }
  }

  @cell %{set: "default", plugins: [:mob_camera], resolved: @resolved}

  defp spec(path) do
    {:ok, spec} = Spec.from_cell(@cell, path, stamp: "T1", udid: Ios.udid_for(path, []), mob_ci_sha: @sha)
    spec
  end

  defp worker_result(spec, fields) do
    Map.merge(Ios.error_result(spec, nil, nil), %{"outcome" => "pass", "layer" => nil, "reason" => nil})
    |> Map.merge(fields)
  end

  describe "the ssh commands" do
    test "are key-only, fail fast and keep a long build alive" do
      argv = Ios.ssh_argv("kevin@10.0.0.71", "true")
      assert ["-o", "BatchMode=yes" | _] = argv
      assert "ConnectTimeout=15" in argv
      assert "ServerAliveInterval=30" in argv
      assert Enum.take(argv, -2) == ["kevin@10.0.0.71", "true"]
    end

    test "sync ships the script inline and checks out exactly the given sha" do
      cmd = Ios.sync_command(@sha, "echo synced\n")
      assert [_, "echo", b64, "|", "base64", "-d", "|", "bash", "-s", "--", sha] = ["" | String.split(cmd, " ")]
      assert Base.decode64!(b64) == "echo synced\n"
      assert sha == @sha

      # The real script is the one in worker/mac.
      assert Ios.sync_command(@sha) =~ Base.encode64(File.read!("worker/mac/sync.sh"))

      assert_raise ArgumentError, fn -> Ios.sync_command("main; rm -rf ~") end
    end

    test "a cell command carries the spec, which decodes back to the same spec" do
      spec = spec("deploy:ios_sim")
      cmd = Ios.cell_command(spec)

      assert cmd =~ ~s|"$HOME/.cache/mob_ci/worker/mob_ci/worker/mac/mob_ci_ios_cell.sh" --spec-b64 |
      [_, b64] = String.split(cmd, "--spec-b64 ")
      assert Spec.from_json(Base.decode64!(b64)) == {:ok, spec}
      # Nothing the remote shell would interpret.
      assert b64 =~ ~r/^[A-Za-z0-9+\/=]+$/
    end
  end

  describe "collecting a session" do
    test "takes the last result line of the log" do
      spec = spec("release:ios")
      first = JSON.encode!(worker_result(spec, %{"outcome" => "fail"}))
      last = JSON.encode!(worker_result(spec, %{"outcome" => "pass"}))

      log = "build output\nMOB_CI_RESULT #{first}\nmore\nMOB_CI_RESULT #{last}\n"
      assert %{"outcome" => "pass"} = Ios.collect(spec, 0, log)
    end

    test "a session that ended without a result is an error at error:ssh with the exit code and the tail" do
      spec = spec("deploy:ios_sim")

      r = Ios.collect(spec, 255, "kevin@10.0.0.71: Permission denied (publickey).\n")
      assert {r["outcome"], r["layer"]} == {"error", "error:ssh"}
      assert r["reason"] =~ "ssh session exited 255 without a result: kevin@10.0.0.71: Permission denied"
      assert r["cell_id"] == spec.cell_id

      # A truncated result line is not a result.
      assert %{"layer" => "error:ssh"} = Ios.collect(spec, 0, "MOB_CI_RESULT {\"schema\":1,")
    end
  end

  describe "run/3 with a stubbed transport" do
    defp transport(test, exits) do
      fn argv, log ->
        send(test, {:ssh, argv, log})
        command = List.last(argv)

        cond do
          command =~ "base64 -d | bash -s" ->
            File.write!(log, "worker: mob_ci ccccccc\n")
            exits.sync

          command =~ "--spec-b64" ->
            [_, b64] = String.split(command, "--spec-b64 ")
            {:ok, spec} = Spec.from_json(Base.decode64!(b64))
            body = if exits.cell == 0, do: "MOB_CI_RESULT " <> JSON.encode!(worker_result(spec, %{})), else: "boom"
            File.write!(log, body <> "\n")
            exits.cell
        end
      end
    end

    defp run!(dir, exits, opts \\ []) do
      opts =
        opts ++
          [ssh: transport(self(), exits), log_dir: dir, mob_ci_sha: @sha, stamp: "T1", static: fn _ -> [] end]

      Ios.run(@cell, ["deploy:ios_sim", "release:ios"], opts)
    end

    test "syncs once, then runs each path in its own session, logging and writing a result per cell", %{tmp_dir: dir} do
      results = run!(dir, %{sync: 0, cell: 0}, host: "kevin@mac")

      assert Enum.map(results, & &1["outcome"]) == ["pass", "pass"]
      assert_received {:ssh, sync_argv, _}
      assert List.last(sync_argv) =~ "bash -s -- #{@sha}"
      assert "kevin@mac" in sync_argv

      for r <- results do
        assert File.read!(r["log_path"]) =~ "MOB_CI_RESULT"
        assert JSON.decode!(File.read!(Path.join(dir, r["cell_id"] <> ".json")))["outcome"] == "pass"
      end
    end

    test "a failing sync is an error:ssh cell for every path, and no cell session is opened", %{tmp_dir: dir} do
      results = run!(dir, %{sync: 128, cell: 0})

      assert Enum.map(results, &{&1["outcome"], &1["layer"]}) == [{"error", "error:ssh"}, {"error", "error:ssh"}]
      assert hd(results)["reason"] =~ "worker sync to #{@sha} on kevin@10.0.0.71 exited 128"
      assert_received {:ssh, _, _}
      refute_received {:ssh, _, _}
    end

    test "a worker that dies mid-cell is error:ssh carrying the exit code", %{tmp_dir: dir} do
      [r | _] = run!(dir, %{sync: 0, cell: 2})
      assert {r["outcome"], r["layer"]} == {"error", "error:ssh"}
      assert r["reason"] =~ "exited 2 without a result: boom"
    end

    test "a set the static gate rejects never leaves the NUC", %{tmp_dir: dir} do
      results = run!(dir, %{sync: 0, cell: 0}, static: fn [:mob_camera] -> ["NSCameraUsageDescription twice"] end)

      assert Enum.map(results, &{&1["outcome"], &1["layer"]}) == [{"error", "static"}, {"error", "static"}]
      assert hd(results)["reason"] == "static gate: NSCameraUsageDescription twice"
      refute_received {:ssh, _, _}
    end

    test "the simulator is left to the worker unless pinned; the iPhone defaults to Kevin's", %{tmp_dir: dir} do
      run!(dir, %{sync: 0, cell: 0}, min_runtime: "27.1")
      assert_received {:ssh, _, _}
      assert_received {:ssh, sim_argv, _}
      [_, b64] = String.split(List.last(sim_argv), "--spec-b64 ")
      {:ok, sim} = Spec.from_json(Base.decode64!(b64))
      assert {sim.udid, sim.min_runtime} == {nil, "27.1"}

      assert Ios.udid_for("deploy:ios_sim", sim_udid: "S") == "S"
      assert Ios.udid_for("deploy:ios_device", []) == "00008110-001E1C3A34F8401E"
      assert Ios.udid_for("release:ios", sim_udid: "S") == nil
    end
  end

  describe "to_outcome/1 (what the results store records)" do
    test "a cell stopped at a step is an error at that step's layer" do
      spec = spec("release:ios")

      for layer <- ["mob_new", "elixir", "doctor", "build:release:ios", "error:disk", "error:ssh", "static"] do
        r = worker_result(spec, %{"outcome" => "fail", "layer" => layer, "reason" => "why"})
        assert Ios.to_outcome(r) == {:error, "why", layer}
      end
    end

    test "an absent iPhone is a skip, not a failure" do
      r = worker_result(spec("deploy:ios_device"), %{"outcome" => "skip", "reason" => "device_absent: X"})
      assert {:ok, [%Result{id: :p2, status: :skip, detail: "device_absent: X"}]} = Ios.to_outcome(r)
    end

    test "a release is one pass carrying the archive" do
      ipa = %{"name" => "CiDefaultHex.ipa", "app" => "CiDefaultHex.app", "bytes" => 10, "sha256" => "ab"}
      r = worker_result(spec("release:ios"), %{"artifacts" => %{"ipa" => ipa}})

      assert {:ok, [%Result{id: :ipa, status: :pass, evidence: ^ipa, detail: detail}]} = Ios.to_outcome(r)
      assert detail =~ "CiDefaultHex.ipa"
    end

    test "a device run is p2, p12 with one item per plugin, and health; failures keep their layers" do
      invs = [
        %{"id" => "p2", "status" => "pass", "layer" => nil, "detail" => "up"},
        %{"id" => "p12:mob_camera", "status" => "fail", "layer" => "plugin:mob_camera", "detail" => "nif"},
        %{"id" => "p12:mob_location", "status" => "skip", "layer" => nil, "detail" => "no selftest in manifest"},
        %{"id" => "health", "status" => "pass", "layer" => nil, "detail" => "counters unchanged"}
      ]

      r = worker_result(spec("deploy:ios_sim"), %{"outcome" => "fail", "invariants" => invs})
      assert {:fail, [p2, health, p12]} = Ios.to_outcome(r)

      assert {p2.id, p2.status} == {:p2, :pass}
      assert {health.id, health.status} == {:health, :pass}
      assert {p12.id, p12.status, p12.layer} == {:p12, :fail, "plugin:mob_camera"}

      assert Enum.map(p12.evidence.items, &{&1.id, &1.title, &1.status, &1.layer}) == [
               {:p12_item, "mob_camera", :fail, "plugin:mob_camera"},
               {:p12_item, "mob_location", :skip, nil}
             ]

      ok = worker_result(spec("deploy:ios_sim"), %{"invariants" => Enum.reject(invs, &(&1["status"] == "fail"))})
      assert {:ok, _} = Ios.to_outcome(ok)
    end
  end

  test "--paths parses one platform's Mac lane paths and refuses anything else" do
    assert Ios.parse_paths!(nil) == ["deploy:ios_sim", "deploy:ios_device", "release:ios"]
    assert Ios.parse_paths!("release:ios, deploy:ios_sim") == ["release:ios", "deploy:ios_sim"]
    assert_raise Mix.Error, ~r/unknown ios Mac lane path\(s\) deploy:android/, fn -> Ios.parse_paths!("deploy:android") end

    assert Ios.parse_paths!(nil, :android) == ["deploy:android_physical"]
    # The farm's redroid paths are not the Mac's, and an iOS run takes no Android path.
    assert_raise Mix.Error, ~r/unknown android Mac lane path\(s\) deploy \(expected: deploy:android_physical\)/, fn ->
      Ios.parse_paths!("deploy:android_physical,deploy", :android)
    end

    assert_raise Mix.Error, ~r/deploy:android_physical/, fn -> Ios.parse_paths!("deploy:android_physical") end
  end

  describe "the results store" do
    defp p12_fail(spec) do
      worker_result(spec, %{
        "outcome" => "fail",
        "duration_ms" => 1234,
        "log_path" => "/logs/x.log",
        "invariants" => [
          %{"id" => "p2", "status" => "pass", "layer" => nil, "detail" => "up"},
          %{"id" => "p12:mob_camera", "status" => "fail", "layer" => "plugin:mob_camera?", "detail" => "nif"},
          %{"id" => "health", "status" => "pass", "layer" => nil, "detail" => "ok"}
        ]
      })
    end

    test "a P12 failure in company is settled against the plugin's singleton cell" do
      outcome = Ios.to_outcome(p12_fail(spec("deploy:ios_sim")))
      set = [:mob_camera, :mob_location]

      layer = fn singleton ->
        {:fail, results} = Ios.settle_p12(outcome, set, fn :mob_camera -> singleton end)
        p12 = Enum.find(results, &(&1.id == :p12))
        {p12.layer, hd(p12.evidence.items).layer}
      end

      assert layer.(:pass) == {{:conflict, set}, {:conflict, set}}
      assert layer.(:fail) == {{:plugin, :mob_camera}, {:plugin, :mob_camera}}
      assert layer.(nil) == {{:plugin_unconfirmed, :mob_camera}, {:plugin_unconfirmed, :mob_camera}}

      # Nothing to settle on an error outcome.
      assert Ios.settle_p12({:error, "x", "doctor"}, set, fn _ -> :pass end) == {:error, "x", "doctor"}
    end

    test "a lane run lands in the store as platform ios, one summary and its invariants per path", %{tmp_dir: dir} do
      {:ok, store} = MobCi.Store.open(Path.join(dir, "results.sqlite"))

      try do
        results = [
          p12_fail(spec("deploy:ios_sim")),
          worker_result(spec("release:ios"), %{"outcome" => "fail", "layer" => "build:release:ios", "reason" => "link"})
        ]

        {:ok, run_id} = Ios.record(store, @cell, results, host: "kevin@mac")
        rows = MobCi.Store.query(store, run_id: run_id)
        # The run carries the sha the worker checked out, not NULL.
        assert Enum.all?(rows, &(&1.mob_ci_sha == @sha))

        summary = fn path -> Enum.find(rows, &(&1.path == path and is_nil(&1.invariant))) end
        assert %{platform: "ios", outcome: :fail, layer: "plugin:mob_camera"} = summary.("deploy:ios_sim")
        assert %{outcome: :error, layer: "build:release:ios"} = summary.("release:ios")

        assert %{outcome: :fail, layer: "plugin:mob_camera"} =
                 Enum.find(rows, &(&1.invariant == "p12:mob_camera"))
      after
        MobCi.Store.close(store)
      end
    end

    test "a physical Android cell is stored as platform android, every row naming the phone it ran on", %{tmp_dir: dir} do
      {:ok, store} = MobCi.Store.open(Path.join(dir, "results.sqlite"))

      moto = %{
        "udid" => "ZY22DP6HFL",
        "name" => "moto g power (2021)",
        "model" => "motorola moto g power (2021)",
        "runtime" => "11",
        "os" => "Android 11",
        "sdk" => 30,
        "attached" => true
      }

      try do
        result = p12_fail(spec("deploy:android_physical")) |> Map.put("device", moto)
        assert result["platform"] == "android"

        # mob_camera passed alone on the same phone path; the lookup must use
        # the result's platform (android), or it finds nothing.
        {:ok, seed} = MobCi.Store.record_run(store, %{trigger: "seed", versions_row: "hex"})

        MobCi.Store.record_cell(store, seed, %{
          set: "singleton:mob_camera",
          platform: :android,
          path: "deploy:android_physical",
          invariant: "p12:mob_camera",
          outcome: :pass
        })

        cell = %{@cell | plugins: [:mob_camera, :mob_location]}
        {:ok, run_id} = Ios.record(store, cell, [result], host: "kevin@mac")
        rows = MobCi.Store.query(store, run_id: run_id)

        assert Enum.all?(rows, &(&1.platform == "android" and &1.path == "deploy:android_physical"))
        assert hd(rows).trigger == "ci.device --platform android"

        device = %{"id" => "ZY22DP6HFL", "name" => "moto g power (2021)", "model" => "motorola moto g power (2021)", "os" => "Android 11"}
        assert Enum.all?(rows, &(&1.detail["device"] == device))

        # Passing alone on the phone: the failure in company is a conflict.
        assert %{layer: "conflict:mob_camera,mob_location"} = Enum.find(rows, &(&1.invariant == "p12:mob_camera"))
      after
        MobCi.Store.close(store)
      end
    end

    test "the store keeps a device's id, name, model and OS; a simulator's OS is its runtime" do
      assert Ios.device_record(nil) == nil

      assert Ios.device_record(%{"udid" => "MID", "name" => "iPhone 17", "runtime" => "27.0"}) ==
               %{"id" => "MID", "name" => "iPhone 17", "model" => "iPhone 17", "os" => "iOS 27.0"}
    end
  end
end
