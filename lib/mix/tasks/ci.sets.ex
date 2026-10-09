defmodule Mix.Tasks.Ci.Sets do
  @shortdoc "List the deterministic plugin sets, or regenerate the pairwise array"
  @moduledoc """
  The named sets `mix ci.device --set <name>` accepts (`MobCi.Sets`).

      mix ci.sets                  # every nightly set name with its plugins
      mix ci.sets --regen          # rewrite priv/sets/pairwise.exs for the current pool
      mix ci.sets --check          # exit 1 if the committed array is stale or incomplete

  `--regen` is the only way the committed covering array changes; run it when
  `priv/plugins.exs` or `priv/device_caps.exs` changes the buildable pool. The
  `default` set is not listed here — it depends on the row's mob_new.
  """
  use Mix.Task

  alias MobCi.Sets

  @switches [regen: :boolean, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    cond do
      opts[:regen] -> regen()
      opts[:check] -> check()
      true -> list()
    end
  end

  defp regen do
    pool = Sets.pool()
    File.write!(Sets.pairwise_path(), Sets.pairwise_source(pool))
    rows = Sets.pairwise(pool)

    Mix.shell().info(
      "wrote #{Path.relative_to_cwd(Sets.pairwise_path())}: #{length(rows)} rows over #{length(pool)} plugins"
    )
  end

  defp check do
    pool = Sets.pool()
    committed = Sets.committed_pairwise()

    cond do
      committed.plugins != pool ->
        Mix.shell().error(
          "pairwise.exs was generated for a different pool; run `mix ci.sets --regen`"
        )

        exit({:shutdown, 1})

      committed.sets != Sets.pairwise(pool) ->
        Mix.shell().error(
          "pairwise.exs does not match the generator's output; run `mix ci.sets --regen`"
        )

        exit({:shutdown, 1})

      not Sets.covers_all_pairs?(pool, committed.sets) ->
        Mix.shell().error(
          "pairwise.exs leaves pairs uncovered: #{inspect(Sets.uncovered_pairs(pool, committed.sets), limit: 5)}"
        )

        exit({:shutdown, 1})

      true ->
        Mix.shell().info(
          "✓ pairwise.exs: #{length(committed.sets)} rows, every pair of #{length(pool)} plugins covered"
        )
    end
  end

  defp list do
    for name <- Sets.nightly(), name != "default" do
      {:ok, spec} = Sets.parse(name)
      {:ok, plugins} = Sets.resolve(spec, [])

      Mix.shell().info(
        "#{String.pad_trailing(name, 28)} #{length(plugins)}  #{Enum.map_join(plugins, " ", &to_string/1)}"
      )
    end

    Mix.shell().info("default                      (read from the row's mob_new at run time)")
  end
end
