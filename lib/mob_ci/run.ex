defmodule MobCi.Run do
  @moduledoc """
  The orchestration spine: build → lease → probe → assert → report → release for
  one activated plugin set. Always tears the lease down (guaranteed `release`),
  so a crashed run never leaks a farm slot away from staging.

  The flow maps to the layers: `MobCi.Build` (L2) → `MobCi.Farm` (L0/L1) →
  `MobCi.Probe`/`MobCi.Invariants` (L3) → `MobCi.Report` (surfaced by L5). This is
  the `:integration` entry; the static, no-device path lives in `mix ci.device
  --static`.
  """

  require Logger
  alias MobCi.{Build, Context, Farm, Invariants, Report}

  @doc """
  Run the full P1–P11 catalog against `set`.

  Opts: `:host` (`:harness` | `:sloppy_joe`), `:artifacts_dir`, `:profile`.
  Returns `{:ok, results}` (all pass/skip) or `{:fail, results}`; infra failures
  (build error, box busy) come back as `{:error, reason}` so a sweep can
  distinguish a product bug from a flaky slot.
  """
  @spec run([atom()], keyword()) :: {:ok, [MobCi.Result.t()]} | {:fail, [MobCi.Result.t()]} | {:error, term()}
  def run(set, opts \\ []) do
    host = Keyword.get(opts, :host, :harness)
    artifacts = Keyword.get(opts, :artifacts_dir)

    Logger.info("[mob_ci] building #{inspect(set)} (host: #{host})")
    artifact = Build.build(set, opts)

    base_ctx = %Context{
      set: set,
      host: host,
      build: Map.take(artifact, [:status, :apk, :permissions]) |> Map.put_new(:conflicts, []),
      nif_probes: Context.default_nif_probes(),
      migration_tables: Context.default_migration_tables(),
      worker_names: Context.default_worker_names(),
      repo: repo_for(host),
      artifacts_dir: artifacts
    }

    case artifact.status do
      {:conflict, _} ->
        # Expected rejection — P1 verifies it; no device needed.
        finalize(set, Invariants.run(base_ctx, [:pure, :build]), artifacts)

      {:error, reason} ->
        {:error, {:build_failed, reason}}

      :ok ->
        run_on_device(base_ctx, artifact, opts)
    end
  end

  defp run_on_device(ctx, artifact, opts) do
    lease_opts = [
      apk: artifact.apk,
      otp_dir: artifact.otp_dir,
      app: artifact.app,
      profile: Keyword.get(opts, :profile, {1080, 2340, 440})
    ]

    case Farm.lease(lease_opts) do
      {:ok, lease} ->
        try do
          live = %{ctx | node: lease.node}
          results = Invariants.run(live, [:pure, :build, :device])
          # P11 checks teardown — evaluate it after release, against the now-gone node.
          {core, _} = Enum.split_with(results, &(&1.id != :p11))
          Farm.release(lease)
          p11 = Invariants.p11(%{live | node: lease.node})
          finalize(ctx.set, core ++ [p11], ctx.artifacts_dir)
        after
          Farm.release(lease)
        end

      {:error, :box_busy} ->
        {:error, :box_busy}

      {:error, reason} ->
        {:error, {:lease_failed, reason}}
    end
  end

  defp finalize(set, results, artifacts_dir) do
    Report.write_artifacts(artifacts_dir, set, results)
    IO.puts(Report.console(results, title: "mob_ci #{inspect(set)}"))
    if Report.ok?(results), do: {:ok, results}, else: {:fail, results}
  end

  # The host app's Ecto repo for P8's table checks. Confirmed per host on wiring.
  defp repo_for(:sloppy_joe), do: nil
  defp repo_for(:harness), do: nil
end
