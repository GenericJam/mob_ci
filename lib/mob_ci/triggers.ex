defmodule MobCi.Triggers do
  @moduledoc """
  What each trigger asks for (Layer 5, `decisions/2026-10-09-trigger-queue.md`):
  a trigger turns into one or more `t:job/0`s that `MobCi.Queue` stores and
  the lane workers drain.

      trigger    row                 sets                                     platforms     priority
      nightly    hex                 Sets.nightly/0 minus the pairwise rows   android, ios  0
      nightly    master              Sets.nightly/0 (pairwise: deploy path)   android, ios  0
      poll       master              per changed repo, see sets_for_repos/1   android, ios  10
      pre-push   master | rc:<r>@<s> as poll                                  android, ios  10
      rc         rc:<repo>@<sha>     as poll, for <repo>                       android, ios  10

  A changed core repo (mob, mob_dev, mob_new) asks for `blank` + `default` +
  `all`; a changed plugin for `default` + `singleton:<plugin>` + `all` (the
  singleton only when the plugin is in the set pool at all: an unbuildable
  plugin has no cell to run).

  Pure except `static_gate/3`, which runs `mix ci.device --static` per set.
  """

  alias MobCi.{Sets, Versions}

  @type job :: %{
          trigger: String.t(),
          versions_row: String.t(),
          sets: [String.t()],
          platforms: [String.t()],
          reason: String.t() | nil,
          priority: integer(),
          not_after: DateTime.t() | nil
        }

  @platforms ["android", "ios"]
  @urgent 10
  @nightly 0

  # Seconds per cell, from the first queued runs on the NUC (2026-10-09, job 1
  # and 2; docs/budgets.md "The nightly"): an Android master cell is cold (some
  # repo moves nearly every day, and a mob move recompiles every dep) — 480–510 s
  # with both paths for default and the singletons, 1000 s for `all`; a hex cell
  # reuses its host (Hex pins change only on a release) — 140–180 s. A
  # deploy-only pairwise row (10–19 plugins) costs about a cold singleton. The
  # Mac rebuilds every iOS host from nothing: ~185 s today with the device path
  # skipped and the release path failing at signing, budgeted at 360 s for all
  # three paths working; `deploy:ios_sim` alone ~150 s.
  @cell_seconds %{
    {"android", :warm, :all_paths} => 180,
    {"android", :warm, :deploy_only} => 120,
    {"android", :cold, :all_paths} => 510,
    {"android", :cold, :deploy_only} => 480,
    {"ios", :warm, :all_paths} => 360,
    {"ios", :warm, :deploy_only} => 150,
    {"ios", :cold, :all_paths} => 360,
    {"ios", :cold, :deploy_only} => 150
  }
  # `all` builds every plugin: twice a singleton's cost, warm or cold.
  @all_factor 2

  # The nightly starts at 22:00 local (priv/systemd/mob-ci-nightly.timer) and
  # must leave the farm to sloppy_joe staging by 07:00: 540 minutes.
  @nightly_start ~T[22:00:00]
  @nightly_end ~T[07:00:00]

  @doc "The lanes a job can name, in the order cells are expanded."
  @spec platforms() :: [String.t()]
  def platforms, do: @platforms

  @doc "The nightly's start and end, local time."
  @spec nightly_window() :: {Time.t(), Time.t()}
  def nightly_window, do: {@nightly_start, @nightly_end}

  @doc "Minutes between the nightly's start and end."
  @spec nightly_window_minutes() :: pos_integer()
  def nightly_window_minutes do
    minutes = div(Time.diff(@nightly_end, @nightly_start), 60)
    if minutes <= 0, do: minutes + 24 * 60, else: minutes
  end

  # ── nightly ──────────────────────────────────────────────────────────────────

  @doc """
  Tonight's jobs: every nightly set on `master`, the same minus the pairwise
  rows on `hex`, Android and iOS, `hex` first. Pruned to fit the window
  (`estimate_minutes/1`): the pairwise rows only run on `master`, where the
  interactions change, and only their deploy path (`cell_paths/2`); a cell
  that has not started by `not_after` expires instead of running into the
  morning, so whatever overruns is the master pairwise tail.
  """
  @spec nightly_jobs(DateTime.t() | nil) :: [job()]
  def nightly_jobs(not_after) do
    all = Sets.nightly()
    hex = Enum.reject(all, &String.starts_with?(&1, "pairwise:"))

    for {row, sets} <- [{"hex", hex}, {"master", all}] do
      %{
        trigger: "nightly",
        versions_row: row,
        sets: sets,
        platforms: @platforms,
        reason: "nightly #{row}",
        priority: @nightly,
        not_after: not_after
      }
    end
  end

  @doc """
  Expected minutes per lane to drain `jobs`: `hex` cells warm (hosts reused,
  Hex pins move only on a release), every other row cold, per
  `@cell_seconds`. The nightly must fit `nightly_window_minutes/0` on each
  lane; the test suite holds it to that. A night after a Hex release (every
  `hex` cell cold too) costs ~150 Android minutes more and loses the last
  `master` pairwise rows to the 07:00 expiry.
  """
  @spec estimate_minutes([job()]) :: %{String.t() => non_neg_integer()}
  def estimate_minutes(jobs) do
    seconds =
      for job <- jobs, set <- job.sets, platform <- job.platforms, reduce: Map.new(@platforms, &{&1, 0}) do
        acc ->
          temp = if job.versions_row == "hex", do: :warm, else: :cold
          kind = if cell_paths(set, platform), do: :deploy_only, else: :all_paths
          s = Map.fetch!(@cell_seconds, {platform, temp, kind}) * if(set == "all", do: @all_factor, else: 1)
          Map.update(acc, platform, s, &(&1 + s))
      end

    Map.new(seconds, fn {lane, s} -> {lane, div(s + 59, 60)} end)
  end

  @doc """
  The `--paths` a cell runs with, `nil` for the lane's default (every path).
  A pairwise row runs the deploy path only: the release build adds nothing
  to a pairwise interaction (`2026-10-08-p12-release-cell-results-store.md`).
  """
  @spec cell_paths(String.t(), String.t()) :: String.t() | nil
  def cell_paths("pairwise:" <> _, "android"), do: "deploy"
  def cell_paths("pairwise:" <> _, "ios"), do: "deploy:ios_sim"
  def cell_paths(_set, _platform), do: nil

  @doc """
  The first `at` (local time) strictly after `now` (a local `NaiveDateTime`).
  """
  @spec next_local(NaiveDateTime.t(), Time.t()) :: NaiveDateTime.t()
  def next_local(now, at) do
    today = NaiveDateTime.new!(NaiveDateTime.to_date(now), at)
    if NaiveDateTime.compare(today, now) == :gt, do: today, else: NaiveDateTime.add(today, 86_400)
  end

  @doc "A local `NaiveDateTime` as UTC, using this machine's zone rules."
  @spec local_to_utc(NaiveDateTime.t()) :: DateTime.t()
  def local_to_utc(naive) do
    erl = NaiveDateTime.to_erl(NaiveDateTime.truncate(naive, :second))

    case :calendar.local_time_to_universal_time_dst(erl) do
      [one] -> utc(one)
      [_dst, std] -> utc(std)
      # A local time skipped by a DST jump: take the same time an hour on.
      [] -> naive |> NaiveDateTime.add(3600) |> local_to_utc()
    end
  end

  defp utc(erl), do: erl |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")

  # ── poll / pre-push / rc ─────────────────────────────────────────────────────

  @doc """
  The sets a change to `repos` asks for, de-duplicated in run order: `blank`
  (a core repo changed), `default`, the changed plugins' singletons in
  committed order, `all`.
  """
  @spec sets_for_repos([atom()]) :: [String.t()]
  def sets_for_repos(repos) do
    core = Map.keys(Versions.core_repos())
    pool = Sets.pool(include_excluded: true)
    changed = MapSet.new(repos)

    blank = if Enum.any?(repos, &(&1 in core)), do: ["blank"], else: []
    singletons = for p <- pool, p in changed, do: "singleton:#{p}"
    blank ++ ["default"] ++ singletons ++ ["all"]
  end

  @doc """
  The poller's job for `changes` (`%{repo, old, new}`, default-branch moves
  seen by `MobCi.Poller`): the `master` row, `trigger` (`poll`, or `pre-push`
  when a push notice from the Mac got there first).
  """
  @spec poll_job([%{repo: atom(), old: String.t(), new: String.t()}], String.t()) :: job()
  def poll_job(changes, trigger \\ "poll") when changes != [] do
    %{
      trigger: trigger,
      versions_row: "master",
      sets: changes |> Enum.map(& &1.repo) |> sets_for_repos(),
      platforms: @platforms,
      reason: Enum.map_join(changes, ", ", &"#{&1.repo} #{short(&1.old)}→#{short(&1.new)}"),
      priority: @urgent,
      not_after: nil
    }
  end

  @doc """
  An `rc:<repo>@<sha>` job from `"<repo>@<sha>"` (what `priv/ci-run.sh rc`
  takes) or a full `rc:` row; `trigger` is `rc`, or `pre-push` for a pushed
  branch sha. Errors are `MobCi.Versions.parse/1`'s.
  """
  @spec rc_job(String.t(), String.t()) :: {:ok, job()} | {:error, String.t()}
  def rc_job(arg, trigger \\ "rc") do
    value = if String.starts_with?(arg, "rc:"), do: arg, else: "rc:" <> arg

    with {:ok, {:rc, repo, _sha} = row} <- Versions.parse(value) do
      row_s = Versions.row_to_string(row)

      {:ok,
       %{
         trigger: trigger,
         versions_row: row_s,
         sets: sets_for_repos([repo]),
         platforms: @platforms,
         reason: row_s,
         priority: @urgent,
         not_after: nil
       }}
    else
      {:ok, _other} -> {:error, "rc needs <repo>@<sha>, got #{inspect(arg)}"}
      {:error, _} = err -> err
    end
  end

  @doc "A hand-made job (`mix ci.queue enqueue`); every set and row must parse."
  @spec manual_job(String.t(), [String.t()], [String.t()], String.t() | nil) :: {:ok, job()} | {:error, String.t()}
  def manual_job(row, sets, platforms, reason \\ nil) do
    with {:ok, parsed} <- Versions.parse(row),
         :ok <- all_ok(sets, &Sets.parse/1),
         :ok <- all_ok(platforms, &platform/1) do
      {:ok,
       %{
         trigger: "manual",
         versions_row: Versions.row_to_string(parsed),
         sets: sets,
         platforms: platforms,
         reason: reason,
         priority: @urgent,
         not_after: nil
       }}
    end
  end

  defp platform(p) when p in @platforms, do: {:ok, p}
  defp platform(p), do: {:error, "unknown platform #{inspect(p)} (expected: #{Enum.join(@platforms, ", ")})"}

  defp all_ok(values, parse) do
    Enum.find_value(values, :ok, fn v ->
      case parse.(v) do
        {:ok, _} -> nil
        {:error, _} = err -> err
      end
    end)
  end

  defp short(nil), do: "∅"
  defp short(sha), do: String.slice(sha, 0, 7)

  # ── the static gate ──────────────────────────────────────────────────────────

  @doc """
  The argv of the static gate for one set on one row (no device, no build;
  recorded in the store as path `static`).
  """
  @spec static_argv(String.t(), String.t()) :: [String.t()]
  def static_argv(row, set), do: ["ci.device", "--static", "--set", set, "--versions", row]

  @doc """
  Run the static gate for `job`'s sets now, one `mix ci.device --static` each
  (a static failure is recorded and printed; the device cells still queue —
  they say which layer breaks). Returns `[{set, exit_code}]`. Options:
  `:runner` (`fn argv, env -> exit_code end`), `:trigger`.
  """
  @spec static_gate(job(), keyword()) :: [{String.t(), integer()}]
  def static_gate(job, opts \\ []) do
    runner = Keyword.get(opts, :runner, &run_mix/2)
    env = [{"MOB_CI_TRIGGER", job.trigger}]

    for set <- job.sets do
      code = runner.(static_argv(job.versions_row, set), env)
      Mix.shell().info("[static] #{job.versions_row} #{set}: exit #{code}")
      {set, code}
    end
  end

  defp run_mix(argv, env) do
    {_, code} =
      System.cmd("mix", argv, env: env, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

    code
  end
end
