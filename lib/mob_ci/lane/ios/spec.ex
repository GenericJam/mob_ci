defmodule MobCi.Lane.Ios.Spec do
  @moduledoc """
  One cell of the Mac lane as the NUC hands it to the Mac worker: the set
  (its name and the plugins the NUC resolved for it), the version row as
  exact pins (`MobCi.Versions.record/1`), the path and the device. The lane
  is the iOS lane plus the physical Android phones, which are attached to the
  Mac too.

      path                    what the worker does
      deploy:ios_sim          mix mob.deploy --native on a simulator, then P2, P12, health
      deploy:ios_device       the same on a physical iPhone (skip: device_absent when
                              it isn't attached or another agent holds it)
      release:ios             mix mob.release --ios: a signed .ipa, no device
      deploy:android_physical mix mob.deploy --native on a physical Android phone
                              (the Motos), then P2, P12, health; skip: device_absent
                              when none is attached and free

  The NUC resolves the row (so both machines build the same versions and a
  `hex` row cannot drift between planning and building); the worker only
  re-materialises those pins locally (`resolved/2`): mob_new's Hex tarball,
  and a checkout for every git pin, since a host depends on those by path.

  Serialised as JSON (`to_json/1`, `from_json/1`), the one format that crosses
  the ssh hop.
  """

  alias MobCi.Versions.Remote

  @ios_paths ["deploy:ios_sim", "deploy:ios_device", "release:ios"]
  @android_paths ["deploy:android_physical"]
  @paths @ios_paths ++ @android_paths

  # `xcrun simctl privacy grant photos` on an iOS 26.x simulator runtime
  # writes a TCC row (auth_version=1) PhotoKit ignores, so a photos plugin's
  # self-test meets a prompt there; from iOS 27 the grant takes. The lane
  # therefore runs on iOS 27+ simulators unless told otherwise.
  @default_min_runtime "27.0"

  @enforce_keys [:cell_id, :set, :plugins, :versions, :path]
  defstruct [:cell_id, :set, :plugins, :versions, :path, :udid, :mob_ci_sha, min_runtime: @default_min_runtime]

  @type path :: String.t()
  @type t :: %__MODULE__{
          cell_id: String.t(),
          set: String.t(),
          plugins: [atom()],
          versions: map(),
          path: path(),
          udid: String.t() | nil,
          mob_ci_sha: String.t() | nil,
          min_runtime: String.t()
        }

  @doc "Every path a Mac lane cell can take."
  @spec paths() :: [path()]
  def paths, do: @paths

  @doc "The Mac lane's paths for one platform (`mix ci.device --platform`)."
  @spec paths(:ios | :android) :: [path()]
  def paths(:ios), do: @ios_paths
  def paths(:android), do: @android_paths

  @doc "The platform a path runs on, as the results store records it."
  @spec platform(path()) :: String.t()
  def platform(path) when path in @android_paths, do: "android"
  def platform(_ios), do: "ios"

  @doc "The lowest simulator iOS runtime a cell runs on unless the spec says otherwise."
  def default_min_runtime, do: @default_min_runtime

  @doc "Whether the path runs on a device (and so leases one)."
  @spec device?(path()) :: boolean()
  def device?(path), do: path in ["deploy:ios_sim", "deploy:ios_device", "deploy:android_physical"]

  @doc """
  Build a spec from a planned cell (`MobCi.Cell.plan/3`). The cell id is
  `<set>-<row>-<path>` folded to `[a-z0-9_-]`, plus `opts[:stamp]` (default a
  UTC timestamp) so two runs of one cell never share a log or result file.

  `deploy:ios_device` needs `opts[:udid]` (the iPhone). `deploy:ios_sim`
  takes one to pin a simulator; without it the worker picks the booted
  simulator with the newest runtime at or above `opts[:min_runtime]`
  (default `#{@default_min_runtime}`) that it can lease.
  `deploy:android_physical` takes an adb serial as `opts[:udid]` to pin a
  phone; without it the worker picks the first attached phone it can lease.
  """
  @spec from_cell(map(), path(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def from_cell(%{set: set, plugins: plugins, resolved: resolved}, path, opts \\ []) do
    udid = opts[:udid]
    min_runtime = opts[:min_runtime] || @default_min_runtime

    cond do
      path not in @paths ->
        {:error, "unknown Mac lane path #{inspect(path)} (expected: #{Enum.join(@paths, " | ")})"}

      path == "deploy:ios_device" and not is_binary(udid) ->
        {:error, "#{path} needs a device udid"}

      not runtime?(min_runtime) ->
        {:error, "min runtime must look like 27.0, got #{inspect(min_runtime)}"}

      true ->
        versions = MobCi.Versions.record(resolved)
        stamp = Keyword.get_lazy(opts, :stamp, &stamp/0)

        {:ok,
         %__MODULE__{
           cell_id: cell_id(set, versions.row, path, stamp),
           set: set,
           plugins: plugins,
           versions: versions,
           path: path,
           udid: if(device?(path), do: udid),
           mob_ci_sha: opts[:mob_ci_sha],
           min_runtime: min_runtime
         }}
    end
  end

  defp runtime?(v), do: is_binary(v) and v =~ ~r/^\d+(\.\d+){0,2}$/

  @doc false
  def cell_id(set, row, path, stamp) do
    "#{set}-#{row}-#{path}-#{stamp}"
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
  end

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

  # ── JSON ─────────────────────────────────────────────────────────────────────

  @doc "The spec as a JSON document."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = s) do
    JSON.encode!(%{
      "schema" => 1,
      "cell_id" => s.cell_id,
      "set" => s.set,
      "plugins" => Enum.map(s.plugins, &Atom.to_string/1),
      "versions" => s.versions,
      "path" => s.path,
      "udid" => s.udid,
      "mob_ci_sha" => s.mob_ci_sha,
      "min_runtime" => s.min_runtime
    })
  end

  @doc "Parse a spec document. Anything but schema 1 with the required keys is an error."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_json(body) do
    with {:ok, %{"schema" => 1} = m} <- decode(body),
         {:ok, versions} <- versions(m["versions"]),
         true <- m["path"] in @paths || {:error, "unknown path #{inspect(m["path"])}"},
         true <-
           m["path"] != "deploy:ios_device" or is_binary(m["udid"]) ||
             {:error, "#{m["path"]} needs a udid"},
         true <- runtime?(m["min_runtime"]) || {:error, "min_runtime must look like 27.0, got #{inspect(m["min_runtime"])}"},
         true <- is_binary(m["set"]) || {:error, "set is required"},
         # The cell id names the scratch dir teardown deletes: only what
         # `cell_id/4` produces, never a path.
         true <-
           (is_binary(m["cell_id"]) and m["cell_id"] =~ ~r/^[a-z0-9][a-z0-9_-]*$/) ||
             {:error, "bad cell_id #{inspect(m["cell_id"])} (expected [a-z0-9][a-z0-9_-]*)"},
         true <- is_list(m["plugins"]) || {:error, "plugins must be a list"} do
      {:ok,
       %__MODULE__{
         cell_id: m["cell_id"],
         set: m["set"],
         plugins: Enum.map(m["plugins"], &String.to_atom/1),
         versions: versions,
         path: m["path"],
         udid: m["udid"],
         mob_ci_sha: m["mob_ci_sha"],
         min_runtime: m["min_runtime"]
       }}
    else
      {:ok, %{"schema" => other}} -> {:error, "unsupported spec schema #{inspect(other)}"}
      {:ok, _} -> {:error, "not a cell spec (no schema)"}
      {:error, _} = err -> err
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:ok, other} -> {:ok, %{"schema" => {:not_an_object, other}}}
      {:error, reason} -> {:error, "spec is not JSON: #{inspect(reason)}"}
    end
  end

  # The record's atoms come back as strings; normalise to the atom-keyed shape
  # `MobCi.Versions.record/1` produces, so a round trip is the identity.
  defp versions(%{"row" => row, "repos" => repos}) when is_binary(row) and is_map(repos) do
    {:ok,
     %{
       row: row,
       repos:
         Map.new(repos, fn {name, pin} ->
           {String.to_atom(name),
            %{version: pin["version"], sha: pin["sha"], source: pin["source"], dir: pin["dir"]}}
         end)
     }}
  end

  defp versions(other), do: {:error, "versions must be a record with row and repos, got #{inspect(other)}"}

  # ── worker side: the pins as a local resolution ──────────────────────────────

  @doc """
  The spec's pins as a `MobCi.Versions.resolved()` on this machine: the row
  parsed back, mob_new's Hex tarball unpacked (its `mix mob.new` runs), and
  every git pin checked out at its exact sha. Hex pins of mob, mob_dev and the
  plugins carry no dir (the host fetches them as `== version` deps). The NUC's
  dirs in the record are ignored. `opts`: `:remote` (`MobCi.Versions.Remote`
  functions), `:cache_dir`.
  """
  @spec resolved(t(), keyword()) :: {:ok, MobCi.Versions.resolved()} | {:error, term()}
  def resolved(%__MODULE__{versions: %{row: row_string, repos: repos}}, opts \\ []) do
    remote = Keyword.get(opts, :remote, Remote.default())
    cache = Keyword.get(opts, :cache_dir, MobCi.Versions.cache_dir())

    with {:ok, row} <- MobCi.Versions.parse(row_string) do
      Enum.reduce_while(repos, {:ok, %{row: row, repos: %{}}}, fn {name, pin}, {:ok, acc} ->
        case pin_here(name, pin, remote, cache) do
          {:ok, local} -> {:cont, {:ok, put_in(acc, [:repos, name], local)}}
          {:error, reason} -> {:halt, {:error, {name, reason}}}
        end
      end)
    end
  end

  defp pin_here(:mob_new, %{source: "hex", version: v}, remote, cache) do
    with {:ok, dir} <- remote.hex_unpack.(:mob_new, v, cache),
         do: {:ok, %{version: v, sha: nil, source: :hex, dir: dir}}
  end

  defp pin_here(_name, %{source: "hex", version: v}, _remote, _cache),
    do: {:ok, %{version: v, sha: nil, source: :hex, dir: nil}}

  defp pin_here(name, %{source: "git:" <> url_sha, version: v}, remote, cache) do
    case Regex.run(~r/^(.+)@([0-9a-f]{7,40})$/, url_sha) do
      [_, url, sha] ->
        with {:ok, %{dir: dir, sha: full}} <- remote.checkout.(name, url, sha, cache),
             do: {:ok, %{version: v, sha: full, source: {:git, url}, dir: dir}}

      nil ->
        {:error, {:bad_source, "git:" <> url_sha}}
    end
  end

  defp pin_here(_name, pin, _remote, _cache), do: {:error, {:bad_pin, pin}}
end
