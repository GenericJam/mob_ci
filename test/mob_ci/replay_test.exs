defmodule MobCi.ReplayTest do
  # async: false — Cell.plan sets the process-global resolved plugin dirs and
  # one test sets $MOB_CI_PINS.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ci.Replay, as: Task
  alias MobCi.{Cell, Matrix, Plugins, Replay, Sets, Store, Versions}

  # Every repo has moved on since the cell ran: Hex says 9.9.9, git HEAD is
  # "f"×40. A replay must not ask for either.
  defp remote(test_pid) do
    %{
      hex_latest: fn name ->
        send(test_pid, {:hex_latest, name})
        {:ok, "9.9.9"}
      end,
      git_head: fn url ->
        send(test_pid, {:git_head, url})
        {:ok, String.duplicate("f", 40)}
      end,
      checkout: fn name, _url, sha, cache ->
        dir = Path.join([cache, "src", to_string(name), sha])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "mix.exs"), ~s(@version "0.9.17-dev"\n))
        {:ok, %{dir: dir, sha: sha}}
      end,
      hex_unpack: fn name, version, cache ->
        dir = Path.join([cache, "hex", "#{name}-#{version}"])
        File.mkdir_p!(dir)
        {:ok, dir}
      end
    }
  end

  @mob_sha String.duplicate("a", 40)

  # What a `random:7` cell on hex recorded (dirs are the NUC's; ignored).
  defp versions do
    %{
      "row" => "hex",
      "repos" => %{
        "mob" => %{"version" => "0.9.17-dev", "sha" => @mob_sha, "source" => "git:https://github.com/GenericJam/mob@#{@mob_sha}", "dir" => "/nuc/mob"},
        "mob_dev" => %{"version" => "0.7.17", "sha" => nil, "source" => "hex", "dir" => nil},
        "mob_new" => %{"version" => "0.6.8", "sha" => nil, "source" => "hex", "dir" => "/nuc/hex/mob_new-0.6.8"},
        "mob_whisper" => %{"version" => "0.1.4", "sha" => nil, "source" => "hex", "dir" => "/nuc/x"},
        "mob_camera" => %{"version" => "0.3.1", "sha" => nil, "source" => "hex", "dir" => "/nuc/y"},
        "mob_location" => %{"version" => "0.2.0", "sha" => nil, "source" => "hex", "dir" => "/nuc/z"}
      }
    }
  end

  defp cell(fields) do
    Map.merge(
      %{id: 42, run_id: 7, set: "default", platform: "android", path: "deploy:android", versions_row: "hex", outcome: :fail, layer: "boot", started_at: "2026-10-08T02:00:00Z", versions: versions()},
      Map.new(fields)
    )
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "mob_ci_replay_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    before = Plugins.resolved_dirs()

    on_exit(fn ->
      Plugins.put_resolved_dirs(before)
      System.delete_env("MOB_CI_PINS")
      System.delete_env("MOB_CI_TRIGGER")
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  describe "argv/1" do
    test "one mix ci.device call per stored path" do
      assert Replay.argv(cell(path: "deploy:android")) == {:ok, ~w(--set default --versions hex --paths deploy)}
      assert Replay.argv(cell(path: "release:android")) == {:ok, ~w(--set default --versions hex --paths release)}
      assert Replay.argv(cell(platform: "all", path: "static", set: "all")) == {:ok, ~w(--set all --versions hex --static)}

      assert Replay.argv(cell(platform: "ios", path: "deploy:ios_device", set: "random:7", versions_row: "rc:mob@abcdef1")) ==
               {:ok, ~w(--platform ios --set random:7 --versions rc:mob@abcdef1 --paths deploy:ios_device)}
    end

    test "fixture hosts and sweep subsets are refused with what to do instead" do
      assert {:error, msg} = Replay.argv(cell(versions_row: "harness", set: "harness:mob_ci_haptic"))
      assert msg =~ "mix ci.device --host harness"

      assert {:error, msg} = Replay.argv(cell(set: "sweep:mob_camera,mob_location"))
      assert msg =~ "mix ci.replay 42 --promote"
    end

    test "the pins are the stored record; a cell without one needs --current" do
      assert {:ok, json} = Replay.pins_json(cell([]))
      assert JSON.decode!(json) == versions()
      assert {:error, msg} = Replay.pins_json(cell(versions: nil))
      assert msg =~ "--current"
    end
  end

  describe "a replay reconstructs the exact cell" do
    test "store → ci.replay → $MOB_CI_PINS → Cell.plan: same pins, same plugin list, nothing re-resolved", %{tmp: tmp} do
      store_path = Path.join(tmp, "results.sqlite")
      store = Store.open!(store_path)
      {:ok, run} = Store.record_run(store, %{trigger: "nightly", versions_row: "hex", host: "nuc", mob_ci_sha: "x"})
      base = %{set: "random:7", platform: :android, path: "release:android", versions: versions()}
      Store.record_cell(store, run, Map.merge(base, %{outcome: :fail, layer: "conflict:mob_camera,mob_location"}))
      Store.record_cell(store, run, Map.merge(base, %{invariant: "p12:mob_camera", outcome: :fail}))
      [_summary, selftest] = Store.query(store, run_id: run)
      Store.close(store)

      # any row of the cell names it
      stored = Task.load_cell(store_path, selftest.id)
      assert stored.invariant == nil and stored.set == "random:7"

      {:ok, argv} = Replay.argv(stored)
      assert argv == ~w(--set random:7 --versions hex --paths release)
      {:ok, json} = Replay.pins_json(stored)
      pins_file = Path.join(tmp, "pins.json")
      File.write!(pins_file, json)
      System.put_env("MOB_CI_PINS", pins_file)

      # random:7 today draws from today's pool; the recorded cell had these three
      refute Sets.random(7, Sets.pool()) == [:mob_camera, :mob_location, :mob_whisper]

      assert {:ok, planned} = Cell.plan("random:7", "hex", remote: remote(self()), cache_dir: tmp)
      assert planned.plugins == [:mob_camera, :mob_location, :mob_whisper]
      assert Store.pins(JSON.decode!(JSON.encode!(Versions.record(planned.resolved)))) == Store.pins(versions())
      assert planned.resolved.repos.mob.dir == Path.join([tmp, "src", "mob", @mob_sha])
      refute_received {:hex_latest, _}
      refute_received {:git_head, _}
    end

    test "the set's activation order is kept for the recorded plugins", %{tmp: tmp} do
      pins = %{row: "hex", repos: Versions.read_pins(write_pins(tmp)) |> elem(1) |> Map.get(:repos) |> Map.drop([:mob_camera])}
      assert {:ok, planned} = Cell.plan("selftest_pilots", "hex", pins: pins, remote: remote(self()), cache_dir: tmp)
      # priv/sets/selftest_pilots.exs lists mob_location, mob_whisper, mob_deliver: deliver wasn't recorded
      assert planned.plugins == [:mob_location, :mob_whisper]
    end

    test "pins of another row are refused, an unreadable $MOB_CI_PINS is an error", %{tmp: tmp} do
      {:ok, pins} = Versions.read_pins(write_pins(tmp))
      assert {:error, msg} = Cell.plan("default", "master", pins: pins, remote: remote(self()), cache_dir: tmp)
      assert msg =~ "row hex, not master"

      System.put_env("MOB_CI_PINS", Path.join(tmp, "missing.json"))
      assert {:error, "pins " <> _} = Cell.plan("default", "hex", remote: remote(self()), cache_dir: tmp)
    end

    defp write_pins(tmp) do
      file = Path.join(tmp, "p.json")
      File.write!(file, JSON.encode!(versions()))
      file
    end
  end

  describe "the run a replay records" do
    test "a pinned replay records as trigger replay and stays out of the grid and the regression check", %{tmp: tmp} do
      store = Store.open!(Path.join(tmp, "r.sqlite"))
      cell = %{set: "default", platform: :android, path: "deploy:android", versions: versions()}
      {:ok, real} = Store.record_run(store, %{trigger: "nightly", versions_row: "hex", host: "nuc", mob_ci_sha: "x"})
      Store.record_cell(store, real, Map.put(cell, :outcome, :pass))

      # what mix ci.replay exports before it runs mix ci.device (which records with trigger "ci.device")
      for {k, v} <- Replay.env(Path.join(tmp, "pins.json")), do: System.put_env(k, v)
      {:ok, replay} = Store.record_run(store, %{trigger: "ci.device", versions_row: "hex", host: "nuc", mob_ci_sha: "x"})
      Store.record_cell(store, replay, Map.merge(cell, %{outcome: :fail, layer: "boot"}))

      summaries = Store.query(store, invariant: nil)
      assert [_, %{trigger: "replay"}] = summaries
      assert Matrix.matrix_md(summaries) =~ "| `default` | ✓ pass |"
      assert Matrix.regressions([List.last(summaries)], summaries) == []

      # --current is a real result of the row today
      for {k, v} <- Replay.env(nil), do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      assert System.get_env("MOB_CI_PINS") == nil
      {:ok, current} = Store.record_run(store, %{trigger: "ci.device", versions_row: "hex", host: "nuc", mob_ci_sha: "x"})
      Store.record_cell(store, current, Map.merge(cell, %{outcome: :fail, layer: "boot"}))
      summaries = Store.query(store, invariant: nil)
      assert %{trigger: "replay-current"} = List.last(summaries)
      assert [_] = Matrix.regressions([List.last(summaries)], summaries)
      Store.close(store)
    end
  end

  describe "promotion/2" do
    test "a failed random:<seed> cell freezes its recorded plugins, in committed order" do
      assert {:ok, "random-7", source} = Replay.promotion(cell(set: "random:7", layer: "build:/home/kevin/h/ci_x"))
      assert {[:mob_camera, :mob_location, :mob_whisper], _} = Code.eval_string(source)
      assert source =~ "mix ci.replay 42 --promote"
      assert source =~ "failed on hex deploy:android @ build:ci_x"
      assert source =~ "mob 0.9.17-dev (git aaaaaaa), mob_dev 0.7.17, mob_new 0.6.8"
      refute source =~ "/home/kevin"
    end

    test "a failed sweep subset freezes the list its name spells out; --name overrides" do
      assert {:ok, "sweep-42", source} = Replay.promotion(cell(set: "sweep:mob_whisper,mob_camera", outcome: :error))
      assert {[:mob_whisper, :mob_camera], _} = Code.eval_string(source)
      assert {:ok, "camera-whisper", _} = Replay.promotion(cell(set: "random:7"), name: "camera-whisper")
    end

    test "passing cells, named sets and bad names are refused" do
      assert {:error, msg} = Replay.promotion(cell(set: "random:7", outcome: :pass))
      assert msg =~ "only a failing cell"
      assert {:error, msg} = Replay.promotion(cell(set: "all"))
      assert msg =~ "already a deterministic set"
      assert {:error, _} = Replay.promotion(cell(set: "sweep:all"))
      assert {:error, _} = Replay.promotion(cell(set: "sweep:mob_nope,mob_camera"))
      assert {:error, _} = Replay.promotion(cell(set: "random:7"), name: "Has Space")
      assert {:error, _} = Replay.promotion(cell(set: "random:7"), name: "pairwise")
      assert {:error, _} = Replay.promotion(cell(set: "random:7", versions: nil))
    end
  end
end
