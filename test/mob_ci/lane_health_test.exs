defmodule MobCi.LaneHealthTest do
  use ExUnit.Case, async: true

  alias MobCi.{Publish, Queue, Store}

  @ios_paths ["deploy:ios_sim", "deploy:ios_device", "release:ios"]
  @disk "3.6 GB free on /, a cell needs 5.0 GB"

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_ci_lane_health_#{System.unique_integer([:positive])}")
    store = Store.open!(Path.join(dir, "results.sqlite"))

    on_exit(fn ->
      Store.close(store)
      File.rm_rf!(dir)
    end)

    %{store: store, dir: dir}
  end

  defp at(iso), do: elem(DateTime.from_iso8601(iso), 1)

  # One run of `cells` ({platform, path, outcome, layer, detail}) at `iso`.
  defp run!(store, iso, cells, opts \\ []) do
    {:ok, run} =
      Store.record_run(store, %{
        trigger: Keyword.get(opts, :trigger, "nightly"),
        versions_row: Keyword.get(opts, :row, "master"),
        host: "nuc",
        mob_ci_sha: "abc",
        started_at: at(iso),
        job_id: opts[:job_id]
      })

    for {platform, path, outcome, layer, detail} <- cells do
      Store.record_cell(store, run, %{set: "default", platform: platform, path: path, outcome: outcome, layer: layer, detail: detail, log_path: opts[:log]})
      # the reader must look at summary rows only
      Store.record_cell(store, run, %{set: "default", platform: platform, path: path, invariant: "p2", outcome: :pass})
    end

    run
  end

  defp ios_disk!(store, iso, opts \\ []),
    do: run!(store, iso, for(p <- @ios_paths, do: {"ios", p, :error, "error:disk", %{error: inspect(@disk)}}), opts)

  defp ios!(store, iso, outcome, layer \\ nil),
    do: run!(store, iso, for(p <- @ios_paths, do: {"ios", p, outcome, layer, nil}))

  defp android!(store, iso, outcome, layer \\ nil),
    do: run!(store, iso, [{"android", "deploy:android", outcome, layer, nil}, {"android", "release:android", outcome, layer, nil}])

  # Notify with a capturing poster; returns {result, health}.
  defp notify(store, extra \\ []) do
    test_pid = self()

    Publish.lanes(
      store,
      Keyword.merge(
        [
          poster: fn text ->
            send(test_pid, {:posted, text})
            :ok
          end,
          now: ~U[2026-10-13 15:00:00Z],
          paused?: fn _ -> false end,
          url: "https://x/matrix.md"
        ],
        extra
      )
    )
  end

  defp lane(health, name), do: Enum.find(health, &(&1.lane == name))

  describe "a dead path" do
    test "every cell of the iOS lane at error:disk pushes one alert with the layer, cause, since and fix", %{store: store} do
      ios!(store, "2026-10-09T20:00:00Z", :pass)
      for d <- 10..14, do: ios_disk!(store, "2026-10-#{d}T06:20:48Z")
      android!(store, "2026-10-14T07:00:00Z", :pass)

      assert {{:posted, text}, health} = notify(store)
      assert_received {:posted, ^text}

      assert text =~ ~r/^@kevin! mob_ci: the iOS lane \(Mac mini\) is down since 2026-10-10 06:20Z/
      assert text =~ "error:disk on deploy:ios_sim, deploy:ios_device, release:ios: every cell since 2026-10-10 06:20Z"
      assert text =~ "cause: " <> @disk
      assert text =~ "fix: free space on the Mac mini"
      refute text =~ "Android"

      ios = lane(health, "ios")
      assert Enum.map(ios.dead, & &1.path) == @ios_paths
      assert Enum.all?(ios.dead, &(&1.cells == 5 and &1.since == "2026-10-10T06:20:48Z"))
      assert lane(health, "android").dead == []
    end

    test "fewer infra cells than the window, or a pass among them, is not a dead path", %{store: store} do
      for d <- 10..13, do: ios_disk!(store, "2026-10-#{d}T06:20:00Z")
      assert {:unchanged, health} = notify(store)
      assert lane(health, "ios").dead == []

      # the window is configurable: 4 is enough at window 4
      assert {{:posted, _}, _} = notify(store, window: 4)
    end

    test "a pass in the last N cells keeps the path alive", %{store: store} do
      for d <- 10..12, do: ios_disk!(store, "2026-10-#{d}T06:20:00Z")
      ios!(store, "2026-10-13T06:00:00Z", :pass)
      ios_disk!(store, "2026-10-14T06:20:00Z")

      assert {:unchanged, health} = notify(store, window: 2)
      assert lane(health, "ios").dead == []
      refute_received {:posted, _}
    end

    test "plugin, build and boot failures and skips are the lane working: no alert", %{store: store} do
      for {layer, d} <- Enum.with_index(["plugin:mob_nfc", "build:release:ios", "boot", "conflict:mob_a,mob_b", "health"], 10) do
        ios!(store, "2026-10-#{d}T06:00:00Z", :fail, layer)
      end

      for d <- 15..19, do: run!(store, "2026-10-#{d}T06:00:00Z", [{"ios", "deploy:ios_device", :skip, nil, nil}])

      assert {:unchanged, health} = notify(store)
      assert lane(health, "ios").dead == []
    end

    test "the farm's infra layers kill the Android lane the same way, with the lost-device line as the cause", %{store: store} do
      reason = {:build_failed, :deploy, {:native_build, "BUILD SUCCESSFUL\n  \e[31m✗ Android native build failed: Selected Android device(s) disconnected: 127.0.0.1:5700\e[0m\n** (Mix) Native build failed\n"}}

      for d <- 10..14 do
        run!(store, "2026-10-#{d}T06:00:00Z", [{"android", "deploy:android", :error, "farm", %{error: inspect(reason)}}])
      end

      assert {{:posted, text}, _} = notify(store)
      assert text =~ "the Android lane (redroid farm, NUC) is down"
      assert text =~ "cause: ✗ Android native build failed: Selected Android device(s) disconnected: 127.0.0.1:5700"
    end

    test "with no stored error, the cause is the worker's step line from the cell's log", %{store: store, dir: dir} do
      log = Path.join(dir, "cell.log")
      File.write!(log, "[ios-worker] step disk …\n[ios-worker] step disk error (4 ms): #{@disk}\n[ios-worker] teardown\n")
      for d <- 10..14, do: run!(store, "2026-10-#{d}T06:00:00Z", [{"ios", "release:ios", :error, "error:ssh", nil}], log: log)

      assert {{:posted, text}, _} = notify(store)
      assert text =~ "error:ssh on release:ios"
      assert text =~ "cause: #{@disk}"
    end
  end

  describe "posting once per state" do
    test "the same state is posted once; another lane alerts on its own; a recovery is a quiet all-clear", %{store: store} do
      for d <- 10..14, do: ios_disk!(store, "2026-10-#{d}T06:20:00Z")
      assert {{:posted, first}, _} = notify(store)
      assert_received {:posted, ^first}

      # more of the same: nothing
      ios_disk!(store, "2026-10-15T06:20:00Z")
      assert {:unchanged, _} = notify(store)
      refute_received {:posted, _}

      # the Android lane dies too: one new alert for it, nothing repeated for iOS
      for d <- 10..14, do: android!(store, "2026-10-#{d}T08:00:00Z", :error, "toolchain")
      assert {{:posted, text}, _} = notify(store)
      assert text =~ "@kevin! mob_ci: the Android lane"
      refute text =~ "iOS lane"

      # one iOS path passes again: a quiet partial recovery
      run!(store, "2026-10-16T06:00:00Z", [{"ios", "release:ios", :pass, nil, nil}])
      assert {{:posted, text}, _} = notify(store)
      refute text =~ "@kevin"
      assert text =~ "the iOS lane (Mac mini) partly recovered; still wrong:\n- error:disk on deploy:ios_sim, deploy:ios_device:"

      # the whole lane passes: all-clear, no push; then silence
      ios!(store, "2026-10-17T06:00:00Z", :pass)
      assert {{:posted, text}, _} = notify(store)
      refute text =~ "@kevin"
      assert text =~ "mob_ci: all clear, the iOS lane (Mac mini) is running cells again (it was down since 2026-10-10 06:20Z: deploy:ios_sim @ error:disk, deploy:ios_device @ error:disk)"
      assert {:unchanged, _} = notify(store)
    end

    test "a held (--no-post) or failed post leaves the state: the next check posts it", %{store: store} do
      for d <- 10..14, do: ios_disk!(store, "2026-10-#{d}T06:20:00Z")

      assert {{:held, text}, _} = notify(store, post: false)
      assert text =~ "@kevin!"
      refute_received {:posted, _}

      assert {{:failed, _, :down}, _} = notify(store, poster: fn _ -> {:error, :down} end)
      assert {{:posted, ^text}, _} = notify(store)
      assert {:unchanged, _} = notify(store)
    end

    test "a dead path whose layer flaps is one problem: no second push", %{store: store} do
      for d <- 10..14, do: ios_disk!(store, "2026-10-#{d}T06:20:00Z")
      assert {{:posted, _}, _} = notify(store)

      for d <- 15..19, do: ios!(store, "2026-10-#{d}T06:00:00Z", :error, "error:ssh")
      assert {:unchanged, health} = notify(store)
      assert Enum.all?(lane(health, "ios").dead, &(&1.layer == "error:ssh" and &1.since == "2026-10-10T06:20:00Z"))
    end

    test "a state file of another shape is dropped, not fatal", %{store: store, dir: dir} do
      File.write!(Path.join(dir, "lane_health.json"), ~s({"ios":{"problems":"old-shape"},"android":7}))
      for d <- 10..14, do: ios_disk!(store, "2026-10-#{d}T06:20:00Z")
      assert {{:posted, "@kevin! " <> _}, _} = notify(store)
      assert {:unchanged, _} = notify(store)
    end
  end

  describe "a lane that ran nothing" do
    defp nightly!(store, row, platforms \\ ["android", "ios"]) do
      job = %{trigger: "nightly", versions_row: row, sets: ["blank", "default"], platforms: platforms, reason: "nightly", priority: 0, not_after: ~U[2026-10-13 13:00:00Z]}
      {:ok, id, _} = Queue.enqueue(store, job, now: ~U[2026-10-13 04:00:00Z])
      id
    end

    # The android lane runs its cells (recording results under the job); the
    # iOS lane never claims one, so they expire at not_after.
    defp android_runs!(store, job_id) do
      for _ <- 1..2 do
        cell = Queue.claim(store, "android", ~U[2026-10-13 05:00:00Z])
        run!(store, "2026-10-13T05:00:00Z", [{"android", "deploy:android", :pass, nil, nil}], job_id: job_id)
        Queue.finish(store, cell.id, 0, nil, ~U[2026-10-13 05:10:00Z])
      end
    end

    test "a finished nightly that scheduled iOS cells and ran none of them alerts", %{store: store} do
      job = nightly!(store, "master")
      android_runs!(store, job)

      # still running (before not_after, iOS cells queued): not judged yet
      assert {:unchanged, _} = notify(store, now: ~U[2026-10-13 12:00:00Z])

      Queue.expire(store, "ios", ~U[2026-10-13 13:00:00Z])

      assert {{:posted, text}, health} = notify(store)
      assert text =~ "@kevin! mob_ci: the iOS lane (Mac mini) is down since 2026-10-13 04:00Z"
      assert text =~ "- ran none of its 2 cells in the master nightly (job #{job}, queued 2026-10-13 04:00Z)"
      assert text =~ "fix: its worker never ran them"
      assert lane(health, "android").idle == []
    end

    test "a paused lane says so; a nightly past not_after counts even if no worker expired its cells", %{store: store} do
      job = nightly!(store, "hex")
      android_runs!(store, job)

      assert {{:posted, text}, _} = notify(store, paused?: &(&1 == "ios"))
      assert text =~ "fix: the lane is paused: `priv/ci-run.sh resume ios`"
    end

    test "the next nightly running cells on the lane clears it", %{store: store} do
      android_runs!(store, nightly!(store, "master"))
      assert {{:posted, _}, _} = notify(store)

      Queue.expire(store, "ios", ~U[2026-10-13 13:00:00Z])
      job = nightly!(store, "master", ["ios"])

      for _ <- 1..2 do
        cell = Queue.claim(store, "ios", ~U[2026-10-14 05:00:00Z])
        run!(store, "2026-10-14T05:00:00Z", [{"ios", "deploy:ios_sim", :pass, nil, nil}], job_id: job)
        Queue.finish(store, cell.id, 0, nil, ~U[2026-10-14 05:10:00Z])
      end

      assert {{:posted, text}, _} = notify(store)
      assert text =~ "all clear, the iOS lane (Mac mini) is running cells again (it was down since 2026-10-13 04:00Z: an idle master nightly)"
    end

    test "an idle row is its own problem: master recovering while hex goes idle alerts", %{store: store} do
      android_runs!(store, nightly!(store, "master"))
      assert {{:posted, _}, _} = notify(store)

      Queue.expire(store, "ios", ~U[2026-10-13 13:00:00Z])
      master = nightly!(store, "master", ["ios"])
      cell = Queue.claim(store, "ios", ~U[2026-10-14 05:00:00Z])
      run!(store, "2026-10-14T05:00:00Z", [{"ios", "deploy:ios_sim", :pass, nil, nil}], job_id: master)
      Queue.finish(store, cell.id, 0, nil, ~U[2026-10-14 05:10:00Z])
      Queue.expire(store, "ios", ~U[2026-10-13 13:00:00Z])
      nightly!(store, "hex", ["ios"])

      assert {{:posted, text}, health} = notify(store)
      assert text =~ "@kevin! mob_ci: the iOS lane (Mac mini) is down"
      assert text =~ "ran none of its 2 cells in the hex nightly"
      assert Enum.map(lane(health, "ios").idle, & &1.versions_row) == ["hex"]
    end
  end

  describe "in the publish" do
    test "matrix.md opens with the lane health and the post goes out with the summary", %{store: store, dir: dir} do
      android!(store, "2026-10-09T06:00:00Z", :pass)
      for d <- 10..14, do: ios_disk!(store, "2026-10-#{d}T06:20:48Z")
      test_pid = self()

      assert {:ok, report} =
               Publish.run(store,
                 out_dir: Path.join(dir, "out"),
                 pusher: fn _ -> {:ok, :unchanged} end,
                 poster: fn text ->
                   send(test_pid, {:posted, text})
                   :ok
                 end,
                 log_dirs: [],
                 paused?: fn _ -> false end
               )

      md = File.read!(Path.join(dir, "out/matrix.md"))

      assert md =~
               "# mob_ci matrix\n\n## Lane health\n\n- **Android lane (redroid farm, NUC)**: up\n" <>
                 "- **iOS lane (Mac mini)**: down since 2026-10-10 06:20Z, `error:disk` on deploy:ios_sim, deploy:ios_device, release:ios\n"

      assert {{:posted, "@kevin! " <> _}, _} = report.lanes
      assert_received {:posted, "mob_ci: " <> _}
      assert_received {:posted, "@kevin! " <> _}
      assert Mix.Tasks.Ci.Report.publish_summary(report) =~ "lanes: android up · ios down since 2026-10-10 06:20Z"
    end
  end
end
