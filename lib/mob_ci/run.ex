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
  alias MobCi.{Build, Context, Farm, Invariants, Report}

  @spec run([atom()], keyword()) ::
          {:ok, [MobCi.Result.t()]} | {:fail, [MobCi.Result.t()]} | {:error, term()}
  def run(set, opts \\ []) do
    host = Keyword.get(opts, :host, :harness)
    artifacts = Keyword.get(opts, :artifacts_dir)

    case prepare(host, set, opts) do
      {:ok, prep} ->
        # Restore any transient host mutation (e.g. sloppy_joe's swapped mob.exs)
        # no matter how the run exits.
        cleanup = Map.get(prep, :cleanup, fn -> :ok end)

        try do
          do_run(set, host, prep.dir, prep.app, prep.pkg, artifacts, opts)
        after
          cleanup.()
        end

      {:error, _} = err ->
        err
    end
  end

  defp prepare(:harness, set, opts) do
    Logger.info("[mob_ci] preparing harness for #{inspect(set)}")
    Build.prepare_harness(set, opts)
  end

  defp prepare(:sloppy_joe, set, _opts) do
    Logger.info("[mob_ci] preparing sloppy_joe (realism gate) for #{inspect(set)}")
    Build.prepare_sloppy_joe(set)
  end

  defp do_run(set, host, dir, app, pkg, artifacts, opts) do
    Logger.info("[mob_ci] booting a CI redroid")

    case Farm.boot(Keyword.take(opts, [:profile])) do
      {:ok, inst} ->
        try do
          deploy_and_probe(set, host, dir, app, pkg, inst, artifacts, opts)
        after
          Farm.release(inst)
        end

      {:error, :box_busy} ->
        {:error, :box_busy}

      {:error, reason} ->
        {:error, {:boot_failed, reason}}
    end
  end

  defp deploy_and_probe(set, host, dir, app, pkg, inst, artifacts, opts) do
    Logger.info("[mob_ci] deploying to #{inst.serial}")

    case Build.deploy(dir, inst.serial) do
      {:conflict, msgs} ->
        # Expected rejection — P1 verifies it; no device probing needed.
        ctx = base_ctx(set, host, app, build_status: {:conflict, msgs})
        finalize(set, Invariants.run(ctx, [:pure, :build]), artifacts)

      {:error, reason} ->
        {:error, {:build_failed, reason}}

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

    case Farm.launch(inst, app: app, pkg: pkg, timeout_ms: Keyword.get(opts, :node_timeout_ms, 60_000)) do
      {:ok, live} ->
        ctx = base_ctx(set, host, app, build_status: :ok, permissions: perms, node: live.node)
        # Everything except P11 (which is post-release).
        results = Invariants.run(ctx, [:pure, :build, :device]) |> Enum.reject(&(&1.id == :p11))
        Farm.release(live)
        p11 = Invariants.p11(ctx)
        finalize(set, results ++ [p11], artifacts)

      {:error, reason} ->
        {:error, {:launch_failed, reason}}
    end
  end

  defp base_ctx(set, host, app, fields) do
    %Context{
      set: set,
      host: host,
      node: Keyword.get(fields, :node),
      repo: repo_module(app),
      build: %{
        status: Keyword.get(fields, :build_status, :unknown),
        apk: nil,
        permissions: Keyword.get(fields, :permissions),
        conflicts: []
      },
      nif_probes: Context.default_nif_probes(),
      migration_tables: Context.default_migration_tables(),
      worker_names: Context.default_worker_names(),
      showcase_screen: Build.showcase_module(app)
    }
  end

  # The generated host app's Ecto repo: <AppModule>.Repo (e.g. MobCiHarness.Repo).
  defp repo_module(app), do: Module.concat([Macro.camelize(to_string(app)), Repo])

  defp finalize(set, results, artifacts_dir) do
    Report.write_artifacts(artifacts_dir, set, results)
    IO.puts("\n" <> Report.console(results, title: "mob_ci #{inspect(set)}"))
    if Report.ok?(results), do: {:ok, results}, else: {:fail, results}
  end
end
