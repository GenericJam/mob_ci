defmodule MobCi.Lane.Ios.Worker do
  @moduledoc """
  Runs one iOS cell on the Mac mini (`mix ci.ios_cell`, which the NUC starts
  over ssh through `worker/mac/mob_ci_ios_cell.sh`) and returns its result as
  a JSON-able map.

      step       what                                           layer on failure
      disk       df -k / has >= 5 GB free, or refuse            error:disk
      resolve    the spec's pins materialised on this Mac        error:worker
      generate   MobCi.Host.generate(platform: :ios)             mob_new | elixir
      doctor     mix mob.doctor in the host                      doctor
      device     simulators: booted, iOS >= the spec's min_runtime,  boot (sim) | skip: device_absent
                 newest runtime first; the iPhone: attached
      lease      agent-lease acquire, first free candidate wins  boot (sim) | skip: device_absent
      build      mix mob.deploy --native --ios --device <udid>   build:<path>
                 (release:ios: mix mob.regen_driver_tab --format c,
                  mix mob.release --ios)
      artifact   the .ipa is a signed Payload/*.app zip          build:release:ios
      probe      worker/mac/probe.exs in the host: grant, relaunch,
                 attach, health, self-tests, health              error:worker

  A step that fails stops the cell (`fail` for a finding, `error` when the
  worker itself could not run it, `skip` for an absent iPhone); a step that
  raises is an `error` at the layer its own failure would have had.

  The probe's facts become invariants (`invariants/2`): `p2` (the node came
  up, layer `boot`), one `p12:<plugin>` per activated plugin (layer
  `plugin:<p>` for a singleton set, `plugin:<p>?` otherwise, until the NUC
  compares it with the plugin's singleton cell) and `health` (a
  `Mob.Diag.health/0` counter that rose across the self-tests, layer
  `health`).

  Almost everything a cell writes lives under one scratch dir,
  `<root>/<cell_id>`: the generated host (with its `deps` and `_build`) and
  `tmp/`, which is the cell's `TMPDIR` for every child (so mob_dev's
  `mob_ios_*` build dirs land there too); the
  rest is the app's staged BEAMs under `~/.mob` and mob_dev's leaked release
  build dir (`app_state_dirs/3`).
  Teardown runs whatever happened, including a step that raised: it
  uninstalls the app from a device it leased, releases the lease and deletes
  the app state and the scratch dir. The result records free disk before and
  after.

  All I/O goes through `deps` (see `default_deps/0`), so the step logic is
  tested without a Mac, a device or Xcode.
  """

  alias MobCi.{Host, Sets}
  alias MobCi.Lane.Ios.{Spec, Tee}

  @min_free_kb 5 * 1024 * 1024
  @team_id "Q89CW299G8"
  # Development builds (simulator, iPhone): any id under the team's wildcard
  # development profile, and none an installed app uses, so teardown's
  # uninstall can only remove what the cell installed.
  @deploy_bundle_id "com.genericjam.mobci"
  # The release path needs an App Store profile for the exact id: the test
  # app's ("Io App Store"). Nothing is installed or uploaded.
  @release_bundle_id "com.genericjam.io"
  @probe_script Path.expand("../../../../worker/mac/probe.exs", __DIR__)
  @selftest_timeout_ms 30_000

  @doc "Free space (KB on `/`) below which a cell refuses to start."
  def min_free_kb, do: @min_free_kb

  @doc "The bundle id a path builds with."
  @spec bundle_id(Spec.path()) :: String.t()
  def bundle_id("release:ios"), do: @release_bundle_id
  def bundle_id(_deploy), do: @deploy_bundle_id

  @doc "Extra `config :mob_dev` entries for the host's mob.exs on `path`."
  @spec mob_exs(Spec.path()) :: keyword()
  def mob_exs(path), do: [ios_bundle_id: bundle_id(path), ios_team_id: @team_id]

  @doc "Where cells' scratch dirs live by default: `$TMPDIR/mob_ci_ios`."
  def default_root, do: Path.join(System.tmp_dir!(), "mob_ci_ios")

  @doc "The agent-lease session name of a cell."
  def session(%Spec{cell_id: id}), do: "mob_ci_ios_#{id}"

  # ── device selection (pure) ──────────────────────────────────────────────────

  @doc """
  The booted, available iOS simulators in `xcrun simctl list devices booted -j`
  output, as `%{"udid", "name", "runtime"}` with the runtime as `"27.0"`.
  """
  @spec parse_simulators(String.t()) :: [map()]
  def parse_simulators(json) do
    for {runtime_id, devices} <- JSON.decode!(json)["devices"] || %{},
        [_, major, minor] <- [Regex.run(~r/SimRuntime\.iOS-(\d+)-(\d+)$/, runtime_id)],
        %{"state" => "Booted"} = d <- devices,
        d["isAvailable"] != false,
        do: %{"udid" => d["udid"], "name" => d["name"], "runtime" => "#{major}.#{minor}"}
  end

  @doc """
  The physical devices in `xcrun devicectl list devices --json-output` output,
  as `%{"udid", "name", "runtime", "attached"}` (attached: the tunnel is up).
  """
  @spec parse_physical(String.t()) :: [map()]
  def parse_physical(json) do
    for %{"hardwareProperties" => %{"reality" => "physical"} = hw} = d <-
          get_in(JSON.decode!(json), ["result", "devices"]) || [] do
      %{
        "udid" => hw["udid"],
        "name" => get_in(d, ["deviceProperties", "name"]),
        "runtime" => get_in(d, ["deviceProperties", "osVersionNumber"]),
        "attached" => get_in(d, ["connectionProperties", "tunnelState"]) == "connected"
      }
    end
  end

  @doc "Whether runtime `\"27.0\"` (or `\"26.5.2\"`) is at least `min`."
  @spec runtime_at_least?(String.t() | nil, String.t()) :: boolean()
  def runtime_at_least?(nil, _min), do: false
  def runtime_at_least?(runtime, min), do: version(runtime) >= version(min)

  defp version(v), do: v |> String.split(".") |> Enum.map(&String.to_integer/1) |> pad()
  defp pad(parts), do: parts ++ List.duplicate(0, max(0, 3 - length(parts)))

  @doc """
  The simulators a `deploy:ios_sim` cell may lease, in the order to try them:
  only runtimes at or above `min` (see `Spec`'s `min_runtime`), newest runtime
  first. A cell that names a `udid` gets exactly that simulator, if it is
  booted and new enough.
  """
  @spec pick_simulators([map()], String.t(), String.t() | nil) :: {:ok, [map()]} | {:error, String.t()}
  def pick_simulators(sims, min, nil) do
    case sims |> Enum.filter(&runtime_at_least?(&1["runtime"], min)) |> Enum.sort_by(&version(&1["runtime"]), :desc) do
      [] ->
        seen = Enum.map_join(sims, ", ", &"#{&1["name"]} (iOS #{&1["runtime"]})")
        {:error, "no booted simulator runs iOS >= #{min} (booted: #{if seen == "", do: "none", else: seen})"}

      ok ->
        {:ok, ok}
    end
  end

  def pick_simulators(sims, min, udid) do
    case Enum.find(sims, &(&1["udid"] == udid)) do
      nil -> {:error, "simulator #{udid} is not booted"}
      sim -> if runtime_at_least?(sim["runtime"], min), do: {:ok, [sim]}, else: {:error, too_old(sim, min)}
    end
  end

  defp too_old(sim, min),
    do: "#{sim["name"]} #{sim["udid"]} runs iOS #{sim["runtime"]}, below the lane's minimum #{min}"

  @doc """
  What a build leaves outside the scratch dir under the app's own name:

    * mob_dev stages the app's BEAMs in `~/.mob/cache/otp-ios-*/<app>` and
      `~/.mob/runtime/ios-*/<app>` (~40 MB each);
    * `ios/release_device.sh` compiles in `BUILD_DIR=$(mktemp -d)` and never
      removes it, and macOS `mktemp -d` ignores `TMPDIR` (it uses the
      per-user `DARWIN_USER_TEMP_DIR`), so each release leaves a ~90 MB
      `tmp.XXXXXXXXXX` holding `<App>.app` there (FINDINGS F11).

  The `ci_*` app names (and their `CiXxx` modules) belong to mob_ci alone, so
  these are removed with the cell; the shared OTP runtime beside them and
  every other `tmp.*` dir are kept.
  """
  @spec app_state_dirs(Spec.t(), Path.t(), Path.t() | nil) :: [Path.t()]
  def app_state_dirs(%Spec{set: set, versions: %{row: row}}, mob_home, darwin_tmp) do
    app = Host.app_name(set, MobCi.Versions.parse!(row)) |> to_string()
    bundle = Macro.camelize(app) <> ".app"

    leaked =
      if darwin_tmp,
        do: Enum.filter(Path.wildcard(Path.join(darwin_tmp, "tmp.*")), &File.dir?(Path.join(&1, bundle))),
        else: []

    Path.wildcard(Path.join([mob_home, "cache", "otp-ios-*", app])) ++
      Path.wildcard(Path.join([mob_home, "runtime", "ios-*", app])) ++ leaked
  end

  # ── pure ─────────────────────────────────────────────────────────────────────

  @doc "Available KB from `df -k /` output (the 4th column of the last line)."
  @spec parse_df(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse_df(out) do
    with [line | _] <- out |> String.split("\n", trim: true) |> Enum.reverse(),
         [_fs, _blocks, _used, avail | _] <- String.split(line),
         {kb, ""} <- Integer.parse(avail) do
      {:ok, kb}
    else
      _ -> {:error, "unparseable df output: #{inspect(out)}"}
    end
  end

  @doc "The disk guard: `:ok`, or the refusal reason."
  @spec disk_guard(non_neg_integer(), non_neg_integer()) :: :ok | {:refuse, String.t()}
  def disk_guard(free_kb, min_kb \\ @min_free_kb) do
    if free_kb >= min_kb,
      do: :ok,
      else: {:refuse, "#{gb(free_kb)} GB free on /, a cell needs #{gb(min_kb)} GB"}
  end

  defp gb(kb), do: Float.round(kb / 1024 / 1024, 1)

  @doc """
  The invariants a probe's facts (the JSON `worker/mac/probe.exs` writes,
  decoded) establish for `plugins`. Each is `%{"id", "status", "layer",
  "detail"}` with `status` in pass | fail | skip | error.
  """
  @spec invariants(map(), [atom()]) :: [map()]
  def invariants(%{"found" => false}, _plugins),
    do: [inv("p2", "error", "boot", "the device was not found when probing")]

  def invariants(%{"alive" => true} = facts, plugins) do
    [inv("p2", "pass", nil, "#{facts["node"]} reachable")] ++
      Enum.map(facts["entries"] || [], &p12(&1, plugins)) ++ [health(facts["findings"] || [])]
  end

  def invariants(facts, _plugins) do
    detail = "node did not come up: #{facts["connect_error"] || "unreachable"}"
    [inv("p2", "fail", "boot", detail), inv("health", "skip", nil, "no node")]
  end

  defp p12(%{"plugin" => p, "status" => "fail", "reason" => reason}, plugins) do
    layer = if Enum.map(plugins, &to_string/1) == [p], do: "plugin:#{p}", else: "plugin:#{p}?"
    inv("p12:#{p}", "fail", layer, reason)
  end

  defp p12(%{"plugin" => p, "status" => status} = e, _plugins),
    do: inv("p12:#{p}", status, nil, e["reason"] || "#{e["ms"]} ms")

  defp health(findings) do
    case for(%{"kind" => "failure", "message" => m} <- findings, do: m) do
      [] ->
        notes = Enum.map_join(findings, "; ", & &1["message"])
        inv("health", "pass", nil, if(notes == "", do: "counters unchanged", else: notes))

      failures ->
        inv("health", "fail", "health", Enum.join(failures, "; "))
    end
  end

  defp inv(id, status, layer, detail),
    do: %{"id" => id, "status" => status, "layer" => layer, "detail" => detail}

  @doc """
  The cell's verdict: the first step that did not pass decides it; otherwise
  the worst invariant (error > fail > pass/skip) with its layer.
  """
  @spec verdict([map()], [map()]) :: {String.t(), String.t() | nil, String.t() | nil}
  def verdict(steps, invariants) do
    case Enum.find(steps, &(&1["status"] != "ok")) do
      %{"status" => status, "layer" => layer, "detail" => detail} ->
        {status, layer, detail}

      nil ->
        bad =
          Enum.find(invariants, &(&1["status"] == "error")) ||
            Enum.find(invariants, &(&1["status"] == "fail"))

        case bad do
          nil -> {"pass", nil, nil}
          %{"status" => s, "layer" => l, "id" => id, "detail" => d} -> {s, l, "#{id}: #{d}"}
        end
    end
  end

  # ── the run ──────────────────────────────────────────────────────────────────

  @doc """
  Run the cell. Options: `:root` (scratch root, default `default_root/0`),
  `:deps` (map overriding `default_deps/0` entries).
  """
  @spec run(Spec.t(), keyword()) :: map()
  def run(%Spec{} = spec, opts \\ []) do
    deps = Map.merge(default_deps(), Map.new(Keyword.get(opts, :deps, %{})))
    scratch = Path.join(Keyword.get(opts, :root, default_root()), spec.cell_id)
    tmp = Path.join(scratch, "tmp")
    started = System.monotonic_time(:millisecond)
    old_tmpdir = System.get_env("TMPDIR")

    state = %{
      spec: spec,
      scratch: scratch,
      tmp: tmp,
      host: nil,
      resolved: nil,
      leased: false,
      lease_tried: false,
      candidates: [],
      device: nil,
      steps: [],
      invariants: [],
      artifacts: %{},
      disk_before: nil
    }

    deps.log.("cell #{spec.cell_id}: #{spec.path} set=#{spec.set} row=#{spec.versions.row}")
    state = run_steps(steps(spec.path), state, deps)
    teardown = teardown(state, deps)

    restore_env("TMPDIR", old_tmpdir)
    steps = Enum.reverse(state.steps)
    {outcome, layer, reason} = verdict(steps, state.invariants)
    deps.log.("cell #{spec.cell_id}: #{outcome}#{if layer, do: " (#{layer})"}")

    %{
      "schema" => 1,
      "cell_id" => spec.cell_id,
      "set" => spec.set,
      "plugins" => Enum.map(spec.plugins, &to_string/1),
      "platform" => "ios",
      "path" => spec.path,
      # The device the cell ran on, with its runtime (`"27.0"`): a simulator
      # the worker picked, or the iPhone.
      "udid" => (state.device || %{})["udid"] || spec.udid,
      "device" => state.device,
      "min_runtime" => spec.min_runtime,
      "versions" => spec.versions,
      "mob_ci_sha" => spec.mob_ci_sha,
      "outcome" => outcome,
      "layer" => layer,
      "reason" => reason,
      "steps" => steps,
      "invariants" => state.invariants,
      "artifacts" => state.artifacts,
      "teardown" => teardown,
      "disk" => %{"before_kb" => state.disk_before, "after_kb" => free_or_nil(deps)},
      "duration_ms" => System.monotonic_time(:millisecond) - started
    }
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp free_or_nil(deps) do
    case safely(deps.free_kb) do
      {:ok, kb} -> kb
      _ -> nil
    end
  end

  @doc "The steps of a path, in order."
  @spec steps(Spec.path()) :: [atom()]
  def steps("release:ios"), do: [:disk, :resolve, :generate, :doctor, :build, :artifact]
  def steps(_deploy), do: [:disk, :resolve, :generate, :doctor, :device, :lease, :build, :probe]

  defp run_steps([], state, _deps), do: state

  defp run_steps([name | rest], state, deps) do
    t0 = System.monotonic_time(:millisecond)
    deps.log.("step #{name} …")
    # A failed acquire may still have started the session's daemon: teardown
    # releases whenever a lease was attempted, so mark it before the call.
    state = if name == :lease, do: %{state | lease_tried: true}, else: state

    {status, state, layer, detail} =
      try do
        case step(name, state, deps) do
          {:ok, state} -> {"ok", state, nil, nil}
          {:ok, state, detail} -> {"ok", state, nil, detail}
          {:fail, layer, detail} -> {"fail", state, layer, detail}
          {:error, layer, detail} -> {"error", state, layer, detail}
          {:skip, detail} -> {"skip", state, nil, detail}
        end
      rescue
        e -> {"error", state, crash_layer(name, state), "#{name} crashed: #{Exception.message(e)}"}
      catch
        kind, reason ->
          {"error", state, crash_layer(name, state), "#{name} crashed: #{inspect({kind, reason})}"}
      end

    ms = System.monotonic_time(:millisecond) - t0
    deps.log.("step #{name} #{status} (#{ms} ms)#{if detail, do: ": " <> clip(detail), else: ""}")

    entry = %{"name" => Atom.to_string(name), "status" => status, "layer" => layer, "ms" => ms, "detail" => detail}
    state = %{state | steps: [entry | state.steps]}

    if status == "ok", do: run_steps(rest, state, deps), else: state
  end

  # A step that raised is attributed where its own failure would be.
  defp crash_layer(:generate, _), do: "mob_new"
  defp crash_layer(:doctor, _), do: "doctor"
  defp crash_layer(name, %{spec: s}) when name in [:build, :artifact], do: "build:#{s.path}"
  defp crash_layer(name, _) when name in [:device, :lease], do: "boot"
  defp crash_layer(:disk, _), do: "error:disk"
  defp crash_layer(_, _), do: "error:worker"

  defp clip(detail) when is_binary(detail), do: detail |> String.slice(-600, 600) |> String.trim()
  defp clip(detail), do: inspect(detail, limit: 20)

  # ── steps ────────────────────────────────────────────────────────────────────

  defp step(:disk, state, deps) do
    with {:ok, kb} <- deps.free_kb.() do
      state = %{state | disk_before: kb}

      case disk_guard(kb) do
        :ok ->
          File.mkdir_p!(state.tmp)
          System.put_env("TMPDIR", state.tmp)
          {:ok, state, "#{gb(kb)} GB free"}

        {:refuse, reason} ->
          {:error, "error:disk", reason}
      end
    else
      {:error, reason} -> {:error, "error:disk", reason}
    end
  end

  defp step(:resolve, state, deps) do
    case deps.resolve.(state.spec) do
      {:ok, resolved} -> {:ok, %{state | resolved: resolved}}
      {:error, reason} -> {:error, "error:worker", "could not materialise the pins: #{inspect(reason)}"}
    end
  end

  defp step(:generate, %{spec: spec} = state, deps) do
    opts = [platform: :ios, root: state.scratch, mob_exs: mob_exs(spec.path), fresh: true]

    case deps.generate.(Sets.parse!(spec.set), spec.plugins, state.resolved, opts) do
      {:ok, host} -> {:ok, %{state | host: host}, host.dir}
      {:error, {layer, reason}} -> {:fail, Atom.to_string(layer), inspect(reason, limit: 50)}
    end
  end

  defp step(:doctor, state, deps) do
    case deps.mix.(["mob.doctor"], state.host.dir) do
      {_tail, 0} -> {:ok, state}
      {tail, code} -> {:fail, "doctor", "mix mob.doctor exited #{code}: #{tail}"}
    end
  end

  defp step(:device, %{spec: %{path: "deploy:ios_device", udid: udid}} = state, deps) do
    case Enum.find(deps.physical_devices.(), &(&1["udid"] == udid)) do
      %{"attached" => true} = device ->
        {:ok, %{state | candidates: [device]}, "#{device["name"]} (iOS #{device["runtime"]})"}

      _ ->
        {:skip, "device_absent: #{udid} is not attached"}
    end
  end

  defp step(:device, %{spec: spec} = state, deps) do
    case pick_simulators(deps.simulators.(), spec.min_runtime, spec.udid) do
      {:ok, sims} ->
        {:ok, %{state | candidates: sims}, Enum.map_join(sims, ", ", &device_label/1)}

      {:error, reason} ->
        {:error, "boot", reason}
    end
  end

  # Try the candidates in order (newest runtime first); the first free one is
  # the cell's device.
  defp step(:lease, %{spec: spec, candidates: candidates} = state, deps) do
    Enum.reduce_while(candidates, [], fn device, refused ->
      case deps.lease.(session(spec), device["udid"]) do
        :ok -> {:halt, {:ok, %{state | leased: true, device: device}, device_label(device)}}
        {:error, why} -> {:cont, [{device, why} | refused]}
      end
    end)
    |> case do
      {:ok, _, _} = ok ->
        ok

      refused ->
        why = refused |> Enum.reverse() |> Enum.map_join("; ", fn {d, w} -> "#{device_label(d)}: #{w}" end)

        if spec.path == "deploy:ios_device",
          do: {:skip, "device_absent: #{spec.udid} is not leasable (#{why})"},
          else: {:error, "boot", "no simulator could be leased: #{why}"}
    end
  end

  defp step(:build, %{spec: %{path: "release:ios"}} = state, deps) do
    dir = state.host.dir

    with {:regen, {_, 0}} <- {:regen, deps.mix.(["mob.regen_driver_tab", "--format", "c"], dir)},
         {:release, {_, 0}} <- {:release, deps.mix.(["mob.release", "--ios"], dir)} do
      {:ok, state}
    else
      {step, {tail, code}} ->
        task = if step == :regen, do: "mob.regen_driver_tab", else: "mob.release --ios"
        {:fail, "build:release:ios", "mix #{task} exited #{code}: #{tail}"}
    end
  end

  defp step(:build, %{spec: spec, device: %{"udid" => udid}} = state, deps) do
    case deps.mix.(["mob.deploy", "--native", "--ios", "--device", udid], state.host.dir) do
      {_tail, 0} -> {:ok, state}
      {tail, code} -> {:fail, "build:#{spec.path}", "mix mob.deploy exited #{code}: #{tail}"}
    end
  end

  defp step(:artifact, state, deps) do
    case Path.wildcard(Path.join(state.host.dir, "_build/mob_release/*.ipa")) do
      [ipa] ->
        case deps.inspect_ipa.(ipa) do
          {:ok, info} -> {:ok, %{state | artifacts: Map.put(state.artifacts, "ipa", info)}, info["name"]}
          {:error, why} -> {:fail, "build:release:ios", "#{Path.basename(ipa)}: #{why}"}
        end

      [] ->
        {:fail, "build:release:ios", "mix mob.release exited 0 but wrote no _build/mob_release/*.ipa"}

      many ->
        {:fail, "build:release:ios", "more than one .ipa: #{Enum.map_join(many, ", ", &Path.basename/1)}"}
    end
  end

  defp step(:probe, %{spec: spec, device: %{"udid" => udid}} = state, deps) do
    out = Path.join(state.scratch, "probe.json")

    case deps.probe.(state.host.dir, udid, out) do
      {:ok, facts} ->
        invariants = invariants(facts, spec.plugins)
        {:ok, %{state | invariants: invariants}, summary(invariants)}

      {:error, why} ->
        {:error, "error:worker", "probe: #{why}"}
    end
  end

  defp device_label(d), do: "#{d["name"]} #{d["udid"]} (iOS #{d["runtime"]})"

  defp summary(invariants),
    do: Enum.map_join(invariants, ", ", &"#{&1["id"]} #{&1["status"]}")

  # ── teardown ─────────────────────────────────────────────────────────────────

  defp teardown(%{spec: spec} = state, deps) do
    uninstall =
      if state.leased,
        do: [{"uninstall", fn -> deps.uninstall.(spec.path, state.device["udid"], bundle_id(spec.path)) end}],
        else: []

    release =
      if state.lease_tried, do: [{"release_lease", fn -> deps.release.(session(spec)) end}], else: []

    delete = [
      {"delete_app_state",
       fn -> Enum.each(app_state_dirs(spec, deps.mob_home, deps.darwin_tmp), deps.rm_rf) end},
      {"delete_scratch", fn -> deps.rm_rf.(state.scratch) end}
    ]

    for {name, fun} <- uninstall ++ release ++ delete do
      result =
        case safely(fun) do
          {:ok, _} -> "ok"
          {:error, why} -> why
        end

      deps.log.("teardown #{name}: #{clip(result)}")
      %{"name" => name, "result" => result}
    end
  end

  defp safely(fun) do
    case fun.() do
      {:error, why} -> {:error, inspect(why)}
      {:ok, v} -> {:ok, v}
      other -> {:ok, other}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  # ── the real I/O ─────────────────────────────────────────────────────────────

  @doc "The I/O the steps use; `run/2`'s `:deps` replaces any of them."
  def default_deps do
    %{
      log: fn line -> IO.puts("[ios-worker #{time()}] #{line}") end,
      free_kb: fn ->
        {out, 0} = System.cmd("df", ["-k", "/"])
        parse_df(out)
      end,
      resolve: &Spec.resolved/1,
      generate: &Host.generate/4,
      mix: fn args, dir -> cmd("mix", args, cd: dir, env: [{"MIX_ENV", "dev"}]) end,
      simulators: fn ->
        {out, 0} = System.cmd("xcrun", ["simctl", "list", "devices", "booted", "-j"])
        parse_simulators(out)
      end,
      physical_devices: fn ->
        out = Path.join(System.tmp_dir!(), "devicectl_#{System.unique_integer([:positive])}.json")

        try do
          {_, 0} = System.cmd("xcrun", ["devicectl", "list", "devices", "--json-output", out], stderr_to_stdout: true)
          parse_physical(File.read!(out))
        after
          File.rm(out)
        end
      end,
      lease: fn session, udid ->
        case cmd("agent-lease", ["acquire", session, "--udid", udid]) do
          {_, 0} -> :ok
          {tail, code} -> {:error, "agent-lease exited #{code}: #{String.trim(tail)}"}
        end
      end,
      release: fn session -> cmd("agent-lease", ["release", session]) end,
      uninstall: &uninstall/3,
      probe: &probe/3,
      inspect_ipa: &inspect_ipa/1,
      rm_rf: fn path -> File.rm_rf!(path) end,
      mob_home: Path.expand("~/.mob"),
      darwin_tmp: darwin_user_temp_dir()
    }
  end

  # Where macOS `mktemp -d` (no template) creates dirs, whatever TMPDIR says.
  defp darwin_user_temp_dir do
    case System.cmd("getconf", ["DARWIN_USER_TEMP_DIR"], stderr_to_stdout: true) do
      {dir, 0} -> String.trim(dir)
      _ -> nil
    end
  end

  defp time, do: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")

  defp cmd(exe, args, opts \\ []) do
    {tee, code} = System.cmd(exe, args, [into: %Tee{}, stderr_to_stdout: true] ++ opts)
    {tee.tail, code}
  end

  defp uninstall("deploy:ios_device", udid, bundle_id) do
    cmd("xcrun", ["devicectl", "device", "uninstall", "app", "--device", udid, bundle_id])
  end

  defp uninstall(_sim, udid, bundle_id) do
    _ = System.cmd("xcrun", ["simctl", "terminate", udid, bundle_id], stderr_to_stdout: true)
    cmd("xcrun", ["simctl", "uninstall", udid, bundle_id])
  end

  defp probe(host_dir, udid, out) do
    args = ["run", "--no-start", @probe_script, udid, out, Integer.to_string(@selftest_timeout_ms)]

    case cmd("mix", args, cd: host_dir, env: [{"MIX_ENV", "dev"}]) do
      {_tail, 0} ->
        with {:ok, body} <- File.read(out),
             {:ok, facts} <- JSON.decode(body) do
          {:ok, facts}
        else
          {:error, why} -> {:error, "no readable #{out}: #{inspect(why)}"}
        end

      {tail, code} ->
        {:error, "probe exited #{code}: #{tail}"}
    end
  end

  @doc false
  # Name, size, sha256 and the bundle inside: an .ipa is a zip whose
  # Payload/<App>.app/ holds the bundle, signed when it carries
  # _CodeSignature/CodeResources. An unsigned archive is a failure: the
  # release path exists to prove the signed artefact.
  def inspect_ipa(ipa) do
    with {:ok, entries} <- :zip.list_dir(String.to_charlist(ipa)),
         names = for({:zip_file, name, _, _, _, _} <- entries, do: to_string(name)),
         [app | _] <- names |> Enum.flat_map(&app_of/1) |> Enum.uniq(),
         true <-
           "Payload/#{app}/_CodeSignature/CodeResources" in names ||
             {:error, "Payload/#{app} is not signed (no _CodeSignature/CodeResources)"} do
      body = File.read!(ipa)

      {:ok,
       %{
         "name" => Path.basename(ipa),
         "bytes" => byte_size(body),
         "sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
         "app" => app
       }}
    else
      [] -> {:error, "no Payload/*.app in the archive"}
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, why} -> {:error, "not a zip: #{inspect(why)}"}
    end
  end

  defp app_of(name) do
    case Regex.run(~r{^Payload/([^/]+\.app)/}, name) do
      [_, app] -> [app]
      nil -> []
    end
  end
end
