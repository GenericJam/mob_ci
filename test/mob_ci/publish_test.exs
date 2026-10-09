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
      assert {:ok, %{posted: {:held, _}}} = publish(store, dir, post: false)
      refute_received {:posted, _}

      assert {:ok, %{posted: {:failed, _, :down}}} = publish(store, dir, poster: fn _ -> {:error, :down} end)

      record!(store, "master", [{"default", "deploy:android", :pass}])
      assert {:ok, %{posted: {:posted, text}}} = publish(store, dir, [])
      assert text =~ "2 cells (hex 1 · master 1)"
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

    test "keeps the newest cell per (row, set, platform, path) forever and passing evidence as a summary row", %{store: store} do
      now = at("2026-12-01T00:00:00Z")
      # 60 days old: default passes on v1, superseded later; random:1 is old and superseded.
      old = record!(store, "hex", [{"default", "deploy:android", :pass}, {"random:1", "deploy:android", :fail}], at: "2026-10-01T00:00:00Z", versions: v("0.9.15"))
      # 50 days old: the same default key fails on v2 — no longer newest either.
      mid = record!(store, "hex", [{"default", "deploy:android", :fail}, {"random:1", "deploy:android", :pass}], at: "2026-10-10T00:00:00Z", versions: v("0.9.16"))
      # 40 days old but the newest of its key: kept whole.
      lone = record!(store, "hex", [{"singleton:mob_x", "deploy:android", :fail}], at: "2026-10-20T00:00:00Z")
      # recent
      recent = record!(store, "hex", [{"default", "deploy:android", :pass}, {"random:1", "deploy:android", :pass}], at: "2026-11-25T00:00:00Z", versions: v("0.9.17"))

      result = Store.prune(store, now: now)
      rows = Store.query(store)
      by_run = Enum.group_by(rows, & &1.run_id)

      # v1's default pass is COMPATIBILITY evidence: its summary stays, its invariant row goes.
      assert [%{set: "default", invariant: nil, outcome: :pass}] = by_run[old]
      # the failing and superseded cells of old runs are gone; the mid run is empty and deleted
      refute Map.has_key?(by_run, mid)
      assert Store.query(store, run_id: mid) == []
      # the newest of a key is kept whole however old
      assert length(by_run[lone]) == 2
      assert length(by_run[recent]) == 4

      assert result.cells == 1 + 2 + 2 + 2
      assert result.runs == 1
      # what the renderers read is unchanged by pruning
      assert Matrix.matrix_md(Store.query(store, invariant: nil)) =~ "✓ pass"
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
