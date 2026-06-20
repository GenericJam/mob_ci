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
    base = "  #{@glyph[r.status]} #{r.id}  #{r.title}"
    if r.detail, do: base <> "\n        ↳ #{r.detail}", else: base
  end

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
    name = "#{r.id} — #{r.title}"
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
  """
  @spec write_artifacts(Path.t() | nil, [atom()], [Result.t()]) :: :ok
  def write_artifacts(nil, _set, _results), do: :ok

  def write_artifacts(dir, set, results) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "junit.xml"), junit(results))

    failing = Enum.filter(results, &(&1.status in [:fail, :error]))

    summary = %{
      plugin_set: set,
      ok: ok?(results),
      tally: tally(results),
      findings:
        Enum.map(failing, fn r ->
          %{id: r.id, title: r.title, status: r.status, detail: r.detail, evidence: inspect(r.evidence)}
        end)
    }

    File.write!(Path.join(dir, "summary.json"), inspect(summary, pretty: true, limit: :infinity))
    :ok
  end
end
