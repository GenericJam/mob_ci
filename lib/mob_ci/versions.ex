defmodule MobCi.Versions do
  @moduledoc """
  Version rows: which mob, mob_dev, mob_new and first-party plugins a run
  builds against, resolved to exact pins before anything is generated.

      row              mob, mob_dev, mob_new, every plugin
      hex              latest stable release of each on Hex
      master           the default-branch sha of each GitHub repo
      rc:<repo>@<sha>  <repo> at <sha>, everything else latest Hex

  `resolve/2` turns a row into `%{row: row, repos: %{name => pin}}` where a
  pin is exact: a Hex version or a git sha plus the checkout it was materialised
  into (clones live under `~/.cache/mob_ci/repos/<name>`, fetched not re-cloned;
  per-sha checkouts under `~/.cache/mob_ci/src/<name>/<sha>` so concurrent rows
  never fight over one working tree). The pins become the dep tuples a host's
  `mix.exs` needs (`dep/2`, `core_deps/1`, `render_dep/1`) and a serialisable
  record (`record/1`) stored with every result.

  Network and disk are behind the `:remote` option (a map of functions, see
  `MobCi.Versions.Remote`), so resolution is unit-tested with nothing fetched.
  """

  alias MobCi.Versions.Remote

  @plugins_path Path.expand("../../priv/plugins.exs", __DIR__)
  @cache_dir Path.expand("~/.cache/mob_ci")

  @core %{
    mob: "https://github.com/GenericJam/mob",
    mob_dev: "https://github.com/GenericJam/mob_dev",
    mob_new: "https://github.com/GenericJam/mob_new"
  }

  @type row :: :hex | :master | {:rc, atom(), String.t()}
  @type pin :: %{
          version: String.t() | nil,
          sha: String.t() | nil,
          source: :hex | {:git, String.t()},
          dir: Path.t() | nil
        }
  @type resolved :: %{row: row(), repos: %{atom() => pin()}}
  @type dep :: {atom(), String.t()} | {atom(), keyword()} | {atom(), String.t(), keyword()}

  # ── the repo list ────────────────────────────────────────────────────────────

  @doc "The first-party plugins in `priv/plugins.exs`, in their committed order."
  @spec plugins() :: [atom()]
  def plugins, do: Enum.map(plugin_repos(), fn {name, _url} -> name end)

  @doc "Plugin → GitHub URL, in committed order (the file is a keyword list)."
  @spec plugin_repos() :: [{atom(), String.t()}]
  def plugin_repos do
    {list, _} = Code.eval_file(@plugins_path)
    list
  end

  @doc "The core repos (mob, mob_dev, mob_new) → GitHub URL."
  @spec core_repos() :: %{atom() => String.t()}
  def core_repos, do: @core

  @doc "Every repo a row resolves: core first, then the plugins in committed order."
  @spec repos() :: [{atom(), String.t()}]
  def repos,
    do:
      [{:mob, @core.mob}, {:mob_dev, @core.mob_dev}, {:mob_new, @core.mob_new}] ++ plugin_repos()

  @doc "Default cache root (`~/.cache/mob_ci`)."
  def cache_dir, do: @cache_dir

  # ── row parsing ──────────────────────────────────────────────────────────────

  @doc """
  Parse a `--versions` value: `hex`, `master`, or `rc:<repo>@<sha>` where
  `<repo>` is a core repo or a listed plugin and `<sha>` is 7–40 hex digits.
  """
  @spec parse(String.t() | nil) :: {:ok, row()} | {:error, String.t()}
  def parse(nil), do: {:ok, :hex}
  def parse("hex"), do: {:ok, :hex}
  def parse("master"), do: {:ok, :master}

  def parse("rc:" <> rest) do
    with [repo, sha] <- String.split(rest, "@", parts: 2),
         {:ok, name} <- known_repo(repo),
         true <-
           Regex.match?(~r/^[0-9a-f]{7,40}$/, sha) ||
             {:error, "rc sha must be 7–40 hex digits, got #{inspect(sha)}"} do
      {:ok, {:rc, name, sha}}
    else
      [_] -> {:error, "rc row needs <repo>@<sha>, got #{inspect(rest)}"}
      {:error, _} = err -> err
    end
  end

  def parse(other),
    do:
      {:error, "unknown --versions #{inspect(other)} (expected: hex | master | rc:<repo>@<sha>)"}

  @doc "Same as `parse/1` but raises `Mix.Error` with the message."
  @spec parse!(String.t() | nil) :: row()
  def parse!(value) do
    case parse(value) do
      {:ok, row} -> row
      {:error, msg} -> Mix.raise(msg)
    end
  end

  defp known_repo(repo) do
    name = String.to_atom(repo)

    if List.keymember?(repos(), name, 0),
      do: {:ok, name},
      else:
        {:error,
         "unknown repo #{inspect(repo)} in rc row (expected a core repo or a plugin from priv/plugins.exs)"}
  end

  @doc "The canonical string form of a row (what `--versions` accepts and results record)."
  @spec row_to_string(row()) :: String.t()
  def row_to_string(:hex), do: "hex"
  def row_to_string(:master), do: "master"
  def row_to_string({:rc, repo, sha}), do: "rc:#{repo}@#{sha}"

  # ── resolution ───────────────────────────────────────────────────────────────

  @doc """
  Resolve `row` to exact pins for every repo (or `opts[:names]`). Options:

    * `:remote` — the fetch functions (default `MobCi.Versions.Remote.default/0`).
    * `:cache_dir` — where clones and unpacked tarballs live.
    * `:names` — the repos to resolve (default all; mob_new is always included
      because the host generator must be runnable).

  Git pins always carry a checkout (hosts depend on it by path). Hex pins of
  mob and mob_dev carry none (Mix fetches them); mob_new's tarball is unpacked
  so its `mix mob.new` can run, and the plugins' so their manifests are the
  pinned version's (`source_dirs/1`).
  """
  @spec resolve(row(), keyword()) :: {:ok, resolved()} | {:error, term()}
  def resolve(row, opts \\ []) do
    remote = Keyword.get(opts, :remote, Remote.default())
    cache = Keyword.get(opts, :cache_dir, @cache_dir)
    names = Keyword.get(opts, :names, Enum.map(repos(), &elem(&1, 0)))
    names = Enum.uniq([:mob_new | names])

    Enum.reduce_while(names, {:ok, %{row: row, repos: %{}}}, fn name, {:ok, acc} ->
      case resolve_one(row, name, remote, cache) do
        {:ok, pin} -> {:cont, {:ok, put_in(acc, [:repos, name], pin)}}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  defp resolve_one(:hex, name, remote, cache), do: hex_pin(name, remote, cache)
  defp resolve_one(:master, name, remote, cache), do: git_head_pin(name, remote, cache)

  defp resolve_one({:rc, name, sha}, name, remote, cache),
    do: git_sha_pin(name, sha, remote, cache)

  defp resolve_one({:rc, _, _}, name, remote, cache), do: hex_pin(name, remote, cache)

  defp hex_pin(name, remote, cache) do
    with {:ok, version} <- remote.hex_latest.(name),
         {:ok, dir} <- hex_dir(name, version, remote, cache) do
      {:ok, %{version: version, sha: nil, source: :hex, dir: dir}}
    end
  end

  # Hex pins of mob and mob_dev are only ever depended on (Mix fetches them);
  # mob_new is run and the plugins' manifests are read (P1/P6/P7 expectations
  # must come from the pinned version), so those are unpacked.
  defp hex_dir(name, _version, _remote, _cache) when name in [:mob, :mob_dev], do: {:ok, nil}
  defp hex_dir(name, version, remote, cache), do: remote.hex_unpack.(name, version, cache)

  defp git_head_pin(name, remote, cache) do
    url = url!(name)

    with {:ok, sha} <- remote.git_head.(url),
         do: git_sha_pin(name, sha, remote, cache)
  end

  defp git_sha_pin(name, sha, remote, cache) do
    url = url!(name)

    with {:ok, %{dir: dir, sha: full}} <- remote.checkout.(name, url, sha, cache) do
      {:ok, %{version: version_in(dir), sha: full, source: {:git, url}, dir: dir}}
    end
  end

  defp url!(name) do
    case List.keyfind(repos(), name, 0) do
      {_, url} -> url
      nil -> raise ArgumentError, "unknown repo #{inspect(name)}"
    end
  end

  @doc "The version a checkout's `mix.exs` declares (`@version \"x\"` or `version: \"x\"`), if parseable."
  @spec version_in(Path.t() | nil) :: String.t() | nil
  def version_in(nil), do: nil

  def version_in(dir) do
    case File.read(Path.join(dir, "mix.exs")) do
      {:ok, body} ->
        case Regex.run(~r/@version\s+"([^"]+)"|version:\s*"([^"]+)"/, body) do
          [_, v] -> v
          [_, "", v] -> v
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ── deps ─────────────────────────────────────────────────────────────────────

  @doc """
  The Mix dep tuple a host declares for `name` under `pin`: an exact Hex
  requirement (`"== 0.9.14"`) or a `path:` dep on the checkout. mob_dev is
  dev-only; every path dep carries `override: true` so a checkout satisfies the
  `~>` requirement Hex plugins declare on mob.
  """
  @spec dep(atom(), pin()) :: dep()
  def dep(:mob_dev, %{source: :hex, version: v}),
    do: {:mob_dev, "== #{v}", only: :dev, runtime: false}

  def dep(name, %{source: :hex, version: v}), do: {name, "== #{v}"}

  def dep(:mob_dev, %{source: {:git, _}, dir: dir}),
    do: {:mob_dev, path: dir, only: :dev, runtime: false, override: true}

  def dep(name, %{source: {:git, _}, dir: dir}), do: {name, path: dir, override: true}

  @doc "Dep tuples for mob + mob_dev (what `MobCi.Build.deps_block/3` takes)."
  @spec core_deps(resolved()) :: [dep()]
  def core_deps(%{repos: repos}),
    do: for(name <- [:mob, :mob_dev], do: dep(name, Map.fetch!(repos, name)))

  @doc "Dep tuples for the given plugins under the resolved row."
  @spec plugin_deps(resolved(), [atom()]) :: [dep()]
  def plugin_deps(%{repos: repos}, names) do
    for name <- names do
      case Map.fetch(repos, name) do
        {:ok, pin} -> dep(name, pin)
        :error -> raise ArgumentError, "plugin #{inspect(name)} was not resolved in this row"
      end
    end
  end

  @doc "Render one dep tuple as its `mix.exs` source, e.g. `{:mob, path: \"/x\", override: true}`."
  @spec render_dep(dep()) :: String.t()
  def render_dep({name, req}) when is_binary(req), do: "{#{inspect(name)}, #{inspect(req)}}"
  def render_dep({name, kw}) when is_list(kw), do: "{#{inspect(name)}, #{render_kw(kw)}}"

  def render_dep({name, req, kw}) when is_binary(req),
    do: "{#{inspect(name)}, #{inspect(req)}, #{render_kw(kw)}}"

  defp render_kw(kw), do: Enum.map_join(kw, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)

  @doc "Plugin → source dir (checkout or unpacked tarball) for every pin that has one — where its manifest is."
  @spec source_dirs(resolved()) :: %{atom() => Path.t()}
  def source_dirs(%{repos: repos}),
    do: for({name, %{dir: dir}} <- repos, is_binary(dir), into: %{}, do: {name, dir})

  @doc "The runnable mob_new source dir of a resolved row."
  @spec mob_new_dir(resolved()) :: Path.t()
  def mob_new_dir(%{repos: %{mob_new: %{dir: dir}}}) when is_binary(dir), do: dir

  # ── the record stored with results ───────────────────────────────────────────

  @doc """
  A serialisable view of the resolution: `%{row: "hex", repos: %{mob: %{version,
  sha, source, dir}}}` with `source` as `"hex"` or `"git:<url>@<sha>"`.
  """
  @spec record(resolved()) :: map()
  def record(%{row: row, repos: repos}) do
    %{
      row: row_to_string(row),
      repos:
        Map.new(repos, fn {name, pin} ->
          {name, %{version: pin.version, sha: pin.sha, source: source_string(pin), dir: pin.dir}}
        end)
    }
  end

  defp source_string(%{source: :hex}), do: "hex"
  defp source_string(%{source: {:git, url}, sha: sha}), do: "git:#{url}@#{sha}"

  @doc "One line per repo, for the console: `mob 0.9.14 (hex)` / `mob 0.9.15 (git abc1234)`."
  @spec summary(resolved()) :: String.t()
  def summary(%{row: row, repos: repos}) do
    lines =
      repos
      |> Enum.sort_by(fn {name, _} -> {core_rank(name), name} end)
      |> Enum.map_join("\n", fn {name, pin} ->
        "  #{String.pad_trailing(to_string(name), 18)} #{pin_string(pin)}"
      end)

    "versions: #{row_to_string(row)}\n" <> lines
  end

  defp core_rank(:mob), do: 0
  defp core_rank(:mob_dev), do: 1
  defp core_rank(:mob_new), do: 2
  defp core_rank(_), do: 3

  defp pin_string(%{source: :hex, version: v}), do: "#{v} (hex)"

  defp pin_string(%{source: {:git, _}, version: v, sha: sha}),
    do: "#{v || "?"} (git #{String.slice(sha, 0, 12)})"
end
