defmodule MobCi.Run do
  @moduledoc """
  The orchestration spine for one activated plugin set:

      prepare harness → boot redroid → deploy --device → launch (CI identity)
        → probe (P1–P10) → release → P11 (post-release)

  Always releases the instance (guaranteed teardown), so a crashed run never
  leaks a farm slot from staging. A cross-plugin conflict short-circuits before
  boot — P1 verifies the rejection with no device needed. This is the
  `:integration` entry; the static, no-device path is `mix ci.device --static`.
  """

  require Logger
  alias MobCi.{Build, Context, DeviceCaps, Farm, Invariants, Report}

  @timings_key :mob_ci_timings

  @spec run([atom()], keyword()) ::
          {:ok, [MobCi.Result.t()]} | {:fail, [MobCi.Result.t()]} | {:error, term()}
  def run(set, opts \\ []) do
    host = Keyword.get(opts, :host, :harness)
    artifacts = Keyword.get(opts, :artifacts_dir)
    Process.put(@timings_key, [])

    case step(:prepare, fn -> prepare(host, set, opts) end) do
      {:ok, prep} ->
        # Restore any transient host mutation (e.g. sloppy_joe's swapped mob.exs)
        # no matter how the run exits.
        cleanup = Map.get(prep, :cleanup, fn -> :ok end)

        try do
          do_run(set, host, prep.dir, prep.app, prep.pkg, artifacts, stamp_opts(prep, opts))
        after
          cleanup.()
          write_timings(artifacts)
        end

      {:error, reason} ->
        write_timings(artifacts)
        error({:prepare_failed, host_dir(host), reason})
    end
  end

  @doc """
  Per-step wall-clock durations of the run in progress (`[{step, ms}]`, in
  order): prepare, boot, deploy, launch, probe, release — the budget data
  `docs/budgets.md` is written from. Lives in the process dictionary of the
  process that called `run/2`.
  """
  @spec timings() :: [{atom(), non_neg_integer()}]
  def timings, do: Enum.reverse(Process.get(@timings_key, []))

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
  # record are stamped onto every result (see `MobCi.Result.stamp/3`).
  defp prepare(:generated, set, opts) do
    Logger.info("[mob_ci] using generated host #{opts[:prepared].app} for #{inspect(set)}")
    {:ok, Keyword.fetch!(opts, :prepared)}
  end

  defp do_run(set, host, dir, app, pkg, artifacts, opts) do
    Logger.info("[mob_ci] booting a CI redroid")

    case step(:boot, fn -> Farm.boot(Keyword.take(opts, [:profile])) end) do
      {:ok, inst} ->
        try do
          deploy_and_probe(set, host, dir, app, pkg, inst, artifacts, opts)
        after
          step(:release, fn -> Farm.release(inst) end)
        end

      {:error, :box_busy} ->
        error(:box_busy)

      {:error, reason} ->
        error({:boot_failed, reason})
    end
  end

  defp host_dir(:sloppy_joe), do: Build.sloppy_joe_dir()
  defp host_dir(:harness), do: Build.harness_root()

  defp deploy_and_probe(set, host, dir, app, pkg, inst, artifacts, opts) do
    Logger.info("[mob_ci] deploying to #{inst.serial}")

    log = if artifacts, do: Path.join(artifacts, "deploy.log")

    case step(:deploy, fn -> Build.deploy(dir, inst.serial, log: log) end) do
      {:conflict, msgs} ->
        # Expected rejection — P1 verifies it; no device probing needed.
        ctx = base_ctx(set, host, dir, app, build_status: {:conflict, msgs})
        finalize(set, Invariants.run(ctx, [:pure, :build]), artifacts, opts)

      {:error, reason} ->
        error({:build_failed, dir, reason})

      :ok ->
        probe(set, host, dir, app, pkg, inst, artifacts, opts)
    end
  end

  defp probe(set, host, dir, app, pkg, inst, artifacts, opts) do
    perms =
      with {:ok, apk} <- Build.locate_apk(dir), {:ok, p} <- Build.read_permissions(apk) do
        p
      else
        _ -> nil
      end

    launch = fn -> Farm.launch(inst, app: app, pkg: pkg, timeout_ms: Keyword.get(opts, :node_timeout_ms, 60_000)) end

    case step(:launch, launch) do
      {:ok, live} ->
        ctx = base_ctx(set, host, dir, app, build_status: :ok, permissions: perms, node: live.node)
        # Everything except P11 (which is post-release).
        results =
          step(:probe, fn -> Invariants.run(ctx, [:pure, :build, :device]) |> Enum.reject(&(&1.id == :p11)) end)

        step(:release_live, fn -> Farm.release(live) end)
        p11 = Invariants.p11(ctx)
        finalize(set, results ++ [p11], artifacts, opts)

      {:error, reason} ->
        error({:launch_failed, reason})
    end
  end

  @doc """
  The layer an orchestration error (a `{:error, reason}` from `run/2`) belongs
  to, so a run that never reached the catalog is still attributed: host
  preparation and native build → `{:build, dir}`; farm admission, boot and app
  launch → `:boot`.
  """
  @spec error_layer(term()) :: MobCi.Result.layer()
  def error_layer({:prepare_failed, dir, _reason}), do: {:build, dir}
  def error_layer({:build_failed, dir, _reason}), do: {:build, dir}
  def error_layer(:box_busy), do: :boot
  def error_layer({:boot_failed, _reason}), do: :boot
  def error_layer({:launch_failed, _reason}), do: :boot
  def error_layer(_other), do: nil

  defp error(reason) do
    Logger.error("[mob_ci] layer=#{inspect(error_layer(reason))} #{inspect(reason, limit: 8)}")
    {:error, reason}
  end

  defp base_ctx(set, host, dir, app, fields) do
    %Context{
      set: set,
      host: host,
      host_dir: dir,
      node: Keyword.get(fields, :node),
      repo: repo_module(app),
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
      showcase_screen: if(host == :generated, do: nil, else: Build.showcase_module(app))
    }
  end

  # The generated host app's Ecto repo: <AppModule>.Repo (e.g. MobCiHarness.Repo).
  defp repo_module(app), do: Module.concat([Macro.camelize(to_string(app)), Repo])

  # A prepared host that knows its cell (MobCi.Host) stamps every result with
  # the set name and version record; the harness and sloppy_joe hosts don't.
  defp stamp_opts(%{set: set_name, versions: versions}, opts),
    do: Keyword.merge(opts, set_name: set_name, versions: versions)

  defp stamp_opts(_prep, opts), do: opts

  defp finalize(set, results, artifacts_dir, opts) do
    results = MobCi.Result.stamp(results, opts[:set_name], opts[:versions])
    Report.write_artifacts(artifacts_dir, set, results)
    IO.puts("\n" <> Report.console(results, title: "mob_ci #{inspect(set)}"))
    if Report.ok?(results), do: {:ok, results}, else: {:fail, results}
  end
end
