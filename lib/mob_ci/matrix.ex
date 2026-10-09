defmodule MobCi.Matrix do
  @moduledoc """
  The published reports, rendered from the results store's summary rows
  (`MobCi.Store.query(store, invariant: nil)`, every run): pure, so the same
  store always renders byte-identical files and a diff of the published branch
  is a diff of results.

    * `matrix_md/1` — `matrix.md`: the latest grid per version row (`hex`,
      `master`, the five newest `rc:` rows), set × build path, each cell its
      outcome and the layer of a failure, plus the sampled sets
      (`random:<seed>`, sweep subsets) whose latest cell failed, with the cell
      id `mix ci.replay` takes.
    * `compatibility_md/1` — `COMPATIBILITY.md`: version tuples (mob,
      mob_dev, mob_new, every plugin's pin) on which both `default` and `all`
      passed on every build path (`paths/0`), newest first; the candidates
      that aren't there yet and what they miss; and which plugin versions have
      passed with which mob / mob_dev.
    * `regressions/2` and `post/3` — the Muster summary of the cells recorded
      since the previous publish.

  Pinned replays (`mix ci.replay`, run trigger `replay`) reproduce an old
  cell: they are evidence for `COMPATIBILITY.md` (exact versions) but never the
  "latest" of a grid cell nor a regression. Nothing private is rendered: no
  hosts, no log paths, and absolute paths inside a layer are cut to their last
  segment (`public_layer/1`).
  """

  alias MobCi.{Report, Sets, Store}

  @glyph %{pass: "✓", fail: "✗", skip: "–", error: "!"}
  @paths ["static", "deploy:android", "release:android", "deploy:ios_sim", "deploy:ios_device", "release:ios"]
  @verified_sets ["default", "all"]
  @core ["mob", "mob_dev", "mob_new"]
  @rc_rows 5
  @candidates 10

  # What each build path proves and on which ABI (the farm is x86_64 redroid;
  # the Mac's simulators and the iPhone are arm64; docs/budgets.md).
  @path_notes [
    ["`static`", "the manifest gate (`cross_validate`): the set composes", "none (no build)"],
    ["`deploy:android`", "`mix mob.deploy --native`, P1–P12 on a redroid emulator", "x86_64"],
    ["`release:android`", "`mix mob.release --android` as a universal APK on a fresh redroid, P2/P10–P12", "x86_64 runs; arm64 and armv7 only compile"],
    ["`deploy:ios_sim`", "`mix mob.deploy --native` on an iOS simulator, P2/P12/health", "arm64 (simulator)"],
    ["`deploy:ios_device`", "the same on a physical iPhone", "arm64"],
    ["`release:ios`", "`mix mob.release --ios`: a signed .ipa, not run", "arm64 (build only)"]
  ]

  @doc "Every build path a verified combination must pass, in column order."
  @spec paths() :: [String.t()]
  def paths, do: @paths

  # ── row / set classification ─────────────────────────────────────────────────

  @doc "Is `row` a published version row (`hex`, `master`, `rc:<repo>@<sha>`) rather than a fixture host?"
  @spec public_row?(String.t()) :: boolean()
  def public_row?(row), do: row in ["hex", "master"] or String.starts_with?(row, "rc:")

  @doc """
  Is `set` sampled rather than deterministic: `random:<seed>`, or a device
  sweep subset `sweep:<plugins>`? (`sweep:<named set>` is the static sweep of
  that set, deterministic.)
  """
  @spec sampled_set?(String.t()) :: boolean()
  def sampled_set?("random:" <> _), do: true
  def sampled_set?("sweep:fixtures"), do: false
  def sampled_set?("sweep:" <> rest), do: match?({:error, _}, Sets.parse(rest))
  def sampled_set?(_), do: false

  @doc "A layer token with absolute paths (`/…/x`, `~/…/x`) cut to their last segment."
  @spec public_layer(String.t() | nil) :: String.t() | nil
  def public_layer(nil), do: nil
  def public_layer(layer), do: Regex.replace(~r{(?<=^|[\s:])(?:~|/)[^\s:,]*/([^\s:,/]+)}, layer, "\\1")

  # ── matrix.md ────────────────────────────────────────────────────────────────

  @doc "`matrix.md` for the store's summary rows."
  @spec matrix_md([map()]) :: String.t()
  def matrix_md(summaries) do
    latest = latest(summaries)
    rows = rows(latest)

    blocks =
      if rows == [],
        do: ["No results on a version row yet.\n"],
        else: Enum.map(rows, fn row -> row_block(row, Enum.filter(latest, &(&1.versions_row == row))) end)

    Enum.join(
      [
        """
        # mob_ci matrix

        The latest result of every cell mob_ci has run, per version row: one
        line per plugin set, one column per build path. Generated from the
        mob_ci results store by `mix ci.report --publish`; do not edit. Verified
        version combinations are in [COMPATIBILITY.md](COMPATIBILITY.md).

        `✓ pass` · `✗ fail @ layer` · `! error @ layer` (the run could not
        finish: build, boot, farm) · `– skip` · `·` never ran. Layers are
        described in mob_ci's `decisions/2026-06-19-mob-ci-design.md`.
        """
        | blocks
      ],
      "\n"
    )
    |> tidy()
  end

  # The newest non-replay summary per (row, set, platform, path) of the public rows.
  defp latest(summaries) do
    summaries
    |> Enum.filter(&(public_row?(&1.versions_row) and &1.trigger != "replay"))
    |> Enum.group_by(&{&1.versions_row, &1.set, &1.platform, &1.path})
    |> Enum.map(fn {_, cells} -> Enum.max_by(cells, & &1.id) end)
    |> Enum.sort_by(& &1.id)
  end

  # hex, master, then the newest rc rows (newest run first, name breaks ties).
  defp rows(latest) do
    rows = latest |> Enum.map(& &1.versions_row) |> Enum.uniq()
    newest = fn row -> latest |> Enum.filter(&(&1.versions_row == row)) |> Enum.map(& &1.started_at) |> Enum.max() end

    rc =
      rows
      |> Enum.filter(&String.starts_with?(&1, "rc:"))
      |> Enum.sort_by(&{newest.(&1), &1}, :desc)
      |> Enum.take(@rc_rows)

    Enum.filter(["hex", "master"], &(&1 in rows)) ++ rc
  end

  defp row_block(row, cells) do
    {sampled, grid} = Enum.split_with(cells, &sampled_set?(&1.set))
    newest = cells |> Enum.map(& &1.started_at) |> Enum.max()

    [
      "## #{row}\n",
      "Latest run #{newest}. Core versions in this grid: #{core_line(cells)}.\n",
      if(grid == [], do: "", else: grid_table(grid) <> "\n" <> tally_line(grid) <> "\n"),
      sampled_block(sampled)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp grid_table(cells) do
    paths = cells |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort_by(&Report.path_rank/1)
    sets = cells |> Enum.map(& &1.set) |> Enum.uniq() |> Enum.sort_by(&Report.set_rank/1)
    by_cell = Map.new(cells, &{{&1.set, &1.path}, &1})

    table(
      ["set" | paths],
      for(set <- sets, do: ["`#{set}`" | Enum.map(paths, &cell_text(Map.get(by_cell, {set, &1})))])
    )
  end

  defp sampled_block(sampled) do
    failed = sampled |> Enum.filter(&(&1.outcome in [:fail, :error])) |> Enum.sort_by(& &1.id, :desc)

    if failed == [] do
      ""
    else
      """
      Sampled sets whose latest cell failed (`mix ci.replay <cell>` reruns one;
      `--promote` commits it under `priv/sets/` as a regression set):

      """ <>
        table(
          ["cell", "set", "path", "result"],
          for(c <- failed, do: ["#{c.id}", "`#{c.set}`", c.path, cell_text(c)])
        ) <> "\n"
    end
  end

  defp tally_line(cells) do
    t = Enum.frequencies_by(cells, & &1.outcome)
    "#{t[:pass] || 0} pass, #{t[:fail] || 0} fail, #{t[:error] || 0} error, #{t[:skip] || 0} skip.\n"
  end

  # Distinct core tuples among the cells, newest cell first.
  defp core_line(cells) do
    cells
    |> Enum.sort_by(& &1.id, :desc)
    |> Enum.map(&Store.pins(&1.versions))
    |> Enum.reject(&(&1 == %{}))
    |> Enum.map(&core_label/1)
    |> Enum.uniq()
    |> case do
      [] -> "not recorded"
      labels -> Enum.join(labels, "; ")
    end
  end

  defp cell_text(nil), do: "·"

  defp cell_text(%{outcome: outcome, layer: layer}) do
    layer = public_layer(layer)
    "#{@glyph[outcome]} #{outcome}" <> if(layer, do: " @ `#{escape(layer)}`", else: "")
  end

  # ── COMPATIBILITY.md ─────────────────────────────────────────────────────────

  @doc """
  The version tuples of the public rows' `default` and `all` cells, newest
  first. A tuple is a set of exact pins (mob, mob_dev, mob_new and plugins);
  a cell belongs to every tuple whose pins agree with all of its own (they
  share every repo at the same pin). `all` cells (the widest pin sets) found
  the tuples, so one night's `default` (a few plugins) and `all` cells on
  Android and iOS form one tuple, and a `default` cell counts for every
  `all` tuple it is part of: a later release of a plugin outside `default`
  starts a new tuple without taking the older one's `default` results away.
  A `default` cell no `all` tuple contains founds its own. Each tuple is
  `%{pins, rows, newest, status, verified}` where `status` maps `{set, path}`
  to the newest member cell's outcome and `verified` is true when every
  `{default | all, path}` passed.
  """
  @spec tuples([map()]) :: [map()]
  def tuples(summaries) do
    summaries
    |> Enum.filter(&(public_row?(&1.versions_row) and &1.set in @verified_sets))
    |> Enum.map(&Map.put(&1, :pins, Store.pins(&1.versions)))
    |> Enum.filter(fn c -> Enum.all?(@core, &Map.has_key?(c.pins, &1)) end)
    |> Enum.sort_by(&{if(&1.set == "all", do: 0, else: 1), -&1.id})
    |> Enum.reduce([], fn cell, clusters ->
      if Enum.any?(clusters, &consistent?(&1.pins, cell.pins)) do
        Enum.map(clusters, fn c ->
          if consistent?(c.pins, cell.pins), do: %{pins: Map.merge(c.pins, cell.pins), cells: c.cells ++ [cell]}, else: c
        end)
      else
        clusters ++ [%{pins: cell.pins, cells: [cell]}]
      end
    end)
    |> Enum.map(&tuple/1)
    |> Enum.sort_by(&{&1.newest, &1.id}, :desc)
  end

  defp consistent?(a, b), do: Enum.all?(b, fn {name, pin} -> Map.get(a, name, pin) == pin end)

  defp tuple(%{pins: pins, cells: cells}) do
    status =
      cells
      |> Enum.group_by(&{&1.set, &1.path})
      |> Map.new(fn {key, cs} -> {key, Enum.max_by(cs, & &1.id).outcome} end)

    %{
      pins: pins,
      id: cells |> Enum.map(& &1.id) |> Enum.max(),
      rows: cells |> Enum.map(& &1.versions_row) |> Enum.uniq() |> Enum.sort(),
      newest: cells |> Enum.map(& &1.started_at) |> Enum.max(),
      status: status,
      verified: for(s <- @verified_sets, p <- @paths, do: status[{s, p}] == :pass) |> Enum.all?()
    }
  end

  @doc "`COMPATIBILITY.md` for the store's summary rows."
  @spec compatibility_md([map()]) :: String.t()
  def compatibility_md(summaries), do: summaries |> compatibility() |> tidy()

  defp compatibility(summaries) do
    {verified, candidates} = summaries |> tuples() |> Enum.split_with(& &1.verified)
    candidates = Enum.take(candidates, @candidates)

    verified_text =
      if verified == [],
        do: "None yet: no version tuple has passed both `default` and `all` on every path. The candidates below show what each one is missing.\n",
        else: Enum.map_join(verified, "\n", &verified_block/1)

    candidates_text =
      if candidates == [],
        do: "None.\n",
        else: Enum.map_join(candidates, "\n", &candidate_block/1)

    """
    # Verified combinations

    Which versions of mob, mob_dev, mob_new and the first-party plugins work
    together, as proven on devices by [mob_ci](https://github.com/GenericJam/mob_ci).
    Generated from the mob_ci results store by `mix ci.report --publish`; do
    not edit.

    A combination is **verified** when, with exactly these versions, both the
    `default` set (what `mix mob.new` activates) and the `all` set (every
    buildable first-party plugin) passed on every build path below. Hex
    versions are plain (`0.9.15`); a git checkout is `version (git sha)`.
    Newest first.

    #{table(["path", "what runs", "ABI on the device"], @path_notes)}
    ## Verified

    #{verified_text}
    ## Candidates

    The #{@candidates} newest tuples that ran `default` or `all` but are not
    verified: the newest outcome of each set on each path (`·` never ran).

    #{candidates_text}
    ## Plugins

    Which plugin versions have passed (a `singleton:<plugin>`, `default` or
    `all` cell passed with the plugin in it) with which mob and mob_dev, on
    which build paths.

    #{plugin_table(summaries)}
    """
  end

  defp verified_block(t) do
    """
    ### #{core_label(t.pins)}

    Row #{Enum.join(t.rows, ", ")}; newest result #{t.newest}.

    Plugins: #{plugins_label(t.pins)}.
    """
  end

  defp candidate_block(t) do
    rows =
      for set <- @verified_sets do
        ["`#{set}`" | Enum.map(@paths, &status_text(t.status[{set, &1}]))]
      end

    """
    ### #{core_label(t.pins)}

    Row #{Enum.join(t.rows, ", ")}; newest result #{t.newest}.

    #{table(["set" | @paths], rows)}
    Plugins: #{plugins_label(t.pins)}.
    """
  end

  defp status_text(nil), do: "·"
  defp status_text(outcome), do: "#{@glyph[outcome]} #{outcome}"

  defp plugin_table(summaries) do
    rows =
      for c <- summaries,
          public_row?(c.versions_row),
          c.outcome == :pass,
          Store.evidence_set?(c.set),
          pins = Store.pins(c.versions),
          Enum.all?(["mob", "mob_dev"], &Map.has_key?(pins, &1)),
          {name, pin} <- pins,
          name not in @core,
          do: {{name, pin, pins["mob"], pins["mob_dev"]}, c.path}

    if rows == [] do
      "No plugin has passed yet.\n"
    else
      rows
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort(fn {{n1, p1, m1, d1}, _}, {{n2, p2, m2, d2}, _} ->
        compare_rows([{:asc, n1, n2}, {:desc, p1, p2}, {:desc, m1, m2}, {:desc, d1, d2}])
      end)
      |> Enum.map(fn {{name, pin, mob, mob_dev}, paths} ->
        paths = paths |> Enum.uniq() |> Enum.sort_by(&Report.path_rank/1) |> Enum.map_join(", ", &"`#{&1}`")
        ["`#{name}`", pin_label(pin), pin_label(mob), pin_label(mob_dev), paths]
      end)
      |> then(&table(["plugin", "version", "mob", "mob_dev", "passed on"], &1))
    end
  end

  # Lexicographic over {direction, a, b}: names ascending, pins newest first.
  defp compare_rows([]), do: true

  defp compare_rows([{dir, a, b} | rest]) do
    case compare(a, b) do
      :eq -> compare_rows(rest)
      :lt -> dir == :asc
      :gt -> dir == :desc
    end
  end

  defp compare(a, b) when is_binary(a), do: if(a == b, do: :eq, else: if(a < b, do: :lt, else: :gt))

  # Pins: Hex releases by version (semver), a git pin after any release of
  # the same version; then the sha, so the order is total.
  defp compare({v1, s1, _} = a, {v2, s2, _} = b) when a != b do
    case {parse_version(v1), parse_version(v2)} do
      {{:ok, x}, {:ok, y}} ->
        case Version.compare(x, y) do
          :eq -> compare_sha(s1, s2)
          other -> other
        end

        # unparsable (nil) versions sort below everything, by sha
      {{:ok, _}, :error} -> :gt
      {:error, {:ok, _}} -> :lt
      {:error, :error} -> compare_sha(s1, s2)
    end
  end

  defp compare(_, _), do: :eq

  defp compare_sha(nil, nil), do: :eq
  defp compare_sha(nil, _), do: :lt
  defp compare_sha(_, nil), do: :gt
  defp compare_sha(a, b), do: compare(a, b)

  defp parse_version(v) when is_binary(v), do: Version.parse(v)
  defp parse_version(_), do: :error

  # ── labels ───────────────────────────────────────────────────────────────────

  defp core_label(pins), do: Enum.map_join(@core, " · ", &"#{&1} #{pin_label(pins[&1])}")

  defp plugins_label(pins) do
    case pins |> Map.drop(@core) |> Enum.sort() do
      [] -> "none"
      plugins -> Enum.map_join(plugins, ", ", fn {name, pin} -> "#{name} #{pin_label(pin)}" end)
    end
  end

  @doc false
  def pin_label(nil), do: "?"
  def pin_label({v, nil, _source}), do: v || "?"
  def pin_label({v, sha, _source}), do: "#{v || "?"} (git #{String.slice(sha, 0, 7)})"

  # ── the Muster post ──────────────────────────────────────────────────────────

  @doc """
  The regressions among `window` (summary rows): a non-replay cell that
  failed or errored whose previous non-skip outcome for the same (row, set,
  platform, path), among non-replay cells of `history`, was a pass.

  `pass → fail`, `pass → error` and `pass → skip → fail` regress; `fail →
  fail`, `error → fail`, a first-ever failure and `skip → fail` with no pass
  before it don't (nothing that worked broke; a skip proved nothing either
  way). Sorted by row order, set, path.
  """
  @spec regressions([map()], [map()]) :: [map()]
  def regressions(window, history) do
    history =
      history
      |> Enum.reject(&(&1.trigger == "replay"))
      |> Enum.group_by(&grid_key/1)

    window
    |> Enum.filter(&(&1.trigger != "replay" and &1.outcome in [:fail, :error]))
    |> Enum.flat_map(fn cell ->
      previous =
        history
        |> Map.get(grid_key(cell), [])
        |> Enum.filter(&(&1.id < cell.id and &1.outcome != :skip))
        |> Enum.max_by(& &1.id, fn -> nil end)

      if previous && previous.outcome == :pass, do: [Map.put(cell, :previous, previous)], else: []
    end)
    |> Enum.uniq_by(&grid_key/1)
    |> Enum.sort_by(&{row_order(&1.versions_row), Report.set_rank(&1.set), Report.path_rank(&1.path)})
  end

  defp grid_key(c), do: {c.versions_row, c.set, c.platform, c.path}

  defp row_order("hex"), do: {0, ""}
  defp row_order("master"), do: {1, ""}
  defp row_order(row), do: {2, row}

  @doc """
  The one Muster `#mob` post for `window` (the summary rows recorded since the
  previous publish), or nil when the window is empty: counts per row and
  outcome, failures by layer, regressions, `@kevin` only when the `hex` row
  regressed, and the link to `matrix.md`.
  """
  @spec post([map()], [map()], String.t()) :: String.t() | nil
  def post([], _regressions, _url), do: nil

  def post(window, regressions, url) do
    t = Enum.frequencies_by(window, & &1.outcome)

    rows =
      window
      |> Enum.frequencies_by(& &1.versions_row)
      |> Enum.sort_by(fn {row, _} -> row_order(row) end)
      |> Enum.map_join(" · ", fn {row, n} -> "#{row} #{n}" end)

    layers =
      window
      |> Enum.filter(&(&1.outcome in [:fail, :error]))
      |> Enum.frequencies_by(&(public_layer(&1.layer) || "unattributed"))
      |> Enum.sort_by(fn {layer, n} -> {-n, layer} end)

    failures =
      if layers == [],
        do: "no failures",
        else: "failures by layer: " <> Enum.map_join(layers, " · ", fn {l, n} -> "#{l} ×#{n}" end)

    regression_lines =
      for r <- regressions do
        "regression: #{r.versions_row} #{r.set} #{r.path}: pass → #{r.outcome}" <>
          if(r.layer, do: " @ #{public_layer(r.layer)}", else: "") <> " (cell #{r.id})"
      end

    kevin = if Enum.any?(regressions, &(&1.versions_row == "hex")), do: ["@kevin the hex row regressed"], else: []

    Enum.join(
      [
        "mob_ci: #{length(window)} cells (#{rows}) — #{t[:pass] || 0} pass, #{t[:fail] || 0} fail, " <>
          "#{t[:error] || 0} error, #{t[:skip] || 0} skip",
        failures
      ] ++ regression_lines ++ kevin ++ ["matrix: #{url}"],
      "\n"
    )
  end

  # ── markdown ─────────────────────────────────────────────────────────────────

  defp table(header, rows) do
    line = fn cols -> "| " <> Enum.join(cols, " | ") <> " |" end
    Enum.join([line.(header), line.(Enum.map(header, fn _ -> "---" end)) | Enum.map(rows, line)], "\n") <> "\n"
  end

  # One blank line between blocks, one newline at the end.
  defp tidy(text), do: (text |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim_trailing()) <> "\n"

  defp escape(text), do: String.replace(text, "|", "\\|")
end
