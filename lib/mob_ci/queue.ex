defmodule MobCi.Queue do
  @moduledoc """
  The durable trigger queue on the NUC: two tables in the results store
  (`jobs`, `job_cells`, `priv/schema.sql` schema 2), drained by one worker per
  lane. Rationale: `decisions/2026-10-09-trigger-queue.md`.

  A **job** is one trigger's request, `MobCi.Triggers.job/0`: a versions row,
  its sets, its platforms, a reason, a priority and an optional `not_after`.
  `enqueue/3` expands it into one **cell** per (set, platform), sets in the
  job's order. A cell identical to one still queued (same row, set,
  platform and paths) whose job runs at least as soon and can't expire
  sooner is stored as a `duplicate` of it instead of running twice: a
  `master` cell resolves the default-branch shas when it *starts*, so the
  queued one already covers the newer commit. A running cell has resolved
  its shas and is never a dedup target.

  A **lane** is a platform: `android` (the shared redroid farm) and `ios`
  (the Mac mini over ssh). One worker per lane (`drain/3`, run under `flock`
  by `priv/ci-run.sh drain <lane>`) claims cells one at a time, highest job
  priority first, then oldest job, then the job's set order, and runs each
  as its own `mix ci.device` with `MOB_CI_TRIGGER` / `MOB_CI_JOB_ID` set, so
  the store's run rows say which trigger and job produced them. The two
  lanes use different machines and run side by side.

  A job is **done** when none of its cells is queued or running and every
  cell it deferred to (a `duplicate`) is done too; the worker that finishes
  it runs `mix ci.report --publish` (or `mix ci.report` where the task has no
  `--publish`) once. A cell of a job with `not_after` that has not started by
  then `expire`s (the nightly yields the farm in the morning). A cell whose
  `mix ci.device` exits 3 failed on infrastructure (layer `farm`: it lost its
  instance; layer `toolchain`: the build's JVM crashed) and is retried
  once, ahead of the rest of its priority. A worker that
  starts finds what a crashed worker of its lane left behind: `running`
  cells (requeued) and jobs it completed without publishing (published).
  Before every Android cell the worker reaps the farm (`MobCi.Farm.reap/0`):
  a `ci-redroid` whose owning cell died without releasing it is downed.
  """

  alias MobCi.{Farm, Store, Triggers}

  @type cell :: %{
          id: pos_integer(),
          job_id: pos_integer(),
          trigger: String.t(),
          versions_row: String.t(),
          set: String.t(),
          platform: String.t(),
          paths: String.t() | nil,
          retry_of: pos_integer() | nil
        }

  # A cell runs at most this long, then `timeout` kills it (exit 124).
  @cell_timeout_s 90 * 60
  @publish_timeout_s 15 * 60
  # `mix ci.device`: infrastructure failed under a path (layer farm or toolchain).
  @infra_exit 3

  # ── enqueue ──────────────────────────────────────────────────────────────────

  @doc """
  Store `job` and its cells. Returns `{:ok, job_id, cells}` where each cell
  is `%{id, set, platform, status, duplicate_of}`. Atomic (one write
  transaction), so a worker never claims half a job.
  """
  @spec enqueue(Store.t(), Triggers.job(), keyword()) :: {:ok, pos_integer(), [map()]}
  def enqueue(store, job, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Store.transaction!(store, fn ->
      Store.exec!(
        store,
        "INSERT INTO jobs (trigger, versions_row, sets, platforms, reason, priority, not_after, enqueued_at) " <>
          "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        [
          job.trigger,
          job.versions_row,
          JSON.encode!(job.sets),
          JSON.encode!(job.platforms),
          job[:reason],
          Map.get(job, :priority, 0),
          iso(job[:not_after]),
          iso(now)
        ]
      )

      job_id = Store.last_id(store)
      cells = for set <- job.sets, platform <- job.platforms, do: add_cell(store, job_id, job, set, platform)
      {:ok, job_id, cells}
    end)
  end

  # Dedup only onto a queued cell whose job runs at least as soon (priority)
  # and can't expire before this one would: a poll cell folded into a nightly
  # cell would otherwise wait at nightly priority and vanish with it at 07:00.
  defp add_cell(store, job_id, job, set, platform) do
    row = job.versions_row
    paths = Triggers.cell_paths(set, platform)
    not_after = iso(job[:not_after])

    dup =
      case Store.rows!(
             store,
             ~s{SELECT c.id FROM job_cells c JOIN jobs j ON j.id = c.job_id WHERE c.status = 'queued' } <>
               ~s{AND c.versions_row = ?1 AND c."set" = ?2 AND c.platform = ?3 } <>
               "AND IFNULL(c.paths, '') = IFNULL(?4, '') AND j.priority >= ?5 " <>
               "AND (j.not_after IS NULL OR (?6 IS NOT NULL AND j.not_after >= ?6)) ORDER BY c.id LIMIT 1",
             [row, set, platform, paths, Map.get(job, :priority, 0), not_after]
           ) do
        [[id]] -> id
        [] -> nil
      end

    status = if dup, do: "duplicate", else: "queued"

    Store.exec!(
      store,
      ~s{INSERT INTO job_cells (job_id, versions_row, "set", platform, paths, status, duplicate_of) } <>
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      [job_id, row, set, platform, paths, status, dup]
    )

    %{id: Store.last_id(store), set: set, platform: platform, status: status, duplicate_of: dup}
  end

  # ── the lane worker's steps ──────────────────────────────────────────────────

  @doc """
  Requeue `lane`'s cells left `running` by a worker that died. Only call it
  holding the lane's lock (`priv/ci-run.sh drain` takes it). Returns the count.
  """
  @spec recover(Store.t(), String.t()) :: non_neg_integer()
  def recover(store, lane) do
    Store.exec!(
      store,
      "UPDATE job_cells SET status = 'queued', started_at = NULL WHERE platform = ?1 AND status = 'running'",
      [lane]
    )

    Store.changes(store)
  end

  @doc """
  Expire `lane`'s queued cells whose job's `not_after` has passed; returns the
  ids of the jobs that this completed.
  """
  @spec expire(Store.t(), String.t(), DateTime.t()) :: [pos_integer()]
  def expire(store, lane, now) do
    Store.transaction!(store, fn ->
      job_ids =
        store
        |> Store.rows!(
          "SELECT DISTINCT c.job_id FROM job_cells c JOIN jobs j ON j.id = c.job_id " <>
            "WHERE c.platform = ?1 AND c.status = 'queued' AND j.not_after IS NOT NULL AND j.not_after <= ?2",
          [lane, iso(now)]
        )
        |> Enum.map(&hd/1)

      for job_id <- job_ids do
        Store.exec!(
          store,
          "UPDATE job_cells SET status = 'expired', finished_at = ?3 WHERE job_id = ?1 AND platform = ?2 AND status = 'queued'",
          [job_id, lane, iso(now)]
        )
      end

      Enum.flat_map(job_ids, &complete_affected(store, &1, lane, now))
    end)
  end

  @doc """
  Claim `lane`'s next cell: highest job priority, then a retry of a cell that
  lost its instance, then the oldest job, then the job's set order. `nil`
  when the lane is empty.
  """
  @spec claim(Store.t(), String.t(), DateTime.t()) :: cell() | nil
  def claim(store, lane, now) do
    rows =
      Store.rows!(
        store,
        "UPDATE job_cells SET status = 'running', started_at = ?2 WHERE id = (" <>
          "SELECT c.id FROM job_cells c JOIN jobs j ON j.id = c.job_id " <>
          "WHERE c.platform = ?1 AND c.status = 'queued' " <>
          "ORDER BY j.priority DESC, (c.retry_of IS NULL), c.job_id, c.id LIMIT 1) " <>
          ~s{RETURNING id, job_id, versions_row, "set", platform, paths, retry_of},
        [lane, iso(now)]
      )

    case rows do
      [] ->
        nil

      [[id, job_id, row, set, platform, paths, retry_of]] ->
        [[trigger]] = Store.rows!(store, "SELECT trigger FROM jobs WHERE id = ?1", [job_id])

        %{
          id: id,
          job_id: job_id,
          trigger: trigger,
          versions_row: row,
          set: set,
          platform: platform,
          paths: paths,
          retry_of: retry_of
        }
    end
  end

  @doc """
  `mix ci.device`'s exit code for a cell infrastructure failed under (layer
  `farm` or `toolchain`): `finish/5` queues one retry of it.
  """
  @spec infra_exit() :: 3
  def infra_exit, do: @infra_exit

  @doc """
  Record a claimed cell's exit code and log; returns the ids of the jobs this
  completed (its own, and any whose duplicate was waiting on it). A cell
  that exited `infra_exit/0` and is not itself a retry gets one retry (same
  row, set, platform and paths, `retry_of` it), claimed before anything else
  of its priority; cells that deferred to it defer to the retry instead, so
  no job completes on the lost attempt alone. Both attempts stay recorded:
  as cells here and as runs in the store.
  """
  @spec finish(Store.t(), pos_integer(), integer(), Path.t() | nil, DateTime.t()) :: [pos_integer()]
  def finish(store, cell_id, exit_code, log_path, now) do
    Store.transaction!(store, fn ->
      Store.exec!(
        store,
        "UPDATE job_cells SET status = 'done', exit_code = ?2, log_path = ?3, finished_at = ?4 WHERE id = ?1",
        [cell_id, exit_code, log_path, iso(now)]
      )

      [[job_id, lane, retry_of]] =
        Store.rows!(store, "SELECT job_id, platform, retry_of FROM job_cells WHERE id = ?1", [cell_id])

      if exit_code == @infra_exit and is_nil(retry_of), do: queue_retry(store, cell_id)

      waiting =
        store
        |> Store.rows!("SELECT DISTINCT job_id FROM job_cells WHERE duplicate_of = ?1", [cell_id])
        |> Enum.map(&hd/1)

      Enum.flat_map(Enum.uniq([job_id | waiting]), &complete(store, &1, lane, now))
    end)
  end

  defp queue_retry(store, cell_id) do
    Store.exec!(
      store,
      ~s{INSERT INTO job_cells (job_id, versions_row, "set", platform, paths, status, retry_of) } <>
        ~s{SELECT job_id, versions_row, "set", platform, paths, 'queued', id FROM job_cells WHERE id = ?1},
      [cell_id]
    )

    retry = Store.last_id(store)
    Store.exec!(store, "UPDATE job_cells SET duplicate_of = ?2 WHERE duplicate_of = ?1", [cell_id, retry])
    say("[queue] cell #{cell_id} failed on infrastructure (layer farm or toolchain); retrying once as cell #{retry}")
  end

  # Expiring cells can release jobs whose duplicates pointed at them.
  defp complete_affected(store, job_id, lane, now) do
    waiting =
      store
      |> Store.rows!(
        "SELECT DISTINCT d.job_id FROM job_cells d JOIN job_cells c ON c.id = d.duplicate_of WHERE c.job_id = ?1",
        [job_id]
      )
      |> Enum.map(&hd/1)

    Enum.flat_map(Enum.uniq([job_id | waiting]), &complete(store, &1, lane, now))
  end

  # Mark `job_id` done if nothing of it is pending; [job_id] when this call did
  # it. The completing lane owns the job's publish (`unpublished/2`).
  defp complete(store, job_id, lane, now) do
    Store.exec!(
      store,
      "UPDATE jobs SET status = 'done', finished_at = ?2, publish_lane = ?3 WHERE id = ?1 AND status = 'queued' " <>
        "AND NOT EXISTS (" <>
        "SELECT 1 FROM job_cells c WHERE c.job_id = ?1 AND (c.status IN ('queued', 'running') OR " <>
        "(c.status = 'duplicate' AND EXISTS (SELECT 1 FROM job_cells d WHERE d.id = c.duplicate_of " <>
        "AND d.status IN ('queued', 'running')))))",
      [job_id, iso(now), lane]
    )

    if Store.changes(store) == 1, do: [job_id], else: []
  end

  @doc """
  Jobs `lane` completed but never published (its worker died between the
  two). Only call it holding the lane's lock: then no live worker owns them.
  """
  @spec unpublished(Store.t(), String.t()) :: [pos_integer()]
  def unpublished(store, lane) do
    store
    |> Store.rows!(
      "SELECT id FROM jobs WHERE status = 'done' AND publish_exit IS NULL AND publish_lane = ?1 ORDER BY id",
      [lane]
    )
    |> Enum.map(&hd/1)
  end

  @doc "Record the exit code of the report run after `job_id` finished."
  @spec record_publish(Store.t(), pos_integer(), integer()) :: :ok
  def record_publish(store, job_id, code),
    do: Store.exec!(store, "UPDATE jobs SET publish_exit = ?2 WHERE id = ?1", [job_id, code])

  # ── the worker ───────────────────────────────────────────────────────────────

  @doc """
  Drain `lane` until it has nothing queued: requeue orphans, then repeatedly
  expire overdue cells, claim one, run it, record it, and publish every job
  that completed. Options (all for tests; the defaults run the real thing):

    * `:run_cell` — `fn cell -> {exit_code, log_path} end` (default
      `run_cell/2`: `mix ci.device` under `timeout`).
    * `:publish` — `fn job -> exit_code end` (default `publish/2`).
    * `:now` — `fn -> DateTime.t() end`.
    * `:log_dir` — where cell and publish logs go (default `log_dir/0`).
    * `:reap` — `fn -> any end`, run before every Android cell (default
      `MobCi.Farm.reap/0`, its lines logged).

  Returns `%{ran: [cell], published: [job_id], recovered: n}`.
  """
  @spec drain(Store.t(), String.t(), keyword()) :: %{ran: [cell()], published: [pos_integer()], recovered: non_neg_integer()}
  def drain(store, lane, opts \\ []) do
    lane in Triggers.platforms() || raise ArgumentError, "unknown lane #{inspect(lane)}"
    log_dir = Keyword.get_lazy(opts, :log_dir, &log_dir/0)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    run_cell = Keyword.get(opts, :run_cell, &run_cell(&1, log_dir))
    publish = Keyword.get(opts, :publish, &publish(&1, log_dir))
    reap = Keyword.get(opts, :reap, &reap_farm/0)

    # A cell killed mid-run (SIGKILL, a reboot) left its instance up; take the
    # slot back before this cell asks for one.
    run_cell = if lane == "android", do: fn cell -> reap.(); run_cell.(cell) end, else: run_cell

    recovered = recover(store, lane)
    if recovered > 0, do: say("[#{lane}] requeued #{recovered} cell(s) a dead worker left running")
    acc = %{ran: [], published: [], recovered: recovered}

    # A worker that died after completing a job but before its report ran.
    acc = publish_all(store, unpublished(store, lane), publish, acc)
    loop(store, lane, now, run_cell, publish, acc)
  end

  defp loop(store, lane, now, run_cell, publish, acc) do
    acc = publish_all(store, expire(store, lane, now.()), publish, acc)

    case claim(store, lane, now.()) do
      nil ->
        %{acc | ran: Enum.reverse(acc.ran), published: Enum.reverse(acc.published)}

      cell ->
        say("[#{lane}] job #{cell.job_id} (#{cell.trigger}) cell #{cell.id}: #{cell.set} on #{cell.versions_row}")
        {code, log} = run_cell.(cell)
        say("[#{lane}] cell #{cell.id} exit #{code} — #{log}")
        done = finish(store, cell.id, code, log, now.())
        acc = publish_all(store, done, publish, %{acc | ran: [cell | acc.ran]})
        loop(store, lane, now, run_cell, publish, acc)
    end
  end

  defp publish_all(store, job_ids, publish, acc) do
    Enum.reduce(job_ids, acc, fn job_id, acc ->
      job = job(store, job_id)
      code = publish.(job)
      record_publish(store, job_id, code)
      say("[publish] job #{job_id} (#{job.trigger} #{job.versions_row}) done; report exit #{code}")
      %{acc | published: [job_id | acc.published]}
    end)
  end

  # ── running a cell ───────────────────────────────────────────────────────────

  @doc """
  The `mix` argv for a cell. Android cells write their artifacts (build logs,
  junit, summary.json) under `<log_dir>/cell-<id>/` so a later cell never
  overwrites the logs the store points at.
  """
  @spec cell_argv(cell(), Path.t()) :: [String.t()]
  def cell_argv(%{platform: "android"} = cell, log_dir) do
    ["ci.device", "--set", cell.set, "--versions", cell.versions_row] ++
      paths_flag(cell) ++ ["--artifacts", Path.join(log_dir, "cell-#{cell.id}")]
  end

  def cell_argv(%{platform: "ios"} = cell, _log_dir) do
    ["ci.device", "--platform", "ios", "--set", cell.set, "--versions", cell.versions_row] ++ paths_flag(cell)
  end

  defp paths_flag(%{paths: nil}), do: []
  defp paths_flag(%{paths: paths}), do: ["--paths", paths]

  @doc "The environment a queued run carries into the store (`MobCi.Store.run_context/2`)."
  @spec run_env(%{trigger: String.t(), job_id: pos_integer()} | map()) :: [{String.t(), String.t()}]
  def run_env(%{trigger: trigger} = job_or_cell) do
    id = Map.get(job_or_cell, :job_id) || Map.fetch!(job_or_cell, :id)
    [{"MOB_CI_TRIGGER", trigger}, {"MOB_CI_JOB_ID", to_string(id)}]
  end

  @doc """
  Run one cell as its own `mix ci.device`, output to `<log_dir>/cell-<id>.log`.
  `MOB_CI_CELL_ID` labels the farm instance it boots (`ci-farm.sh status`).
  """
  @spec run_cell(cell(), Path.t()) :: {integer(), Path.t()}
  def run_cell(cell, log_dir) do
    log = Path.join(log_dir, "cell-#{cell.id}.log")
    env = run_env(cell) ++ [{"MOB_CI_CELL_ID", to_string(cell.id)}]
    {mix_cmd(cell_argv(cell, log_dir), env, log, @cell_timeout_s), log}
  end

  defp reap_farm do
    for line <- Farm.reap(), do: say("[android] reap: #{line}")
  end

  @doc """
  The report a finished job runs: `ci.report --publish` when the task
  documents `--publish` (MOB-417), else plain `ci.report`.
  """
  @spec publish_argv(String.t() | nil) :: [String.t()]
  def publish_argv(report_doc) do
    if is_binary(report_doc) and String.contains?(report_doc, "--publish"),
      do: ["ci.report", "--publish"],
      else: ["ci.report"]
  end

  @doc """
  Run the report for a finished job; returns its exit code (logged, never
  retried). It runs with `MOB_CI_TRIGGER` / `MOB_CI_JOB_ID` unset: the report
  records no run of its own, and anything it starts (a git hook on the
  matrix push) must not be filed under this job.
  """
  @spec publish(map(), Path.t()) :: integer()
  def publish(job, log_dir) do
    log = Path.join(log_dir, "job-#{job.id}-report.log")
    mix_cmd(publish_argv(report_doc()), [{"MOB_CI_TRIGGER", nil}, {"MOB_CI_JOB_ID", nil}], log, @publish_timeout_s)
  end

  defp report_doc do
    case Mix.Task.get("ci.report") do
      nil -> nil
      mod -> Mix.Task.moduledoc(mod) || ""
    end
  end

  defp mix_cmd(argv, env, log, timeout_s) do
    File.mkdir_p!(Path.dirname(log))
    {cmd, args} = with_timeout(timeout_s, ["mix" | argv])
    File.write!(log, "$ #{Enum.join([cmd | args], " ")}\n")
    {_, code} = System.cmd(cmd, args, env: env, into: File.stream!(log, [:append]), stderr_to_stdout: true)
    code
  end

  # coreutils `timeout` (the NUC has it): a wedged cell can't hold the lane.
  defp with_timeout(seconds, [cmd | args]) do
    case System.find_executable("timeout") do
      nil -> {cmd, args}
      timeout -> {timeout, ["--kill-after=120", to_string(seconds), cmd | args]}
    end
  end

  @doc "`$MOB_CI_LOG_DIR`, else `~/mob_ci_logs/queue`."
  @spec log_dir() :: Path.t()
  def log_dir do
    case System.get_env("MOB_CI_LOG_DIR") do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> Path.expand("~/mob_ci_logs/queue")
    end
  end

  # ── reading ──────────────────────────────────────────────────────────────────

  @doc "One job with its decoded sets and platforms."
  @spec job(Store.t(), pos_integer()) :: map()
  def job(store, id) do
    [[id, trigger, row, sets, platforms, reason, priority, not_after, enqueued, finished, publish, status]] =
      Store.rows!(
        store,
        "SELECT id, trigger, versions_row, sets, platforms, reason, priority, not_after, enqueued_at, " <>
          "finished_at, publish_exit, status FROM jobs WHERE id = ?1",
        [id]
      )

    %{
      id: id,
      trigger: trigger,
      versions_row: row,
      sets: JSON.decode!(sets),
      platforms: JSON.decode!(platforms),
      reason: reason,
      priority: priority,
      not_after: not_after,
      enqueued_at: enqueued,
      finished_at: finished,
      publish_exit: publish,
      status: status
    }
  end

  @doc "A job's cells in id order."
  @spec cells(Store.t(), pos_integer()) :: [map()]
  def cells(store, job_id) do
    store
    |> Store.rows!(
      ~s{SELECT id, "set", platform, paths, status, duplicate_of, exit_code, started_at, finished_at, log_path, retry_of } <>
        "FROM job_cells WHERE job_id = ?1 ORDER BY id",
      [job_id]
    )
    |> Enum.map(fn [id, set, platform, paths, status, dup, code, started, finished, log, retry_of] ->
      %{
        id: id,
        set: set,
        platform: platform,
        paths: paths,
        status: status,
        duplicate_of: dup,
        exit_code: code,
        started_at: started,
        finished_at: finished,
        log_path: log,
        retry_of: retry_of
      }
    end)
  end

  @doc "Every unfinished job plus the `recent` newest finished ones, oldest first."
  @spec jobs(Store.t(), non_neg_integer()) :: [map()]
  def jobs(store, recent \\ 5) do
    ids =
      Store.rows!(
        store,
        "SELECT id FROM jobs WHERE status = 'queued' UNION " <>
          "SELECT id FROM (SELECT id FROM jobs WHERE status = 'done' ORDER BY id DESC LIMIT ?1) ORDER BY id",
        [recent]
      )

    Enum.map(ids, fn [id] -> job(store, id) end)
  end

  @doc "A console table of `jobs/2` with per-status cell counts."
  @spec format_status(Store.t(), [map()]) :: String.t()
  def format_status(_store, []), do: "queue empty"

  def format_status(store, jobs) do
    Enum.map_join(jobs, "\n", fn job ->
      counts =
        store
        |> cells(job.id)
        |> Enum.frequencies_by(& &1.status)
        |> Enum.sort()
        |> Enum.map_join(" ", fn {s, n} -> "#{s}=#{n}" end)

      "##{job.id} #{job.status} #{job.trigger} #{job.versions_row} " <>
        "#{Enum.join(job.platforms, "+")} #{length(job.sets)} set(s) [#{counts}] — #{job.reason}" <>
        if(job.publish_exit, do: " (report exit #{job.publish_exit})", else: "")
    end)
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp say(msg), do: Mix.shell().info(msg)
end
