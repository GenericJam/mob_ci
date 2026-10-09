defmodule MobCi.Run do
  @moduledoc """
  The orchestration spine for one activated plugin set, over one or more build
  paths of the same prepared host:

    * `:deploy` (`deploy:android`) — the dev APK:
      boot redroid → `mix mob.deploy --native --device` → grant permissions →
      launch (CI identity) → probe P1–P10 + P12 → release → P11.
    * `:release` (`release:android`) — what a user ships:
      `mix mob.release --android` → universal APK (bundletool) → boot a fresh
      redroid → install → grant → first launch unpacks OTP, cookie provisioned →
      launch → probe P2, P12, P10 → release → P11.

  Permissions are granted after install and before launch
  (`MobCi.Farm.grant_permissions/4`): granting to a running app can kill it.
  Every instance is released whatever happens (guaranteed teardown), so a
  crashed run never leaks a farm slot from staging. A cross-plugin conflict
  short-circuits before probing — P1 verifies the rejection.

  Each path's outcome is printed, written to `--artifacts` (junit.xml,
  summary.json, timings.json, deploy.log / release.log) and, given a
  `MobCi.Store` (`:store` + `:run_id`), recorded as a cell. This is the
  `:integration` entry; the static, no-device path is `mix ci.device --static`.
  """

  require Logger
  alias MobCi.{Build, Context, DeviceCaps, Farm, Invariants, Plugins, Report, Result, Store}

  @timings_key :mob_ci_timings

  @type path :: :deploy | :release
  @type outcome :: {:ok, [Result.t()]} | {:fail, [Result.t()]} | {:error, term()}
  @type path_run :: %{
          path: String.t(),
          outcome: outcome(),
          duration_ms: non_neg_integer(),
          log_path: Path.t() | nil
        }

  @doc """
  Run `set` on its host over `opts[:paths]` (default `[:deploy]`) and return
  one `t:path_run/0` per path, in order. Options: `:host` (`:harness |
  :sloppy_joe | :generated`), `:prepared` (a `MobCi.Host` for `:generated`),
  `:artifacts_dir`, `:store` + `:run_id` (record the cells), `:versions_row`
  (the row the P12 singleton lookup reads; defaults to the stamped record's
  row), `:selftest_timeout_ms`, `:profile`, `:node_timeout_ms`, `:fresh`.
  """
  @spec run([atom()], keyword()) :: [path_run()]
  def run(set, opts \\ []) do
    host = Keyword.get(opts, :host, :harness)
    artifacts = opts |> Keyword.get(:artifacts_dir) |> expand()
    paths = Keyword.get(opts, :paths, [:deploy])
    Process.put(@timings_key, [])

    {runs, opts} =
      try do
        case step(:prepare, fn -> prepare(host, set, opts) end) do
          {:ok, prep} ->
            # Restore any transient host mutation (e.g. sloppy_joe's swapped mob.exs)
            # no matter how the run exits.
            cleanup = Map.get(prep, :cleanup, fn -> :ok end)
            opts = stamp_opts(prep, opts)

            try do
              {for(path <- paths, do: run_path(path, set, host, prep, artifacts, opts)), opts}
            after
              cleanup.()
            end

          {:error, reason} ->
            {for(path <- paths, do: errored(path, error({:prepare_failed, host_dir(host), reason}), 0, nil)), opts}
        end
      after
        # The budget data survives even a run that raised.
        write_timings(artifacts)
      end

    Report.write_artifacts(artifacts, set, artifact_results(runs, opts))
    # The stamped opts: a generated host's set name and version record.
    record(runs, set, host, opts)
    runs
  end

  @doc """
  Per-step wall-clock durations of the run in progress (`[{step, ms}]`, in
  order): prepare, then the deploy path's boot, deploy, grant, launch, probe,
  release (teardown), then the release path's `release:*` steps — the budget
  data `docs/budgets.md` is written from. Lives in the process dictionary of
  the process that called `run/2`.
  """
  @spec timings() :: [{atom(), non_neg_integer()}]
  def timings, do: Enum.reverse(Process.get(@timings_key, []))

  @doc """
  The worst verdict across a run's paths: `:error` if a path never reached the
  catalog, else `:fail` if any invariant failed or errored, else `:ok`.
  """
  @spec verdict([path_run()]) :: :ok | :fail | :error
  def verdict(runs) do
    outcomes = Enum.map(runs, & &1.outcome)

    cond do
      Enum.any?(outcomes, &match?({:error, _}, &1)) -> :error
      Enum.any?(outcomes, &match?({:fail, _}, &1)) -> :fail
      true -> :ok
    end
  end

  @doc """
  The paths of a run that say nothing about the code because infrastructure
  failed under them: layer `farm` (an orchestration error `error_layer/1`
  puts at `:farm`, or catalog results re-attributed to it by the post-path
  liveness check) or layer `toolchain` (the build's JVM crashed).
  `mix ci.device` exits 3 when this is non-empty, which the queue retries once.
  """
  @spec infra_failed([path_run()]) :: [String.t()]
  def infra_failed(runs) do
    for %{path: path, outcome: outcome} <- runs, infra?(outcome), do: path
  end

  @infra_layers [:farm, :toolchain]

  defp infra?({:error, reason}), do: error_layer(reason) in @infra_layers
  defp infra?({_verdict, results}), do: Enum.any?(results, &(&1.layer in @infra_layers))

  @doc false
  # A path's outcome once the post-path check found its instance gone: an
  # orchestration error becomes `{:instance_lost, why, reason}` (layer
  # `:farm`); failing or erroring catalog results are re-attributed to `:farm`
  # (a probe that lost its device says nothing about the code), and so are
  # P12's failing per-plugin items, which the store keeps as `p12:<p>` rows
  # the singleton lookup reads. Passes and skips stand.
  @spec mark_lost(outcome(), String.t()) :: outcome()
  def mark_lost({:error, reason}, why), do: {:error, {:instance_lost, why, reason}}

  def mark_lost({verdict, results}, why), do: {verdict, Enum.map(results, &lost(&1, why))}

  defp lost(%Result{status: s} = r, why) when s in [:fail, :error] do
    r = %{Result.at(r, :farm) | detail: "#{r.detail} [instance lost: #{why}]"}

    case r.evidence do
      %{items: items} = ev when is_list(items) -> %{r | evidence: %{ev | items: Enum.map(items, &lost(&1, why))}}
      _ -> r
    end
  end

  defp lost(r, _why), do: r

  # Did the path go wrong in a way the instance's disappearance could explain?
  # (An error already at `:farm` or `:toolchain` needs no second look.)
  defp needs_liveness_check?({:error, reason}), do: error_layer(reason) not in @infra_layers
  defp needs_liveness_check?({_verdict, results}), do: Enum.any?(results, &(&1.status in [:fail, :error]))

  # Probe results with a failure: is the instance still there? Run before the
  # catalog releases the live instance (P11 checks that teardown).
  defp farm_check(results, inst) do
    with true <- needs_liveness_check?({:fail, results}),
         {:lost, why} <- Farm.alive(inst) do
      Logger.error("[mob_ci] layer=:farm instance #{inst.serial} lost during the probe: #{why}")
      elem(mark_lost({:fail, results}, why), 1)
    else
      _ -> results
    end
  end

  @doc """
  The results the `--artifacts` dir reports for a run: every path's catalog
  results, and for a path that never reached the catalog one `:path` error
  carrying the orchestration reason and its `error_layer/1`, so junit.xml and
  summary.json can't read green when a path errored.
  """
  @spec artifact_results([path_run()], keyword()) :: [Result.t()]
  def artifact_results(runs, opts) do
    Enum.flat_map(runs, fn
      %{outcome: {:error, reason}, path: path} ->
        Result.error(:path, "build path reached the catalog", inspect(reason, limit: 20))
        |> Result.at(error_layer(reason))
        |> List.wrap()
        |> Result.stamp(opts[:set_name], opts[:versions], path)

      %{outcome: {_verdict, results}} ->
        results
    end)
  end

  defp step(name, fun) do
    {us, result} = :timer.tc(fun)
    ms = div(us, 1000)
    Process.put(@timings_key, [{name, ms} | Process.get(@timings_key, [])])
    Logger.info("[mob_ci] step=#{name} ms=#{ms}")
    result
  end

  defp write_timings(nil), do: :ok

  defp write_timings(dir) do
    File.mkdir_p!(dir)
    body = Enum.map_join(timings(), ",\n", fn {k, ms} -> ~s(  "#{k}": #{ms}) end)
    File.write!(Path.join(dir, "timings.json"), "{\n" <> body <> "\n}\n")
  end

  defp expand(nil), do: nil
  defp expand(dir), do: Path.expand(dir)

  defp prepare(:harness, set, opts) do
    Logger.info("[mob_ci] preparing harness for #{inspect(set)}")
    Build.prepare_harness(set, opts)
  end

  defp prepare(:sloppy_joe, set, _opts) do
    Logger.info("[mob_ci] preparing sloppy_joe (realism gate) for #{inspect(set)}")
    Build.prepare_sloppy_joe(set)
  end

  # A host `MobCi.Host.generate/4` already built for a (set, version row): the
  # prepared map rides in as `opts[:prepared]`; its set name and version
  # record are stamped onto every result (see `MobCi.Result.stamp/4`).
  defp prepare(:generated, set, opts) do
    Logger.info("[mob_ci] using generated host #{opts[:prepared].app} for #{inspect(set)}")
    {:ok, Keyword.fetch!(opts, :prepared)}
  end

  defp host_dir(:sloppy_joe), do: Build.sloppy_joe_dir()
  defp host_dir(:harness), do: Build.harness_root()
  defp host_dir(:generated), do: MobCi.Host.hosts_root()

  # ── one build path ───────────────────────────────────────────────────────────

  defp run_path(path, set, host, prep, artifacts, opts) do
    log = if artifacts, do: Path.join(artifacts, "#{path}.log")
    {us, outcome} = :timer.tc(fn -> do_path(path, set, host, prep, log, opts) end)
    ms = div(us, 1000)

    case outcome do
      {:error, _} = err -> errored(path, err, ms, log)
      {_verdict, _results} -> %{path: Build.path_label(path), outcome: outcome, duration_ms: ms, log_path: log}
    end
  end

  defp errored(path, {:error, _} = err, ms, log),
    do: %{path: Build.path_label(path), outcome: err, duration_ms: ms, log_path: log}

  defp do_path(:deploy, set, host, prep, log, opts) do
    Logger.info("[mob_ci] deploy:android — booting a CI redroid")

    with_instance(:boot, :release, opts, fn inst ->
      deploy_and_probe(set, host, prep, inst, log, opts)
    end)
  end

  defp do_path(:release, set, host, prep, log, opts) do
    Logger.info("[mob_ci] release:android — mix mob.release --android")

    case step(:"release:build", fn -> Build.build_release(prep.dir, log: log) end) do
      {:conflict, msgs} ->
        ctx = base_ctx(set, host, prep, :release, opts, build_status: {:conflict, msgs})
        finalize(:release, set, [Invariants.p1(ctx)], opts)

      {:error, reason} ->
        error({:build_failed, :release, reason})

      {:ok, apk} ->
        with_instance(:"release:boot", :"release:teardown", opts, fn inst ->
          install_and_probe(set, host, prep, apk, inst, opts)
        end)
    end
  end

  # Boot an instance, run `fun` on it and always release it. A path that
  # errored is checked against the instance before release: if the container
  # or its adb device is gone, the error is the farm's (`mark_lost/2`), not
  # the code's. (Probe results are checked in `farm_check/2`, before the
  # catalog's own release_live tears the instance down.)
  defp with_instance(boot_step, release_step, opts, fun) do
    boot_opts = [profile: opts[:profile], run: opts[:run_id]] |> Enum.reject(&is_nil(elem(&1, 1)))

    case step(boot_step, fn -> Farm.boot(boot_opts) end) do
      {:ok, inst} ->
        try do
          outcome = fun.(inst)

          with {:error, _} <- outcome,
               true <- needs_liveness_check?(outcome),
               {:lost, why} <- Farm.alive(inst) do
            Logger.error("[mob_ci] layer=:farm instance #{inst.serial} lost: #{why}")
            mark_lost(outcome, why)
          else
            _ -> outcome
          end
        after
          step(release_step, fn -> Farm.release(inst) end)
        end

      {:error, :box_busy} ->
        error(:box_busy)

      {:error, reason} ->
        error({:boot_failed, reason})
    end
  end

  defp deploy_and_probe(set, host, prep, inst, log, opts) do
    Logger.info("[mob_ci] deploying to #{inst.serial}")

    case step(:deploy, fn -> Build.deploy(prep.dir, inst.serial, log: log) end) do
      {:conflict, msgs} ->
        # Expected rejection — P1 verifies it; no device probing needed.
        ctx = base_ctx(set, host, prep, :deploy, opts, build_status: {:conflict, msgs})
        finalize(:deploy, set, Invariants.run(ctx, [:pure, :build]), opts)

      {:error, reason} ->
        error({:build_failed, :deploy, reason})

      :ok ->
        step(:grant, fn -> grant(inst, set, prep.pkg) end)
        probe(set, host, prep, inst, opts)
    end
  end

  defp probe(set, host, prep, inst, opts) do
    perms =
      with {:ok, apk} <- Build.locate_apk(prep.dir), {:ok, p} <- Build.read_permissions(apk) do
        p
      else
        _ -> nil
      end

    case step(:launch, fn -> launch(inst, prep, opts) end) do
      {:ok, live} ->
        ctx = base_ctx(set, host, prep, :deploy, opts, build_status: :ok, permissions: perms, node: live.node)
        # Everything except P11 (which is post-release).
        results =
          step(:probe, fn -> Invariants.run(ctx, [:pure, :build, :device]) |> Enum.reject(&(&1.id == :p11)) end)
          |> farm_check(inst)

        step(:release_live, fn -> Farm.release(live) end)
        finalize(:deploy, set, results ++ [Invariants.p11(ctx)], opts)

      {:error, reason} ->
        error({:launch_failed, reason})
    end
  end

  # The release path proves what the dev path can't: the shipped bundle boots
  # (P2), every self-test passes in it (P12), it survives a walk (P10) and
  # tears down (P11). P3–P9 stay on the dev path, where the build is the
  # same set's and the probes are cheap.
  defp install_and_probe(set, host, prep, apk, inst, opts) do
    with :ok <- step(:"release:install", fn -> install(inst, apk) end),
         _grants = step(:"release:grant", fn -> grant(inst, set, prep.pkg) end),
         :ok <- step(:"release:provision", fn -> provision(inst, prep, opts) end),
         {:ok, live} <- step(:"release:launch", fn -> launch(inst, prep, opts) end) do
      ctx = base_ctx(set, host, prep, :release, opts, build_status: :ok, node: live.node)

      results =
        step(:"release:probe", fn -> [Invariants.p2(ctx), Invariants.p12(ctx), Invariants.p10(ctx)] end)
        |> farm_check(inst)

      step(:"release:release_live", fn -> Farm.release(live) end)
      finalize(:release, set, results ++ [Invariants.p11(ctx)], opts)
    end
  end

  defp install(inst, apk) do
    case Farm.install_apk(inst, apk) do
      :ok -> :ok
      {:error, reason} -> error({:install_failed, :release, reason})
    end
  end

  defp provision(inst, prep, opts) do
    case Farm.provision_release(inst, app: prep.app, pkg: prep.pkg, timeout_ms: Keyword.get(opts, :node_timeout_ms, 90_000)) do
      :ok -> :ok
      {:error, reason} -> error({:launch_failed, reason})
    end
  end

  defp launch(inst, prep, opts) do
    case Farm.launch(inst, app: prep.app, pkg: prep.pkg, timeout_ms: Keyword.get(opts, :node_timeout_ms, 60_000)) do
      {:ok, _} = ok -> ok
      {:error, reason} -> error({:launch_failed, reason})
    end
  end

  defp grant(inst, set, pkg) do
    grants = Farm.grant_permissions(inst, Plugins.activated(set), pkg)

    for %{plugin: p, permission: perm, status: status} <- grants do
      Logger.info("[mob_ci] grant #{perm} (#{p}): #{inspect(status)}")
    end

    grants
  end

  @doc """
  The layer an orchestration error (a path outcome `{:error, reason}`)
  belongs to, so a path that never reached the catalog is still attributed:
  host preparation → `{:build, dir}`; a build path that failed outright →
  `build:<path>` (`build:<path>/<p>` when mob_dev named the plugin, see
  `MobCi.Build.path_failure_layer/2`); a release APK the device refused →
  `build:release:android`; farm admission, boot and app launch → `:boot`.
  A build, install or launch that failed because the device went away
  (`MobCi.Farm.lost_device?/1`), and any error after which the instance was
  found gone (`{:instance_lost, why, reason}`), → `:farm`; a build whose JVM
  crashed (`MobCi.Build.toolchain_crash?/1`) → `:toolchain`.
  """
  @spec error_layer(term()) :: Result.layer()
  def error_layer({:prepare_failed, dir, _reason}), do: {:build, dir}
  def error_layer({:instance_lost, _why, _reason}), do: :farm

  def error_layer({:build_failed, path, reason}) when path in [:deploy, :release] do
    cond do
      Farm.lost_device?(reason) -> :farm
      Build.toolchain_crash?(reason) -> :toolchain
      true -> Build.path_failure_layer(path, reason)
    end
  end

  def error_layer({:install_failed, path, reason}),
    do: if(Farm.lost_device?(reason), do: :farm, else: {:build, Build.path_label(path)})

  def error_layer(:box_busy), do: :boot
  def error_layer({:boot_failed, _reason}), do: :boot
  def error_layer({:launch_failed, reason}), do: if(Farm.lost_device?(reason), do: :farm, else: :boot)
  def error_layer(_other), do: nil

  defp error(reason) do
    Logger.error("[mob_ci] layer=#{inspect(error_layer(reason))} #{inspect(reason, limit: 8)}")
    {:error, reason}
  end

  defp base_ctx(set, host, prep, path, opts, fields) do
    %Context{
      set: set,
      host: host,
      host_dir: prep.dir,
      node: Keyword.get(fields, :node),
      repo: repo_module(prep.app),
      build: %{
        status: Keyword.get(fields, :build_status, :unknown),
        apk: nil,
        permissions: Keyword.get(fields, :permissions),
        conflicts: []
      },
      nif_probes: Map.merge(Context.default_nif_probes(), DeviceCaps.nif_probes(set)),
      migration_tables: Context.default_migration_tables(),
      worker_names: Context.default_worker_names(),
      screen_caps: DeviceCaps.screen_caps(set),
      # The fixture harness writes a P5 showcase screen; a generated host
      # (MobCi.Host) has none, so P5 reports that rather than a phantom crash.
      showcase_screen: if(host == :generated, do: nil, else: Build.showcase_module(prep.app)),
      selftest_timeout_ms: Keyword.get(opts, :selftest_timeout_ms, 30_000),
      static_conflicts: Keyword.get(opts, :static_conflicts),
      singleton_selftest: singleton_lookup(path, opts)
    }
  end

  @doc """
  The P12 singleton lookup for a path: the newest self-test outcome of a
  plugin in its `singleton:<p>` cell on the same versions row and path, read
  from the store; with no store (or no row) nothing is ever known.
  """
  @spec singleton_lookup(path(), keyword()) :: (atom() -> Result.status() | nil)
  def singleton_lookup(path, opts) do
    case {opts[:store], versions_row(opts)} do
      {%Store{} = store, row} when is_binary(row) ->
        fn plugin ->
          Store.singleton_selftest(store, plugin, versions_row: row, platform: :android, path: Build.path_label(path))
        end

      _ ->
        fn _plugin -> nil end
    end
  end

  defp versions_row(opts), do: opts[:versions_row] || get_in(opts, [:versions, :row])

  # The generated host app's Ecto repo: <AppModule>.Repo (e.g. MobCiHarness.Repo).
  defp repo_module(app), do: Module.concat([Macro.camelize(to_string(app)), Repo])

  # A prepared host that knows its cell (MobCi.Host) stamps every result with
  # the set name and version record; the harness and sloppy_joe hosts don't.
  defp stamp_opts(%{set: set_name, versions: versions}, opts),
    do: Keyword.merge(opts, set_name: set_name, versions: versions)

  defp stamp_opts(_prep, opts), do: opts

  defp finalize(path, set, results, opts) do
    label = Build.path_label(path)
    results = Result.stamp(results, opts[:set_name], opts[:versions], label)
    IO.puts("\n" <> Report.console(results, title: "mob_ci #{label} #{inspect(set)}"))
    if Report.ok?(results), do: {:ok, results}, else: {:fail, results}
  end

  # ── the store ────────────────────────────────────────────────────────────────

  @doc """
  The store name of a run's set: the cell's set name (`MobCi.Sets.name/1`)
  when the host knows it, else `<host>:<plugins>` for the harness and
  sloppy_joe hosts.
  """
  @spec set_name([atom()], atom(), keyword()) :: String.t()
  def set_name(set, host, opts), do: opts[:set_name] || "#{host}:#{Enum.join(set, ",")}"

  defp record(runs, set, host, opts) do
    with %Store{} = store <- opts[:store], run_id when is_integer(run_id) <- opts[:run_id] do
      for run <- runs do
        meta = %{
          set: set_name(set, host, opts),
          platform: :android,
          path: run.path,
          versions: opts[:versions],
          duration_ms: run.duration_ms,
          log_path: run.log_path
        }

        outcome =
          case run.outcome do
            {:error, reason} -> {:error, reason, error_layer(reason)}
            other -> other
          end

        Store.record_results(store, run_id, meta, outcome)
      end
    end

    :ok
  end
end
