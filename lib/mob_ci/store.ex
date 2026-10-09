defmodule MobCi.Store do
  @moduledoc """
  The results store: one SQLite file (`exqlite`) every run writes its cells
  into, so the matrix (MOB-417), the P12 singleton comparison and
  `mix ci.report` read history instead of per-run artifact dirs.

  Default location `~/.local/share/mob_ci/results.sqlite`, overridden by
  `MOB_CI_STORE`. Two tables (`priv/schema.sql`):

    * `runs` — one per invocation: started_at, trigger, versions_row, host,
      mob_ci_sha.
    * `cells` — the outcomes of a run. A row with `invariant` NULL is a cell's
      summary (set × platform × path, outcome rolled up); the other rows of
      the same cell are its invariants (`"p2"`, `"p12"`) and each plugin's
      self-test (`"p12:mob_location"`). `outcome` is pass | fail | skip |
      error, `layer` the `MobCi.Report.format_layer/1` token of a non-pass,
      `detail` and `versions` JSON.

  `open/1` applies the schema on every open (every statement is
  `IF NOT EXISTS`) and records `PRAGMA user_version`; WAL mode and a busy
  timeout let the iOS lane and an Android run write the same file.
  """

  alias MobCi.{Report, Result}

  @schema_version 1
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
          optional(:mob_ci_sha) => String.t() | nil
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
  store changes nothing (every statement is `IF NOT EXISTS`).
  """
  @spec migrate(t()) :: :ok | {:error, term()}
  def migrate(%__MODULE__{conn: conn} = store) do
    with :ok <- Exqlite.Sqlite3.execute(conn, @schema) do
      if user_version(store) < @schema_version,
        do: Exqlite.Sqlite3.execute(conn, "PRAGMA user_version = #{@schema_version}"),
        else: :ok
    end
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
  """
  @spec record_run(t(), run_meta()) :: {:ok, pos_integer()}
  def record_run(%__MODULE__{} = store, meta) do
    started = Map.get(meta, :started_at) || DateTime.utc_now()

    params = [
      DateTime.to_iso8601(DateTime.truncate(started, :second)),
      to_string(Map.fetch!(meta, :trigger)),
      to_string(Map.fetch!(meta, :versions_row)),
      Map.get_lazy(meta, :host, &hostname/0),
      Map.get_lazy(meta, :mob_ci_sha, &mob_ci_sha/0)
    ]

    exec!(
      store,
      "INSERT INTO runs (started_at, trigger, versions_row, host, mob_ci_sha) VALUES (?1, ?2, ?3, ?4, ?5)",
      params
    )

    {:ok, last_id(store)}
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

    * `:run_id`, `:versions_row`, `:set`, `:platform`, `:path`, `:outcome`,
      `:trigger` — equality.
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
    filters = [
      set: "singleton:#{plugin}",
      invariant: "p12:#{plugin}",
      versions_row: Keyword.fetch!(opts, :versions_row),
      platform: Keyword.get(opts, :platform, :android),
      path: Keyword.fetch!(opts, :path),
      limit: 1
    ]

    case query(store, filters) do
      [%{outcome: outcome}] -> outcome
      [] -> nil
    end
  end

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

  defp exec!(%__MODULE__{conn: conn}, sql, params) do
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

  defp rows!(%__MODULE__{conn: conn}, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      rows
    after
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp last_id(%__MODULE__{conn: conn}) do
    {:ok, id} = Exqlite.Sqlite3.last_insert_rowid(conn)
    id
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
