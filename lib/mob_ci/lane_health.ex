defmodule MobCi.LaneHealth do
  @moduledoc """
  Is each device lane still running cells? A lane is the machine a cell runs
  on, the trigger queue's two lanes: `android` (the NUC's redroid farm:
  `deploy:android`, `release:android`) and `ios` (the Mac mini worker:
  `deploy:ios_sim`, `deploy:ios_device`, `release:ios`, and the Motos'
  `deploy:android_physical`).

  A lane has two kinds of problem:

    * **a dead path**: the path's last `window` summary cells (default 5;
      `$MOB_CI_LANE_WINDOW`, `mix ci.report --lane-window N`; any row, any
      trigger) all stopped at an infrastructure layer (`MobCi.Store.infra?/1`:
      `farm`, `toolchain`, `error:disk`, `error:ssh`, `error:worker`, …). The
      machine stopped them, not the code under test, so no regression check
      ever sees them; a plugin failure, a build error or a skip is the lane
      working.
    * **idle**: the newest nightly job of a row that is over (done, or past
      its `not_after`) scheduled cells on the lane (not counting duplicates
      of another job's cell) and none of them recorded a result.

  `notify/2` posts a change of a lane's problems to Muster once: a new
  problem (a path newly dead, a row's nightly newly idle) pushes to Kevin
  (`@kevin!`) with the layer, the cause line from the cell's error (or its
  log), since when, and a fix hint; fewer problems, or none (recovery), is a
  quiet post. A dead path whose layer changes is the same problem. What was
  last posted is kept in `lane_health.json` beside the store (next to the
  post marker) and written right after the post went out, so a state is
  posted once (a crash between the two would post it again); a held
  (`--no-post`) or failed post leaves it unchanged, so the next check posts
  again.
  """

  alias MobCi.{Build, Farm, Matrix, Report, Store}
  alias MobCi.Lane.Ios.Spec

  @lanes ["android", "ios"]
  @default_window 5
  @labels %{"android" => "Android lane (redroid farm, NUC)", "ios" => "iOS lane (Mac mini)"}

  @type dead :: %{
          lane: String.t(),
          path: String.t(),
          layer: String.t(),
          cause: String.t() | nil,
          since: String.t(),
          cells: pos_integer(),
          cell_id: pos_integer()
        }
  @type idle :: %{
          lane: String.t(),
          job_id: pos_integer(),
          versions_row: String.t(),
          enqueued_at: String.t(),
          scheduled: pos_integer()
        }
  @type t :: %{lane: String.t(), dead: [dead()], idle: [idle()], paused: boolean()}

  @doc "The lanes, in report order."
  @spec lanes() :: [String.t()]
  def lanes, do: @lanes

  @doc "A lane's human name."
  @spec label(String.t()) :: String.t()
  def label(lane), do: Map.get(@labels, lane, "#{lane} lane")

  @doc "The lane a summary row ran on (`nil` for the static gate)."
  @spec lane_of(map()) :: String.t() | nil
  def lane_of(%{path: "static"}), do: nil

  def lane_of(%{path: path, platform: platform}) do
    cond do
      path in Spec.paths() -> "ios"
      platform in @lanes -> platform
      true -> nil
    end
  end

  @doc "`opts[:window]`, else `$MOB_CI_LANE_WINDOW`, else #{@default_window}."
  @spec window(keyword()) :: pos_integer()
  def window(opts) do
    case Keyword.get(opts, :window) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case Integer.parse(System.get_env("MOB_CI_LANE_WINDOW") || "") do
          {n, ""} when n > 0 -> n
          _ -> @default_window
        end
    end
  end

  # ── the check ────────────────────────────────────────────────────────────────

  @doc """
  The health of every lane that has a summary row or an idle nightly, in
  `lanes/0` order. `summaries` are `Store.query(store, invariant: nil)`.
  Options: `:window`, `:now` (when a nightly is over), `:paused?`
  (`fn lane -> boolean end`, default: `locks/pause-<lane>` beside the store,
  what `priv/ci-run.sh pause` writes).
  """
  @spec check(Store.t(), [map()], keyword()) :: [t()]
  def check(store, summaries, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    paused? = Keyword.get(opts, :paused?, &paused?(store, &1))
    dead = dead_paths(summaries, window(opts))
    idle = idle_jobs(store, now)
    seen = summaries |> Enum.map(&lane_of/1) |> MapSet.new()

    for lane <- @lanes, MapSet.member?(seen, lane) or Map.has_key?(idle, lane) do
      %{lane: lane, dead: Map.get(dead, lane, []), idle: Map.get(idle, lane, []), paused: paused?.(lane)}
    end
  end

  @doc """
  The dead paths among `summaries`, by lane: those whose newest `window` (or
  more) summary rows are all `Store.infra?/1`. Each carries the newest row's
  layer and cause, the start of the streak (`since`), its length and the
  newest row's id. Pure.
  """
  @spec dead_paths([map()], pos_integer()) :: %{String.t() => [dead()]}
  def dead_paths(summaries, window) do
    summaries
    |> Enum.filter(&(&1.invariant == nil and lane_of(&1) != nil))
    |> Enum.group_by(&{lane_of(&1), &1.path})
    |> Enum.flat_map(fn {{lane, path}, cells} ->
      streak = cells |> Enum.sort_by(& &1.id, :desc) |> Enum.take_while(&Store.infra?/1)

      if length(streak) >= window do
        newest = hd(streak)

        [
          %{
            lane: lane,
            path: path,
            layer: newest.layer,
            cause: cause(newest),
            since: List.last(streak).started_at,
            cells: length(streak),
            cell_id: newest.id
          }
        ]
      else
        []
      end
    end)
    |> Enum.group_by(& &1.lane)
    |> Map.new(fn {lane, dead} -> {lane, Enum.sort_by(dead, &Report.path_rank(&1.path))} end)
  end

  @doc """
  The idle nightlies, by lane: per (lane, row), the newest nightly job that
  is over (`done`, or past its `not_after` at `now`) and scheduled cells on
  the lane, when none of them recorded a summary row.
  """
  @spec idle_jobs(Store.t(), DateTime.t()) :: %{String.t() => [idle()]}
  def idle_jobs(store, now) do
    ran =
      store
      |> Store.rows!(
        "SELECT r.job_id, c.platform, c.path, COUNT(*) FROM cells c JOIN runs r ON r.id = c.run_id " <>
          "WHERE c.invariant IS NULL AND r.job_id IS NOT NULL GROUP BY r.job_id, c.platform, c.path",
        []
      )
      |> Enum.reduce(%{}, fn [job, platform, path, n], acc ->
        case lane_of(%{platform: platform, path: path}) do
          nil -> acc
          lane -> Map.update(acc, {job, lane}, n, &(&1 + n))
        end
      end)

    store
    |> Store.rows!(
      "SELECT j.id, j.versions_row, j.enqueued_at, c.platform, COUNT(*) FROM jobs j JOIN job_cells c ON c.job_id = j.id " <>
        "WHERE j.trigger = 'nightly' AND c.status <> 'duplicate' " <>
        "AND (j.status = 'done' OR (j.not_after IS NOT NULL AND j.not_after <= ?1)) " <>
        "GROUP BY j.id, c.platform",
      [now |> DateTime.truncate(:second) |> DateTime.to_iso8601()]
    )
    |> Enum.map(fn [id, row, enqueued, lane, n] ->
      %{lane: lane, job_id: id, versions_row: row, enqueued_at: enqueued, scheduled: n}
    end)
    |> Enum.group_by(&{&1.lane, &1.versions_row})
    |> Enum.map(fn {_, jobs} -> Enum.max_by(jobs, & &1.job_id) end)
    |> Enum.filter(&(Map.get(ran, {&1.job_id, &1.lane}, 0) == 0))
    |> Enum.sort_by(& &1.job_id)
    |> Enum.group_by(& &1.lane)
  end

  defp paused?(%Store{path: path}, lane), do: File.exists?(Path.join([Path.dirname(path), "locks", "pause-#{lane}"]))

  # ── the cause line ───────────────────────────────────────────────────────────

  # The worker's own line for a step that errored (`step disk error (4 ms): …`).
  @step_error ~r/step \S+ error \(\d+ ms\): (.+)$/m
  @failure_word ~r/error|fail|refus|denied|timed? ?out|unreachable|not found|no space|exited/i

  @doc """
  The one line that says why a cell stopped: from the cell's stored error
  (`detail.error`, the inspected reason: every string in it, line by line),
  else from its log; a lost-device or JVM-crash line first, else the last line
  that names a failure, else the last line. `nil` when neither has text.
  """
  @spec cause(map()) :: String.t() | nil
  def cause(cell) do
    case error_text(Map.get(cell, :detail)) do
      nil -> cell |> Map.get(:log_path) |> log_cause()
      text -> pick_line(text)
    end
  end

  defp error_text(%{"error" => error}) when is_binary(error) and error != "" do
    encoder = fn name, _meta -> {:ok, %{atom: name}} end

    case Code.string_to_quoted(error, static_atoms_encoder: encoder) do
      {:ok, ast} ->
        {_, strings} = Macro.prewalk(ast, [], fn node, acc -> {node, if(is_binary(node), do: [node | acc], else: acc)} end)
        if strings == [], do: error, else: strings |> Enum.reverse() |> Enum.join("\n")

      _ ->
        error
    end
  end

  defp error_text(_), do: nil

  defp log_cause(path) when is_binary(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      tail =
        try do
          {:ok, _} = :file.position(io, max(size - 32_768, 0))
          IO.binread(io, :eof)
        after
          File.close(io)
        end

      case tail do
        text when is_binary(text) ->
          case Regex.scan(@step_error, text) do
            [] -> pick_line(text)
            matches -> matches |> List.last() |> List.last() |> clip()
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp log_cause(_), do: nil

  defp pick_line(text) do
    lines =
      text
      |> String.replace(~r/\e\[[0-9;]*m/, "")
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    line =
      Enum.find(lines, &(Farm.lost_device?(&1) or Build.toolchain_crash?(&1))) ||
        lines |> Enum.reverse() |> Enum.find(&(&1 =~ @failure_word)) ||
        List.last(lines)

    line && clip(line)
  end

  defp clip(line) do
    line = String.trim(line)
    if String.length(line) > 240, do: String.slice(line, 0, 239) <> "…", else: line
  end

  # ── problems, alerts and the state file ──────────────────────────────────────

  @doc """
  A lane's problems as comparable keys: `["dead", path]` per dead path,
  `["idle", row]` per row whose nightly ran none of the lane's cells.
  Sorted. The layer is not part of a key: a dead path flapping between
  `error:disk` and `error:ssh` is still the one problem, posted once.
  """
  @spec problems(t()) :: [[String.t()]]
  def problems(%{dead: dead, idle: idle}),
    do: Enum.sort(Enum.map(dead, &["dead", &1.path]) ++ Enum.map(idle, &["idle", &1.versions_row]))

  @doc """
  The post for the change from `previous` (the state file: lane →
  `%{"problems" => keys, "since" => iso, "was" => [description]}`) to
  `health`, or nil when no lane changed. A lane with a problem it didn't
  have is an alert, and any alert makes the post push to Kevin (`@kevin!`);
  a lane with fewer problems, or none, gets a quiet line. Pure.
  """
  @spec alert([t()], map(), String.t()) :: String.t() | nil
  def alert(health, previous, url) do
    changes = changes(health, previous)

    blocks =
      for {kind, lane} <- changes do
        case kind do
          :down -> down_block(lane)
          :better -> "mob_ci: the #{label(lane.lane)} partly recovered; still wrong:\n" <> problem_lines(lane)
          :recovered -> recovered_line(lane.lane, previous[lane.lane])
        end
      end

    cond do
      blocks == [] -> nil
      match?([{:down, _} | _], changes) -> Enum.join(["@kevin! " <> hd(blocks) | tl(blocks)] ++ ["matrix: #{url}"], "\n\n")
      true -> Enum.join(blocks ++ ["matrix: #{url}"], "\n\n")
    end
  end

  # Every lane whose problems differ from what was last posted, worst first.
  defp changes(health, previous) do
    current = Map.new(health, &{&1.lane, &1})
    lanes = Enum.filter(@lanes ++ (Map.keys(previous) -- @lanes), &(Map.has_key?(current, &1) or Map.has_key?(previous, &1)))

    for lane <- lanes,
        h = Map.get(current, lane, %{lane: lane, dead: [], idle: [], paused: false}),
        now = problems(h),
        before = get_in(previous, [lane, "problems"]) || [],
        now != before do
      kind =
        cond do
          now -- before != [] -> :down
          now == [] -> :recovered
          true -> :better
        end

      {kind, h}
    end
    |> Enum.sort_by(fn {kind, h} -> {Enum.find_index([:down, :better, :recovered], &(&1 == kind)), h.lane} end)
  end

  defp down_block(lane) do
    "mob_ci: the #{label(lane.lane)} is down since #{short_time(since(lane))}\n" <> problem_lines(lane)
  end

  defp problem_lines(lane) do
    dead =
      lane.dead
      |> Enum.group_by(&{&1.layer, &1.cause})
      |> Enum.sort_by(fn {_, ds} -> ds |> Enum.map(& &1.since) |> Enum.min() end)
      |> Enum.map(fn {{layer, cause}, ds} ->
        paths = Enum.map_join(ds, ", ", & &1.path)
        cells = ds |> Enum.map(& &1.cells) |> Enum.sum()
        first = ds |> Enum.map(& &1.since) |> Enum.min()
        newest = ds |> Enum.map(& &1.cell_id) |> Enum.max()

        Enum.join(
          [
            "- #{layer} on #{paths}: every cell since #{short_time(first)} stopped there (#{cells} cells, newest #{newest})",
            if(cause, do: "  cause: #{cause}"),
            "  fix: #{hint(layer, lane.lane)}"
          ]
          |> Enum.reject(&is_nil/1),
          "\n"
        )
      end)

    idle =
      for job <- lane.idle do
        "- ran none of its #{job.scheduled} cells in the #{job.versions_row} nightly (job #{job.job_id}, queued #{short_time(job.enqueued_at)})\n" <>
          "  fix: #{idle_hint(lane)}"
      end

    Enum.join(dead ++ idle, "\n")
  end

  defp recovered_line(lane, previous) do
    was =
      case previous do
        %{"was" => [_ | _] = was} -> Enum.filter(was, &is_binary/1)
        _ -> Enum.map(previous["problems"] || [], &Enum.join(&1, " "))
      end

    since = if is_binary(previous["since"]), do: " since #{short_time(previous["since"])}", else: ""
    "mob_ci: all clear, the #{label(lane)} is running cells again (it was down#{since}: #{Enum.join(was, ", ")})"
  end

  # What the state file keeps for the all-clear line: each dead path with its
  # layer, each idle row.
  defp descriptions(lane) do
    Enum.map(lane.dead, &"#{&1.path} @ #{&1.layer}") ++ Enum.map(lane.idle, &"an idle #{&1.versions_row} nightly")
  end

  @doc "When the lane's oldest current problem started (ISO 8601), or nil."
  @spec since(t()) :: String.t() | nil
  def since(lane) do
    (Enum.map(lane.dead, & &1.since) ++ Enum.map(lane.idle, & &1.enqueued_at)) |> Enum.min(fn -> nil end)
  end

  @doc "What to do about a lane stuck at `layer`."
  @spec hint(String.t(), String.t()) :: String.t()
  def hint("error:disk", _lane),
    do:
      "free space on the Mac mini's / (a cell refuses to start under 5 GB): `df -h /`, then " <>
        "~/Library/Developer/Xcode/DerivedData, `xcrun simctl delete unavailable`, leftovers under $TMPDIR/mob_ci_ios"

  def hint("error:ssh", _lane),
    do: "the NUC can't run the Mac worker over ssh: on the NUC `ssh kevin@10.0.0.71 true`; is the Mac awake and on the LAN?"

  def hint("error:worker", _lane),
    do: "the Mac worker fails before it builds: read the cell's log (`priv/ci-run.sh queue show <job>` on the NUC) and the Mac's ~/.cache/mob_ci/worker checkout"

  def hint("farm", _lane),
    do: "the redroid farm keeps losing its instances: on the NUC `priv/ci-farm.sh status`, `docker ps`, free memory"

  def hint("toolchain", _lane),
    do: "the build's JVM keeps crashing on the NUC: the hs_err_pid file named in the cell's log (FINDINGS F15)"

  def hint(_layer, _lane), do: "an orchestration step fails before the build: read the cell's log"

  defp idle_hint(%{paused: true, lane: lane}),
    do: "the lane is paused: `priv/ci-run.sh resume #{lane}` on the NUC"

  defp idle_hint(%{lane: lane}),
    do: "its worker never ran them: on the NUC `systemctl --user status mob-ci-drain@#{lane}`, `priv/ci-run.sh queue status`"

  @doc "`2026-10-10T06:20:48Z` → `2026-10-10 06:20Z`."
  @spec short_time(String.t() | nil) :: String.t()
  def short_time(nil), do: "?"

  def short_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt |> DateTime.to_iso8601() |> String.slice(0, 16) |> String.replace("T", " ") |> Kernel.<>("Z")
      _ -> iso
    end
  end

  @doc "One line per lane for the console: `ios down since … (error:disk on …)`."
  @spec summary([t()]) :: String.t()
  def summary([]), do: "no lane has run a cell yet"
  def summary(health), do: Enum.map_join(health, " · ", &"#{&1.lane} #{status_text(&1, &1.paused)}")

  @doc "The lane-health block at the top of `matrix.md` (public: layers cut by `Matrix.public_layer/1`)."
  @spec matrix_block([t()]) :: String.t()
  def matrix_block([]), do: ""

  def matrix_block(health) do
    lines = Enum.map_join(health, "\n", &"- **#{label(&1.lane)}**: #{status_text(&1, false)}")
    "## Lane health\n\n" <> lines <> "\n"
  end

  defp status_text(lane, paused) do
    suffix = if paused, do: " (paused)", else: ""

    case problems(lane) do
      [] ->
        "up" <> suffix

      _ ->
        dead =
          lane.dead
          |> Enum.group_by(&Matrix.public_layer(&1.layer))
          |> Enum.map(fn {layer, ds} -> "`#{layer}` on #{Enum.map_join(ds, ", ", & &1.path)}" end)

        idle = Enum.map(lane.idle, &"ran none of its #{&1.scheduled} cells in the #{&1.versions_row} nightly (job #{&1.job_id})")
        "down since #{short_time(since(lane))}, " <> Enum.join(dead ++ idle, "; ") <> suffix
    end
  end

  # ── notify ───────────────────────────────────────────────────────────────────

  @doc "The state file of `store`: `lane_health.json` beside it."
  @spec state_path(Store.t()) :: Path.t()
  def state_path(%Store{path: path}), do: Path.join(Path.dirname(path), "lane_health.json")

  @doc """
  Check the lanes and post a change since the last post. Options: those of
  `check/3`, `:state` (default `state_path/1`), `:post` (default true),
  `:poster` (`fn text -> :ok | {:error, reason} end`), `:url` (the matrix
  link). Returns `{result, health}` with result `:unchanged`, `{:held, text}`
  (`post: false`), `{:posted, text}` or `{:failed, text, reason}`; the state
  file is written only after a post went out. Call it under the publish lock.
  """
  @spec notify(Store.t(), keyword()) :: {term(), [t()]}
  def notify(store, opts) do
    state = Keyword.get_lazy(opts, :state, fn -> state_path(store) end)
    health = check(store, Store.query(store, invariant: nil), opts)
    previous = read_state(state)

    result =
      case alert(health, previous, Keyword.get(opts, :url, "")) do
        nil ->
          :unchanged

        text ->
          if Keyword.get(opts, :post, true) do
            case Keyword.fetch!(opts, :poster).(text) do
              :ok ->
                write_state(state, health)
                {:posted, text}

              {:error, reason} ->
                {:failed, text, reason}
            end
          else
            {:held, text}
          end
      end

    {result, health}
  end

  # Lanes whose entry isn't the current shape (a list of string-list keys)
  # are dropped: an old or hand-edited file must not wedge the check.
  defp read_state(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = state} <- JSON.decode(body) do
      for {lane, %{"problems" => keys} = entry} <- state,
          is_list(keys),
          Enum.all?(keys, &(is_list(&1) and &1 != [] and Enum.all?(&1, fn k -> is_binary(k) end))),
          into: %{},
          do: {lane, entry}
    else
      _ -> %{}
    end
  end

  defp write_state(path, health) do
    state =
      for lane <- health, (keys = problems(lane)) != [], into: %{} do
        {lane.lane, %{"problems" => keys, "since" => since(lane), "was" => descriptions(lane)}}
      end

    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(state))
    File.rename!(tmp, path)
  end
end
