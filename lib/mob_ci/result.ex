defmodule MobCi.Result do
  @moduledoc """
  One invariant's outcome. `status` is `:pass | :fail | :skip | :error`:

    * `:pass`  — the invariant held.
    * `:fail`  — the invariant was checkable and did not hold (a real finding).
    * `:skip`  — not applicable to this set (e.g. P8 with no migration-bearing
                 plugin activated), or gated off by `device_caps` as an expected
                 hardware limitation. Not a failure.
    * `:error` — the check itself couldn't run (dead node, RPC failure, missing
                 build output). Distinct from `:fail` so infra flakiness isn't
                 reported as a product bug.

  `set` and `versions` say which cell produced the result: the set name
  (`MobCi.Sets.name/1`) and the version record (`MobCi.Versions.record/1`);
  `path` which build path of that cell (`"deploy:android"`, the dev APK
  `mix mob.deploy` installs; `"release:android"`, the `mix mob.release`
  bundle). Invariants leave them `nil`; the orchestrator stamps every result
  of a run with `stamp/4` before it is reported or stored.
  `layer` says *where* a non-passing result belongs, so every failure is
  attributed (a result that cannot say which layer failed is a bug in mob_ci):

    * `:static`            — the manifests / `cross_validate` verdict.
    * `{:build, dir}`      — the native build of the host at `dir`.
    * `{:build, path}` / `{:build, path, p}` — a build path that failed
                             outright (`"deploy:android"`, `"release:android"`),
                             naming the plugin mob_dev blamed when it did.
    * `:boot`              — farm boot / launch / node registration.
    * `{:plugin, p}`       — one plugin's own contribution misbehaved.
    * `{:plugin_unconfirmed, p}` — p's self-test failed in a larger set and
                             there is no singleton result to say whether it
                             fails alone (P12); reported as `plugin:<p>?`.
    * `{:conflict, [p]}`   — several plugins implicated; P12 says so when a
                             self-test passes in p's singleton cell but fails here.
    * `:health`            — the app BEAM as a whole (died, or outlived release).

  `nil` on a pass/skip.
  """

  @enforce_keys [:id, :title, :status]
  defstruct [:id, :title, :status, :detail, :evidence, :set, :versions, :path, :layer]

  @type status :: :pass | :fail | :skip | :error
  @type layer ::
          :static
          | {:build, Path.t()}
          | {:build, String.t(), atom()}
          | :boot
          | {:plugin, atom()}
          | {:plugin_unconfirmed, atom()}
          | {:conflict, [atom()]}
          | :health
          | nil
  @type t :: %__MODULE__{
          id: atom(),
          title: String.t(),
          status: status(),
          detail: String.t() | nil,
          evidence: term(),
          set: String.t() | nil,
          versions: map() | nil,
          path: String.t() | nil,
          layer: layer()
        }

  @doc "Stamp every result with the cell (and build path) that produced it."
  @spec stamp([t()], String.t() | nil, map() | nil, String.t() | nil) :: [t()]
  def stamp(results, set, versions, path \\ nil),
    do: Enum.map(results, &%{&1 | set: set, versions: versions, path: path})

  def pass(id, title, detail \\ nil), do: %__MODULE__{id: id, title: title, status: :pass, detail: detail}
  def fail(id, title, detail, evidence \\ nil),
    do: %__MODULE__{id: id, title: title, status: :fail, detail: detail, evidence: evidence}

  def skip(id, title, detail), do: %__MODULE__{id: id, title: title, status: :skip, detail: detail}

  def error(id, title, detail, evidence \\ nil),
    do: %__MODULE__{id: id, title: title, status: :error, detail: detail, evidence: evidence}

  @doc "Attribute a result to a layer (no-op on pass/skip, which have nothing to attribute)."
  @spec at(t(), layer()) :: t()
  def at(%__MODULE__{status: s} = r, _layer) when s in [:pass, :skip], do: r
  def at(%__MODULE__{} = r, layer), do: %{r | layer: layer}

  @doc """
  The layer a list of (bad) results points at: one shared layer stays as is;
  several distinct plugins become `{:conflict, plugins}`; otherwise the first.
  """
  @spec attribute([t()]) :: layer()
  def attribute(results) do
    case results |> Enum.map(& &1.layer) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> nil
      [one] -> one
      many -> if Enum.all?(many, &match?({:plugin, _}, &1)), do: {:conflict, Enum.map(many, &elem(&1, 1))}, else: hd(many)
    end
  end

  @doc "Collapse a list of per-item results into one (worst status wins). Results-first so it pipes."
  @spec rollup([t()], atom(), String.t()) :: t()
  def rollup(results, id, title) do
    cond do
      results == [] -> skip(id, title, "no applicable subjects in this set")
      Enum.any?(results, &(&1.status == :fail)) -> worst(id, title, results, :fail)
      Enum.any?(results, &(&1.status == :error)) -> worst(id, title, results, :error)
      Enum.all?(results, &(&1.status == :skip)) -> skip(id, title, summarize(results))
      true -> pass(id, title, summarize(results))
    end
  end

  defp worst(id, title, results, status) do
    bad = Enum.filter(results, &(&1.status == status))
    %__MODULE__{id: id, title: title, status: status, detail: summarize(bad), evidence: bad, layer: attribute(bad)}
  end

  defp summarize(results) do
    results
    |> Enum.map(fn r -> "#{r.detail || r.id}" end)
    |> Enum.join("; ")
  end
end
