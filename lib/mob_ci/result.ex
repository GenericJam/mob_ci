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
  """

  @enforce_keys [:id, :title, :status]
  defstruct [:id, :title, :status, :detail, :evidence]

  @type status :: :pass | :fail | :skip | :error
  @type t :: %__MODULE__{
          id: atom(),
          title: String.t(),
          status: status(),
          detail: String.t() | nil,
          evidence: term()
        }

  def pass(id, title, detail \\ nil), do: %__MODULE__{id: id, title: title, status: :pass, detail: detail}
  def fail(id, title, detail, evidence \\ nil),
    do: %__MODULE__{id: id, title: title, status: :fail, detail: detail, evidence: evidence}

  def skip(id, title, detail), do: %__MODULE__{id: id, title: title, status: :skip, detail: detail}

  def error(id, title, detail, evidence \\ nil),
    do: %__MODULE__{id: id, title: title, status: :error, detail: detail, evidence: evidence}

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
    %__MODULE__{id: id, title: title, status: status, detail: summarize(bad), evidence: bad}
  end

  defp summarize(results) do
    results
    |> Enum.map(fn r -> "#{r.detail || r.id}" end)
    |> Enum.join("; ")
  end
end
