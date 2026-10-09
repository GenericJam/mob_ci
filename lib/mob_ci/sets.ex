defmodule MobCi.Sets do
  @moduledoc """
  Named, deterministic plugin sets — what runs every night beside the
  StreamData sweep (`MobCi.Sweep`):

      blank            no plugins: the generator and core alone
      default          what `mix mob.new` activates today (read from the row's
                       mob_new, never hardcoded here)
      singleton:<p>    one plugin alone
      all              every buildable first-party plugin
      demo             mob_plugin_demo's activation (priv/sets/demo.exs), the
                       first-party part of it
      pairwise:<i>     row <i> of the committed pairwise covering array
                       (priv/sets/pairwise.exs; `mix ci.sets --regen`)
      random:<seed>    a seeded 3–8 plugin subset, replayable from the seed
      <file>           priv/sets/<file>.exs, a committed regression set

  Every set is drawn from `MobCi.Versions.plugins/0` minus what
  `priv/device_caps.exs` marks unbuildable (`MobCi.DeviceCaps.buildable/1`)
  and minus `priv/sets/exclusions.exs` (plugins parked while a known finding
  is open; `--static` plans with them included so the finding stays visible),
  so the same name is the same set on every machine and every night. `all`
  and the pairwise rows use the committed plugin order; `default`, `demo` and
  file sets keep their source's activation order.
  """

  alias MobCi.{DeviceCaps, Versions}

  @sets_dir Path.expand("../../priv/sets", __DIR__)
  @pairwise_path Path.join(@sets_dir, "pairwise.exs")
  @demo_path Path.join(@sets_dir, "demo.exs")
  @exclusions_path Path.join(@sets_dir, "exclusions.exs")
  # Files under priv/sets/ that are not regression sets: the array, the demo
  # list (both have their own names) and the exclusions config.
  @not_sets ["pairwise", "demo", "exclusions"]

  @type spec ::
          :blank
          | :default
          | :all
          | :demo
          | {:singleton, atom()}
          | {:pairwise, non_neg_integer()}
          | {:random, non_neg_integer()}
          | {:file, String.t()}

  # ── the pool ─────────────────────────────────────────────────────────────────

  @doc """
  The buildable first-party plugins minus the committed exclusions, in
  committed order — the pool every built set draws from. `include_excluded:
  true` (what `--static` plans with) keeps the excluded plugins in, so the
  finding that excluded them stays visible.
  """
  @spec pool(keyword()) :: [atom()]
  def pool(opts \\ []) do
    buildable = DeviceCaps.buildable(Versions.plugins())

    if Keyword.get(opts, :include_excluded, false),
      do: buildable,
      else: Enum.reject(buildable, &Keyword.has_key?(exclusions(), &1))
  end

  @doc """
  Plugins kept out of the built sets while a known finding is open
  (`priv/sets/exclusions.exs`: plugin → reason naming the FINDINGS entry).
  The `:mob_ci, :exclusions` application env replaces the committed list when
  set (tests park a plugin without editing the file).
  """
  @spec exclusions() :: [{atom(), String.t()}]
  def exclusions do
    case Application.fetch_env(:mob_ci, :exclusions) do
      {:ok, list} ->
        list

      :error ->
        {list, _} = Code.eval_file(@exclusions_path)
        list
    end
  end

  # ── names ────────────────────────────────────────────────────────────────────

  @doc """
  Parse a `--set` name. Unknown names and malformed indices/seeds are errors
  with a message that lists what is accepted.
  """
  @spec parse(String.t() | nil) :: {:ok, spec()} | {:error, String.t()}
  def parse(nil), do: {:ok, :default}
  def parse("blank"), do: {:ok, :blank}
  def parse("default"), do: {:ok, :default}
  def parse("all"), do: {:ok, :all}
  def parse("demo"), do: {:ok, :demo}

  # A singleton of an excluded plugin still runs: alone it doesn't collide.
  def parse("singleton:" <> name) do
    plugin = String.to_atom(name)

    if plugin in Versions.plugins(),
      do: {:ok, {:singleton, plugin}},
      else: {:error, "unknown plugin #{inspect(name)} in singleton set (see priv/plugins.exs)"}
  end

  def parse("pairwise:" <> index) do
    rows = length(pairwise_rows())

    case Integer.parse(index) do
      {i, ""} when i >= 0 and i < rows ->
        {:ok, {:pairwise, i}}

      {i, ""} ->
        {:error,
         "pairwise index #{i} out of range (the committed array has #{rows} rows: 0..#{rows - 1})"}

      _ ->
        {:error, "pairwise index must be an integer, got #{inspect(index)}"}
    end
  end

  def parse("random:" <> seed) do
    case Integer.parse(seed) do
      {s, ""} when s >= 0 -> {:ok, {:random, s}}
      _ -> {:error, "random seed must be a non-negative integer, got #{inspect(seed)}"}
    end
  end

  def parse(name) when is_binary(name) do
    if Regex.match?(~r/^[a-z0-9_-]+$/, name) and name not in @not_sets and File.regular?(file_path(name)) do
      {:ok, {:file, name}}
    else
      {:error,
       "unknown --set #{inspect(name)} (expected: blank | default | all | demo | singleton:<plugin> | " <>
         "pairwise:<i> | random:<seed> | a file under priv/sets/)"}
    end
  end

  @doc "Same as `parse/1` but raises `Mix.Error` with the message."
  @spec parse!(String.t() | nil) :: spec()
  def parse!(name) do
    case parse(name) do
      {:ok, spec} -> spec
      {:error, msg} -> Mix.raise(msg)
    end
  end

  @doc "The canonical name of a spec (what results record)."
  @spec name(spec()) :: String.t()
  def name(:blank), do: "blank"
  def name(:default), do: "default"
  def name(:all), do: "all"
  def name(:demo), do: "demo"
  def name({:singleton, p}), do: "singleton:#{p}"
  def name({:pairwise, i}), do: "pairwise:#{i}"
  def name({:random, s}), do: "random:#{s}"
  def name({:file, f}), do: f

  @doc "Every nightly set name, in run order: blank, default, singletons, all, pairwise rows, demo, files."
  @spec nightly() :: [String.t()]
  def nightly do
    singletons = for p <- pool(include_excluded: true), do: "singleton:#{p}"
    # The greedy array's first row is the whole pool (ties go to "on"), which
    # `all` already builds; don't run it twice.
    pool = pool()
    pairwise = for {row, i} <- Enum.with_index(pairwise_rows()), row != pool, do: "pairwise:#{i}"
    ["blank", "default"] ++ singletons ++ ["all"] ++ pairwise ++ ["demo"] ++ file_names()
  end

  # ── resolution ───────────────────────────────────────────────────────────────

  @doc """
  The plugins of a set. `:default` needs `opts[:mob_new_dir]` (the resolved
  row's mob_new checkout, see `default_plugins/1`); everything else is pure.
  `include_excluded: true` draws from the pool with the committed exclusions
  kept in (`all`, `default`, `demo` and file sets grow back; the pairwise
  rows and seeded sets are fixed by their definition and don't change).
  """
  @spec resolve(spec(), keyword()) :: {:ok, [atom()]} | {:error, term()}
  def resolve(:blank, _opts), do: {:ok, []}
  def resolve(:all, opts), do: {:ok, pool(opts)}
  def resolve(:demo, opts), do: {:ok, in_pool(demo_plugins(), opts)}
  def resolve({:singleton, p}, _opts), do: {:ok, [p]}
  def resolve({:pairwise, i}, _opts), do: {:ok, Enum.at(pairwise_rows(), i)}
  def resolve({:random, seed}, _opts), do: {:ok, random(seed, pool())}
  def resolve({:file, name}, opts), do: {:ok, file_plugins(name, opts)}

  def resolve(:default, opts) do
    case Keyword.fetch(opts, :mob_new_dir) do
      {:ok, dir} ->
        with {:ok, plugins} <- default_plugins(dir), do: {:ok, in_pool(plugins, opts)}

      :error ->
        {:error, :default_needs_mob_new_dir}
    end
  end

  @doc """
  What this mob_new's `mix mob.new` (non-blank) activates — read from its
  `MobNew.ProjectGenerator.assigns/2` by running `mix run` inside the checkout
  (after `mix deps.get` there, in prod so only its runtime deps are fetched),
  so the list follows the resolved row rather than this repo's memory of it.
  """
  @spec default_plugins(Path.t()) :: {:ok, [atom()]} | {:error, term()}
  def default_plugins(mob_new_dir) do
    expr =
      ~s|IO.write("MOB_CI_DEFAULT " <> Enum.join(MobNew.ProjectGenerator.assigns("mob_ci_probe", []).mob_plugins, " "))|

    with {:ok, _} <- mob_new_mix(["deps.get"], mob_new_dir),
         {:ok, out} <- mob_new_mix(["run", "--no-start", "-e", expr], mob_new_dir) do
      case Regex.run(~r/MOB_CI_DEFAULT ?(.*)$/m, out) do
        [_, list] -> {:ok, list |> String.split(" ", trim: true) |> Enum.map(&String.to_atom/1)}
        nil -> {:error, {:default_plugins, :no_marker, String.slice(out, -400, 400)}}
      end
    end
  end

  defp mob_new_mix(args, dir) do
    case System.cmd("mix", args, cd: dir, env: [{"MIX_ENV", "prod"}], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:default_plugins, hd(args), code, String.slice(out, -400, 400)}}
    end
  end

  # ── random ───────────────────────────────────────────────────────────────────

  @doc "A seeded 3–8 element subset of `pool` in pool order; the same seed always gives the same set."
  @spec random(non_neg_integer(), [atom()]) :: [atom()]
  def random(seed, pool) do
    state = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
    {size, state} = :rand.uniform_s(6, state)
    size = min(size + 2, length(pool))

    {picked, _} =
      Enum.reduce(1..size//1, {[], {pool, state}}, fn _, {acc, {rest, st}} ->
        {i, st} = :rand.uniform_s(length(rest), st)
        {p, rest} = List.pop_at(rest, i - 1)
        {[p | acc], {rest, st}}
      end)

    Enum.filter(pool, &(&1 in picked))
  end

  # ── pairwise covering array ──────────────────────────────────────────────────

  @doc """
  A greedy binary covering array of strength 2 over `plugins`: a list of
  subsets such that for every two plugins each of the four activation
  combinations (both, either alone, neither) occurs in some subset. Rows are
  built one at a time, each the best of `2 × length(plugins)` greedy
  candidates (one per starting factor and starting value), so the result is a
  pure function of the input.
  Fewer than two plugins have no pairs: the array is empty.
  """
  @spec pairwise([atom()]) :: [[atom()]]
  def pairwise(plugins) when length(plugins) < 2, do: []

  def pairwise(plugins) do
    n = length(plugins)

    uncovered =
      for i <- 0..(n - 2),
          j <- (i + 1)..(n - 1),
          vi <- [0, 1],
          vj <- [0, 1],
          into: MapSet.new(),
          do: {i, j, vi, vj}

    rows = build_rows(n, uncovered, [])
    for row <- rows, do: for({p, 1} <- Enum.zip(plugins, row), do: p)
  end

  defp build_rows(n, uncovered, acc) do
    if MapSet.size(uncovered) == 0 do
      Enum.reverse(acc)
    else
      {row, covered} =
        for(start <- 0..(n - 1), first <- [1, 0], do: greedy_row(n, start, first, uncovered))
        |> Enum.max_by(fn {_row, covered} -> MapSet.size(covered) end)

      # Any uncovered {i, j, vi, vj} is covered by the candidate that starts at
      # i with vi (j then gains at least that tuple), so every round progresses.
      if MapSet.size(covered) == 0, do: raise("pairwise: no candidate row covers a new pair")

      build_rows(n, MapSet.difference(uncovered, covered), [row | acc])
    end
  end

  # Assign factors in order start, start+1, … (mod n), the first taking
  # `first`; each later one takes the value that covers more still-uncovered
  # tuples against the factors already assigned, preferring 1 on a tie (dense
  # rows first). Returns {values_by_index, covered}.
  defp greedy_row(n, start, first, uncovered) do
    order = for k <- 1..(n - 1)//1, do: rem(start + k, n)

    assigned =
      Enum.reduce(order, %{start => first}, fn i, assigned ->
        gain = fn v ->
          Enum.count(assigned, fn {j, vj} -> MapSet.member?(uncovered, tuple(i, v, j, vj)) end)
        end

        v = if gain.(1) >= gain.(0), do: 1, else: 0
        Map.put(assigned, i, v)
      end)

    row = for i <- 0..(n - 1), do: Map.fetch!(assigned, i)

    covered =
      for i <- 0..(n - 2),
          j <- (i + 1)..(n - 1),
          t = {i, j, Enum.at(row, i), Enum.at(row, j)},
          MapSet.member?(uncovered, t),
          into: MapSet.new(),
          do: t

    {row, covered}
  end

  defp tuple(i, vi, j, vj) when i < j, do: {i, j, vi, vj}
  defp tuple(i, vi, j, vj), do: {j, i, vj, vi}

  @doc "Does `rows` cover every pair of `plugins` in all four activation combinations?"
  @spec covers_all_pairs?([atom()], [[atom()]]) :: boolean()
  def covers_all_pairs?(plugins, rows), do: uncovered_pairs(plugins, rows) == []

  @doc "The `{a, b, a_on?, b_on?}` combinations no row covers (empty for a complete array)."
  @spec uncovered_pairs([atom()], [[atom()]]) :: [{atom(), atom(), boolean(), boolean()}]
  def uncovered_pairs(plugins, rows) do
    sets = Enum.map(rows, &MapSet.new/1)

    for {a, i} <- Enum.with_index(plugins),
        {b, j} <- Enum.with_index(plugins),
        i < j,
        va <- [true, false],
        vb <- [true, false],
        not Enum.any?(sets, &(MapSet.member?(&1, a) == va and MapSet.member?(&1, b) == vb)),
        do: {a, b, va, vb}
  end

  @doc "The committed array's rows (`priv/sets/pairwise.exs`)."
  @spec pairwise_rows() :: [[atom()]]
  def pairwise_rows, do: committed_pairwise().sets

  @doc "The committed `%{plugins, sets}` of `priv/sets/pairwise.exs`."
  @spec committed_pairwise() :: %{plugins: [atom()], sets: [[atom()]]}
  def committed_pairwise do
    {%{plugins: _, sets: _} = data, _} = Code.eval_file(@pairwise_path)
    data
  end

  @doc "Source of `priv/sets/pairwise.exs` for the current pool (what `mix ci.sets --regen` writes)."
  @spec pairwise_source([atom()]) :: String.t()
  def pairwise_source(plugins) do
    rows = pairwise(plugins)

    """
    # Generated by `mix ci.sets --regen` — do not edit. A greedy pairwise covering
    # array (strength 2) over the buildable first-party plugins: every pair of
    # plugins appears together, each alone, and both absent in some row.
    # `test/mob_ci/sets_test.exs` fails when this drifts from the pool.
    %{
      plugins: #{wrap(plugins, 2)},
      sets: [
    #{Enum.map_join(rows, ",\n", fn row -> "    " <> wrap(row, 4) end)}
      ]
    }
    """
  end

  defp wrap(list, indent) do
    list
    |> inspect(limit: :infinity, pretty: true, width: 78 - indent)
    |> String.replace("\n", "\n" <> String.duplicate(" ", indent))
  end

  @doc "Path of the committed pairwise array."
  def pairwise_path, do: @pairwise_path

  # ── demo + files ─────────────────────────────────────────────────────────────

  @doc "mob_plugin_demo's activation list as committed in `priv/sets/demo.exs` (all 18, including its in-tree prototypes)."
  @spec demo_plugins() :: [atom()]
  def demo_plugins do
    {%{plugins: plugins}, _} = Code.eval_file(@demo_path)
    plugins
  end

  defp file_path(name), do: Path.join(@sets_dir, "#{name}.exs")

  defp file_plugins(name, opts) do
    {plugins, _} = Code.eval_file(file_path(name))
    in_pool(plugins, opts)
  end

  # Keep the source's own order (mob_new's, the demo's, the file's): activation
  # order is part of what a set tests.
  defp in_pool(plugins, opts) do
    pool = pool(opts)
    Enum.filter(plugins, &(&1 in pool))
  end

  defp file_names do
    @sets_dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".exs"))
    |> Enum.reject(&(&1 in @not_sets))
    |> Enum.sort()
  end
end
