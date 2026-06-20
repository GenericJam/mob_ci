defmodule Mix.Tasks.Ci.Device do
  @shortdoc "Run the mob_ci device-invariant catalog against a plugin set"
  @moduledoc """
  The one local entry point — Layer 5's canonical trigger. Every other trigger
  (systemd timer, git hook, Forgejo/GH adapter) is a thin wrapper that checks out
  and calls this.

      mix ci.device                          # the milestone-1 fixed sample set
      mix ci.device --plugins haptic,notes   # an explicit set (mob_ci_ prefix optional)
      mix ci.device --static                 # static composability only, no device/build
      mix ci.device --junit artifacts/junit.xml

  ## Modes

    * `--static` — runs only the manifest-level checks: `cross_validate` (the
      static half of P1) plus the projection summary (expected permission union,
      screen routes, NIF modules, …). Fast, no farm slot, no build. Exit code is
      non-zero when the set has cross-plugin conflicts — usable as a pre-build
      gate in any pipeline today.

    * default (device) — the full P1–P11 run: build the set, lease a farm slot,
      boot, probe, assert, tear down. The build/farm layers (L0–L2) are wired in
      the milestone-1 farm-integration slice; until then this prints the plan and
      runs the static checks, so the command is useful immediately and grows into
      the full run without changing its interface.
  """
  use Mix.Task

  alias MobCi.{Invariants, Plugins, Report}
  alias MobDev.Plugin.Validator

  @switches [plugins: :string, static: :boolean, junit: :string, host: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    set = resolve_set(opts[:plugins])

    Mix.shell().info(plan(set))

    static = run_static(set)

    if opts[:static] do
      finish_static(static, opts)
    else
      Mix.shell().info("""

      Device run (P2–P11) requires the farm layer (L0–L2), landing in the
      milestone-1 farm-integration slice. See decisions/2026-06-19-mob-ci-design.md.
      Ran the static checks above; re-run with --static to gate on them alone.
      """)

      finish_static(static, opts)
    end
  end

  # ── set resolution ──────────────────────────────────────────────────────────

  defp resolve_set(nil), do: Plugins.sample_set()

  defp resolve_set(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn n -> if String.starts_with?(n, "mob_ci_"), do: n, else: "mob_ci_" <> n end)
    |> Enum.map(&String.to_atom/1)
  end

  # ── static composability ────────────────────────────────────────────────────

  defp run_static(set) do
    %{
      set: set,
      conflicts: Validator.cross_validate(Plugins.activated(set)).errors,
      permissions: Plugins.expected_permissions(set) |> MapSet.to_list() |> Enum.sort(),
      nifs: Plugins.expected_nif_modules(set),
      screens: Plugins.expected_screens(set),
      components: Plugins.expected_components(set),
      workers: Plugins.expected_supervised(set)
    }
  end

  defp finish_static(static, opts) do
    Mix.shell().info(static_report(static))

    maybe_write_junit(opts[:junit], static)

    if static.conflicts != [] do
      Mix.shell().error("\nStatic gate: #{length(static.conflicts)} cross-plugin conflict(s) — build would be rejected.")
      exit({:shutdown, 1})
    else
      Mix.shell().info("\nStatic gate: set composes cleanly.")
    end
  end

  defp static_report(s) do
    """

    ── static composability ──────────────────────────────────────
      activated:   #{Enum.map_join(s.set, ", ", &Atom.to_string/1)}
      NIF modules: #{fmt(s.nifs)}
      screens:     #{fmt(s.screens)}
      components:  #{fmt(s.components)}
      workers:     #{fmt(s.workers)}
      permissions: #{fmt(s.permissions)}
      conflicts:   #{if s.conflicts == [], do: "none", else: "\n        - " <> Enum.join(s.conflicts, "\n        - ")}
    """
  end

  defp fmt([]), do: "(none)"
  defp fmt(list), do: Enum.map_join(list, ", ", &to_string/1)

  defp maybe_write_junit(nil, _static), do: :ok

  defp maybe_write_junit(path, static) do
    # In --static mode the only assertable invariant is P1's static half; emit it
    # so a pipeline gets a JUnit artifact even from the fast path.
    result =
      if static.conflicts == [],
        do: MobCi.Result.pass(:p1_static, "set composes cleanly (cross_validate)"),
        else: MobCi.Result.fail(:p1_static, "cross-plugin conflicts", Enum.join(static.conflicts, "; "), static.conflicts)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Report.junit([result], suite: "mob_ci.static"))
    Mix.shell().info("wrote JUnit → #{path}")
  end

  # ── the plan (always printed) ────────────────────────────────────────────────

  defp plan(set) do
    rows =
      Enum.map_join(Invariants.all(), "\n", fn {id, title, layer} ->
        "  #{String.pad_trailing(to_string(id), 4)} [#{String.pad_trailing(to_string(layer), 6)}] #{title}"
      end)

    """
    ── mob_ci device invariant catalog ───────────────────────────
      set: #{Enum.map_join(set, ", ", &Atom.to_string/1)}

    #{rows}
    """
  end
end
