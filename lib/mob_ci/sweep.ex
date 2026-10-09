defmodule MobCi.Sweep do
  @moduledoc """
  The property sweep over plugin-activation subsets — the reason mob_ci exists.
  The activation space is 2^N; you can't enumerate it, so generate it, and on a
  failure **shrink to the minimal offending subset** (usually a pair).

  Two tiers, because a device run costs minutes and a manifest check costs
  microseconds:

    * **static sweep** (`static_findings/1`) — generate subsets, check that
      `Validator.cross_validate/1` flags a conflict *iff* the subset actually
      collides. Catches validator soundness bugs across the whole space in
      milliseconds, no device. This is also a real `ExUnitProperties` property
      (see the test).

    * **device sweep** (`device_sweep/1`) — sample K clean subsets, run each
      through the full P1–P11 catalog on the farm, and `minimize/2` any failure
      to the smallest subset that still fails.

  `minimize/2` is a pure greedy delta-debug (oracle injected), so it's
  unit-tested with a synthetic oracle and reused for both the StreamData shrink
  and the expensive device shrink.
  """

  require Logger
  alias MobCi.{Build, Context, Farm, Invariants, Plugins}
  alias MobDev.Plugin.Validator

  # Static pool includes the manifest-only clash pair (cross_validate reads
  # manifests directly — no build needed), so the sweep exercises a real conflict.
  @static_pool [:mob_ci_palette, :mob_ci_haptic, :mob_ci_gauge, :mob_ci_notes, :mob_ci_pulse,
                :mob_ci_clash_a, :mob_ci_clash_b]

  # Device pool is the buildable fixtures only (clash pair is manifest-only — no
  # mix.exs/lib, can't be a path dep).
  @device_pool [:mob_ci_palette, :mob_ci_haptic, :mob_ci_gauge, :mob_ci_notes, :mob_ci_pulse]

  def static_pool, do: @static_pool
  def device_pool, do: @device_pool

  @doc "A StreamData generator of subsets of `pool` (shrinks toward smaller subsets)."
  @spec subset_gen([atom()]) :: StreamData.t([atom()])
  def subset_gen(pool) do
    StreamData.list_of(StreamData.boolean(), length: length(pool))
    |> StreamData.map(fn flags -> for {p, true} <- Enum.zip(pool, flags), do: p end)
  end

  @doc """
  Greedy delta-debug: the smallest subset of `set` for which `oracle` still
  returns true (reproduces). Pure given the oracle; repeats to a fixpoint so the
  result is 1-minimal (no single element removable). Precondition: `oracle.(set)`.
  """
  @spec minimize([atom()], ([atom()] -> boolean())) :: [atom()]
  def minimize(set, oracle) do
    reduced =
      Enum.reduce(set, set, fn elem, current ->
        candidate = current -- [elem]
        if candidate != [] and oracle.(candidate), do: candidate, else: current
      end)

    if reduced == set, do: set, else: minimize(reduced, oracle)
  end

  @doc """
  Does this subset genuinely collide? The only colliding pair among the fixtures
  is the deliberate clash pair (same route/NIF/component). Independent of
  `cross_validate` so the static property isn't circular — if a newly-added
  fixture accidentally collides with another, the property fails and points at it.
  """
  @spec colliding?([atom()]) :: boolean()
  def colliding?(subset), do: :mob_ci_clash_a in subset and :mob_ci_clash_b in subset

  @doc "Does `cross_validate` report a conflict for this subset?"
  @spec rejected?([atom()]) :: boolean()
  def rejected?(subset), do: Validator.cross_validate(Plugins.activated(subset)).errors != []

  @doc """
  Static sweep: check `cross_validate` agrees with `colliding?/1` for each of
  `count` generated subsets. Returns the list of *inconsistencies* (empty = the
  validator is sound over the sampled space), each minimized to the offending core.
  """
  @spec static_findings(keyword()) :: [%{subset: [atom()], cross_validate: boolean(), colliding: boolean(), minimal: [atom()]}]
  def static_findings(opts \\ []) do
    count = Keyword.get(opts, :count, 200)
    pool = Keyword.get(opts, :pool, @static_pool)

    subset_gen(pool)
    |> Enum.take(count)
    |> Enum.filter(fn s -> rejected?(s) != colliding?(s) end)
    |> Enum.map(fn s ->
      # Minimize toward the smallest subset that still disagrees.
      minimal = minimize(s, fn sub -> rejected?(sub) != colliding?(sub) end)
      %{subset: s, cross_validate: rejected?(s), colliding: colliding?(s), minimal: minimal}
    end)
    |> Enum.uniq_by(& &1.minimal)
  end

  @doc """
  Static conflict sweep over a pool of REAL plugins (a version row's set):
  sample `count` subsets, keep the ones `cross_validate` rejects, and shrink
  each to its minimal rejected core — the pairs (usually) that can't be
  activated together. Returns the distinct minimal cores; empty means the
  sampled space composes.
  """
  @spec static_conflicts(keyword()) :: [[atom()]]
  def static_conflicts(opts) do
    count = Keyword.get(opts, :count, 200)
    pool = Keyword.fetch!(opts, :pool)

    [pool | Enum.take(subset_gen(pool), count)]
    |> Enum.filter(&rejected?/1)
    |> Enum.map(&minimize(&1, fn sub -> rejected?(sub) end))
    |> Enum.uniq()
    |> Enum.sort_by(&{length(&1), &1})
  end

  @doc """
  Device sweep: run `:runs` sampled subsets of the device pool through the full
  P1–P11 catalog on one reused harness + container, then shrink each failing
  subset to its minimal core. Returns `%{ran: [{subset, verdict}], minimal_failures}`
  or `{:error, reason}` if the farm couldn't be acquired.

  `:run_subset` (a `subset -> {:pass|:fail|:error, results}` fn) can be injected
  for testing; the default builds + boots for real. `:cell` (a `MobCi.Cell`
  plan) sweeps the cell's plugins on a host `MobCi.Host.generate/4` builds for
  the row instead of the fixture harness; every result is then stamped with
  the set name and version record.
  """
  @spec device_sweep(keyword()) :: %{ran: list(), minimal_failures: [[atom()]]} | {:error, term()}
  def device_sweep(opts \\ []) do
    cell = Keyword.get(opts, :cell)
    pool = if cell, do: cell.plugins, else: Keyword.get(opts, :pool, @device_pool)
    subsets = Keyword.get(opts, :subsets) || sample_subsets(pool, Keyword.get(opts, :runs, 4))

    case Keyword.get(opts, :run_subset) do
      run when is_function(run, 1) ->
        do_sweep(subsets, run)

      nil ->
        with {:ok, harness} <- prepare_host(cell, pool, opts),
             {:ok, inst} <- Farm.boot(Keyword.take(opts, [:profile])) do
          try do
            do_sweep(subsets, fn subset -> run_one(harness, inst, subset) end)
          after
            Farm.release(inst)
          end
        end
    end
  end

  # The fixture harness activates via Build.activate/3 (mob.exs + P5 showcase);
  # a generated host via MobCi.Host.activate/2 (mob.exs with trust) and has no
  # showcase screen.
  defp prepare_host(nil, pool, _opts) do
    with {:ok, h} <- Build.prepare_sweep_harness(pool: pool) do
      {:ok, Map.merge(h, %{activate: fn dir, subset, app -> Build.activate(dir, subset, app) end, showcase: true, set: nil, versions: nil})}
    end
  end

  defp prepare_host(cell, pool, opts) do
    with {:ok, h} <- MobCi.Host.generate(cell.spec, pool, cell.resolved, Keyword.take(opts, [:fresh])) do
      {:ok, Map.merge(h, %{activate: fn _dir, subset, _app -> MobCi.Host.activate(h, subset) end, showcase: false})}
    end
  end

  defp do_sweep(subsets, run_subset) do
    ran =
      for subset <- subsets do
        Logger.info("[mob_ci.sweep] #{inspect(subset)}")
        {subset, run_subset.(subset)}
      end

    minimal =
      for {subset, {:fail, _}} <- ran,
          do: minimize(subset, fn sub -> match?({:fail, _}, run_subset.(sub)) end)

    %{ran: ran, minimal_failures: Enum.uniq(minimal)}
  end

  # Sample N distinct non-empty subsets, always including the full pool.
  defp sample_subsets(pool, n) do
    sampled =
      subset_gen(pool)
      |> Stream.filter(&(&1 != []))
      |> Stream.uniq()
      |> Enum.take(n)

    Enum.uniq([pool | sampled])
  end

  # One subset through the catalog on the shared harness+container.
  defp run_one(harness, inst, subset) do
    harness.activate.(harness.dir, subset, harness.app)

    case Build.deploy(harness.dir, inst.serial) do
      {:conflict, msgs} ->
        {:fail, [MobCi.Result.fail(:p1, "build outcome", "rejected: #{Enum.join(msgs, "; ")}")]}

      {:error, reason} ->
        {:error, reason}

      :ok ->
        probe_subset(harness, inst, subset)
    end
  end

  defp probe_subset(harness, inst, subset) do
    perms =
      with {:ok, apk} <- Build.locate_apk(harness.dir), {:ok, p} <- Build.read_permissions(apk),
           do: p, else: (_ -> nil)

    case Farm.launch(inst, app: harness.app, pkg: harness.pkg) do
      {:ok, live} ->
        ctx = %Context{
          set: subset,
          host: :harness,
          node: live.node,
          repo: Module.concat([Macro.camelize(to_string(harness.app)), Repo]),
          build: %{status: :ok, apk: nil, permissions: perms, conflicts: []},
          nif_probes: Map.merge(Context.default_nif_probes(), MobCi.DeviceCaps.nif_probes(subset)),
          migration_tables: Context.default_migration_tables(),
          worker_names: Context.default_worker_names(),
          screen_caps: MobCi.DeviceCaps.screen_caps(subset),
          showcase_screen: if(harness.showcase, do: Build.showcase_module(harness.app))
        }

        results =
          Invariants.run(ctx, [:pure, :build, :device])
          |> Enum.reject(&(&1.id == :p11))
          |> MobCi.Result.stamp(harness.set, harness.versions)

        {verdict(results), results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verdict(results) do
    cond do
      Enum.any?(results, &(&1.status == :fail)) -> :fail
      Enum.any?(results, &(&1.status == :error)) -> :error
      true -> :pass
    end
  end

  @doc "One-line console summary of a device-sweep result."
  @spec summarize(%{ran: list(), minimal_failures: [[atom()]]}) :: String.t()
  def summarize(%{ran: ran, minimal_failures: minimal}) do
    counts = Enum.frequencies_by(ran, fn {_s, v} -> elem_verdict(v) end)

    lines =
      Enum.map(ran, fn {s, v} ->
        "  #{glyph(elem_verdict(v))} #{inspect(s)}#{verdict_note(v)}"
      end)

    footer =
      if minimal == [],
        do: "no failing subsets",
        else: "minimal failing subsets:\n" <> Enum.map_join(minimal, "\n", &"  ✗ #{inspect(&1)}")

    Enum.join(lines, "\n") <> "\n\n" <> "verdicts: #{inspect(counts)}\n" <> footer
  end

  defp elem_verdict({v, _}), do: v
  defp elem_verdict(v), do: v

  defp verdict_note({:error, reason}), do: "  (error: #{inspect(reason, limit: 5)})"
  defp verdict_note({:fail, results}) do
    bad = for r <- List.wrap(results), r.status == :fail, do: r.id
    "  (failed: #{inspect(bad)})"
  end

  defp verdict_note(_), do: ""
  defp glyph(:pass), do: "✓"
  defp glyph(:fail), do: "✗"
  defp glyph(_), do: "!"
end
