defmodule MobCi.Versions.Remote do
  @moduledoc """
  The network and disk side of `MobCi.Versions`, as a map of four functions so
  resolution can be driven with stubs in tests:

      hex_latest.(name)                      → {:ok, "0.9.14"} | {:error, term}
      git_head.(url)                         → {:ok, sha} | {:error, term}
      checkout.(name, url, sha, cache_dir)   → {:ok, %{dir: dir, sha: full_sha}} | {:error, term}
      hex_unpack.(name, version, cache_dir)  → {:ok, dir} | {:error, term}

  The real implementations: Hex's package API via `curl`, `git ls-remote` for
  the default-branch sha, one clone per repo under `<cache>/repos/<name>`
  (fetched on every resolution, never re-cloned) with a detached `git worktree`
  per sha under `<cache>/src/<name>/<sha>`, and Hex tarballs unpacked under
  `<cache>/hex/<name>-<version>`.
  """

  @type t :: %{
          hex_latest: (atom() -> {:ok, String.t()} | {:error, term()}),
          git_head: (String.t() -> {:ok, String.t()} | {:error, term()}),
          checkout: (atom(), String.t(), String.t(), Path.t() ->
                       {:ok, %{dir: Path.t(), sha: String.t()}} | {:error, term()}),
          hex_unpack: (atom(), String.t(), Path.t() -> {:ok, Path.t()} | {:error, term()})
        }

  @spec default() :: t()
  def default do
    %{
      hex_latest: &hex_latest/1,
      git_head: &git_head/1,
      checkout: &checkout/4,
      hex_unpack: &hex_unpack/3
    }
  end

  @doc "Latest stable version of a package from the Hex API."
  @spec hex_latest(atom()) :: {:ok, String.t()} | {:error, term()}
  def hex_latest(name) do
    with {:ok, body} <- curl("https://hex.pm/api/packages/#{name}"),
         %{"latest_stable_version" => v} when is_binary(v) <- decode(body) do
      {:ok, v}
    else
      %{"latest_version" => v} when is_binary(v) -> {:ok, v}
      {:error, _} = err -> err
      other -> {:error, {:hex_api, name, other}}
    end
  end

  @doc "The sha the remote's HEAD (default branch) points at."
  @spec git_head(String.t()) :: {:ok, String.t()} | {:error, term()}
  def git_head(url) do
    case git(["ls-remote", url, "HEAD"]) do
      {:ok, out} ->
        case Regex.run(~r/^([0-9a-f]{40})\tHEAD/m, out) do
          [_, sha] -> {:ok, sha}
          nil -> {:error, {:no_head, url, out}}
        end

      err ->
        err
    end
  end

  @doc """
  Materialise `sha` (full or abbreviated) of `url` under
  `<cache>/src/<name>/<full sha>`. The clone in `<cache>/repos/<name>` is
  created once and fetched each time; the checkout is a detached worktree of
  it, reused when it already exists.
  """
  @spec checkout(atom(), String.t(), String.t(), Path.t()) ::
          {:ok, %{dir: Path.t(), sha: String.t()}} | {:error, term()}
  def checkout(name, url, sha, cache_dir) do
    repo = Path.join([cache_dir, "repos", to_string(name)])

    with :ok <- ensure_clone(repo, url),
         {:ok, _} <- git(["-C", repo, "fetch", "--quiet", "origin"]),
         {:ok, out} <- git(["-C", repo, "rev-parse", "--verify", "#{sha}^{commit}"]),
         full = String.trim(out),
         dir = Path.join([cache_dir, "src", to_string(name), full]),
         :ok <- ensure_worktree(repo, dir, full) do
      {:ok, %{dir: dir, sha: full}}
    end
  end

  defp ensure_worktree(repo, dir, full) do
    if File.exists?(Path.join(dir, ".git")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(dir))

      case git(["-C", repo, "worktree", "add", "--detach", dir, full]) do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  defp ensure_clone(repo, url) do
    if File.dir?(Path.join(repo, ".git")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(repo))

      case git(["clone", "--quiet", url, repo]) do
        {:ok, _} -> :ok
        err -> err
      end
    end
  end

  @doc "Unpack `<name>-<version>` from repo.hex.pm under `<cache>/hex/<name>-<version>` (reused when present)."
  @spec hex_unpack(atom(), String.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def hex_unpack(name, version, cache_dir) do
    dir = Path.join([cache_dir, "hex", "#{name}-#{version}"])

    if File.regular?(Path.join(dir, "mix.exs")) do
      {:ok, dir}
    else
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mob_ci-#{name}-#{version}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      outer = Path.join(tmp, "package.tar")

      with {:ok, _} <-
             sh("curl", [
               "-sfL",
               "-o",
               outer,
               "https://repo.hex.pm/tarballs/#{name}-#{version}.tar"
             ]),
           {:ok, _} <- sh("tar", ["-xf", outer, "-C", tmp, "contents.tar.gz"]),
           :ok <- File.mkdir_p(dir),
           {:ok, _} <- sh("tar", ["-xzf", Path.join(tmp, "contents.tar.gz"), "-C", dir]) do
        File.rm_rf!(tmp)
        {:ok, dir}
      else
        err ->
          File.rm_rf!(tmp)
          File.rm_rf!(dir)
          err
      end
    end
  end

  defp curl(url), do: sh("curl", ["-sfL", url])

  defp git(args), do: sh("git", args)

  defp sh(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {bin, args, code, String.slice(out, -400, 400)}}
    end
  rescue
    e in ErlangError -> {:error, {bin, Exception.message(e)}}
  end

  defp decode(body) do
    :json.decode(body)
  rescue
    _ -> {:error, {:bad_json, String.slice(body, 0, 100)}}
  end
end
