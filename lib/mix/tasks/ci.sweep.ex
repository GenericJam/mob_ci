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
      shrink any failing subset to its minimal core. Must run as a distributed
      node (it reaches the device):

          elixir --name s@127.0.0.1 --cookie mob_secret -S mix run -e \\
            'MobCi.Sweep.device_sweep(runs: 4) |> MobCi.Sweep.summarize() |> IO.puts()'

      (run via `mix run` so the node is named; the bare `mix ci.sweep` device
      path is for a wrapper that sets `--name`.)
  """
  use Mix.Task

  alias MobCi.Sweep

  @switches [static: :boolean, runs: :integer, count: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)

    if opts[:static] or is_nil(opts[:runs]) do
      static(opts)
    else
      Mix.shell().error(
        "device sweep needs a distributed node — run:\n" <>
          "  elixir --name s@127.0.0.1 --cookie mob_secret -S mix run -e " <>
          "'MobCi.Sweep.device_sweep(runs: #{opts[:runs]}) |> MobCi.Sweep.summarize() |> IO.puts()'"
      )

      exit({:shutdown, 2})
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
