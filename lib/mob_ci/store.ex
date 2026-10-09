defmodule MobCi.Store do
  @moduledoc """
  The results store: one SQLite file (`exqlite`) every run writes its cells
  into, so the matrix (MOB-417), the P12 singleton comparison and
  `mix ci.report` read history instead of per-run artifact dirs.

  Default location `~/.local/share/mob_ci/results.sqlite`, overridden by
  `MOB_CI_STORE`. Two tables (`priv/schema.sql`):

    * `runs` — one per invocation: started_at, trigger, versions_row, host,
      mob_ci_sha, job_id (the `MobCi.Queue` job that ran it, else NULL).
    * `cells` — the outcomes of a run. A row with `invariant` NULL is a cell's
      summary (set × platform × path, outcome rolled up); the other rows of
      the same cell are its invariants (`"p2"`, `"p12"`) and each plugin's
      self-test (`"p12:mob_location"`). `outcome` is pass | fail | skip |
      error, `layer` the `MobCi.Report.format_layer/1` token of a non-pass,
      `detail` and `versions` JSON.

  `open/1` applies the schema on every open (every statement is
  `IF NOT EXISTS`), adds the columns a later version needs and records
  `PRAGMA user_version`; WAL mode and a busy timeout let the iOS lane, the
  queue's lane workers and an Android run write the same file. The trigger
  queue's tables (`jobs`, `job_cells`, `heads`, `pushes`, schema 2; schema 3
  adds `job_cells.retry_of`) live in the same file; `MobCi.Queue` and
  `MobCi.Poller` own them.
  """

  alias MobCi.{Report, Result}

  @schema_version 3
  @schema_file Path.expand("../../priv/schema.sql", __DIR__)
  @external_resource @schema_file
  @schema File.read!(@schema_file)

  @enforce_keys [:conn, :path]
  defstruct [:conn, :path]

  @type t :: %__MODULE__{conn: reference(), path: Path.t()}
  @type outcome :: :pass | :fail | :skip | :error

  @type run_meta :: %{
          required(:trigger) => String.t(),
          required(:versions_row) => String.t(),
          optional(:host) => String.t(),
          optional(:started_at) => DateTime.t(),
          optional(:mob_ci_sha) => String.t() | nil,
          optional(:job_id) => pos_integer() | nil
        }

  @type cell :: %{
          required(:set) => String.t(),
          required(:platform) => atom() | String.t(),
          required(:path) => String.t(),
          required(:outcome) => outcome() | String.t(),
          optional(:invariant) => String.t() | nil,
          optional(:layer) => Result.layer() | String.t(),
          optional(:duration_ms) => non_neg_integer() | nil,
          optional(:log_path) => Path.t() | nil,
          optional(:detail) => map() | nil,
          optional(:versions) => map() | nil
        }

  @doc "The schema version `open/1` migrates to."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "`$MOB_CI_STORE`, else `~/.local/share/mob_ci/results.sqlite`."
  @spec default_path() :: Path.t()
  def default_path do
    case System.get_env("MOB_CI_STORE") do
      nil -> Path.expand("~/.local/share/mob_ci/results.sqlite")
      "" -> Path.expand("~/.local/share/mob_ci/results.sqlite")
      path -> Path.expand(path)
    end
  end

  @doc "Open (creating the file and its directory) and migrate the store at `path`."
  @spec open(Path.t()) :: {:ok, t()} | {:error, term()}
  def open(path \\ default_path()) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))

    with {:ok, conn} <- Exqlite.Sqlite3.open(path),
         :ok <- Exqlite.Sqlite3.set_busy_timeout(conn, 10_000),
         :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = WAL"),
         :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA foreign_keys = ON"),
         store = %__MODULE__{conn: conn, path: path},
         :ok <- migrate(store) do
      {:ok, store}
    end
  end

  @doc "Same as `open/1`, raising on failure."
  @spec open!(Path.t()) :: t()
  def open!(path \\ default_path()) do
    case open(path) do
      {:ok, store} -> store
      {:error, reason} -> raise "mob_ci store #{path}: #{inspect(reason)}"
    end
  end

  @doc "Close the connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{conn: conn}) do
    Exqlite.Sqlite3.close(conn)
    :ok
  end

  @doc """
  Bring the schema to `schema_version/0`. Idempotent: running it on a current
  store changes nothing (every statement is `IF NOT EXISTS`, and a column is
  only added when missing).
  """
  @spec migrate(t()) :: :ok | {:error, term()}
  def migrate(%__MODULE__{conn: conn} = store) do
    with :ok <- Exqlite.Sqlite3.execute(conn, @schema),
         :ok <- add_column(store, "runs", "job_id", "INTEGER"),
         :ok <- add_column(store, "jobs", "publish_lane", "TEXT"),
         :ok <- add_column(store, "job_cells", "retry_of", "INTEGER") do
      if user_version(store) < @schema_version,
        do: Exqlite.Sqlite3.execute(conn, "PRAGMA user_version = #{@schema_version}"),
        else: :ok
    end
  end

  # Schema 2: runs.job_id, jobs.publish_lane; schema 3: job_cells.retry_of (the
  # cell a farm retry reruns). ALTER TABLE has no IF NOT EXISTS, so look first.
  defp add_column(%__MODULE__{conn: conn} = store, table, column, type) do
    present = store |> rows!("PRAGMA table_info(#{table})", []) |> Enum.any?(fn [_, name | _] -> name == column end)
    if present, do: :ok, else: Exqlite.Sqlite3.execute(conn, "ALTER TABLE #{table} ADD COLUMN #{column} #{type}")
  end

  @doc "The store's `PRAGMA user_version`."
  @spec user_version(t()) :: non_neg_integer()
  def user_version(store) do
    [[v]] = rows!(store, "PRAGMA user_version", [])
    v
  end

  # ── writing ──────────────────────────────────────────────────────────────────

  @doc """
  Record a run and return its id. `:host` defaults to this machine's short
  hostname, `:started_at` to now, `:mob_ci_sha` to the checkout's `HEAD`.
  A queue worker runs every cell with `MOB_CI_TRIGGER` and `MOB_CI_JOB_ID`
  set: the first replaces `:trigger` (a run then says `nightly`, `poll`, …
  rather than the task that ran it), the second fills `:job_id`; see
  `run_context/2`.
  """
  @spec record_run(t(), run_meta()) :: {:ok, pos_integer()}
  def record_run(%__MODULE__{} = store, meta) do
    meta = run_context(meta, System.get_env())
    started = Map.get(meta, :started_at) || DateTime.utc_now()

    params = [
      DateTime.to_iso8601(DateTime.truncate(started, :second)),
      to_string(Map.fetch!(meta, :trigger)),
      to_string(Map.fetch!(meta, :versions_row)),
      Map.get_lazy(meta, :host, &hostname/0),
      Map.get_lazy(meta, :mob_ci_sha, &mob_ci_sha/0),
      Map.get(meta, :job_id)
    ]

    exec!(
      store,
      "INSERT INTO runs (started_at, trigger, versions_row, host, mob_ci_sha, job_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      params
    )

    {:ok, last_id(store)}
  end

  @doc """
  `meta` with the queue's environment applied: a non-empty `MOB_CI_TRIGGER`
  replaces `:trigger`, a positive integer `MOB_CI_JOB_ID` sets `:job_id`
  unless `meta` has one. Pure; `env` is a `System.get_env/0` map.
  """
  @spec run_context(run_meta(), %{optional(String.t()) => String.t()}) :: run_meta()
  def run_context(meta, env) do
    meta =
      case env["MOB_CI_TRIGGER"] do
        t when is_binary(t) and t != "" -> Map.put(meta, :trigger, t)
        _ -> meta
      end

    with nil <- Map.get(meta, :job_id),
         id when is_binary(id) <- env["MOB_CI_JOB_ID"],
         {n, ""} when n > 0 <- Integer.parse(id) do
      Map.put(meta, :job_id, n)
    else
      _ -> meta
    end
  end

  @doc "Record one cell row (a summary when `:invariant` is nil) under `run_id`."
  @spec record_cell(t(), pos_integer(), cell()) :: :ok
  def record_cell(%__MODULE__{} = store, run_id, cell) do
    outcome = cell |> Map.fetch!(:outcome) |> to_string()

    unless outcome in ~w(pass fail skip error),
      do: raise(ArgumentError, "outcome must be pass | fail | skip | error, got #{inspect(outcome)}")

    params = [
      run_id,
      to_string(Map.fetch!(cell, :set)),
      to_string(Map.fetch!(cell, :platform)),
      to_string(Map.fetch!(cell, :path)),
      cell |> Map.get(:invariant) |> nil_or_string(),
      cell |> Map.get(:layer) |> layer_string(),
      outcome,
      Map.get(cell, :duration_ms),
      cell |> Map.get(:log_path) |> nil_or_string(),
      cell |> Map.get(:detail) |> json(),
      cell |> Map.get(:versions) |> json()
    ]

    exec!(
      store,
      ~s{INSERT INTO cells (run_id, "set", platform, path, invariant, layer, outcome, duration_ms, log_path, detail, versions) } <>
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
      params
    )

    :ok
  end

  @doc """
  Record one path of one cell from its catalog results: the summary row
  (outcome rolled up as `summary_outcome/1`, layer `MobCi.Result.attribute/1`
  of the non-passing results), one row per result (`invariant` = its id) and
  one per plugin self-test under P12 (`"p12:<plugin>"`). An orchestration
  error (`{:error, reason, layer}`: the path never reached the catalog) is a
  single `error` summary row.

  `meta` carries `:set`, `:platform`, `:path`, `:versions`, `:duration_ms`
  and `:log_path`.
  """
  @spec record_results(t(), pos_integer(), map(), {:ok | :fail, [Result.t()]} | {:error, term(), Result.layer() | String.t()}) ::
          :ok
  def record_results(store, run_id, meta, {:error, reason, layer}) do
    record_cell(store, run_id, cell_meta(meta, %{
      outcome: :error,
      layer: layer,
      detail: %{error: inspect(reason, limit: 50, printable_limit: 4_000)}
    }))
  end

  def record_results(store, run_id, meta, {verdict, results}) when verdict in [:ok, :fail] do
    for row <- result_rows(meta, results), do: record_cell(store, run_id, row)
    :ok
  end

  @doc false
  # The rows `record_results/4` writes for a result list (pure).
  @spec result_rows(map(), [Result.t()]) :: [cell()]
  def result_rows(meta, results) do
    bad = Enum.filter(results, &(&1.status in [:fail, :error]))

    summary =
      cell_meta(meta, %{
        outcome: summary_outcome(results),
        layer: Result.attribute(bad),
        detail: %{
          tally: Report.tally(results),
          failing: Enum.map(bad, &to_string(&1.id))
        }
      })

    per_invariant =
      for r <- results do
        cell_meta(meta, %{
          invariant: to_string(r.id),
          outcome: r.status,
          layer: r.layer,
          duration_ms: nil,
          detail: %{title: r.title, detail: r.detail}
        })
      end

    selftests =
      for %Result{id: :p12, evidence: %{items: items}} <- results, item <- items do
        cell_meta(meta, %{
          invariant: "p12:#{item.title}",
          outcome: item.status,
          layer: item.layer,
          duration_ms: get_in(item.evidence || %{}, [:ms]),
          detail: %{detail: item.detail}
        })
      end

    [summary | per_invariant] ++ selftests
  end

  defp cell_meta(meta, fields) do
    meta
    |> Map.take([:set, :platform, :path, :versions, :duration_ms, :log_path])
    |> Map.merge(fields)
  end

  @doc """
  A path's overall outcome: `fail` if any result failed, else `error` if any
  errored, else `skip` if every result skipped (or there are none), else `pass`.
  """
  @spec summary_outcome([Result.t()]) :: outcome()
  def summary_outcome(results) do
    statuses = Enum.map(results, & &1.status)

    cond do
      :fail in statuses -> :fail
      :error in statuses -> :error
      Enum.all?(statuses, &(&1 == :skip)) -> :skip
      true -> :pass
    end
  end

  # ── reading ──────────────────────────────────────────────────────────────────

  @doc """
  Cells joined with their run, oldest first. Filters (all optional):

    * `:id`, `:run_id`, `:versions_row`, `:set`, `:platform`, `:path`,
      `:outcome`, `:trigger` — equality.
    * `:invariant` — equality; `nil` selects summary rows only.
    * `:latest` — `true` keeps only the newest row per (versions_row, set,
      platform, path, invariant): the current grid.
    * `:limit` — at most this many rows (the newest ones, still returned
      oldest first).

  Each row is a map: `:id, :run_id, :set, :platform, :path, :invariant,
  :layer, :outcome` (atom), `:duration_ms, :log_path, :detail, :versions`
  (decoded JSON, string keys), plus the run's `:started_at, :trigger,
  :versions_row, :host, :mob_ci_sha`.
  """
  @spec query(t(), keyword()) :: [map()]
  def query(%__MODULE__{} = store, filters \\ []) do
    {where, params} = where(filters)

    latest =
      if Keyword.get(filters, :latest, false),
        do: [
          ~s{c.id IN (SELECT MAX(c2.id) FROM cells c2 JOIN runs r2 ON r2.id = c2.run_id } <>
            ~s{GROUP BY r2.versions_row, c2."set", c2.platform, c2.path, IFNULL(c2.invariant, ''))}
        ],
        else: []

    clauses = where ++ latest
    where_sql = if clauses == [], do: "", else: " WHERE " <> Enum.join(clauses, " AND ")

    limit_sql =
      case Keyword.get(filters, :limit) do
        n when is_integer(n) and n > 0 -> " ORDER BY c.id DESC LIMIT #{n}"
        _ -> " ORDER BY c.id ASC"
      end

    sql =
      ~s{SELECT c.id, c.run_id, c."set", c.platform, c.path, c.invariant, c.layer, c.outcome, } <>
        "c.duration_ms, c.log_path, c.detail, c.versions, r.started_at, r.trigger, r.versions_row, r.host, r.mob_ci_sha " <>
        "FROM cells c JOIN runs r ON r.id = c.run_id" <> where_sql <> limit_sql

    rows = store |> rows!(sql, params) |> Enum.map(&row_map/1)
    if Keyword.has_key?(filters, :limit), do: Enum.sort_by(rows, & &1.id), else: rows
  end

  @filter_columns [
    id: "c.id",
    run_id: "c.run_id",
    versions_row: "r.versions_row",
    set: ~s{c."set"},
    platform: "c.platform",
    path: "c.path",
    outcome: "c.outcome",
    trigger: "r.trigger"
  ]

  defp where(filters) do
    {clauses, params} =
      Enum.reduce(filters, {[], []}, fn
        {:invariant, nil}, {cs, ps} ->
          {["c.invariant IS NULL" | cs], ps}

        {:invariant, inv}, {cs, ps} ->
          {["c.invariant = ?#{length(ps) + 1}" | cs], ps ++ [to_string(inv)]}

        {key, value}, {cs, ps} ->
          case Keyword.fetch(@filter_columns, key) do
            {:ok, column} -> {["#{column} = ?#{length(ps) + 1}" | cs], ps ++ [param(value)]}
            :error -> {cs, ps}
          end
      end)

    {Enum.reverse(clauses), params}
  end

  defp param(v) when is_integer(v), do: v
  defp param(v), do: to_string(v)

  @doc """
  The newest self-test outcome of `plugin` in its singleton cell
  (`singleton:<plugin>`) on `versions_row`/`platform`/`path`, or nil if that
  singleton never ran: what P12 compares a failure in a larger set with.
  """
  @spec singleton_selftest(t(), atom() | String.t(), keyword()) :: outcome() | nil
  def singleton_selftest(store, plugin, opts) do
    # Every row of the key, oldest first: the newest that isn't a `farm`
    # cell's (an instance lost mid-probe says nothing about the plugin).
    filters = [
      set: "singleton:#{plugin}",
      invariant: "p12:#{plugin}",
      versions_row: Keyword.fetch!(opts, :versions_row),
      platform: Keyword.get(opts, :platform, :android),
      path: Keyword.fetch!(opts, :path)
    ]

    case store |> query(filters) |> Enum.reject(&farm?/1) |> List.last() do
      %{outcome: outcome} -> outcome
      nil -> nil
    end
  end

  # ── retention ────────────────────────────────────────────────────────────────

  @doc """
  Delete what the store no longer needs. A cell (its summary row plus its
  invariant and self-test rows) whose run started more than `:days` (default
  30) before `:now` is deleted unless something still reads it:

    * kept whole, forever: the newest cell of its (versions_row, set,
      platform, path), overall and among non-`replay` runs (the grid), and
      the newest `singleton:<p>` cell per key that has self-test rows (the
      P12 singleton lookup, `singleton_selftest/3`, reads those rows, and an
      errored cell has none);
    * kept as its summary row only: the newest non-skip non-replay cell per
      key among the cells already reported (`:reported`, the last summary id
      a Muster post covered; default all), the baseline of the next
      regression check; and for `default`, `all` and `singleton:<p>`, the
      newest cell and the newest passing cell per (set, platform, path,
      exact pins), the evidence `COMPATIBILITY.md` is built from (a later
      failure of the same pins must keep demoting a tuple).

  Runs left without cells go too. Returns the counts and the `log_path`s of
  the deleted rows (the caller deletes those files, `MobCi.Publish.prune/2`).
  """
  @spec prune(t(), keyword()) :: %{cells: non_neg_integer(), runs: non_neg_integer(), log_paths: [Path.t()]}
  def prune(%__MODULE__{} = store, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = now |> DateTime.add(-Keyword.get(opts, :days, 30) * 86_400, :second) |> iso()

    transaction!(store, fn ->
      rows = query(store)
      summaries = Enum.filter(rows, &is_nil(&1.invariant))
      selftests = for r <- rows, String.starts_with?(r.invariant || "", "p12:"), into: MapSet.new(), do: cell_key(r)
      {whole, summary_only} = retained(summaries, selftests: selftests, reported: Keyword.get(opts, :reported))
      by_cell = Enum.group_by(rows, &cell_key/1)

      {cells, logs} =
        for s <- summaries, s.started_at < cutoff, key = cell_key(s), not MapSet.member?(whole, key), reduce: {0, []} do
          {n, logs} ->
            only_details = MapSet.member?(summary_only, key)
            gone = if only_details, do: Enum.filter(by_cell[key], & &1.invariant), else: by_cell[key]

            exec!(
              store,
              ~s{DELETE FROM cells WHERE run_id = ?1 AND "set" = ?2 AND platform = ?3 AND path = ?4} <>
                if(only_details, do: " AND invariant IS NOT NULL", else: ""),
              [s.run_id, s.set, s.platform, s.path]
            )

            {n + length(gone), logs ++ for(r <- gone, r.log_path, do: r.log_path)}
        end

      exec!(store, "DELETE FROM runs WHERE started_at < ?1 AND NOT EXISTS (SELECT 1 FROM cells WHERE cells.run_id = runs.id)", [cutoff])
      %{cells: cells, runs: changes(store), log_paths: logs |> Enum.uniq() |> Enum.sort()}
    end)
  end

  @evidence_sets ["default", "all"]

  @doc false
  # The cells `prune/2` keeps (pure): {kept whole, kept as summary only}, as
  # {run_id, set, platform, path} keys. `opts`: `:selftests` (keys of cells
  # with `p12:` rows), `:reported` (last reported summary id, nil = all).
  @spec retained([map()], keyword()) :: {MapSet.t(), MapSet.t()}
  def retained(summaries, opts \\ []) do
    newest = fn rows, by -> rows |> Enum.group_by(by) |> Enum.map(fn {_, rs} -> Enum.max_by(rs, & &1.id) end) end
    grid_key = &{&1.versions_row, &1.set, &1.platform, &1.path}
    real = Enum.reject(summaries, &(&1.trigger == "replay"))
    selftests = Keyword.get(opts, :selftests, MapSet.new())
    reported = Keyword.get(opts, :reported)

    singleton_selftests =
      Enum.filter(summaries, &(String.starts_with?(&1.set, "singleton:") and not farm?(&1) and MapSet.member?(selftests, cell_key(&1))))

    whole = newest.(summaries, grid_key) ++ newest.(real, grid_key) ++ newest.(singleton_selftests, grid_key)

    # A farm cell (the instance was lost) says nothing about the code, so it
    # is never the baseline a later regression check compares against.
    baseline =
      real
      |> Enum.filter(&(&1.outcome != :skip and not farm?(&1) and (is_nil(reported) or &1.id <= reported)))
      |> newest.(grid_key)

    evidence = Enum.filter(summaries, &evidence_set?(&1.set))
    pins_key = &{&1.set, &1.platform, &1.path, pins(&1.versions)}
    evidence = newest.(evidence, pins_key) ++ newest.(Enum.filter(evidence, &(&1.outcome == :pass)), pins_key)

    {MapSet.new(whole, &cell_key/1), MapSet.new(baseline ++ evidence, &cell_key/1)}
  end

  @doc """
  Is this summary row a `farm` cell — its instance (redroid container, adb
  device) was lost mid-path, so it says nothing about the code under test?
  """
  @spec farm?(map()) :: boolean()
  def farm?(row), do: Map.get(row, :layer) in ["farm", :farm]

  @doc "Is `set` one `COMPATIBILITY.md` reads (`default`, `all`, `singleton:<p>`)?"
  @spec evidence_set?(String.t()) :: boolean()
  def evidence_set?("singleton:" <> _), do: true
  def evidence_set?(set), do: set in @evidence_sets

  @doc """
  The exact pins of a stored versions record, machine-independent: repo name
  → `{version, sha, source}` (the record's `dir` is where *that* machine
  materialised the pin, not part of it). `%{}` for a cell without versions.
  """
  @spec pins(map() | nil) :: %{String.t() => {String.t() | nil, String.t() | nil, String.t() | nil}}
  def pins(%{"repos" => repos}) when is_map(repos),
    do: Map.new(repos, fn {name, p} -> {to_string(name), {p["version"], p["sha"], p["source"]}} end)

  def pins(_), do: %{}

  defp cell_key(s), do: {s.run_id, s.set, s.platform, s.path}

  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # ── plumbing ─────────────────────────────────────────────────────────────────

  defp row_map([id, run_id, set, platform, path, inv, layer, outcome, ms, log, detail, versions, started, trigger, row, host, sha]) do
    %{
      id: id,
      run_id: run_id,
      set: set,
      platform: platform,
      path: path,
      invariant: inv,
      layer: layer,
      outcome: String.to_existing_atom(outcome),
      duration_ms: ms,
      log_path: log,
      detail: decode(detail),
      versions: decode(versions),
      started_at: started,
      trigger: trigger,
      versions_row: row,
      host: host,
      mob_ci_sha: sha
    }
  end

  defp decode(nil), do: nil
  defp decode(text), do: JSON.decode!(text)

  defp json(nil), do: nil
  defp json(term), do: term |> jsonable() |> JSON.encode!()

  # JSON has no tuples, pids or refs: those are inspected; maps and lists recurse.
  @doc false
  def jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def jsonable(%MapSet{} = s), do: s |> MapSet.to_list() |> jsonable()
  def jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()
  def jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), jsonable(v)} end)
  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  def jsonable(v) when is_atom(v), do: Atom.to_string(v)
  def jsonable(v), do: inspect(v, limit: 50, printable_limit: 4_000)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)

  defp nil_or_string(nil), do: nil
  defp nil_or_string(v), do: to_string(v)

  defp layer_string(nil), do: nil
  defp layer_string(s) when is_binary(s), do: s
  defp layer_string(layer), do: Report.format_layer(layer)

  # The SQL helpers below are public for the modules that own the store's
  # other tables (MobCi.Queue, MobCi.Poller); everything else reads query/2.

  @doc false
  @spec exec!(t(), String.t(), list()) :: :ok
  def exec!(%__MODULE__{conn: conn}, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)

      case Exqlite.Sqlite3.step(conn, stmt) do
        :done -> :ok
        {:row, _} -> :ok
        other -> raise "mob_ci store: #{inspect(other)} on #{sql}"
      end
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  @doc false
  @spec rows!(t(), String.t(), list()) :: [list()]
  def rows!(%__MODULE__{conn: conn}, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      rows
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  @doc false
  @spec last_id(t()) :: pos_integer()
  def last_id(%__MODULE__{conn: conn}) do
    {:ok, id} = Exqlite.Sqlite3.last_insert_rowid(conn)
    id
  end

  @doc false
  # Rows the last statement changed.
  @spec changes(t()) :: non_neg_integer()
  def changes(%__MODULE__{conn: conn}) do
    {:ok, n} = Exqlite.Sqlite3.changes(conn)
    n
  end

  @doc false
  # Run `fun` in a write transaction (BEGIN IMMEDIATE takes the write lock up
  # front, so two lane workers never interleave a read-then-write).
  @spec transaction!(t(), (-> result)) :: result when result: term()
  def transaction!(%__MODULE__{conn: conn}, fun) do
    :ok = Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      :ok = Exqlite.Sqlite3.execute(conn, "COMMIT")
      result
    rescue
      e ->
        Exqlite.Sqlite3.execute(conn, "ROLLBACK")
        reraise e, __STACKTRACE__
    end
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    name |> to_string() |> String.split(".") |> hd()
  end

  @mob_ci_dir Path.expand("../..", __DIR__)

  @doc "The git sha of the mob_ci checkout running this code (nil outside git)."
  @spec mob_ci_sha() :: String.t() | nil
  def mob_ci_sha do
    case System.cmd("git", ["-C", @mob_ci_dir, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
