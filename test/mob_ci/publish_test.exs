defmodule MobCi.PublishTest do
  use ExUnit.Case, async: true

  alias MobCi.{Matrix, Publish, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_ci_publish_test_#{System.unique_integer([:positive])}")
    store = Store.open!(Path.join(dir, "results.sqlite"))

    on_exit(fn ->
      Store.close(store)
      File.rm_rf!(dir)
    end)

    %{store: store, dir: dir}
  end

  defp at(iso), do: elem(DateTime.from_iso8601(iso), 1)

  defp record!(store, row, outcomes, opts \\ []) do
    {:ok, run} =
      Store.record_run(store, %{
        trigger: Keyword.get(opts, :trigger, "nightly"),
        versions_row: row,
        host: "nuc",
        mob_ci_sha: "abc",
        started_at: at(Keyword.get(opts, :at, "2026-10-08T02:00:00Z"))
      })

    for {set, path, outcome} <- outcomes do
      layer = if outcome in [:fail, :error], do: Keyword.get(opts, :layer, "boot")
      platform = if path == "static", do: "all", else: path |> String.split(":") |> List.last()
      Store.record_cell(store, run, %{set: set, platform: platform, path: path, outcome: outcome, layer: layer, log_path: opts[:log], versions: opts[:versions]})
      Store.record_cell(store, run, %{set: set, platform: platform, path: path, invariant: "p2", outcome: outcome, log_path: opts[:log]})
    end

    run
  end

  defp summaries(store), do: Store.query(store, invariant: nil)

  # ── regression rule ──────────────────────────────────────────────────────────

  describe "regressions/2" do
    # One key's history, oldest first; the last outcome is the window.
    defp regressed?(store, outcomes, opts \\ []) do
      for o <- Enum.drop(outcomes, -1), do: record!(store, "hex", [{"default", "deploy:android", o}])
      record!(store, "hex", [{"default", "deploy:android", List.last(outcomes)}], opts)
      all = summaries(store)
      window = [Enum.max_by(all, & &1.id)]
      Matrix.regressions(window, all) != []
    end

    test "pass → fail regresses", %{store: store} do
      assert regressed?(store, [:pass, :fail])
    end

    test "pass → error regresses (a build or generator error is a broken user path)", %{store: store} do
      assert regressed?(store, [:pass, :error])
    end

    test "a skip in between proves nothing: pass → skip → fail regresses", %{store: store} do
      assert regressed?(store, [:pass, :skip, :fail])
    end

    test "fail → fail and error → fail are still broken, not a regression", %{store: store} do
      refute regressed?(store, [:pass, :fail, :fail])
    end

    test "error → fail is not a regression", %{store: store} do
      refute regressed?(store, [:error, :fail])
    end

    test "skip → fail with no pass before it is not a regression", %{store: store} do
      refute regressed?(store, [:skip, :fail])
    end

    test "a first-ever failure is not a regression", %{store: store} do
      refute regressed?(store, [:fail])
    end

    test "fail → pass and pass → pass are not regressions", %{store: store} do
      refute regressed?(store, [:fail, :pass])
    end

    test "a pinned replay's failure never regresses, and a replay's pass is not the baseline", %{store: store} do
      refute regressed?(store, [:pass, :fail], trigger: "replay")

      record!(store, "master", [{"default", "deploy:android", :fail}])
      record!(store, "master", [{"default", "deploy:android", :pass}], trigger: "replay")
      record!(store, "master", [{"default", "deploy:android", :fail}])
      all = summaries(store)
      assert Matrix.regressions([Enum.max_by(all, & &1.id)], all) == []
    end

    test "the key is (row, set, platform, path): another path's pass is not this one's baseline", %{store: store} do
      record!(store, "hex", [{"default", "release:android", :pass}])
      record!(store, "master", [{"default", "deploy:android", :pass}])
      record!(store, "hex", [{"default", "deploy:android", :fail}])
      all = summaries(store)
      assert Matrix.regressions([Enum.max_by(all, & &1.id)], all) == []
    end
  end

  # ── the post ─────────────────────────────────────────────────────────────────

  describe "post/3" do
    test "counts, failures by layer, regressions; @kevin only when hex regressed", %{store: store} do
      record!(store, "hex", [{"default", "deploy:android", :pass}, {"all", "deploy:android", :pass}], at: "2026-10-07T02:00:00Z")
      record!(store, "master", [{"default", "deploy:android", :pass}], at: "2026-10-07T03:00:00Z")
      first = summaries(store) |> Enum.map(& &1.id) |> Enum.max()

      record!(store, "hex", [{"default", "deploy:android", :fail}, {"all", "deploy:android", :pass}, {"blank", "static", :skip}], layer: "build:/home/kevin/x/ci_default_hex")
      record!(store, "master", [{"default", "deploy:android", :error}], layer: "plugin:mob_x")

      all = summaries(store)
      window = Enum.filter(all, &(&1.id > first))
      text = Matrix.post(window, Matrix.regressions(window, all), "https://example/matrix.md")

      assert text == """
             mob_ci: 4 cells (hex 3 · master 1) — 1 pass, 1 fail, 1 error, 1 skip
             failures by layer: build:ci_default_hex ×1 · plugin:mob_x ×1
             regression: hex default deploy:android: pass → fail @ build:ci_default_hex (cell #{Enum.find(window, &(&1.versions_row == "hex" and &1.set == "default")).id})
             regression: master default deploy:android: pass → error @ plugin:mob_x (cell #{Enum.find(window, &(&1.versions_row == "master")).id})
             @kevin the hex row regressed
             matrix: https://example/matrix.md\
             """
    end

    test "a master-only regression is reported without @kevin; no failures says so", %{store: store} do
      record!(store, "master", [{"default", "deploy:android", :pass}])
      record!(store, "master", [{"default", "deploy:android", :fail}])
      all = summaries(store)
      window = [List.last(all)]
      text = Matrix.post(window, Matrix.regressions(window, all), "u")
      assert text =~ "regression: master default"
      refute text =~ "@kevin"

      assert Matrix.post([hd(all)], [], "u") =~ "\nno failures\n"
    end

    test "an empty window is no post" do
      assert Matrix.post([], [], "u") == nil
    end
  end

  # ── Publish.run ──────────────────────────────────────────────────────────────

  describe "run/2" do
    defp publish(store, dir, extra) do
      test_pid = self()

      Publish.run(
        store,
        Keyword.merge([
          out_dir: Path.join(dir, "out"),
          pusher: fn files ->
            send(test_pid, {:pushed, files})
            {:ok, :unchanged}
          end,
          poster: fn text ->
            send(test_pid, {:posted, text})
            :ok
          end,
          log_dirs: []
        ], extra)
      )
    end

    test "writes both files, pushes them with the branch README, posts once, and only new cells next time", %{store: store, dir: dir} do
      record!(store, "hex", [{"default", "deploy:android", :pass}])

      assert {:ok, report} = publish(store, dir, [])
      assert File.read!(Path.join(dir, "out/matrix.md")) == Matrix.matrix_md(summaries(store))
      assert File.read!(Path.join(dir, "out/COMPATIBILITY.md")) == Matrix.compatibility_md(summaries(store))
      assert_received {:pushed, %{"matrix.md" => _, "COMPATIBILITY.md" => _, "README.md" => readme}}
      assert readme =~ "never by\nhand"
      assert_received {:posted, "mob_ci: 1 cells (hex 1) — 1 pass" <> _}
      assert {:posted, _} = report.posted

      # nothing new: no post
      assert {:ok, %{posted: :nothing_new}} = publish(store, dir, [])
      refute_received {:posted, _}

      # a new run: only its cell is in the post
      record!(store, "hex", [{"default", "deploy:android", :fail}])
      assert {:ok, _} = publish(store, dir, [])
      assert_received {:posted, "mob_ci: 1 cells (hex 1) — 0 pass, 1 fail" <> rest}
      assert rest =~ "@kevin"
    end

    test "--no-post and a failed post keep the cells for the next post", %{store: store, dir: dir} do
      record!(store, "hex", [{"default", "deploy:android", :pass}])
      assert {:ok, %{posted: {:posted, _}}} = publish(store, dir, [])

      record!(store, "hex", [{"default", "deploy:android", :pass}])
      assert {:ok, %{posted: {:held, _}}} = publish(store, dir, post: false)
      assert {:ok, %{posted: {:failed, _, :down}}} = publish(store, dir, poster: fn _ -> {:error, :down} end)

      record!(store, "master", [{"default", "deploy:android", :pass}])
      assert {:ok, %{posted: {:posted, text}}} = publish(store, dir, [])
      assert text =~ "2 cells (hex 1 · master 1)"
    end

    test "the first publish (no marker) posts the newest run, not the whole history", %{store: store, dir: dir} do
      record!(store, "hex", [{"default", "deploy:android", :pass}])
      record!(store, "hex", [{"default", "deploy:android", :fail}])
      record!(store, "master", [{"default", "deploy:android", :pass}, {"all", "deploy:android", :pass}])

      assert {:ok, %{posted: {:posted, text}}} = publish(store, dir, [])
      assert text =~ "mob_ci: 2 cells (master 2)"
      # the old hex regression was never in a window: no stale @kevin
      refute text =~ "@kevin"
    end

    test "two publishes at once post each cell once", %{store: store, dir: dir} do
      record!(store, "hex", [{"default", "deploy:android", :pass}])
      test_pid = self()

      slow = fn text ->
        Process.sleep(300)
        send(test_pid, {:posted, text})
        :ok
      end

      # two lanes = two processes, each with its own connection to the store
      lane = fn ->
        own = Store.open!(store.path)

        try do
          publish(own, dir, poster: slow)
        after
          Store.close(own)
        end
      end

      results =
        [Task.async(lane), Task.async(lane)]
        |> Task.await_many(10_000)
        |> Enum.map(fn {:ok, r} -> r.posted end)

      assert Enum.count(results, &match?({:posted, _}, &1)) == 1
      assert Enum.count(results, &(&1 == :nothing_new)) == 1
      assert_received {:posted, _}
      refute_received {:posted, _}
      refute File.exists?(Publish.marker_path(store) <> ".lock")
    end

    test "an exception after the files are written is that step's error, not the publish's", %{store: store, dir: dir} do
      record!(store, "hex", [{"default", "deploy:android", :pass}])

      assert {:ok, report} =
               publish(store, dir, pusher: fn _ -> raise "git is gone" end, poster: fn _ -> raise "muster is gone" end)

      assert {:error, %RuntimeError{message: "git is gone"}} = report.pushed
      assert {:error, %RuntimeError{message: "muster is gone"}} = report.posted
      assert File.exists?(Path.join(dir, "out/matrix.md"))
    end

    test "a file that can't be written is the one error; nothing is pushed or posted", %{store: store, dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "out"), "a file where the directory should be")
      record!(store, "hex", [{"default", "deploy:android", :pass}])

      assert {:error, {:write, _, _}} = publish(store, dir, [])
      refute_received {:pushed, _}
      refute_received {:posted, _}
    end
  end

  # ── the matrix branch, against a local bare remote ───────────────────────────

  describe "git_push/2" do
    defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

    defp git_out(dir, args) do
      {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
      String.trim(out)
    end

    test "commits the files as the branch's whole tree, skips an unchanged tree, stacks a change", %{dir: dir} do
      remote = Path.join(dir, "remote.git")
      repo = Path.join(dir, "repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "--quiet", "--bare", remote])
      git!(repo, ["init", "--quiet", "-b", "main"])
      git!(repo, ["remote", "add", "origin", remote])
      File.write!(Path.join(repo, "work.txt"), "untouched")

      assert {:ok, {:pushed, first}} = Publish.git_push(%{"matrix.md" => "a\n", "README.md" => "r\n"}, repo)
      assert git_out(remote, ["ls-tree", "--name-only", "matrix"]) == "README.md\nmatrix.md"
      assert git_out(remote, ["show", "matrix:matrix.md"]) == "a"
      assert git_out(remote, ["log", "-1", "--format=%an <%ae>", "matrix"]) == "mob_ci <mob_ci@users.noreply.github.com>"

      assert {:ok, :unchanged} = Publish.git_push(%{"matrix.md" => "a\n", "README.md" => "r\n"}, repo)

      assert {:ok, {:pushed, second}} = Publish.git_push(%{"matrix.md" => "b\n", "README.md" => "r\n"}, repo)
      assert git_out(remote, ["rev-parse", "matrix^"]) == first
      assert git_out(remote, ["rev-parse", "matrix"]) == second

      # the working tree, its index and HEAD were never touched
      assert File.read!(Path.join(repo, "work.txt")) == "untouched"
      assert git_out(repo, ["status", "--porcelain"]) == "?? work.txt"
    end
  end

  # ── retention ────────────────────────────────────────────────────────────────

  describe "prune" do
    defp v(mob), do: %{row: "hex", repos: %{mob: %{version: mob, sha: nil, source: "hex"}, mob_dev: %{version: "0.7.17", sha: nil, source: "hex"}, mob_new: %{version: "0.6.8", sha: nil, source: "hex"}}}

    test "keeps the newest cell per (row, set, platform, path) whole, evidence as summary rows, deletes the rest", %{store: store} do
      now = at("2026-12-01T00:00:00Z")
      # 60 days old: default passes on v1 (superseded later); random:1 fails, superseded.
      old = record!(store, "hex", [{"default", "deploy:android", :pass}, {"random:1", "deploy:android", :fail}], at: "2026-10-01T00:00:00Z", versions: v("0.9.15"))
      # 50 days old: default fails on v2 (the newest cell of v2's pins); random:1 passes, superseded.
      mid = record!(store, "hex", [{"default", "deploy:android", :fail}, {"random:1", "deploy:android", :pass}], at: "2026-10-10T00:00:00Z", versions: v("0.9.16"))
      # nothing reads this one any more: the run goes too
      gone = record!(store, "hex", [{"random:1", "deploy:android", :skip}], at: "2026-10-11T00:00:00Z")
      # 40 days old but the newest of its key: kept whole.
      lone = record!(store, "hex", [{"singleton:mob_x", "deploy:android", :fail}], at: "2026-10-20T00:00:00Z")
      recent = record!(store, "hex", [{"default", "deploy:android", :pass}, {"random:1", "deploy:android", :pass}], at: "2026-11-25T00:00:00Z", versions: v("0.9.17"))

      result = Store.prune(store, now: now)
      by_run = store |> Store.query() |> Enum.group_by(& &1.run_id)

      assert [%{set: "default", invariant: nil, outcome: :pass}] = by_run[old]
      assert [%{set: "default", invariant: nil, outcome: :fail}] = by_run[mid]
      refute Map.has_key?(by_run, gone)
      assert length(by_run[lone]) == 2
      assert length(by_run[recent]) == 4
      assert result.cells == 3 + 3 + 2
      assert result.runs == 1
    end

    test "a later failure of the same pins keeps demoting their tuple after pruning", %{store: store} do
      for {at, outcome, mob} <- [{"2026-10-01", :pass, "0.9.15"}, {"2026-10-02", :fail, "0.9.15"}, {"2026-10-03", :pass, "0.9.16"}] do
        record!(store, "hex", [{"default", "deploy:android", outcome}], at: at <> "T00:00:00Z", versions: v(mob))
      end

      status = fn -> Enum.find(Matrix.tuples(summaries(store)), &(&1.pins["mob"] == {"0.9.15", nil, "hex"})).status end
      assert status.()[{"default", "deploy:android"}] == :fail
      Store.prune(store, now: at("2026-11-15T00:00:00Z"))
      assert status.()[{"default", "deploy:android"}] == :fail
    end

    test "the P12 singleton lookup survives a newer errored singleton cell", %{store: store} do
      {:ok, ok_run} = Store.record_run(store, %{trigger: "nightly", versions_row: "hex", host: "nuc", mob_ci_sha: "x", started_at: at("2026-10-01T00:00:00Z")})
      base = %{set: "singleton:mob_x", platform: :android, path: "deploy:android"}
      Store.record_cell(store, ok_run, Map.put(base, :outcome, :pass))
      Store.record_cell(store, ok_run, Map.merge(base, %{invariant: "p12:mob_x", outcome: :pass}))
      # host generation failed: a lone error summary, no self-test rows
      {:ok, err_run} = Store.record_run(store, %{trigger: "nightly", versions_row: "hex", host: "nuc", mob_ci_sha: "x", started_at: at("2026-10-02T00:00:00Z")})
      Store.record_cell(store, err_run, Map.merge(base, %{outcome: :error, layer: "mob_new"}))

      lookup = fn -> Store.singleton_selftest(store, :mob_x, versions_row: "hex", platform: :android, path: "deploy:android") end
      assert lookup.() == :pass
      Store.prune(store, now: at("2026-11-15T00:00:00Z"))
      assert lookup.() == :pass
    end

    test "the regression baseline survives a month of skips", %{store: store} do
      record!(store, "hex", [{"pairwise:3", "deploy:android", :pass}], at: "2026-10-01T00:00:00Z")
      record!(store, "hex", [{"pairwise:3", "deploy:android", :skip}], at: "2026-10-02T00:00:00Z")
      reported = summaries(store) |> Enum.map(& &1.id) |> Enum.max()
      Store.prune(store, now: at("2026-11-15T00:00:00Z"), reported: reported)

      record!(store, "hex", [{"pairwise:3", "deploy:android", :fail}], at: "2026-11-16T00:00:00Z")
      all = summaries(store)
      assert [%{set: "pairwise:3"}] = Matrix.regressions([Enum.max_by(all, & &1.id)], all)
    end

    test "a newer replay doesn't make the row's real latest prunable", %{store: store} do
      real = record!(store, "hex", [{"default", "deploy:android", :fail}], at: "2026-10-01T00:00:00Z")
      record!(store, "hex", [{"default", "deploy:android", :pass}], at: "2026-11-30T00:00:00Z", trigger: "replay")
      Store.prune(store, now: at("2026-12-01T00:00:00Z"))
      assert [_, _] = Store.query(store, run_id: real)
    end

    test "deletes old log files nothing points at any more, keeps referenced and recent ones", %{store: store, dir: dir} do
      logs = Path.join(dir, "mob_ci_logs")
      File.mkdir_p!(Path.join(logs, "ios/cell1"))
      pruned_log = Path.join(logs, "pruned.log")
      kept_log = Path.join(logs, "kept.log")
      stray_old = Path.join(logs, "ios/cell1/run.log")
      stray_new = Path.join(logs, "fresh.log")
      script = Path.join(logs, "harness1.sh")
      for f <- [pruned_log, kept_log, stray_old, stray_new, script], do: File.write!(f, "x")
      old_mtime = DateTime.to_unix(at("2026-10-01T00:00:00Z"))
      for f <- [pruned_log, kept_log, stray_old, script], do: File.touch!(f, old_mtime)
      File.touch!(stray_new, DateTime.to_unix(at("2026-11-20T00:00:00Z")))

      record!(store, "hex", [{"default", "deploy:android", :fail}], at: "2026-10-01T00:00:00Z", log: pruned_log)
      record!(store, "hex", [{"default", "deploy:android", :pass}], at: "2026-10-02T00:00:00Z", log: kept_log)

      result = Publish.prune(store, now: at("2026-12-01T00:00:00Z"), log_dirs: [logs])

      assert result.logs_deleted == Enum.sort([pruned_log, stray_old])
      refute File.exists?(pruned_log)
      refute File.exists?(stray_old)
      refute File.dir?(Path.join(logs, "ios"))
      assert File.exists?(kept_log)
      assert File.exists?(stray_new)
      assert File.exists?(script)
    end
  end
end
