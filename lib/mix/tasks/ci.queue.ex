defmodule Mix.Tasks.Ci.Queue do
  @shortdoc "The mob_ci trigger queue: enqueue nightly / rc / manual jobs, record pushes, drain a lane"
  @moduledoc """
  The durable job queue triggers write and the lane workers drain
  (`MobCi.Queue`; tables in the results store). Every trigger reaches it
  through `priv/ci-run.sh`, which also starts the lane workers afterwards.

      mix ci.queue                                   # status: unfinished + recent jobs
      mix ci.queue nightly                           # tonight's hex + master jobs (until 07:00 local)
      mix ci.queue rc mob_camera@1a2b3c4             # rc:<repo>@<sha>: static gate now, then queue
      mix ci.queue enqueue --versions master --sets default,all [--platforms android] [--reason TEXT]
      mix ci.queue push mob 1a2b3c4… refs/heads/master   # a pre-push notice (from the Mac, over ssh)
      mix ci.queue drain --lane android              # run android cells until the lane is empty
      mix ci.queue show 42                           # one job and its cells

  Every subcommand takes `--store PATH` (default `$MOB_CI_STORE` or
  `~/.local/share/mob_ci/results.sqlite`). `drain` must run under the lane's
  lock (`priv/ci-run.sh drain <lane>` takes it with `flock`). Cell logs go to
  `$MOB_CI_LOG_DIR` (default `~/mob_ci_logs/queue`).
  """
  use Mix.Task

  alias MobCi.{Poller, Queue, Store, Triggers}

  @switches [store: :string, lane: :string, versions: :string, sets: :string, platforms: :string, reason: :string, until: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unknown option(s): #{Enum.map_join(invalid, " ", &elem(&1, 0))}")

    store = Store.open!(opts[:store] || Store.default_path())

    try do
      command(args, opts, store)
    after
      Store.close(store)
    end
  end

  defp command([], _opts, store), do: Mix.shell().info(Queue.format_status(store, Queue.jobs(store)))
  defp command(["status"], opts, store), do: command([], opts, store)

  defp command(["show", id], _opts, store) do
    job = Queue.job(store, String.to_integer(id))
    Mix.shell().info(Queue.format_status(store, [job]))

    for c <- Queue.cells(store, job.id) do
      Mix.shell().info(
        "  cell #{c.id} #{c.platform} #{c.set}#{if c.paths, do: " (#{c.paths})", else: ""}: #{c.status}" <>
          if(c.duplicate_of, do: " of #{c.duplicate_of}", else: "") <>
          if(c.exit_code, do: " exit #{c.exit_code}", else: "") <> if(c.log_path, do: " #{c.log_path}", else: "")
      )
    end
  end

  defp command(["nightly"], opts, store) do
    until = parse_time!(opts[:until] || "07:00")
    not_after = NaiveDateTime.local_now() |> Triggers.next_local(until) |> Triggers.local_to_utc()
    jobs = Triggers.nightly_jobs(not_after)
    est = Triggers.estimate_minutes(jobs)

    Mix.shell().info(
      "nightly: cells not started by #{DateTime.to_iso8601(not_after)} expire; expected lane minutes #{inspect(est)} " <>
        "(window #{Triggers.nightly_window_minutes()})"
    )

    Enum.each(jobs, &enqueue(store, &1))
  end

  defp command(["rc", arg], _opts, store) do
    case Triggers.rc_job(arg) do
      {:ok, job} ->
        Triggers.static_gate(job)
        enqueue(store, job)

      {:error, msg} ->
        Mix.raise(msg)
    end
  end

  defp command(["enqueue"], opts, store) do
    sets = csv(opts[:sets]) || Mix.raise("enqueue needs --sets a,b,…")
    platforms = csv(opts[:platforms]) || Triggers.platforms()

    case Triggers.manual_job(opts[:versions] || "master", sets, platforms, opts[:reason]) do
      {:ok, job} -> enqueue(store, job)
      {:error, msg} -> Mix.raise(msg)
    end
  end

  defp command(["push", repo, sha | ref], _opts, store) do
    case Poller.record_push(store, repo, sha, List.first(ref), DateTime.utc_now()) do
      {:ok, id} -> Mix.shell().info("push #{id}: #{repo}@#{sha} pending until it is on the remote")
      {:error, msg} -> Mix.raise(msg)
    end
  end

  defp command(["drain"], opts, store) do
    lane = opts[:lane] || Mix.raise("drain needs --lane android|ios")
    if lane not in Triggers.platforms(), do: Mix.raise("unknown lane #{inspect(lane)} (expected: android | ios)")
    result = Queue.drain(store, lane)

    Mix.shell().info(
      "[#{lane}] drained: #{length(result.ran)} cell(s), #{length(result.published)} job(s) published, " <>
        "#{result.recovered} requeued"
    )
  end

  defp command(other, _opts, _store),
    do: Mix.raise("unknown ci.queue command #{inspect(Enum.join(other, " "))} (see mix help ci.queue)")

  defp enqueue(store, job) do
    {:ok, id, cells} = Queue.enqueue(store, job)
    dups = Enum.count(cells, &(&1.status == "duplicate"))

    Mix.shell().info(
      "job #{id}: #{job.trigger} #{job.versions_row} #{Enum.join(job.platforms, "+")} — " <>
        "#{length(cells) - dups} cell(s) queued, #{dups} already queued elsewhere — #{job.reason}"
    )
  end

  defp csv(nil), do: nil
  defp csv(s), do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp parse_time!(s) do
    case Time.from_iso8601(if String.length(s) == 5, do: s <> ":00", else: s) do
      {:ok, t} -> t
      _ -> Mix.raise("--until takes HH:MM, got #{inspect(s)}")
    end
  end
end
