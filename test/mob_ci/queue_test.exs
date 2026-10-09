defmodule MobCi.QueueTest do
  use ExUnit.Case, async: true

  alias MobCi.{Queue, Store}

  setup do
    path = Path.join(System.tmp_dir!(), "mob_ci_queue_#{System.unique_integer([:positive])}/results.sqlite")
    store = Store.open!(path)

    on_exit(fn ->
      Store.close(store)
      File.rm_rf!(Path.dirname(path))
    end)

    %{store: store}
  end

  @t0 ~U[2026-10-09 04:00:00Z]

  defp job(fields) do
    Map.merge(
      %{trigger: "poll", versions_row: "master", sets: ["default"], platforms: ["android"], reason: "test", priority: 10, not_after: nil},
      Map.new(fields)
    )
  end

  # Drain with a stub runner: record what ran (in order) and what got published.
  defp drain(store, lane, opts \\ []) do
    me = self()
    codes = Keyword.get(opts, :codes, %{})

    Queue.drain(store, lane,
      now: Keyword.get(opts, :now, fn -> @t0 end),
      log_dir: "/nonexistent",
      run_cell: fn cell ->
        send(me, {:ran, cell})
        {Map.get(codes, cell.set, 0), "/logs/cell-#{cell.id}.log"}
      end,
      publish: fn job ->
        send(me, {:published, job.id})
        0
      end,
      reap: fn -> :ok end
    )
  end

  defp ran do
    receive do
      {:ran, cell} -> [{cell.versions_row, cell.set, cell.platform} | ran()]
    after
      0 -> []
    end
  end

  defp published do
    receive do
      {:published, id} -> [id | published()]
    after
      0 -> []
    end
  end

  describe "enqueue/3" do
    test "expands sets × platforms in set order, pairwise rows on the deploy path only", %{store: store} do
      {:ok, id, cells} =
        Queue.enqueue(store, job(sets: ["blank", "pairwise:3"], platforms: ["android", "ios"]), now: @t0)

      assert Enum.map(cells, &{&1.set, &1.platform, &1.status}) == [
               {"blank", "android", "queued"},
               {"blank", "ios", "queued"},
               {"pairwise:3", "android", "queued"},
               {"pairwise:3", "ios", "queued"}
             ]

      assert Enum.map(Queue.cells(store, id), & &1.paths) == [nil, nil, "deploy", "deploy:ios_sim"]
      assert %{status: "queued", sets: ["blank", "pairwise:3"], platforms: ["android", "ios"]} = Queue.job(store, id)
    end

    test "a cell already queued on the same row, set, platform and paths is a duplicate of it", %{store: store} do
      {:ok, _first, [default, all]} = Queue.enqueue(store, job(sets: ["default", "all"]), now: @t0)

      {:ok, _second, cells} =
        Queue.enqueue(store, job(sets: ["default", "singleton:mob_camera", "all"]), now: @t0)

      assert [
               %{set: "default", status: "duplicate", duplicate_of: d},
               %{set: "singleton:mob_camera", status: "queued", duplicate_of: nil},
               %{set: "all", status: "duplicate", duplicate_of: a}
             ] = cells

      assert {d, a} == {default.id, all.id}
    end

    test "only queued cells dedup: another row, another platform, or a cell already running is not a duplicate", %{store: store} do
      {:ok, _, [running]} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
      assert %{id: id} = Queue.claim(store, "android", @t0)
      assert id == running.id

      {:ok, _, cells} = Queue.enqueue(store, job(sets: ["default"], platforms: ["android", "ios"]), now: @t0)
      assert Enum.map(cells, & &1.status) == ["queued", "queued"]

      {:ok, _, [hex]} = Queue.enqueue(store, job(sets: ["default"], versions_row: "hex"), now: @t0)
      assert hex.status == "queued"
    end

    test "a cell only folds into one that runs as soon and can't expire sooner", %{store: store} do
      deadline = ~U[2026-10-09 13:00:00Z]
      {:ok, _, [nightly]} = Queue.enqueue(store, job(trigger: "nightly", sets: ["default"], priority: 0, not_after: deadline), now: @t0)

      # urgent: the nightly cell runs at lower priority and expires at 07:00
      {:ok, _, [poll]} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
      assert {poll.status, poll.duplicate_of} == {"queued", nil}

      # same priority, same deadline: folds into the first nightly cell
      {:ok, _, [again]} = Queue.enqueue(store, job(trigger: "nightly", sets: ["default"], priority: 0, not_after: deadline), now: @t0)
      assert {again.status, again.duplicate_of} == {"duplicate", nightly.id}

      # no deadline: can't defer to the expiring nightly cell, folds into the poll one
      {:ok, _, [manual]} = Queue.enqueue(store, job(trigger: "manual", sets: ["default"], priority: 0), now: @t0)
      assert {manual.status, manual.duplicate_of} == {"duplicate", poll.id}
    end

    test "the urgent cell still runs when the nightly it shares a set with expires", %{store: store} do
      deadline = ~U[2026-10-09 13:00:00Z]
      {:ok, nightly, _} = Queue.enqueue(store, job(trigger: "nightly", sets: ["blank", "default"], priority: 0, not_after: deadline), now: @t0)
      {:ok, poll, _} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)

      # the clock passes the deadline during the first cell
      clock = :counters.new(1, [])

      now = fn ->
        :counters.add(clock, 1, 1)
        if :counters.get(clock, 1) <= 1, do: @t0, else: DateTime.add(deadline, 60)
      end

      drain(store, "android", now: now)
      assert ran() == [{"master", "default", "android"}]
      assert [%{status: "expired"}, %{status: "expired"}] = Queue.cells(store, nightly)
      assert [%{status: "done", exit_code: 0}] = Queue.cells(store, poll)
      assert Enum.sort(published()) == [nightly, poll]
    end
  end

  describe "drain/3" do
    test "runs a lane's cells by priority, then oldest job, then set order; leaves the other lane alone", %{store: store} do
      {:ok, _, _} = Queue.enqueue(store, job(trigger: "nightly", versions_row: "hex", sets: ["blank", "all"], platforms: ["android", "ios"], priority: 0), now: @t0)
      {:ok, _, _} = Queue.enqueue(store, job(sets: ["default", "singleton:mob_nfc"]), now: @t0)
      {:ok, _, _} = Queue.enqueue(store, job(versions_row: "rc:mob@abcdef1", sets: ["blank"]), now: @t0)

      result = drain(store, "android")

      assert ran() == [
               {"master", "default", "android"},
               {"master", "singleton:mob_nfc", "android"},
               {"rc:mob@abcdef1", "blank", "android"},
               {"hex", "blank", "android"},
               {"hex", "all", "android"}
             ]

      assert length(result.ran) == 5
      # the nightly job still has iOS cells queued: not done, not published
      assert Enum.sort(published()) == [2, 3]
      assert Queue.job(store, 1).status == "queued"

      drain(store, "ios")
      assert ran() == [{"hex", "blank", "ios"}, {"hex", "all", "ios"}]
      assert published() == [1]
      assert %{status: "done", publish_exit: 0} = Queue.job(store, 1)
    end

    test "records exit codes and log paths per cell, and runs carry trigger + job id", %{store: store} do
      {:ok, id, _} = Queue.enqueue(store, job(sets: ["default", "all"]), now: @t0)
      drain(store, "android", codes: %{"all" => 1})

      assert [%{status: "done", exit_code: 0, log_path: "/logs/cell-1.log"}, %{status: "done", exit_code: 1}] =
               Queue.cells(store, id)

      assert Queue.run_env(%{trigger: "poll", job_id: id}) == [{"MOB_CI_TRIGGER", "poll"}, {"MOB_CI_JOB_ID", "#{id}"}]
      assert Queue.run_env(Queue.job(store, id)) == [{"MOB_CI_TRIGGER", "poll"}, {"MOB_CI_JOB_ID", "#{id}"}]
    end

    test "a job whose cell is a duplicate completes only after the cell it defers to ran", %{store: store} do
      {:ok, first, _} = Queue.enqueue(store, job(sets: ["default"], platforms: ["ios"]), now: @t0)
      {:ok, second, cells} = Queue.enqueue(store, job(sets: ["default"], platforms: ["ios", "android"]), now: @t0)
      assert Enum.map(cells, & &1.status) == ["duplicate", "queued"]

      drain(store, "android")
      assert published() == []
      assert Queue.job(store, second).status == "queued"

      drain(store, "ios")
      assert ran() |> Enum.map(&elem(&1, 2)) == ["android", "ios"]
      assert Enum.sort(published()) == [first, second]
    end

    test "a job enqueued as nothing but duplicates waits for the originals, and is published once", %{store: store} do
      {:ok, first, _} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
      {:ok, second, cells} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
      assert Enum.map(cells, & &1.status) == ["duplicate"]
      assert Queue.job(store, second).status == "queued"

      drain(store, "android")
      assert length(ran()) == 1
      assert Enum.sort(published()) == [first, second]
      drain(store, "android")
      assert published() == []
    end

    test "cells not started by the job's not_after expire, and that completes the job", %{store: store} do
      deadline = ~U[2026-10-09 13:00:00Z]
      {:ok, id, _} = Queue.enqueue(store, job(trigger: "nightly", sets: ["blank", "all"], not_after: deadline, priority: 0), now: @t0)

      # The first cell starts before the deadline; the clock passes it while it runs.
      clock = :counters.new(1, [])

      now = fn ->
        :counters.add(clock, 1, 1)
        if :counters.get(clock, 1) <= 1, do: @t0, else: DateTime.add(deadline, 60)
      end

      drain(store, "android", now: now)
      assert ran() == [{"master", "blank", "android"}]
      assert [%{status: "done"}, %{status: "expired"}] = Queue.cells(store, id)
      assert published() == [id]
      assert Queue.job(store, id).status == "done"
    end

    test "a worker requeues cells a dead worker left running, on its own lane only", %{store: store} do
      {:ok, _, _} = Queue.enqueue(store, job(sets: ["default"], platforms: ["android", "ios"]), now: @t0)
      assert %{platform: "android"} = Queue.claim(store, "android", @t0)
      assert %{platform: "ios"} = Queue.claim(store, "ios", @t0)

      result = drain(store, "android")
      assert result.recovered == 1
      assert ran() == [{"master", "default", "android"}]
      assert Enum.map(Queue.cells(store, 1), & &1.status) == ["done", "running"]
    end

    test "a job its lane completed but never published (the worker died) is published by the next worker, once", %{store: store} do
      {:ok, id, _} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
      cell = Queue.claim(store, "android", @t0)
      # the job completes in the store, then the worker dies before its report
      assert Queue.finish(store, cell.id, 0, "/logs/x.log", @t0) == [id]
      assert %{status: "done", publish_exit: nil} = Queue.job(store, id)

      # the other lane doesn't own it
      assert %{published: []} = drain(store, "ios")

      assert %{published: [^id], ran: []} = drain(store, "android")
      assert Queue.job(store, id).publish_exit == 0
      assert %{published: []} = drain(store, "android")
    end

    test "the farm is reaped before every Android cell, and never for iOS", %{store: store} do
      {:ok, _, _} = Queue.enqueue(store, job(sets: ["blank", "default"], platforms: ["android", "ios"]), now: @t0)
      events = Agent.start_link(fn -> [] end) |> elem(1)
      log = fn e -> Agent.update(events, &[e | &1]) end

      for lane <- ["android", "ios"] do
        Queue.drain(store, lane,
          now: fn -> @t0 end,
          log_dir: "/nonexistent",
          run_cell: fn cell -> log.({:ran, cell.platform, cell.set}); {0, "/logs/x.log"} end,
          publish: fn _ -> 0 end,
          reap: fn -> log.(:reap) end
        )
      end

      assert Agent.get(events, &Enum.reverse/1) == [
               :reap,
               {:ran, "android", "blank"},
               :reap,
               {:ran, "android", "default"},
               {:ran, "ios", "blank"},
               {:ran, "ios", "default"}
             ]
    end

    # A runner whose answers for a set come from a list, one per attempt.
    defp drain_scripted(store, lane, answers) do
      me = self()
      script = Agent.start_link(fn -> answers end) |> elem(1)

      Queue.drain(store, lane,
        now: fn -> @t0 end,
        log_dir: "/nonexistent",
        run_cell: fn cell ->
          send(me, {:ran, cell})
          code = Agent.get_and_update(script, fn s -> {hd(Map.get(s, cell.set, [0])), Map.update(s, cell.set, [0], &(tl(&1) ++ [0]))} end)
          {code, "/logs/cell-#{cell.id}.log"}
        end,
        publish: fn job ->
          send(me, {:published, job.id})
          0
        end,
        reap: fn -> :ok end
      )
    end

    test "a cell that lost its instance (exit 3) is retried once, before the rest of its job; both attempts stay", %{store: store} do
      {:ok, id, [default, all]} = Queue.enqueue(store, job(sets: ["default", "all"]), now: @t0)
      drain_scripted(store, "android", %{"default" => [Queue.farm_exit(), 0]})

      assert ran() == [{"master", "default", "android"}, {"master", "default", "android"}, {"master", "all", "android"}]

      assert [
               %{id: d, set: "default", status: "done", exit_code: 3, retry_of: nil},
               %{id: a, set: "all", status: "done", exit_code: 0},
               %{set: "default", status: "done", exit_code: 0, retry_of: retried}
             ] = Queue.cells(store, id)

      assert {d, a, retried} == {default.id, all.id, default.id}
      assert published() == [id]
    end

    test "a retry that loses its instance too is not retried again", %{store: store} do
      {:ok, id, _} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
      drain_scripted(store, "android", %{"default" => [3, 3, 3]})

      assert length(ran()) == 2
      assert Enum.map(Queue.cells(store, id), &{&1.exit_code, &1.status}) == [{3, "done"}, {3, "done"}]
      assert published() == [id]
    end

    test "only exit 3 retries: a failing or erroring cell is a result", %{store: store} do
      {:ok, _, _} = Queue.enqueue(store, job(sets: ["default", "all"]), now: @t0)
      drain_scripted(store, "android", %{"default" => [1], "all" => [2]})
      assert length(ran()) == 2
    end

    test "a job deferring to a cell that lost its instance waits for the retry", %{store: store} do
      {:ok, first, _} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
      {:ok, second, [dup]} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
      assert dup.status == "duplicate"

      # the lost attempt: neither job may complete on it
      cell = Queue.claim(store, "android", @t0)
      assert Queue.finish(store, cell.id, Queue.farm_exit(), "/x.log", @t0) == []
      assert [%{duplicate_of: retry}] = Queue.cells(store, second)
      assert retry != cell.id

      drain_scripted(store, "android", %{})
      assert Enum.sort(published()) == [first, second]
    end

    test "an empty lane drains to nothing", %{store: store} do
      assert %{ran: [], published: [], recovered: 0} = drain(store, "ios")
    end
  end

  describe "commands" do
    test "android cells write artifacts per cell; iOS cells go through --platform ios; paths only when set" do
      android = %{id: 7, job_id: 1, trigger: "poll", versions_row: "master", set: "pairwise:2", platform: "android", paths: "deploy"}

      assert Queue.cell_argv(android, "/q") ==
               ~w(ci.device --set pairwise:2 --versions master --paths deploy --artifacts /q/cell-7)

      ios = %{android | id: 8, platform: "ios", set: "default", paths: nil}
      assert Queue.cell_argv(ios, "/q") == ~w(ci.device --platform ios --set default --versions master)
    end

    test "the report runs with --publish only where ci.report documents it" do
      assert Queue.publish_argv("mix ci.report --publish   # regenerate matrix.md") == ["ci.report", "--publish"]
      assert Queue.publish_argv("mix ci.report --invariants") == ["ci.report"]
      assert Queue.publish_argv(nil) == ["ci.report"]
    end
  end

  test "status lists unfinished jobs with cell counts", %{store: store} do
    {:ok, _, _} = Queue.enqueue(store, job(sets: ["default", "all"]), now: @t0)
    {:ok, _, _} = Queue.enqueue(store, job(sets: ["default"]), now: @t0)
    text = Queue.format_status(store, Queue.jobs(store))
    assert text =~ "#1 queued poll master android 2 set(s) [queued=2]"
    assert text =~ "#2 queued poll master android 1 set(s) [duplicate=1]"
  end
end
