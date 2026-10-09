defmodule Mix.Tasks.Ci.IosCell do
  @shortdoc "Run one iOS cell on this Mac (the Mac worker of the iOS lane)"
  @moduledoc """
  The Mac side of the iOS lane (`MobCi.Lane.Ios.Worker`): one host at a time,
  generated, built, run and deleted. The NUC starts it over ssh through
  `worker/mac/mob_ci_ios_cell.sh` with a spec it planned; run by hand it plans
  the cell itself.

      # what the NUC sends
      mix ci.ios_cell --spec-b64 <base64 spec JSON>
      mix ci.ios_cell --spec spec.json

      # by hand, on the Mac (paths run in order, one host each)
      mix ci.ios_cell --set default --versions hex --path deploy:ios_sim
      mix ci.ios_cell --set default --versions hex --path release:ios

  A `deploy:ios_sim` cell leases the booted simulator with the newest iOS
  runtime at or above `--min-runtime` (default 27.0: `simctl privacy grant
  photos` is ignored on 26.x) unless `--sim-udid` pins one;
  `deploy:ios_device` uses `--device-udid` (default Kevin's iPhone).

  Each cell's result is printed as one line, `MOB_CI_RESULT <json>` (the line
  the NUC collects), and with `--out DIR` also written to
  `DIR/<cell_id>.json`. `--root DIR` moves the scratch dirs (default
  `$TMPDIR/mob_ci_ios`).

  Exit status: 0 when every cell passed or skipped, 1 when one failed, 2 when
  one errored (the cell could not run).
  """
  use Mix.Task

  alias MobCi.Cell
  alias MobCi.Lane.Ios
  alias MobCi.Lane.Ios.{Spec, Worker}

  @switches [
    spec: :string,
    spec_b64: :string,
    set: :string,
    versions: :string,
    path: :keep,
    sim_udid: :string,
    device_udid: :string,
    min_runtime: :string,
    out: :string,
    root: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("unexpected arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}")

    results = Enum.map(specs!(opts), &run_one(&1, opts))
    exit_with(results)
  end

  defp specs!(opts) do
    cond do
      opts[:spec_b64] -> [parse!(Base.decode64!(opts[:spec_b64]))]
      opts[:spec] -> [parse!(File.read!(opts[:spec]))]
      true -> plan!(opts)
    end
  end

  defp parse!(json) do
    case Spec.from_json(json) do
      {:ok, spec} -> spec
      {:error, msg} -> Mix.raise("bad cell spec: #{msg}")
    end
  end

  defp plan!(opts) do
    paths = Keyword.get_values(opts, :path)
    if paths == [], do: Mix.raise("give --spec, --spec-b64, or --set/--versions with --path")

    cell = Cell.plan!(opts[:set], opts[:versions])
    Mix.shell().info(Cell.describe(cell))

    for path <- paths do
      spec_opts = [udid: Ios.udid_for(path, opts), min_runtime: opts[:min_runtime]]

      case Spec.from_cell(cell, path, spec_opts) do
        {:ok, spec} -> spec
        {:error, msg} -> Mix.raise(msg)
      end
    end
  end

  defp run_one(spec, opts) do
    result = Worker.run(spec, Keyword.take(opts, [:root]))
    json = JSON.encode!(result)

    if dir = opts[:out] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{spec.cell_id}.json"), json)
    end

    IO.puts(Ios.summary_line(result))
    IO.puts(Ios.marker() <> json)
    result
  end

  defp exit_with(results) do
    outcomes = Enum.map(results, & &1["outcome"])

    cond do
      "error" in outcomes -> exit({:shutdown, 2})
      "fail" in outcomes -> exit({:shutdown, 1})
      true -> :ok
    end
  end
end
