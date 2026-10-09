defmodule Mix.Tasks.Ci.Report do
  @shortdoc "Print the latest mob_ci grid; --publish writes and pushes matrix.md / COMPATIBILITY.md and posts to Muster"
  @moduledoc """
  Reads the results store (`MobCi.Store`) and prints, for every versions row
  it holds, the newest outcome of every (set, build path) cell: one line per
  set, one column per path (`static`, `deploy:android`, `release:android`,
  the iOS lane's paths), each cell `✓ pass`, `✗ fail @ <layer>`,
  `! error @ <layer>` or `– skip`.

      mix ci.report                       # every row
      mix ci.report --versions hex        # one row
      mix ci.report --set default         # one set across rows
      mix ci.report --store /tmp/r.sqlite # another store (default $MOB_CI_STORE
                                          # or ~/.local/share/mob_ci/results.sqlite)
      mix ci.report --invariants          # also list each non-passing invariant
                                          # and self-test of the shown cells

  ## Publishing: `--publish`

      mix ci.report --publish             # what the triggers run after every job
      mix ci.report --publish --no-post   # fold this job into the next Muster post
      mix ci.report --publish --no-push   # write the files, don't push them
      mix ci.report --publish --out DIR   # write them elsewhere (default: cwd)
      mix ci.report --prune               # only the store / log retention

  `--publish` (`MobCi.Publish`) renders `matrix.md` (latest grid per version
  row) and `COMPATIBILITY.md` (verified version combinations, plugin ×
  mob / mob_dev passes) from the store into `--out` (gitignored in the
  checkout), commits them to the `matrix` branch of `origin` without touching
  the working tree and pushes it, posts one Muster `#mob` summary of the
  cells recorded since the previous post (as `$MOB_CI_MUSTER_BOT`, default
  `mob_ci-nightly`; `@kevin` only when the `hex` row regressed: a cell whose
  previous non-skip outcome was a pass now fails or errors), then prunes the
  store (cells older than 30 days, keeping the newest per (row, set,
  platform, path) and the passing evidence `COMPATIBILITY.md` needs) and
  `*.log` files older than 30 days under `~/mob_ci_logs`.

  Exit status: 0 whenever both files were written, including when there was
  nothing new to post or the push / post / prune failed (printed as
  warnings: the next publish catches up); 1 when a file could not be
  written or the store doesn't exist (a wrong `--store` must not push an
  empty matrix over the published one). Two publishes at once (both lanes
  finishing) take turns on a lock file beside the store, so no cell is
  posted twice.
  """
  use Mix.Task

  alias MobCi.{Publish, Report, Store}

  @switches [
    store: :string,
    versions: :string,
    set: :string,
    invariants: :boolean,
    publish: :boolean,
    post: :boolean,
    push: :boolean,
    out: :string,
    prune: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    path = opts[:store] || Store.default_path()

    cond do
      opts[:publish] -> publish(path, opts)
      opts[:prune] -> prune(path)
      true -> print(path, opts)
    end
  end

  defp print(path, opts) do
    unless File.exists?(path), do: Mix.raise("no results store at #{path} (run mix ci.device first)")

    store = Store.open!(path)

    try do
      filters =
        [invariant: nil, latest: true] ++
          Enum.reject([versions_row: opts[:versions], set: opts[:set]], fn {_, v} -> is_nil(v) end)

      cells = Store.query(store, filters)
      Mix.shell().info(Report.grid(cells))

      if opts[:invariants], do: Mix.shell().info("\n" <> findings(store, cells))
    after
      Store.close(store)
    end
  end

  # A missing store is a misconfigured $MOB_CI_STORE / --store, not an empty
  # history: never render and push an empty matrix over the public branch.
  defp publish(path, opts) do
    unless File.exists?(path), do: Mix.raise("no results store at #{path}; nothing published")
    store = Store.open!(path)

    try do
      case Publish.run(store,
             out_dir: opts[:out] || File.cwd!(),
             push: Keyword.get(opts, :push, true),
             post: Keyword.get(opts, :post, true)
           ) do
        {:ok, report} ->
          Mix.shell().info(publish_summary(report))

        {:error, reason} ->
          Mix.shell().error("mob_ci publish: could not write the reports: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    after
      Store.close(store)
    end
  end

  @doc false
  def publish_summary(report) do
    lines =
      ["wrote #{Enum.join(report.written, ", ")}"] ++
        [pushed_line(report.pushed), posted_line(report.posted), pruned_line(report.pruned)]

    Enum.join(lines, "\n")
  end

  defp pushed_line(:skipped), do: "push: skipped (--no-push)"
  defp pushed_line({:ok, :unchanged}), do: "push: matrix branch unchanged"
  defp pushed_line({:ok, {:pushed, sha}}), do: "push: matrix branch → #{sha} (#{Publish.url("matrix.md")})"
  defp pushed_line({:error, %_{} = e}), do: "WARNING push failed: #{Exception.message(e)}"
  defp pushed_line({:error, reason}), do: "WARNING push failed: #{inspect(reason)}"

  defp posted_line(:nothing_new), do: "muster: no new cells since the last post"
  defp posted_line({:held, text}), do: "muster: held for the next post (--no-post):\n" <> indent(text)
  defp posted_line({:posted, text}), do: "muster: posted to #mob:\n" <> indent(text)
  defp posted_line({:failed, text, reason}), do: "WARNING muster post failed (#{inspect(reason)}); kept for the next one:\n" <> indent(text)
  defp posted_line({:error, e}), do: "WARNING muster step failed: #{Exception.message(e)}"

  defp pruned_line(:skipped), do: "prune: skipped"
  defp pruned_line({:error, e}), do: "WARNING prune failed: #{Exception.message(e)}"

  defp pruned_line(p),
    do: "prune: #{p.cells} cell rows, #{p.runs} runs, #{length(p.logs_deleted)} log files"

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  defp prune(path) do
    unless File.exists?(path), do: Mix.raise("no results store at #{path}")
    store = Store.open!(path)

    try do
      Mix.shell().info(pruned_line(Publish.prune(store)))
    after
      Store.close(store)
    end
  end

  # The non-passing invariant / self-test rows behind the shown summary cells.
  defp findings(store, cells) do
    lines =
      for cell <- cells,
          cell.outcome in [:fail, :error],
          row <- Store.query(store, run_id: cell.run_id, set: cell.set, path: cell.path, platform: cell.platform),
          row.invariant,
          row.outcome in [:fail, :error] do
        detail = get_in(row.detail || %{}, ["detail"]) || ""
        "  #{cell.versions_row} #{cell.set} #{cell.path} #{row.invariant}: #{row.outcome}" <>
          if(row.layer, do: " @ #{row.layer}", else: "") <> if(detail != "", do: " — #{detail}", else: "")
      end

    if lines == [], do: "no failing invariants in the shown cells", else: Enum.join(["findings:" | lines], "\n")
  end
end
