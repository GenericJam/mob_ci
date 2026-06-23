defmodule Mix.Tasks.Ci.Device do
  @shortdoc "Run the mob_ci device-invariant catalog against a plugin set"
  @moduledoc """
  The one local entry point — Layer 5's canonical trigger. Every other trigger
  (systemd timer, git hook, Forgejo/GH adapter) is a thin wrapper that checks out
  and calls this.

      mix ci.device                          # full P1–P11 on the harness sample set
      mix ci.device --static                 # static composability only, no device/build
      mix ci.device --plugins haptic,notes   # an explicit harness set (mob_ci_ prefix optional)
      mix ci.device --host sloppy_joe        # realism gate: the real app's buildable set
      mix ci.device --host sloppy_joe --plugins touch,notify
      mix ci.device --artifacts artifacts/ci # JUnit + summary.json destination

  ## Modes

    * `--static` — runs only the manifest-level checks: `cross_validate` (the
      static half of P1) plus the projection summary (expected permission union,
      screen routes, NIF modules, …). Fast, no farm slot, no build. Exit code is
      non-zero when the set has cross-plugin conflicts — the fast pre-build gate a
      git hook can run on every push.

    * default (device) — the full P1–P11 run: build the set, lease a farm slot,
      boot, deploy, probe, assert, tear down (`MobCi.Run.run/2`). Self-starts
      distribution (`mob_ci@127.0.0.1`, cookie `mob_secret`) so it works as a plain
      `mix` invocation — no `elixir --name` wrapper needed. Exit 0 on pass, 1 on a
      failing invariant, 2 on an orchestration error (boot/build/launch). Best
      scheduled in a low-traffic window (each device build is ~minutes); the
      systemd timer adapter does exactly that.
  """
  use Mix.Task

  alias MobCi.{Build, DeviceCaps, Dist, Invariants, Plugins, Report, Run}
  alias MobDev.Plugin.Validator

  @switches [plugins: :string, static: :boolean, junit: :string, host: :string, artifacts: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    host = parse_host(opts[:host])
    set = resolve_set(opts[:plugins], host)

    Mix.shell().info(plan(set, host))

    if opts[:static] do
      finish_static(run_static(set), opts)
    else
      finish_device(set, host, opts)
    end
  end

  # ── host + set resolution ─────────────────────────────────────────────────────

  @doc false
  def parse_host(nil), do: :harness
  def parse_host("harness"), do: :harness
  def parse_host("sloppy_joe"), do: :sloppy_joe

  def parse_host(other) do
    Mix.raise("unknown --host #{inspect(other)} (expected: harness | sloppy_joe)")
  end

  # No --plugins: the host's default set. Harness → the fixture sample; sloppy_joe
  # → its real buildable plugins (screencast excluded, see device_caps F4).
  @doc false
  def resolve_set(nil, :harness), do: Plugins.sample_set()
  def resolve_set(nil, :sloppy_joe), do: DeviceCaps.buildable(Build.sloppy_joe_plugins())

  # Explicit --plugins: a shorthand CSV. Harness names get the `mob_ci_` prefix,
  # sloppy_joe names the `mob_` prefix, when not already qualified.
  def resolve_set(csv, host) do
    prefix = if host == :harness, do: "mob_ci_", else: "mob_"

    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn n -> if String.starts_with?(n, prefix), do: n, else: prefix <> n end)
    |> Enum.map(&String.to_atom/1)
  end

  # ── device run (default) ──────────────────────────────────────────────────────

  defp finish_device(set, host, opts) do
    Dist.ensure!()
    artifacts = opts[:artifacts] || "artifacts/ci-device"

    case Run.run(set, host: host, artifacts_dir: artifacts) do
      {:ok, _results} ->
        Mix.shell().info("\nmob_ci device run: PASS (artifacts → #{artifacts})")

      {:fail, results} ->
        bad = for r <- results, r.status in [:fail, :error], do: r.id
        Mix.shell().error("\nmob_ci device run: FAIL — #{inspect(bad)} (artifacts → #{artifacts})")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("\nmob_ci device run: ERROR — #{inspect(reason)}")
        exit({:shutdown, 2})
    end
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

  defp plan(set, host) do
    rows =
      Enum.map_join(Invariants.all(), "\n", fn {id, title, layer} ->
        "  #{String.pad_trailing(to_string(id), 4)} [#{String.pad_trailing(to_string(layer), 6)}] #{title}"
      end)

    """
    ── mob_ci device invariant catalog ───────────────────────────
      host: #{host}
      set:  #{Enum.map_join(set, ", ", &Atom.to_string/1)}

    #{rows}
    """
  end
end
