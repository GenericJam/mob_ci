defmodule MobCi.PollerTest do
  use ExUnit.Case, async: true

  alias MobCi.{Poller, Queue, Store}

  setup do
    path = Path.join(System.tmp_dir!(), "mob_ci_poller_#{System.unique_integer([:positive])}/results.sqlite")
    store = Store.open!(path)

    on_exit(fn ->
      Store.close(store)
      File.rm_rf!(Path.dirname(path))
    end)

    %{store: store}
  end

  @repos [mob: "u/mob", mob_dev: "u/mob_dev", mob_camera: "u/mob_camera", mob_nfc: "u/mob_nfc"]
  @t0 ~U[2026-10-09 15:00:00Z]

  defp sha(c), do: String.duplicate(c, 40)

  # A stub remote: repo url → %{ref => sha}; a missing url is unreachable.
  defp remote(table) do
    fn url, which ->
      case Map.fetch(table, url) do
        {:ok, refs} ->
          refs = if which == :head, do: Map.take(refs, ["HEAD"]), else: refs
          {:ok, Enum.map_join(refs, "", fn {ref, s} -> "#{s}\t#{ref}\n" end)}

        :error ->
          {:error, "fatal: could not read from remote"}
      end
    end
  end

  defp heads(m, d, c, n),
    do: %{
      "u/mob" => %{"HEAD" => sha(m), "refs/heads/master" => sha(m)},
      "u/mob_dev" => %{"HEAD" => sha(d)},
      "u/mob_camera" => %{"HEAD" => sha(c)},
      "u/mob_nfc" => %{"HEAD" => sha(n)}
    }

  defp cycle(store, table, opts \\ []) do
    me = self()

    defaults = [
      repos: @repos,
      ls_remote: remote(table),
      static: fn job ->
        send(me, {:static, job.versions_row, job.sets})
        Enum.map(job.sets, &{&1, 0})
      end,
      now: @t0
    ]

    Poller.cycle(store, Keyword.merge(defaults, opts))
  end

  describe "parse_ls_remote/1" do
    test "maps refs to shas, ignoring noise" do
      out = """
      #{sha("a")}\tHEAD
      #{sha("a")}\trefs/heads/master
      #{sha("b")}\trefs/tags/v1.0^{}
      warning: redirecting to https://example.com/x.git/

      not-a-sha\trefs/heads/x
      """

      assert Poller.parse_ls_remote(out) == %{
               "HEAD" => sha("a"),
               "refs/heads/master" => sha("a"),
               "refs/tags/v1.0^{}" => sha("b")
             }
    end
  end

  describe "diff/3" do
    test "moved shas are changes in repo order, unseen repos a baseline, unreachable repos neither" do
      stored = %{mob: sha("1"), mob_camera: sha("2"), mob_nfc: sha("3")}
      current = %{mob: sha("1"), mob_camera: sha("9"), mob_dev: sha("4")}

      assert Poller.diff(stored, current, Keyword.keys(@repos)) ==
               {[%{repo: :mob_camera, old: sha("2"), new: sha("9")}], [:mob_dev]}
    end
  end

  describe "cycle/2" do
    test "the first cycle records a baseline and queues nothing", %{store: store} do
      result = cycle(store, heads("1", "2", "3", "4"))
      assert result.baseline == Keyword.keys(@repos)
      assert result.changes == [] and result.jobs == []
      refute_received {:static, _, _}
      assert Poller.heads(store) == %{mob: sha("1"), mob_dev: sha("2"), mob_camera: sha("3"), mob_nfc: sha("4")}
    end

    test "a moved plugin runs the static gate and queues default + its singleton + all on master", %{store: store} do
      cycle(store, heads("1", "2", "3", "4"))
      result = cycle(store, heads("1", "2", "5", "4"))

      assert result.changes == [%{repo: :mob_camera, old: sha("3"), new: sha("5")}]
      assert_received {:static, "master", ["default", "singleton:mob_camera", "all"]}
      assert [id] = result.jobs

      assert %{trigger: "poll", versions_row: "master", sets: ["default", "singleton:mob_camera", "all"], platforms: ["android", "ios"]} =
               Queue.job(store, id)

      assert Queue.job(store, id).reason == "mob_camera 3333333→5555555"
      assert Poller.heads(store).mob_camera == sha("5")

      # nothing moved since: no new job
      assert cycle(store, heads("1", "2", "5", "4")).jobs == []
    end

    test "a moved core repo queues blank + default + all; several changes share one job", %{store: store} do
      cycle(store, heads("1", "2", "3", "4"))
      result = cycle(store, heads("7", "2", "3", "8"))
      [id] = result.jobs
      assert Queue.job(store, id).sets == ["blank", "default", "singleton:mob_nfc", "all"]
    end

    test "an unreachable repo is reported and keeps its stored sha", %{store: store} do
      cycle(store, heads("1", "2", "3", "4"))
      table = Map.delete(heads("1", "2", "3", "4"), "u/mob_nfc")
      result = cycle(store, table)
      assert [{:mob_nfc, "fatal: could not read from remote"}] = result.errors
      assert Poller.heads(store).mob_nfc == sha("4")
    end

    test "a second change before the first job ran folds into the queued cells", %{store: store} do
      cycle(store, heads("1", "2", "3", "4"))
      [first] = cycle(store, heads("1", "2", "5", "4")).jobs
      [second] = cycle(store, heads("1", "2", "6", "4")).jobs
      assert Enum.all?(Queue.cells(store, second), &(&1.status == "duplicate"))
      assert Enum.all?(Queue.cells(store, first), &(&1.status == "queued"))
    end
  end

  describe "pre-push notices" do
    setup %{store: store} do
      cycle(store, heads("1", "2", "3", "4"))
      :ok
    end

    test "a sha that lands as the default-branch head is covered by the poll job (no second job)", %{store: store} do
      {:ok, push} = Poller.record_push(store, "mob_camera", sha("5"), "refs/heads/master", @t0)
      result = cycle(store, heads("1", "2", "5", "4"))
      assert [{^push, :covered}] = result.pushes
      assert [id] = result.jobs
      assert Queue.job(store, id).trigger == "pre-push"
      assert Poller.pending_pushes(store) == []
      assert [[^id]] = Store.rows!(store, "SELECT job_id FROM pushes WHERE id = ?1", [push])
    end

    test "a notice for a head the poller already saw is covered, by no job of this cycle", %{store: store} do
      {:ok, push} = Poller.record_push(store, "mob_camera", sha("3"), "refs/heads/master", @t0)
      # another repo moves in the same cycle
      result = cycle(store, heads("1", "2", "3", "9"))
      assert [{^push, :covered}] = result.pushes
      assert [id] = result.jobs
      assert Queue.job(store, id).trigger == "poll"
      assert [[nil]] = Store.rows!(store, "SELECT job_id FROM pushes WHERE id = ?1", [push])
    end

    test "a sha pushed to a branch runs as its own rc row", %{store: store} do
      {:ok, push} = Poller.record_push(store, "mob_nfc", String.slice(sha("e"), 0, 12), "refs/heads/feature", @t0)
      table = put_in(heads("1", "2", "3", "4"), ["u/mob_nfc", "refs/heads/feature"], sha("e"))
      result = cycle(store, table)

      assert [{^push, :branch}] = result.pushes
      assert [id] = result.jobs
      assert %{trigger: "pre-push", versions_row: row, sets: ["default", "singleton:mob_nfc", "all"]} = Queue.job(store, id)
      assert row == "rc:mob_nfc@#{sha("e")}"
      assert_received {:static, ^row, _}
    end

    test "a sha not on the remote stays pending, and expires after an hour", %{store: store} do
      {:ok, push} = Poller.record_push(store, "mob", sha("f"), "refs/heads/master", @t0)
      assert cycle(store, heads("1", "2", "3", "4")).pushes == []
      assert [%{id: ^push}] = Poller.pending_pushes(store)

      result = cycle(store, heads("1", "2", "3", "4"), now: DateTime.add(@t0, 3600))
      assert [{^push, :expired}] = result.pushes
      assert result.jobs == []
    end

    test "an unknown repo or a bad sha is refused", %{store: store} do
      assert {:error, msg} = Poller.record_push(store, "not_a_repo", sha("1"), nil, @t0)
      assert msg =~ "unknown repo"
      assert {:error, _} = Poller.record_push(store, "mob", "xyz", nil, @t0)
    end

    test "await_pushes returns as soon as a pending push is on its remote, without running a cycle", %{store: store} do
      {:ok, _} = Poller.record_push(store, "mob_camera", sha("5"), "refs/heads/master", @t0)
      calls = :counters.new(1, [])
      landed = heads("1", "2", "5", "4")
      before = heads("1", "2", "3", "4")

      ls = fn url, which ->
        # the push becomes visible on the third look
        :counters.add(calls, 1, 1)
        remote(if(:counters.get(calls, 1) >= 3, do: landed, else: before)).(url, which)
      end

      me = self()
      opts = [repos: @repos, ls_remote: ls, now: DateTime.add(@t0, 60), sleep: fn ms -> send(me, {:slept, ms}) end, interval_ms: 10]

      assert Poller.await_pushes(store, opts ++ [max_ms: 1_000]) == :landed
      assert_received {:slept, 10}
      assert :counters.get(calls, 1) == 3
      # nothing settled or queued: the caller's locked cycle does that
      assert [_] = Poller.pending_pushes(store)
      assert Queue.jobs(store) == []

      cycle(store, landed)
      assert Poller.await_pushes(store, opts) == :settled
    end

    test "await_pushes gives up after max_ms while the push is still missing", %{store: store} do
      {:ok, _} = Poller.record_push(store, "mob", sha("f"), "refs/heads/master", @t0)
      opts = [repos: @repos, ls_remote: remote(heads("1", "2", "3", "4")), now: @t0, sleep: fn _ -> :ok end]
      assert Poller.await_pushes(store, opts ++ [interval_ms: 10, max_ms: 30]) == :timeout
    end
  end
end
