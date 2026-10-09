defmodule MobCi.Report do
  @moduledoc """
  Turns a list of `%MobCi.Result{}` into the two outputs a trigger consumes: a
  human console summary (for a local run or a CI log) and JUnit XML (for any CI
  UI that renders test reports — GH, Forgejo, GitLab all read it). Pure: results
  in, strings out, so it's unit-testable and trigger-agnostic.
  """

  alias MobCi.Result

  @glyph %{pass: "✓", fail: "✗", skip: "–", error: "!"}

  @doc "One-line-per-result console block plus a tallied footer."
  @spec console([Result.t()], keyword()) :: String.t()
  def console(results, opts \\ []) do
    title = Keyword.get(opts, :title, "mob_ci")
    lines = Enum.map(results, &result_line/1)
    counts = tally(results)

    footer =
      "#{counts.pass} passed, #{counts.fail} failed, #{counts.error} errored, #{counts.skip} skipped"

    Enum.join([header(title) | lines] ++ ["", footer], "\n")
  end

  defp header(title), do: "── #{title} " <> String.duplicate("─", max(0, 60 - String.length(title)))

  defp result_line(%Result{} = r) do
    base = "  #{@glyph[r.status]} #{r.id}  #{r.title}" <> layer_tag(r)
    if r.detail, do: base <> "\n        ↳ #{r.detail}", else: base
  end

  defp layer_tag(%Result{layer: nil}), do: ""
  defp layer_tag(%Result{layer: layer}), do: "  @ #{format_layer(layer)}"

  @doc """
  A layer as its canonical one-token form: `static | build:<path> |
  build:<path>/<p> | boot | plugin:<p> | plugin:<p>? | conflict:<set> | health`.
  """
  @spec format_layer(Result.layer()) :: String.t()
  def format_layer({:build, dir}), do: "build:#{dir}"
  def format_layer({:build, path, plugin}), do: "build:#{path}/#{plugin}"
  def format_layer({:plugin, p}), do: "plugin:#{p}"
  def format_layer({:plugin_unconfirmed, p}), do: "plugin:#{p}?"
  def format_layer({:conflict, set}), do: "conflict:#{Enum.join(set, ",")}"
  def format_layer(atom) when is_atom(atom), do: to_string(atom)

  @doc "Tally results by status."
  @spec tally([Result.t()]) :: %{pass: non_neg_integer(), fail: non_neg_integer(), error: non_neg_integer(), skip: non_neg_integer()}
  def tally(results) do
    base = %{pass: 0, fail: 0, error: 0, skip: 0}
    Enum.reduce(results, base, fn r, acc -> Map.update!(acc, r.status, &(&1 + 1)) end)
  end

  @doc "Did the run pass overall? (any :fail or :error → false)"
  @spec ok?([Result.t()]) :: boolean()
  def ok?(results), do: Enum.all?(results, &(&1.status in [:pass, :skip]))

  @doc "JUnit XML for the results. `:fail`→failure, `:error`→error, `:skip`→skipped."
  @spec junit([Result.t()], keyword()) :: String.t()
  def junit(results, opts \\ []) do
    suite = Keyword.get(opts, :suite, "mob_ci.device")
    counts = tally(results)

    cases = Enum.map_join(results, "\n", &junit_case/1)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuites>
      <testsuite name="#{xml(suite)}" tests="#{length(results)}" failures="#{counts.fail}" errors="#{counts.error}" skipped="#{counts.skip}">
    #{cases}
      </testsuite>
    </testsuites>
    """
  end

  defp junit_case(%Result{} = r) do
    name = if r.path, do: "[#{r.path}] #{r.id} — #{r.title}", else: "#{r.id} — #{r.title}"
    body = junit_body(r)
    "    <testcase name=\"#{xml(name)}\" classname=\"mob_ci\">#{body}</testcase>"
  end

  defp junit_body(%Result{status: :pass}), do: ""
  defp junit_body(%Result{status: :skip, detail: d}), do: "<skipped message=\"#{xml(d || "")}\"/>"

  defp junit_body(%Result{status: :fail, detail: d, evidence: e}),
    do: "<failure message=\"#{xml(d || "")}\">#{xml(inspect(e, pretty: true, limit: :infinity))}</failure>"

  defp junit_body(%Result{status: :error, detail: d, evidence: e}),
    do: "<error message=\"#{xml(d || "")}\">#{xml(inspect(e, pretty: true, limit: :infinity))}</error>"

  defp xml(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp xml(other), do: xml(inspect(other))

  @doc """
  Write `junit.xml` + a `counterexample.json`-ish summary into `dir`. The
  counterexample is the load-bearing artifact: the failing plugin set + each
  failing invariant's detail/evidence, so a sweep failure is reproducible.
  `results` may span several build paths of the cell (each result carries
  its `path`).
  """
  @spec write_artifacts(Path.t() | nil, [atom()], [Result.t()]) :: :ok
  def write_artifacts(nil, _set, _results), do: :ok

  def write_artifacts(dir, set, results) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "junit.xml"), junit(results))

    failing = Enum.filter(results, &(&1.status in [:fail, :error]))

    stamped = List.first(results) || %{set: nil, versions: nil}

    summary = %{
      plugin_set: set,
      set: stamped.set,
      versions: stamped.versions,
      paths: results |> Enum.map(& &1.path) |> Enum.uniq(),
      ok: ok?(results),
      tally: tally(results),
      findings:
        Enum.map(failing, fn r ->
          %{
            id: r.id,
            path: r.path,
            title: r.title,
            status: r.status,
            layer: r.layer && format_layer(r.layer),
            detail: r.detail,
            evidence: inspect(r.evidence)
          }
        end)
    }

    File.write!(Path.join(dir, "summary.json"), inspect(summary, pretty: true, limit: :infinity))
    :ok
  end

  # ── the stored grid (mix ci.report) ─────────────────────────────────────────

  @doc """
  The latest grid per versions row, as text: one block per row, one line per
  set, one column per build path (`deploy:android`, `release:android`,
  `deploy:ios_sim`, …), each cell `<glyph> <outcome>` plus `@ <layer>` when
  attributed. `cells` are `MobCi.Store.query/2` summary rows
  (`invariant: nil, latest: true`).
  """
  @spec grid([map()]) :: String.t()
  def grid([]), do: "no results in the store yet"

  def grid(cells) do
    cells
    |> Enum.group_by(& &1.versions_row)
    |> Enum.sort_by(fn {row, _} -> {row_rank(row), row} end)
    |> Enum.map_join("\n\n", fn {row, row_cells} -> row_block(row, row_cells) end)
  end

  defp row_rank("hex"), do: 0
  defp row_rank("master"), do: 1
  defp row_rank(_), do: 2

  defp row_block(row, cells) do
    paths = cells |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort_by(&path_rank/1)
    by_cell = Map.new(cells, &{{&1.set, &1.path}, &1})
    sets = cells |> Enum.map(& &1.set) |> Enum.uniq() |> Enum.sort_by(&set_rank/1)
    newest = cells |> Enum.map(& &1.started_at) |> Enum.max()

    table =
      [["set" | paths]] ++
        for set <- sets do
          [set | Enum.map(paths, fn p -> grid_cell(Map.get(by_cell, {set, p})) end)]
        end

    widths = Enum.zip_with(table, fn col -> col |> Enum.map(&String.length/1) |> Enum.max() end)

    lines =
      Enum.map(table, fn cols ->
        cols
        |> Enum.zip(widths)
        |> Enum.map_join("  ", fn {c, w} -> String.pad_trailing(c, w) end)
        |> String.trim_trailing()
      end)

    tally = Enum.frequencies_by(cells, & &1.outcome)

    footer =
      "#{Map.get(tally, :pass, 0)} passed, #{Map.get(tally, :fail, 0)} failed, " <>
        "#{Map.get(tally, :error, 0)} errored, #{Map.get(tally, :skip, 0)} skipped"

    Enum.join(
      [header("versions: #{row} (latest run #{newest})") | Enum.map(lines, &("  " <> &1))] ++ ["  " <> footer],
      "\n"
    )
  end

  defp grid_cell(nil), do: "·"

  defp grid_cell(%{outcome: outcome, layer: layer}),
    do: "#{@glyph[outcome]} #{outcome}" <> if(layer, do: " @ #{layer}", else: "")

  @doc false
  # Column order: static first, then android (deploy before release), then the
  # other platforms (deploy before release; a simulator before a device).
  # Shared with `MobCi.Matrix`.
  def path_rank("static"), do: {0, 0, 0, "static"}

  def path_rank(path) do
    {kind, platform} =
      case String.split(path, ":", parts: 2) do
        [k, p] -> {k, p}
        [k] -> {k, ""}
      end

    rank = Enum.find_index(["deploy", "release"], &(&1 == kind)) || 2
    target = Enum.find_index(["android", "ios_sim", "ios_device"], &(&1 == platform)) || 3
    {if(platform == "android", do: 1, else: 2), rank, target, path}
  end

  @doc false
  # Row order: blank, default, all, demo first; then the rest alphabetically
  # (singletons group). Shared with `MobCi.Matrix`.
  def set_rank(set) do
    {Enum.find_index(["blank", "default", "all", "demo"], &(&1 == set)) || 4, set}
  end
end
