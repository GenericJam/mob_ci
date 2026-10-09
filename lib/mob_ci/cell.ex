defmodule MobCi.Cell do
  @moduledoc """
  One cell of the matrix: a named set × a version row, planned end to end —
  parse both names, resolve the core repos, read the set (the `default` set
  needs the row's mob_new), resolve the set's plugins, and point manifest
  lookup at the pinned sources. `mix ci.device --set … --versions …` and
  `mix ci.sweep --versions …` start here; `MobCi.Host.generate/4` takes the
  plan from there.
  """

  alias MobCi.{Plugins, Sets, Versions}

  @type t :: %{
          row: Versions.row(),
          spec: Sets.spec(),
          set: String.t(),
          plugins: [atom()],
          resolved: Versions.resolved()
        }

  @doc """
  Plan the cell for the raw `--set` / `--versions` values (either may be nil:
  `default` and `hex`). `include_excluded: true` keeps the plugins in
  `priv/sets/exclusions.exs` in the set (the static gate runs that way, so a
  parked collision stays visible). The remaining options go to
  `MobCi.Versions.resolve/2` (`:remote`, `:cache_dir`), so tests plan with
  nothing fetched.

  `:pins` (default: `$MOB_CI_PINS`, `MobCi.Versions.env_pins/0`) replays a
  stored cell: every repo is re-materialised at its recorded pin instead of
  resolved from the row, and the set is the recorded plugins, so a
  `random:<seed>` or `all` cell is the same set even after the pool changed.
  Sets defined in committed order (`all`, `pairwise:<i>`, `random:<seed>`)
  keep that order; sets with their own activation order (`default`, `demo`,
  files) keep theirs for the plugins they still list, then the rest in
  committed order. The pins' row must be the `--versions` row.
  """
  @spec plan(String.t() | nil, String.t() | nil, keyword()) :: {:ok, t()} | {:error, String.t()}
  def plan(set_name, versions_name, opts \\ []) do
    with {:ok, row} <- Versions.parse(versions_name),
         {:ok, spec} <- Sets.parse(set_name),
         {:ok, pins} <- pins(opts, row),
         opts = Keyword.put(opts, :pins, pins && pins.repos),
         {:ok, core} <- resolve(row, [:mob, :mob_dev, :mob_new], opts),
         {:ok, plugins} <- set_plugins(spec, core, Keyword.take(opts, [:include_excluded])),
         plugins = pinned_plugins(spec, plugins, pins),
         {:ok, more} <- resolve(row, plugins, Keyword.put(opts, :mob_new, false)) do
      # One mob_new pin per cell: the one the `default` set was read from.
      resolved = %{core | repos: Map.merge(more.repos, core.repos)}
      Plugins.put_resolved_dirs(Versions.source_dirs(resolved))
      {:ok, %{row: row, spec: spec, set: Sets.name(spec), plugins: plugins, resolved: resolved}}
    end
  end

  defp pins(opts, row) do
    with {:ok, pins} <- if(Keyword.has_key?(opts, :pins), do: {:ok, opts[:pins]}, else: Versions.env_pins()) do
      cond do
        is_nil(pins) -> {:ok, nil}
        pins.row == Versions.row_to_string(row) -> {:ok, pins}
        true -> {:error, "pinned versions are row #{pins.row}, not #{Versions.row_to_string(row)}"}
      end
    end
  end

  @doc false
  # The recorded plugins of a pinned cell, in the set's activation order.
  @spec pinned_plugins(Sets.spec(), [atom()], map() | nil) :: [atom()]
  def pinned_plugins(_spec, plugins, nil), do: plugins

  def pinned_plugins(spec, plugins, %{repos: repos}) do
    recorded = repos |> Map.keys() |> Kernel.--([:mob, :mob_dev, :mob_new])
    order = Versions.plugins()
    committed = Enum.sort_by(recorded, &{Enum.find_index(order, fn p -> p == &1 end) || length(order), &1})

    if spec in [:default, :demo] or match?({:file, _}, spec) do
      kept = Enum.filter(plugins, &(&1 in recorded))
      kept ++ (committed -- kept)
    else
      committed
    end
  end

  @doc "Same as `plan/3` but raises `Mix.Error` with the message."
  @spec plan!(String.t() | nil, String.t() | nil, keyword()) :: t()
  def plan!(set_name, versions_name, opts \\ []) do
    case plan(set_name, versions_name, opts) do
      {:ok, cell} -> cell
      {:error, msg} -> Mix.raise(msg)
    end
  end

  defp resolve(row, names, opts) do
    case Versions.resolve(row, Keyword.put(opts, :names, names)) do
      {:ok, _} = ok ->
        ok

      {:error, {name, reason}} ->
        {:error,
         "could not resolve #{name} for row #{Versions.row_to_string(row)}: #{inspect(reason)}"}
    end
  end

  defp set_plugins(spec, core, set_opts) do
    case Sets.resolve(spec, [mob_new_dir: Versions.mob_new_dir(core)] ++ set_opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, "could not read set #{Sets.name(spec)}: #{inspect(reason)}"}
    end
  end

  @doc "The console block every run prints: the set, its plugins, the exclusions in force, and the resolved versions."
  @spec describe(t()) :: String.t()
  def describe(%{set: set, plugins: plugins, resolved: resolved}) do
    """
    set: #{set} (#{length(plugins)} plugin#{if length(plugins) == 1, do: "", else: "s"})
      #{if plugins == [], do: "(none)", else: Enum.map_join(plugins, ", ", &Atom.to_string/1)}
    #{exclusions_line(plugins)}#{Versions.summary(resolved)}
    """
  end

  defp exclusions_line(plugins) do
    case Sets.exclusions() do
      [] ->
        ""

      excluded ->
        Enum.map_join(excluded, "", fn {p, reason} ->
          state =
            if p in plugins, do: "included for the static gate", else: "excluded from built sets"

          "  #{p}: #{state} — #{reason}\n"
        end)
    end
  end
end
