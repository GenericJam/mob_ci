defmodule Mix.Tasks.Ci.Replay do
  @shortdoc "Rerun one stored cell exactly, or promote a failed sampled cell to a regression set"
  @moduledoc """
  Rerun one cell from the results store with the set, version row,
  platform, path and exact pins it recorded (`MobCi.Replay`).

      mix ci.replay 1234                  # rerun cell 1234 with its recorded pins
      mix ci.replay 1234 --current        # same set/row/path, the row as it resolves today
      mix ci.replay 1234 --dry-run        # print the mix ci.device call and the pins, run nothing
      mix ci.replay 1234 --promote        # freeze a failed random:<seed> / sweep cell
                                          # into priv/sets/<name>.exs (default random-<seed>
                                          # or sweep-<cell id>; --name NAME)
      mix ci.replay 1234 --store PATH     # another store (default $MOB_CI_STORE or
                                          # ~/.local/share/mob_ci/results.sqlite)

  Any row of a cell works as the id: an invariant or self-test row replays
  its cell. The rerun is `mix ci.device` on that one path (`--static`,
  `--paths deploy|release`, or `--platform ios --paths <ios path>`) with
  `$MOB_CI_PINS` naming the recorded versions record, so `MobCi.Cell.plan/3`
  checks every repo out at its recorded pin and builds the recorded plugin
  list, and `$MOB_CI_TRIGGER=replay`, so the run is recorded as a replay:
  `COMPATIBILITY.md` counts it (exact versions) but `matrix.md` and the
  regression check skip it (old versions are not the row's latest).
  `--current` drops the pins and records as `replay-current`, a real result
  of the row today. Exit status is `mix ci.device`'s.

  A promoted set is a file under `priv/sets/`: commit it in a PR, and the
  nightly runs it from then on (`MobCi.Sets.nightly/0`).
  """
  use Mix.Task

  alias MobCi.{Replay, Store}

  @switches [store: :string, current: :boolean, dry_run: :boolean, promote: :boolean, name: :string]
  @sets_dir Path.expand("../../../priv/sets", __DIR__)

  @impl Mix.Task
  def run(argv) do
    {opts, args, _invalid} = OptionParser.parse(argv, strict: @switches)

    id =
      case args do
        [id] ->
          case Integer.parse(id) do
            {n, ""} -> n
            _ -> Mix.raise("cell id must be an integer, got #{inspect(id)}")
          end

        _ ->
          Mix.raise("usage: mix ci.replay <cell id> [--current] [--dry-run] [--promote [--name NAME]] [--store PATH]")
      end

    path = opts[:store] || Store.default_path()
    unless File.exists?(path), do: Mix.raise("no results store at #{path}")
    cell = load_cell(path, id)

    if opts[:promote], do: promote(cell, opts), else: replay(cell, path, opts)
  end

  @doc false
  # The summary row of the cell that row `id` belongs to (any row of a cell works).
  def load_cell(path, id) do
    store = Store.open!(path)

    try do
      case Store.query(store, id: id) do
        [row] ->
          [summary | _] =
            Store.query(store, run_id: row.run_id, set: row.set, platform: row.platform, path: row.path, invariant: nil) ++
              [row]

          summary

        [] ->
          Mix.raise("no cell #{id} in #{path}")
      end
    after
      Store.close(store)
    end
  end

  defp promote(cell, opts) do
    case Replay.promotion(cell, name: opts[:name]) do
      {:ok, name, source} ->
        file = Path.join(@sets_dir, "#{name}.exs")
        if File.exists?(file), do: Mix.raise("#{file} exists; pick another --name")
        File.write!(file, source)
        Mix.shell().info("wrote #{file}:\n\n#{source}\nCommit it in a PR; the nightly runs it as --set #{name}.")

      {:error, msg} ->
        Mix.raise(msg)
    end
  end

  defp replay(cell, store_path, opts) do
    argv =
      case Replay.argv(cell) do
        {:ok, argv} -> argv ++ ["--store", store_path]
        {:error, msg} -> Mix.raise(msg)
      end

    pins =
      if opts[:current] do
        nil
      else
        case Replay.pins_json(cell) do
          {:ok, json} -> json
          {:error, msg} -> Mix.raise(msg)
        end
      end

    Mix.shell().info(
      "replaying cell #{cell.id} (run #{cell.run_id}, #{cell.started_at}: #{cell.outcome}" <>
        if(cell.layer, do: " @ #{cell.layer}", else: "") <>
        ")\n  mix ci.device #{Enum.join(argv, " ")}\n  " <>
        if(pins, do: "pinned to the recorded versions", else: "--current: the row as it resolves today")
    )

    if opts[:dry_run] do
      if pins, do: Mix.shell().info(pins)
    else
      file = Path.join(System.tmp_dir!(), "mob_ci_replay_#{cell.id}_#{System.unique_integer([:positive])}.json")
      if pins, do: File.write!(file, pins)

      for {name, value} <- Replay.env(pins && file) do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      try do
        Mix.Task.run("ci.device", argv)
      after
        File.rm(file)
      end
    end
  end
end
