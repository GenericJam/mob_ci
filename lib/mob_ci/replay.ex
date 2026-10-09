defmodule MobCi.Replay do
  @moduledoc """
  `mix ci.replay <cell id>`: rerun one stored cell exactly, or promote a
  failed sampled cell to a committed regression set.

  A stored cell knows its set, version row, platform, path and the exact
  pins it ran with (`versions`). `argv/1` turns it into the `mix ci.device`
  invocation of that one path; `pins_json/1` is the record `mix ci.replay`
  hands over in `$MOB_CI_PINS`, so `MobCi.Cell.plan/3` re-materialises those
  pins and the recorded plugin list instead of resolving the row afresh (a
  `random:<seed>` or `all` cell stays the same set after the pool moved).

  `promotion/2` freezes a failing `random:<seed>` or device-sweep
  (`sweep:<plugins>`) cell into `priv/sets/<name>.exs`, which `MobCi.Sets`
  then runs every night as `--set <name>`.
  """

  alias MobCi.{Matrix, Sets, Store, Versions}

  @doc """
  The `mix ci.device` arguments that rerun `cell` (a store row; its set,
  platform, path and run's versions_row are used). Errors name why a cell
  can't be replayed as such: a fixture-host row (`harness`, `sloppy_joe`), a
  sampled sweep subset (promote it first), or an unknown path.
  """
  @spec argv(map()) :: {:ok, [String.t()]} | {:error, String.t()}
  def argv(%{set: set, platform: platform, path: path, versions_row: row} = cell) do
    with :ok <- replayable_row(row),
         :ok <- replayable_set(cell),
         {:ok, path_args} <- path_args(platform, path) do
      {pre, post} = path_args
      {:ok, pre ++ ["--set", set, "--versions", row] ++ post}
    end
  end

  defp replayable_row(row) do
    case Versions.parse(row) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error,
         "cell ran on the #{row} host, not a version row; rerun it with `mix ci.device --host #{row} --plugins …`"}
    end
  end

  defp replayable_set(%{set: set, id: id}) do
    case Sets.parse(set) do
      {:ok, _} ->
        :ok

      {:error, msg} ->
        if Matrix.sampled_set?(set),
          do: {:error, "#{set} is a sampled sweep subset, not a named set: `mix ci.replay #{id} --promote` commits it as one, then replay that"},
          else: {:error, msg}
    end
  end

  defp path_args("all", "static"), do: {:ok, {[], ["--static"]}}
  defp path_args("android", "deploy:android"), do: {:ok, {[], ["--paths", "deploy"]}}
  defp path_args("android", "release:android"), do: {:ok, {[], ["--paths", "release"]}}
  defp path_args("ios", path), do: {:ok, {["--platform", "ios"], ["--paths", path]}}
  defp path_args(platform, path), do: {:error, "no replay for platform #{platform} path #{path}"}

  @doc "The cell's versions record as the JSON `$MOB_CI_PINS` names, or an error when the cell recorded none."
  @spec pins_json(map()) :: {:ok, String.t()} | {:error, String.t()}
  def pins_json(%{versions: %{"row" => _, "repos" => _} = versions}), do: {:ok, JSON.encode!(versions)}
  def pins_json(%{id: id}), do: {:error, "cell #{id} recorded no versions; replay it with --current (the row as it resolves today)"}

  @doc """
  The environment `mix ci.replay` runs `mix ci.device` in (nil = unset): a
  pinned replay names its pins file and records as trigger `replay`
  (`MobCi.Store.run_context/2`), which the matrix and the regression check
  skip; `--current` (no pins file) records as `replay-current`, a real
  result of the row today.
  """
  @spec env(Path.t() | nil) :: [{String.t(), String.t() | nil}]
  def env(nil), do: [{"MOB_CI_PINS", nil}, {"MOB_CI_TRIGGER", "replay-current"}]
  def env(pins_file), do: [{"MOB_CI_PINS", pins_file}, {"MOB_CI_TRIGGER", "replay"}]

  @doc """
  A failing sampled cell as a regression set: `{:ok, name, source}` for
  `priv/sets/<name>.exs`. The plugins are the recorded ones (the pins of a
  `random:<seed>` cell, in committed order; the list a `sweep:<plugins>`
  name spells out). `opts[:name]` overrides the default name
  (`random-<seed>` / `sweep-<cell id>`).
  """
  @spec promotion(map(), keyword()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def promotion(cell, opts \\ []) do
    with :ok <- failing(cell),
         {:ok, default_name, plugins} <- sampled_plugins(cell),
         name = Keyword.get(opts, :name) || default_name,
         :ok <- valid_name(name) do
      {:ok, name, source(cell, name, plugins)}
    end
  end

  defp failing(%{outcome: outcome}) when outcome in [:fail, :error], do: :ok
  defp failing(%{id: id, outcome: outcome}), do: {:error, "cell #{id} is #{outcome}; only a failing cell becomes a regression set"}

  defp sampled_plugins(%{set: "random:" <> seed} = cell) do
    order = Versions.plugins()

    case cell.versions |> Store.pins() |> Map.keys() |> Kernel.--(["mob", "mob_dev", "mob_new"]) do
      [] ->
        {:error, "cell #{cell.id} recorded no plugin pins; its random:#{seed} set can't be reconstructed"}

      names ->
        plugins = names |> Enum.map(&String.to_atom/1) |> Enum.sort_by(&{Enum.find_index(order, fn p -> p == &1 end) || length(order), &1})
        {:ok, "random-#{seed}", plugins}
    end
  end

  defp sampled_plugins(%{set: "sweep:" <> list} = cell) do
    if Matrix.sampled_set?(cell.set) do
      known = Versions.plugins()
      plugins = list |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)

      case plugins -- known do
        [] -> {:ok, "sweep-#{cell.id}", plugins}
        unknown -> {:error, "#{cell.set} names plugins not in priv/plugins.exs: #{Enum.join(unknown, ", ")}"}
      end
    else
      {:error, "#{cell.set} is a static sweep of a named set; there is nothing to freeze"}
    end
  end

  defp sampled_plugins(%{set: set}),
    do: {:error, "#{set} is already a deterministic set; only random:<seed> and sweep subsets are promoted"}

  defp valid_name(name) do
    cond do
      not Regex.match?(~r/^[a-z0-9_-]+$/, name) -> {:error, "set name #{inspect(name)} must match [a-z0-9_-]+"}
      name in ["pairwise", "demo", "exclusions", "blank", "default", "all"] -> {:error, "#{name} is a reserved set name"}
      true -> :ok
    end
  end

  defp source(cell, name, plugins) do
    pins = Store.pins(cell.versions)
    core = Enum.map_join(["mob", "mob_dev", "mob_new"], ", ", &"#{&1} #{Matrix.pin_label(pins[&1])}")

    """
    # Regression set, promoted by `mix ci.replay #{cell.id} --promote` from the
    # #{cell.set} cell #{cell.id} (run #{cell.run_id}, #{cell.started_at}) that
    # #{if cell.outcome == :fail, do: "failed", else: "errored"} on #{cell.versions_row} #{cell.path}#{if cell.layer, do: " @ #{Matrix.public_layer(cell.layer)}", else: ""}.
    # Core pins of that run: #{core}.
    # Runs every night as `--set #{name}`; delete it once the finding is fixed.
    #{inspect(plugins, limit: :infinity)}
    """
  end
end
