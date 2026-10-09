defmodule MobCi.Lane.Ios.Reaper do
  @moduledoc """
  Teardown of a Mac-lane run whose worker did not finish, and the reaper the
  next cell runs first (MOB-466).

  A **run** is one `mob_ci_ios_cell.sh` session on the Mac: a dir
  `runs_root()/<run_id>` holding `guard.pid` (the process that answers for
  the run), `alive` (stamped every 2 s while it does) and `cells/` (the
  teardown manifest of each cell still running, `Worker.manifest_path/2`).
  `worker/mac/guard.sh` creates it and runs the worker with
  `MOB_CI_RUN=<run_id>` in its environment; a hand run of `mix
  ci.ios_cell` registers itself (`register/1`). A run's processes are those
  carrying that variable (every child inherits it) and all their
  descendants: the BEAM puts each port program (mix, zig, gradle,
  xcodebuild) in a session of its own, so neither a process group nor a
  session holds a cell's processes, and macOS shows `ps -E` no environment
  for Apple's own binaries (`/bin/sh`, xcodebuild, clang), which are found
  through their parents instead (`run_processes/3`).

  `teardown_run/2` (what the guard runs when its worker ends, however it
  ends) stops the run's processes, undoes every cell whose manifest is left
  (`Worker.teardown_manifest/2`: uninstall, lease release, app state,
  scratch), then stops what is left of the run: the lease's agent-device
  daemon goes last, so the release can still talk to it.

  `reap/2` finds what dead runs left (a guard that was SIGKILLed, a Mac that
  rebooted) and removes only mob_ci's own leftovers:

    * runs whose guard is gone or silent: `teardown_run/2`, then the run dir;
    * processes tagged with a run that is not live;
    * `mob_ci_ios_*` agent-lease sessions (their state dirs, and claims
      `agent-device device status` lists) that no live cell owns, idle for
      `reap_after_s()`: released, and their state dirs pruned;
    * cell scratch dirs, the `ci_*` apps' staged BEAMs in `~/.mob` and
      mob_dev's leaked `tmp.*` release dirs holding a `Ci*.app`, untouched for
      `reap_after_s()` and not a live cell's.

  Shared daemons a cell may happen to start never count as the cell's: the
  adb server and epmd serve every agent on the Mac.

  All I/O goes through `deps` (`default_deps/0`), so this is tested with a
  stub `ps`, `kill` and agent-lease.
  """

  alias MobCi.Host
  alias MobCi.Lane.Ios.{Spec, Worker}

  @tag "MOB_CI_RUN"
  # The guard stamps `alive` every 2 s; a run silent this long is dead.
  @alive_stale_s 120
  @reap_after_s 30 * 60
  @grace_ms 10_000
  @run_id ~r/^[A-Za-z0-9._-]+$/
  @cell_id ~r/^[a-z0-9][a-z0-9_-]*$/

  @doc "The environment variable that tags a run's processes."
  def tag, do: @tag

  @doc "Where run dirs live (`MOB_CI_RUNS_ROOT` overrides)."
  def runs_root, do: System.get_env("MOB_CI_RUNS_ROOT") || Path.expand("~/.cache/mob_ci/runs")

  @doc "How long an unowned leftover must be idle before `reap/2` removes it (`MOB_CI_REAP_AFTER_S` overrides)."
  def reap_after_s do
    case Integer.parse(System.get_env("MOB_CI_REAP_AFTER_S", "")) do
      {s, ""} when s >= 0 -> s
      _ -> @reap_after_s
    end
  end

  # ── the current run ──────────────────────────────────────────────────────────

  @doc """
  The run this worker belongs to: `{run_id, run_dir}` from `MOB_CI_RUN` /
  `MOB_CI_RUN_DIR` (set by `worker/mac/guard.sh`), or, for a hand run, a run
  registered here: a fresh dir whose `guard.pid` is this BEAM, stamped
  `alive` by a linked process, with `MOB_CI_RUN` put in the environment so
  every child carries it. Such a run is undone by the next `reap/2` if this
  BEAM dies before its cells' teardown.
  """
  @spec register(Path.t()) :: {String.t(), Path.t()}
  def register(root \\ runs_root()) do
    case {System.get_env(@tag), System.get_env("MOB_CI_RUN_DIR")} do
      {id, dir} when is_binary(id) and is_binary(dir) and id != "" ->
        {id, dir}

      _ ->
        id = "hand-" <> Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ") <> "-#{System.pid()}"
        dir = Path.join(root, id)
        File.mkdir_p!(Path.join(dir, "cells"))
        File.write!(Path.join(dir, "guard.pid"), System.pid())
        stamp = Path.join(dir, "alive")
        File.touch!(stamp)

        spawn_link(fn -> stamp_loop(stamp) end)
        System.put_env(@tag, id)
        System.put_env("MOB_CI_RUN_DIR", dir)
        {id, dir}
    end
  end

  defp stamp_loop(stamp) do
    Process.sleep(2_000)
    File.touch(stamp)
    stamp_loop(stamp)
  end

  # ── processes (pure) ─────────────────────────────────────────────────────────

  @doc """
  The processes in `ps -axww -E -o pid=,ppid=,command=` output (macOS: the
  command line followed by the environment the process started with), as
  `%{pid, ppid, run, command}`, `run` the value of its `MOB_CI_RUN` or nil.
  macOS shows no environment for platform binaries (`/bin/sh`, xcodebuild,
  clang): those have `run: nil` and are found as descendants
  (`run_processes/3`).
  """
  @spec parse_ps(String.t()) :: [map()]
  def parse_ps(out) do
    for line <- String.split(out, "\n"),
        [_, pid, ppid, command] <- [Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(.*)$/, line)] do
      run =
        case Regex.run(~r/(?:^|\s)#{@tag}=(\S+)(?=\s|$)/, command) do
          [_, id] -> id
          nil -> nil
        end

      %{pid: String.to_integer(pid), ppid: String.to_integer(ppid), run: run, command: command}
    end
  end

  @doc """
  A daemon every agent on the Mac shares, which a cell may have started but
  never owns: the adb server, epmd.
  """
  @spec shared?(String.t()) :: boolean()
  def shared?(command) do
    exe = command |> String.split(" ", parts: 2) |> hd() |> Path.basename()
    exe == "epmd" or (exe == "adb" and command =~ ~r/\sfork-server(\s|$)/)
  end

  @doc "An agent-device daemon (agent-lease starts one per lease session)."
  @spec lease_daemon?(String.t()) :: boolean()
  def lease_daemon?(command), do: command =~ ~r{agent-device/\S*daemon\.js}

  @doc """
  The processes to stop among `procs` (`parse_ps/1`): those tagged with a
  run `select` accepts, and every descendant of one, except shared daemons,
  and lease daemons (with what they started) unless `daemons?`.
  """
  @spec run_processes([map()], (map() -> boolean()), boolean()) :: [map()]
  def run_processes(procs, select, daemons?) do
    keep? = &(not shared?(&1.command) and (daemons? or not lease_daemon?(&1.command)))
    children = Enum.group_by(procs, & &1.ppid)
    roots = for p <- procs, p.run != nil, select.(p), keep?.(p), do: p
    descend(roots, children, keep?, %{}) |> Map.values() |> Enum.sort_by(& &1.pid)
  end

  defp descend([], _children, _keep?, acc), do: acc

  defp descend([p | rest], children, keep?, acc) do
    if Map.has_key?(acc, p.pid) do
      descend(rest, children, keep?, acc)
    else
      kids = for c <- Map.get(children, p.pid, []), keep?.(c), do: c
      descend(kids ++ rest, children, keep?, Map.put(acc, p.pid, p))
    end
  end

  # ── teardown of one run ──────────────────────────────────────────────────────

  @doc """
  Stop the processes of run `run_id` (`run_processes/3`; never this BEAM):
  SIGTERM to all of them at once, from one snapshot of the process table
  (a child whose parent dies first leaves the tree), then SIGKILL whatever
  is still there after the grace period. Lease daemons only with
  `daemons: true`. Returns the pids signalled.
  """
  @spec stop_run(String.t(), map(), keyword()) :: [pos_integer()]
  def stop_run(run_id, deps, opts \\ []) do
    stop(deps, &(&1.run == run_id), opts)
  end

  defp stop(deps, select, opts) do
    me = String.to_integer(System.pid())

    procs =
      deps.ps.()
      |> parse_ps()
      |> run_processes(select, Keyword.get(opts, :daemons, false))
      |> Enum.reject(&(&1.pid == me))

    if procs != [] do
      Enum.each(procs, &deps.log.("stopping #{&1.pid}#{if &1.run, do: " (run #{&1.run})"}: #{String.slice(&1.command, 0, 160)}"))
      Enum.each(procs, &deps.kill.(&1.pid, "TERM"))
      left = await_gone(procs, deps, deps.grace_ms)

      if left != [] do
        deps.log.("still running after #{deps.grace_ms} ms, SIGKILL: #{Enum.join(left, " ")}")
        Enum.each(left, &deps.kill.(&1, "KILL"))
      end
    end

    Enum.map(procs, & &1.pid)
  end

  # The pids still running the same command (a reused pid is not ours).
  defp await_gone(procs, deps, budget) do
    now = Map.new(parse_ps(deps.ps.()), &{&1.pid, &1.command})
    left = for p <- procs, now[p.pid] == p.command, do: p.pid

    if left == [] or budget <= 0 do
      left
    else
      deps.sleep.(250)
      await_gone(procs, deps, budget - 250)
    end
  end

  @doc """
  Undo run `run_dir`: stop its processes, tear down every cell whose manifest
  is left, then stop what is still tagged, lease daemons included. What
  `worker/mac/guard.sh` runs when its worker ends (`mix ci.ios_cell
  --teardown <run_dir>`). Returns the teardown entries per cell.
  """
  @spec teardown_run(Path.t(), map()) :: %{String.t() => term()}
  def teardown_run(run_dir, deps \\ default_deps()) do
    run_id = Path.basename(run_dir)
    unless run_id =~ @run_id, do: raise(ArgumentError, "not a run dir: #{inspect(run_dir)}")
    deps.log.("run #{run_id}: teardown")

    stop_run(run_id, deps)

    cells =
      for manifest <- Path.wildcard(Path.join([run_dir, "cells", "*.json"])), into: %{} do
        {Path.basename(manifest, ".json"), Worker.teardown_manifest(manifest, deps.worker)}
      end

    stop_run(run_id, deps, daemons: true)
    deps.log.("run #{run_id}: torn down (#{map_size(cells)} cell(s) left by the worker)")
    cells
  end

  # ── the reaper ───────────────────────────────────────────────────────────────

  @doc """
  Whether run dir `dir` still answers for its cells: its `guard.pid` is alive
  and it stamped `alive` (or wrote `guard.pid`) within the last 2 minutes. A
  dir that has no `guard.pid` yet counts as live for its first 2 minutes.
  """
  @spec live?(Path.t(), map(), integer()) :: boolean()
  def live?(dir, deps, now) do
    case File.read(Path.join(dir, "guard.pid")) do
      {:ok, pid} ->
        stamp = Enum.max([mtime(Path.join(dir, "alive")), mtime(Path.join(dir, "guard.pid"))])

        case Integer.parse(String.trim(pid)) do
          {pid, ""} -> now - stamp <= @alive_stale_s and deps.alive?.(pid)
          _ -> false
        end

      {:error, _} ->
        now - mtime(dir) <= @alive_stale_s
    end
  end

  @doc """
  Clean up after dead runs and remove mob_ci's unowned leftovers (see the
  moduledoc). `own` is the reaping run's id, never touched. Returns what was
  done, as `%{runs, processes, leases, dirs}`.
  """
  @spec reap(String.t() | nil, map()) :: map()
  def reap(own, deps \\ default_deps()) do
    now = deps.now.()
    after_s = deps.reap_after_s

    # Everything that might be a leftover is listed before the live runs are
    # read: a cell records its lease and scratch in its manifest before it
    # creates them, so a leftover listed here and owned by a cell that
    # started since is seen as owned below.
    ps = parse_ps(deps.ps.())
    claims = deps.claims.()
    lease_dirs = Path.wildcard(Path.join(deps.lease_root, "mob_ci_ios_*"))
    scratch = for d <- Path.wildcard(Path.join(deps.scratch_root, "*")), Path.basename(d) =~ @cell_id, do: d
    app_dirs = app_state_dirs(deps)

    {live, dead} =
      deps.runs_root
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.filter(&(File.dir?(&1) and Path.basename(&1) =~ @run_id))
      |> Enum.split_with(&(Path.basename(&1) == own or live?(&1, deps, now)))

    live_ids = MapSet.new(live, &Path.basename/1)
    live_specs = Enum.flat_map(live, &specs/1)
    live_cells = MapSet.new(live_specs, & &1.cell_id)
    live_apps = MapSet.new(live_specs, &app_name/1)

    runs =
      for dir <- dead do
        deps.log.("reaper: run #{Path.basename(dir)} is dead")
        teardown_run(dir, deps)
        deps.rm_rf.(dir)
        Path.basename(dir)
      end

    # Only processes listed before the live runs were read: one that started
    # since may belong to a run that started since.
    seen = MapSet.new(ps, & &1.pid)
    orphan? = &(&1.pid in seen and &1.run not in live_ids and &1.run != own)
    stopped = stop(deps, orphan?, [])

    old? = fn path -> now - mtime(path) >= after_s end
    session_cell = fn "mob_ci_ios_" <> cell -> cell end

    stale_dirs = for d <- lease_dirs, session_cell.(Path.basename(d)) not in live_cells, old?.(d), do: d
    claimed = for s <- claims, String.starts_with?(s, "mob_ci_ios_"), session_cell.(s) not in live_cells, do: s
    held = for d <- stale_dirs, File.exists?(Path.join(d, "lease")), do: Path.basename(d)

    leases =
      for session <- Enum.uniq(claimed ++ held) do
        deps.log.("reaper: releasing orphaned lease #{session}")
        {session, deps.release.(session)}
      end

    # Dead runs' teardown already removed their cells' scratch.
    dirs =
      (stale_dirs ++
         for(d <- scratch, Path.basename(d) not in live_cells, old?.(d), do: d) ++
         for({app, d} <- app_dirs, app not in live_apps, old?.(d), do: d))
      |> Enum.uniq()
      |> Enum.filter(&File.exists?/1)

    Enum.each(dirs, fn d ->
      deps.log.("reaper: removing #{d}")
      deps.rm_rf.(d)
    end)

    stopped = stopped ++ stop(deps, orphan?, daemons: true)

    %{runs: runs, processes: stopped, leases: leases, dirs: dirs}
  end

  defp specs(run_dir) do
    for manifest <- Path.wildcard(Path.join([run_dir, "cells", "*.json"])),
        {:ok, body} <- [File.read(manifest)],
        {:ok, %{"spec" => spec}} <- [JSON.decode(body)],
        {:ok, spec} <- [Spec.from_json(JSON.encode!(spec))],
        do: spec
  end

  defp app_name(%Spec{set: set, versions: %{row: row}}),
    do: Host.app_name(set, MobCi.Versions.parse!(row)) |> to_string()

  # `{app, dir}` for the `ci_*` apps' staged BEAMs and mob_dev's leaked
  # release dirs (`Worker.app_state_dirs/3`), whichever cell they came from.
  defp app_state_dirs(deps) do
    staged =
      for pattern <- [["cache", "otp-*", "ci_*"], ["runtime", "*", "ci_*"]],
          d <- Path.wildcard(Path.join([deps.mob_home | pattern])),
          File.dir?(d),
          do: {Path.basename(d), d}

    leaked =
      if deps.darwin_tmp do
        for d <- Path.wildcard(Path.join(deps.darwin_tmp, "tmp.*")),
            app <- Path.wildcard(Path.join(d, "Ci*.app")),
            do: {Macro.underscore(Path.basename(app, ".app")), d}
      else
        []
      end

    staged ++ leaked
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: t}} -> t
      _ -> 0
    end
  end

  # ── the real I/O ─────────────────────────────────────────────────────────────

  @doc """
  The I/O teardown and the reaper use; tests replace any of it. `claims` is
  the sessions holding a device claim (`agent-device device status`).
  """
  def default_deps do
    worker = Worker.default_deps()

    %{
      log: worker.log,
      ps: fn ->
        {out, 0} = System.cmd("/bin/ps", ["-axww", "-E", "-o", "pid=,ppid=,command="])
        out
      end,
      kill: fn pid, signal -> System.cmd("kill", ["-#{signal}", "#{pid}"], stderr_to_stdout: true) end,
      alive?: fn pid -> match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true)) end,
      sleep: &Process.sleep/1,
      now: fn -> System.os_time(:second) end,
      grace_ms: @grace_ms,
      reap_after_s: reap_after_s(),
      claims: fn ->
        case System.cmd("agent-device", ["device", "status"], stderr_to_stdout: true) do
          {out, 0} -> for [_, s] <- Regex.scan(~r/live session=(\S+)/, out), do: s
          _ -> []
        end
      end,
      release: worker.release,
      rm_rf: worker.rm_rf,
      runs_root: runs_root(),
      scratch_root: Worker.default_root(),
      lease_root: System.get_env("AGENT_LEASE_ROOT") || Path.expand("~/.agent-device/agents"),
      mob_home: worker.mob_home,
      darwin_tmp: worker.darwin_tmp,
      worker: worker
    }
  end
end
