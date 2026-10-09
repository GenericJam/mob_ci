defmodule Mix.Tasks.Ci.Report do
  @shortdoc "Print the latest mob_ci grid per versions row from the results store"
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

  Read-only; `matrix.md` generation (MOB-417) builds on the same
  `MobCi.Store.query/2`.
  """
  use Mix.Task

  alias MobCi.{Report, Store}

  @switches [store: :string, versions: :string, set: :string, invariants: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    path = opts[:store] || Store.default_path()

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
