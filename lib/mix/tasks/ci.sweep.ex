defmodule Mix.Tasks.Ci.Sweep do
  @shortdoc "Property sweep over plugin-activation subsets (static or on-device)"
  @moduledoc """
  The property sweep — generate plugin-activation subsets and check invariants
  across the combination space, shrinking failures to the minimal offending set.

      mix ci.sweep --static            # cheap: cross_validate soundness over the space
      mix ci.sweep --runs 4            # device: 4 sampled subsets through P1–P11 + shrink

  ## Modes

    * `--static` — generate subsets and verify `cross_validate` flags a conflict
      iff the subset actually collides. Milliseconds, no farm. Exit non-zero if
      any inconsistency is found (a validator soundness bug), each minimized.

    * default (device) — run `--runs N` (default 4) sampled subsets of the
      device pool through the full catalog on one reused harness + container, and
      shrink any failing subset to its minimal core. Self-starts distribution (so
      a plain `mix ci.sweep --runs N` works — no `elixir --name` wrapper needed)
      and exits non-zero if any sampled subset fails or errors. Expensive (one
      build per activation switch) — best scheduled in a low-traffic window.
  """
  use Mix.Task

  alias MobCi.{Dist, Sweep}

  @switches [static: :boolean, runs: :integer, count: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)

    if opts[:static] or is_nil(opts[:runs]) do
      static(opts)
    else
      device(opts[:runs])
    end
  end

  defp device(runs) do
    Dist.ensure!(:"mob_ci_sweep@127.0.0.1")

    case Sweep.device_sweep(runs: runs) do
      {:error, reason} ->
        Mix.shell().error("device sweep could not start: #{inspect(reason)}")
        exit({:shutdown, 2})

      %{ran: ran} = summary ->
        Mix.shell().info("\n" <> Sweep.summarize(summary))
        failed = Enum.count(ran, fn {_subset, {v, _}} -> v in [:fail, :error] end)

        if failed > 0 do
          Mix.shell().error("device sweep: #{failed}/#{length(ran)} sampled subset(s) failed.")
          exit({:shutdown, 1})
        else
          Mix.shell().info("device sweep: all #{length(ran)} sampled subset(s) green.")
        end
    end
  end

  defp static(opts) do
    findings = Sweep.static_findings(count: Keyword.get(opts, :count, 300))

    if findings == [] do
      Mix.shell().info("✓ static sweep: cross_validate is sound over the sampled subset space.")
    else
      Mix.shell().error("✗ static sweep found #{length(findings)} inconsistency(ies):")

      for f <- findings do
        Mix.shell().error(
          "  minimal #{inspect(f.minimal)} — cross_validate=#{f.cross_validate}, colliding=#{f.colliding}"
        )
      end

      exit({:shutdown, 1})
    end
  end
end
