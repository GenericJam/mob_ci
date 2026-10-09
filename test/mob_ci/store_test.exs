defmodule MobCi.StoreTest do
  use ExUnit.Case, async: true

  alias MobCi.{Result, Store}

  setup do
    path = Path.join(System.tmp_dir!(), "mob_ci_store_#{System.unique_integer([:positive])}/results.sqlite")
    {:ok, store} = Store.open(path)

    on_exit(fn ->
      Store.close(store)
      File.rm_rf!(Path.dirname(path))
    end)

    %{store: store, path: path}
  end

  defp run!(store, row, trigger \\ "ci.device"),
    do: elem(Store.record_run(store, %{trigger: trigger, versions_row: row, host: "nuc", mob_ci_sha: "abc123"}), 1)

  defp cell(fields),
    do: Map.merge(%{set: "default", platform: :android, path: "deploy:android", outcome: :pass}, Map.new(fields))

  test "a run and its cells round-trip, with JSON detail and versions decoded", %{store: store} do
    run = run!(store, "hex")
    versions = %{row: "hex", repos: %{mob: %{version: "0.9.15", sha: nil, source: "hex"}}}

    :ok =
      Store.record_cell(store, run, %{
        set: "default",
        platform: :android,
        path: "release:android",
        invariant: nil,
        layer: {:build, "release:android", :mob_x},
        outcome: :fail,
        duration_ms: 1234,
        log_path: "/tmp/release.log",
        detail: %{reason: {:release_build, "tail"}, items: [:a]},
        versions: versions
      })

    assert [c] = Store.query(store)

    assert %{
             run_id: ^run,
             set: "default",
             platform: "android",
             path: "release:android",
             invariant: nil,
             layer: "build:release:android/mob_x",
             outcome: :fail,
             duration_ms: 1234,
             log_path: "/tmp/release.log",
             trigger: "ci.device",
             versions_row: "hex",
             host: "nuc",
             mob_ci_sha: "abc123"
           } = c

    # Tuples have no JSON form: they are kept inspected, never dropped.
    assert c.detail == %{"reason" => ~s({:release_build, "tail"}), "items" => ["a"]}
    assert c.versions["repos"]["mob"]["version"] == "0.9.15"
    assert {:ok, _, _} = DateTime.from_iso8601(c.started_at)
  end

  test "an outcome outside pass | fail | skip | error is refused", %{store: store} do
    run = run!(store, "hex")
    assert_raise ArgumentError, fn -> Store.record_cell(store, run, cell(outcome: :flaky)) end
    assert Store.query(store) == []
  end

  test "reopening migrates idempotently and keeps the data", %{store: store, path: path} do
    run = run!(store, "hex")
    Store.record_cell(store, run, cell([]))
    assert Store.user_version(store) == Store.schema_version()

    {:ok, again} = Store.open(path)
    assert :ok = Store.migrate(again)
    assert Store.user_version(again) == Store.schema_version()
    assert [%{run_id: ^run}] = Store.query(again)
    Store.close(again)
  end

  test "a schema-1 store gains runs.job_id and the queue tables, keeping its runs" do
    dir = Path.join(System.tmp_dir!(), "mob_ci_store_v1_#{System.unique_integer([:positive])}")
    path = Path.join(dir, "results.sqlite")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # The shipped schema 1 `runs` table, as a 2026-10-08 store has it.
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, trigger TEXT NOT NULL,
        versions_row TEXT NOT NULL, host TEXT NOT NULL, mob_ci_sha TEXT);
      INSERT INTO runs (started_at, trigger, versions_row, host) VALUES ('2026-10-08T00:00:00Z', 'ci.device', 'hex', 'nuc');
      PRAGMA user_version = 1;
      """)

    Exqlite.Sqlite3.close(conn)

    store = Store.open!(path)
    assert Store.user_version(store) == 2
    assert [[1, nil]] = Store.rows!(store, "SELECT id, job_id FROM runs", [])
    assert {:ok, run} = Store.record_run(store, %{trigger: "nightly", versions_row: "hex", job_id: 7})
    assert [[7]] = Store.rows!(store, "SELECT job_id FROM runs WHERE id = ?1", [run])

    for table <- ~w(jobs job_cells heads pushes),
        do: assert([[1]] = Store.rows!(store, "SELECT count(*) FROM sqlite_master WHERE name = ?1", [table]))

    Store.close(store)
  end

  describe "run_context/2 (what a queue worker's environment records)" do
    test "MOB_CI_TRIGGER replaces the task's trigger; MOB_CI_JOB_ID sets the job" do
      meta = %{trigger: "ci.device", versions_row: "hex"}

      assert Store.run_context(meta, %{"MOB_CI_TRIGGER" => "nightly", "MOB_CI_JOB_ID" => "42"}) ==
               %{trigger: "nightly", versions_row: "hex", job_id: 42}
    end

    test "no, empty or malformed variables leave the meta alone; an explicit job_id wins" do
      meta = %{trigger: "ci.device", versions_row: "hex"}
      assert Store.run_context(meta, %{}) == meta
      assert Store.run_context(meta, %{"MOB_CI_TRIGGER" => "", "MOB_CI_JOB_ID" => "x"}) == meta
      assert Store.run_context(meta, %{"MOB_CI_JOB_ID" => "0"}) == meta
      assert Store.run_context(Map.put(meta, :job_id, 3), %{"MOB_CI_JOB_ID" => "9"}).job_id == 3
    end
  end

  test "default_path honours MOB_CI_STORE" do
    # Read-only check of the resolution; no store is opened at either path.
    assert Store.default_path() == Path.expand(System.get_env("MOB_CI_STORE"))
  end

  describe "query filters" do
    setup %{store: store} do
      hex1 = run!(store, "hex")
      Store.record_cell(store, hex1, cell(set: "default", path: "deploy:android", outcome: :fail, layer: :boot))
      Store.record_cell(store, hex1, cell(set: "default", path: "deploy:android", invariant: "p2", outcome: :fail))
      Store.record_cell(store, hex1, cell(set: "all", path: "deploy:android", outcome: :pass))

      master = run!(store, "master")
      Store.record_cell(store, master, cell(set: "default", path: "deploy:android", outcome: :pass))

      hex2 = run!(store, "hex")
      Store.record_cell(store, hex2, cell(set: "default", path: "deploy:android", outcome: :pass))
      Store.record_cell(store, hex2, cell(set: "default", path: "release:android", outcome: :error, layer: {:build, "release:android"}))

      ios = run!(store, "hex", "ios-lane")
      Store.record_cell(store, ios, cell(set: "default", platform: :ios, path: "deploy:ios_sim", outcome: :skip))

      %{hex1: hex1, hex2: hex2, master: master, ios: ios}
    end

    test "equality filters, alone and combined", %{store: store, hex1: hex1} do
      assert length(Store.query(store, versions_row: "master")) == 1
      assert length(Store.query(store, run_id: hex1)) == 3
      assert [%{set: "all"}] = Store.query(store, set: "all")
      assert [%{path: "release:android", layer: "build:release:android"}] = Store.query(store, path: "release:android")
      assert [%{platform: "ios"}] = Store.query(store, platform: :ios)
      assert [%{trigger: "ios-lane"}] = Store.query(store, trigger: "ios-lane")
      assert length(Store.query(store, outcome: :fail)) == 2
      assert [%{invariant: "p2"}] = Store.query(store, invariant: "p2")
      assert length(Store.query(store, versions_row: "hex", set: "default", outcome: :fail)) == 2
    end

    test "invariant: nil keeps summary rows only", %{store: store} do
      rows = Store.query(store, invariant: nil)
      assert length(rows) == 6
      assert Enum.all?(rows, &is_nil(&1.invariant))
    end

    test "latest keeps the newest row per (row, set, platform, path, invariant)", %{store: store, hex2: hex2} do
      latest = Store.query(store, invariant: nil, latest: true)

      keyed = Map.new(latest, &{{&1.versions_row, &1.set, &1.path}, &1})
      assert map_size(keyed) == length(latest)

      # hex/default/deploy ran twice: the second (pass) replaces the first (fail).
      assert %{outcome: :pass, run_id: ^hex2} = keyed[{"hex", "default", "deploy:android"}]
      assert %{outcome: :pass} = keyed[{"master", "default", "deploy:android"}]
      assert %{outcome: :pass} = keyed[{"hex", "all", "deploy:android"}]
      assert %{outcome: :error} = keyed[{"hex", "default", "release:android"}]
      assert %{outcome: :skip} = keyed[{"hex", "default", "deploy:ios_sim"}]
    end

    test "limit returns the newest rows, oldest first", %{store: store} do
      rows = Store.query(store, invariant: nil, limit: 2)
      assert [%{path: "release:android"}, %{path: "deploy:ios_sim"}] = rows
    end
  end

  describe "record_results/4" do
    test "a path's results: summary + one row per invariant + one per plugin self-test", %{store: store} do
      run = run!(store, "hex")

      a = %{Result.pass(:p12_item, "mob_a", "mob_a: pass") | evidence: %{ms: 40, module: A}}
      b = %{Result.fail(:p12_item, "mob_b", "mob_b: no fix") |> Result.at({:plugin, :mob_b}) | evidence: %{ms: 7, module: B}}
      p12 = %{Result.rollup([a, b], :p12, "self-tests") | evidence: %{items: [a, b]}}
      p2 = Result.pass(:p2, "boots", "up")

      meta = %{set: "default", platform: :android, path: "deploy:android", versions: %{row: "hex"}, duration_ms: 9_000, log_path: "/l"}
      :ok = Store.record_results(store, run, meta, {:fail, [p2, p12]})

      rows = Map.new(Store.query(store, run_id: run), &{&1.invariant, &1})
      assert map_size(rows) == 5

      assert %{outcome: :fail, layer: "plugin:mob_b", duration_ms: 9_000, log_path: "/l"} = rows[nil]
      assert rows[nil].detail["tally"] == %{"pass" => 1, "fail" => 1, "error" => 0, "skip" => 0}
      assert rows[nil].detail["failing"] == ["p12"]
      assert %{outcome: :pass, layer: nil} = rows["p2"]
      assert %{outcome: :fail, layer: "plugin:mob_b"} = rows["p12"]
      assert %{outcome: :pass, duration_ms: 40} = rows["p12:mob_a"]
      assert %{outcome: :fail, duration_ms: 7, layer: "plugin:mob_b"} = rows["p12:mob_b"]
      assert rows["p12:mob_b"].detail == %{"detail" => "mob_b: no fix"}
    end

    test "an orchestration error is one error summary row with its layer", %{store: store} do
      run = run!(store, "hex")
      meta = %{set: "default", platform: :android, path: "release:android", versions: nil, duration_ms: 5, log_path: nil}
      :ok = Store.record_results(store, run, meta, {:error, {:build_failed, :release, {:release_build, "x"}}, {:build, "release:android"}})

      assert [%{invariant: nil, outcome: :error, layer: "build:release:android", detail: %{"error" => err}}] =
               Store.query(store, run_id: run)

      assert err =~ "release_build"
    end

    test "summary_outcome: fail beats error beats pass; all skips (or nothing) is skip" do
      p = Result.pass(:a, "")
      s = Result.skip(:b, "", "")
      f = Result.fail(:c, "", "")
      e = Result.error(:d, "", "")

      assert Store.summary_outcome([p, s, e, f]) == :fail
      assert Store.summary_outcome([p, e]) == :error
      assert Store.summary_outcome([p, s]) == :pass
      assert Store.summary_outcome([s, s]) == :skip
      assert Store.summary_outcome([]) == :skip
    end
  end
end
