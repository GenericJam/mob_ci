defmodule MobCi.Invariants do
  @moduledoc """
  The P1–P11 invariant catalog. Each `p<N>/1` takes a `%MobCi.Context{}` and
  returns a `%MobCi.Result{}`. `all/0` lists them with the layer each needs
  (`:pure` — manifests only; `:build` — the L2 build output; `:device` — a live
  leased node), so the runner can run the offline ones in unit tests and gate
  the device ones behind `:integration`.

  The design rule: an invariant returns `:fail` only when it was genuinely
  checkable and the product misbehaved. Anything that prevents the check from
  running (dead node, RPC failure, missing build artifact) is `:error`; anything
  not applicable to the activated set is `:skip`. That separation keeps farm
  flakiness out of the product-bug signal.
  """

  alias MobCi.{Context, Plugins, Probe, Result}
  alias MobDev.Plugin.Validator

  @catalog [
    {:p1, "build outcome matches static conflict analysis", :build},
    {:p2, "BEAM boots and the node registers", :device},
    {:p3, "every activated NIF loads on device", :device},
    {:p4, "every declared screen pushes and renders", :device},
    {:p5, "every UI component renders without a dispatch crash", :device},
    {:p6, "merged APK permissions equal the union of activated plugins'", :build},
    {:p7, "on-device runtime manifest equals the activated set exactly", :device},
    {:p8, "tier-3 migrations applied on device", :device},
    {:p9, "tier-4 supervised workers alive and on_start ran", :device},
    {:p10, "interaction sweep leaves the BEAM alive", :device},
    {:p11, "release tears down cleanly and frees the slot", :device}
  ]

  @doc "The catalog as `{id, title, layer}` tuples."
  @spec all() :: [{atom(), String.t(), :pure | :build | :device}]
  def all, do: @catalog

  @doc "Run the invariants whose layer is in `layers` (default: all) against `ctx`."
  @spec run(Context.t(), [:pure | :build | :device]) :: [Result.t()]
  def run(ctx, layers \\ [:pure, :build, :device]) do
    for {id, _title, layer} <- @catalog, layer in layers, do: apply(__MODULE__, id, [ctx])
  end

  # ── P1 — build outcome matches static conflict analysis ──────────────────────
  #
  # The contract MOB_PLUGINS.md promises: a conflicting set fails the build at
  # *validate* with a named conflict, and a clean set builds. So cross-check the
  # static `cross_validate` verdict against what the build actually did. This is
  # the one invariant that's meaningful even before a device boots — it catches a
  # gap in `cross_validate` (conflict it missed → build succeeded or died at the
  # linker) and a false positive (clean set it wrongly rejected).
  def p1(%Context{set: set, build: build}) do
    conflicts = Validator.cross_validate(Plugins.activated(set)).errors

    case {conflicts, build.status} do
      {[], :ok} ->
        Result.pass(:p1, title(:p1), "clean set; build ok")

      {[], {:conflict, msgs}} ->
        Result.fail(:p1, title(:p1), "cross_validate found no conflict but build reported one", msgs)

      {[], {:error, reason}} ->
        Result.fail(:p1, title(:p1), "clean set failed to build", reason)

      {[_ | _] = cs, {:conflict, msgs}} ->
        if conflicts_named?(cs, msgs),
          do: Result.pass(:p1, title(:p1), "conflicting set rejected with named conflicts"),
          else: Result.fail(:p1, title(:p1), "build rejected the set but didn't name the conflicts", %{expected: cs, got: msgs})

      {[_ | _] = cs, :ok} ->
        Result.fail(:p1, title(:p1), "conflicting set built anyway — cross_validate/build gap", cs)

      {_cs, :unknown} ->
        Result.error(:p1, title(:p1), "build status unknown (build layer didn't run)")

      {_cs, {:error, reason}} ->
        # Conflicting set that failed for a non-conflict reason — can't attribute.
        Result.error(:p1, title(:p1), "conflicting set errored without a conflict verdict", reason)
    end
  end

  defp conflicts_named?(expected, got) do
    blob = Enum.join(got, "\n")
    Enum.all?(expected, fn e -> String.contains?(blob, e) or substantive_overlap?(e, blob) end)
  end

  # cross_validate phrasings include the conflicting value (a route/atom/module);
  # accept the build's message if it at least surfaces that value.
  defp substantive_overlap?(expected, blob) do
    expected
    |> String.split(~r/[^A-Za-z0-9_\/]+/, trim: true)
    |> Enum.filter(&(String.length(&1) > 3))
    |> Enum.any?(&String.contains?(blob, &1))
  end

  # ── P2 — BEAM boots and the node registers ───────────────────────────────────
  def p2(%Context{node: nil}), do: Result.error(:p2, title(:p2), "no node leased")

  def p2(%Context{node: node}) do
    if Probe.node_up?(node),
      do: Result.pass(:p2, title(:p2), "#{node} reachable"),
      else: Result.fail(:p2, title(:p2), "#{node} did not register / is unreachable")
  end

  # ── P3 — every activated NIF loads on device ─────────────────────────────────
  def p3(%Context{node: nil}), do: Result.error(:p3, title(:p3), "no node leased")

  def p3(%Context{set: set, node: node, nif_probes: probes}) do
    Plugins.expected_nif_modules(set)
    |> Enum.map(fn nif ->
      cond do
        not Probe.module_loaded?(node, nif) ->
          Result.fail(:p3_item, "#{nif}", "#{nif} not loaded on device")

        Map.has_key?(probes, nif) ->
          case Probe.nif_initialized?(node, nif, probes[nif]) do
            :loaded -> Result.pass(:p3_item, "#{nif}", "#{nif} initialized")
            :not_loaded -> Result.fail(:p3_item, "#{nif}", "#{nif} stub loaded but NIF not linked")
            {:error, reason} -> Result.error(:p3_item, "#{nif}", "probe failed", reason)
          end

        true ->
          # Loaded, but no probe export registered — can't prove native init.
          Result.skip(:p3_item, "#{nif}", "#{nif} loaded; no probe export to confirm native init")
      end
    end)
    |> Result.rollup(:p3, title(:p3))
  end

  # ── P4 — every declared screen pushes and renders ────────────────────────────
  def p4(%Context{node: nil}), do: Result.error(:p4, title(:p4), "no node leased")

  def p4(%Context{set: set, node: node, screen_caps: caps}) do
    Plugins.expected_screen_modules(set)
    |> Enum.map(fn screen ->
      case Probe.push_and_read(node, screen) do
        {:ok, %{screen: ^screen, assigns: assigns}} when is_map(assigns) ->
          Result.pass(:p4_item, "#{screen}", "rendered")

        {:ok, %{screen: other}} ->
          degrade_or_fail(screen, caps, "pushed #{screen} but #{other} is showing")

        {:error, reason} ->
          degrade_or_fail(screen, caps, "push/render failed: #{inspect(reason)}")
      end
    end)
    |> Result.rollup(:p4, title(:p4))
  end

  # A screen that doesn't render is a fail — UNLESS device_caps marks it
  # :hardware_degraded (no camera/GPS/biometric on a headless emulator), in which
  # case a graceful non-render is an expected skip. A genuine BEAM crash would
  # have taken the node down and surfaces in P2/P10 regardless.
  defp degrade_or_fail(screen, caps, detail) do
    case Map.get(caps, screen) do
      :hardware_degraded -> Result.skip(:p4_item, "#{screen}", "degraded (expected, headless): #{detail}")
      _ -> Result.fail(:p4_item, "#{screen}", detail)
    end
  end

  # ── P5 — every UI component renders without a dispatch crash ──────────────────
  def p5(%Context{set: set} = ctx) do
    components = Plugins.expected_components(set)

    cond do
      components == [] ->
        Result.skip(:p5, title(:p5), "no UI components in this set")

      ctx.node == nil ->
        Result.error(:p5, title(:p5), "no node leased")

      ctx.showcase_screen == nil ->
        Result.error(:p5, title(:p5), "no showcase screen built (harness didn't emit one)")

      true ->
        case Probe.push_and_read(ctx.node, ctx.showcase_screen) do
          {:ok, %{assigns: assigns}} when is_map(assigns) ->
            Result.pass(:p5, title(:p5), "showcase of #{length(components)} component(s) rendered")

          {:error, reason} ->
            Result.fail(:p5, title(:p5), "component showcase crashed", reason)
        end
    end
  end

  # ── P6 — merged APK permissions == union of activated plugins' ────────────────
  def p6(%Context{set: set, build: %{permissions: nil}}) do
    if Plugins.expected_permissions(set) |> Enum.empty?(),
      do: Result.skip(:p6, title(:p6), "no permissions expected and none read"),
      else: Result.error(:p6, title(:p6), "build layer didn't read APK permissions")
  end

  def p6(%Context{set: set, build: %{permissions: actual}}) do
    expected = Plugins.expected_permissions(set)
    missing = MapSet.difference(expected, actual)

    # Subset, not equality: the APK also carries the app's baseline permissions
    # (INTERNET, …) that aren't plugin-contributed. The invariant is that every
    # *activated-plugin* permission got merged in. The over-merge direction (a
    # deactivated plugin's permission leaking) needs a zero-plugin baseline build
    # to detect cleanly and is better caught at the host-side merge layer.
    cond do
      MapSet.size(missing) > 0 ->
        Result.fail(:p6, title(:p6), "activated-plugin permissions missing from the APK", %{
          missing: MapSet.to_list(missing)
        })

      true ->
        Result.pass(:p6, title(:p6), "all #{MapSet.size(expected)} activated-plugin permission(s) present")
    end
  end

  # ── P7 — on-device runtime manifest == activated set exactly ──────────────────
  def p7(%Context{node: nil}), do: Result.error(:p7, title(:p7), "no node leased")

  def p7(%Context{set: set, node: node}) do
    expected = MapSet.new(Plugins.expected_screens(set))

    case Probe.runtime_screens(node) do
      {:ok, screens} ->
        actual = screens |> runtime_routes() |> MapSet.new()

        cond do
          MapSet.equal?(expected, actual) ->
            Result.pass(:p7, title(:p7), "#{MapSet.size(expected)} screen route(s) match the activated set")

          true ->
            Result.fail(:p7, title(:p7), "runtime manifest drifted from activated set", %{
              missing: MapSet.difference(expected, actual) |> MapSet.to_list(),
              leaked: MapSet.difference(actual, expected) |> MapSet.to_list()
            })
        end

      {:error, reason} ->
        Result.error(:p7, title(:p7), "could not read runtime manifest", reason)
    end
  end

  # Mob.Plugins.screens/0 returns the runtime manifest's screen list; normalize to
  # the set of default_routes regardless of whether entries are maps or structs.
  defp runtime_routes(screens) when is_list(screens) do
    for s <- screens, route = route_of(s), is_binary(route), do: route
  end

  defp runtime_routes(_), do: []

  defp route_of(%{default_route: r}), do: r
  defp route_of(%{route: r}), do: r
  defp route_of({_mod, r}) when is_binary(r), do: r
  defp route_of(_), do: nil

  # ── P8 — tier-3 migrations applied on device ─────────────────────────────────
  def p8(%Context{set: set, node: node, repo: repo, migration_tables: tables}) do
    subjects =
      for name <- set, ts = Map.get(tables, name), is_list(ts), t <- ts, do: {name, t}

    cond do
      subjects == [] ->
        Result.skip(:p8, title(:p8), "no migration-bearing plugin in this set")

      node == nil or repo == nil ->
        Result.error(:p8, title(:p8), "no node/repo to check tables against")

      true ->
        subjects
        |> Enum.map(fn {name, table} ->
          case Probe.table_exists?(node, repo, table) do
            {:ok, true} -> Result.pass(:p8_item, table, "#{name}: #{table} exists")
            {:ok, false} -> Result.fail(:p8_item, table, "#{name}: migration table #{table} missing")
            {:error, reason} -> Result.error(:p8_item, table, "table check failed", reason)
          end
        end)
        |> Result.rollup(:p8, title(:p8))
    end
  end

  # ── P9 — tier-4 supervised workers alive and on_start ran ─────────────────────
  def p9(%Context{set: set, node: node, worker_names: names}) do
    workers = for name <- set, w = Map.get(names, name), do: {name, w}

    cond do
      workers == [] ->
        Result.skip(:p9, title(:p9), "no supervised-worker plugin in this set")

      node == nil ->
        Result.error(:p9, title(:p9), "no node leased")

      true ->
        workers
        |> Enum.map(fn {plugin, worker} ->
          if Probe.process_alive?(node, worker) do
            # on_start having run is observable through readable settings.
            case Probe.get_setting(node, plugin, :enabled) do
              {:ok, _} -> Result.pass(:p9_item, "#{worker}", "alive; settings readable")
              {:error, reason} -> Result.fail(:p9_item, "#{worker}", "alive but settings unreadable", reason)
            end
          else
            Result.fail(:p9_item, "#{worker}", "supervised worker #{worker} not alive")
          end
        end)
        |> Result.rollup(:p9, title(:p9))
    end
  end

  # ── P10 — interaction sweep leaves the BEAM alive ────────────────────────────
  def p10(%Context{node: nil}), do: Result.error(:p10, title(:p10), "no node leased")

  def p10(%Context{set: set, node: node}) do
    screens = Plugins.expected_screen_modules(set)

    # Walk every activated screen in turn, then confirm the node survived. The
    # property-sweep (milestone 2) replaces this fixed walk with a generated,
    # shrinkable tap/nav sequence — same invariant, richer input.
    Enum.each(screens, fn s -> Probe.push_and_read(node, s) end)

    if Probe.node_up?(node),
      do: Result.pass(:p10, title(:p10), "survived a walk over #{length(screens)} screen(s)"),
      else: Result.fail(:p10, title(:p10), "BEAM died during the interaction walk")
  end

  # ── P11 — release tears down cleanly and frees the slot ──────────────────────
  # Checked post-release by the runner, which passes a node it expects to be
  # *gone*. Inverted polarity: success means the node is no longer reachable.
  def p11(%Context{node: nil}), do: Result.skip(:p11, title(:p11), "nothing leased")

  def p11(%Context{node: node}) do
    if Probe.node_up?(node),
      do: Result.fail(:p11, title(:p11), "#{node} still reachable after release"),
      else: Result.pass(:p11, title(:p11), "#{node} torn down")
  end

  defp title(id) do
    {_id, t, _layer} = Enum.find(@catalog, fn {i, _, _} -> i == id end)
    t
  end
end
