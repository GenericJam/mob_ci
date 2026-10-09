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
  `<cache>/hex/<name>-<version>`. A mkdir lock per repo / tarball under
  `<cache>/locks` serialises resolvers that share a cache.
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

    locked(cache_dir, "repos-#{name}", fn ->
      with :ok <- ensure_clone(repo, url),
           {:ok, _} <- git(["-C", repo, "fetch", "--quiet", "origin"]),
           {:ok, out} <- git(["-C", repo, "rev-parse", "--verify", "#{sha}^{commit}"]),
           full = String.trim(out),
           dir = Path.join([cache_dir, "src", to_string(name), full]),
           :ok <- ensure_worktree(repo, dir, full) do
        {:ok, %{dir: dir, sha: full}}
      end
    end)
  end

  # One resolver at a time per repo / tarball across OS processes (two rows
  # resolving at once would race `git fetch` / `worktree add` on the shared
  # clone, or unpack into the same dir): an atomic `mkdir` lock under
  # `<cache>/locks`. A lock older than ten minutes belongs to a resolver that
  # died mid-fetch and is broken; a waiter outlasts that window (fifteen
  # minutes) so a dead holder never becomes a timeout, and a timeout is
  # returned as `{:error, {:lock_timeout, path}}`, not raised.
  @lock_poll_ms 200
  @lock_stale_s 600
  @lock_wait_ms 900_000

  defp locked(cache_dir, key, fun) do
    lock = Path.join([cache_dir, "locks", key])
    File.mkdir_p!(Path.dirname(lock))

    case acquire(lock, System.monotonic_time(:millisecond) + @lock_wait_ms) do
      :ok ->
        try do
          fun.()
        after
          File.rmdir(lock)
        end

      {:error, _} = err ->
        err
    end
  end

  defp acquire(lock, deadline) do
    case File.mkdir(lock) do
      :ok ->
        :ok

      {:error, :eexist} ->
        cond do
          stale?(lock) ->
            File.rmdir(lock)
            acquire(lock, deadline)

          System.monotonic_time(:millisecond) > deadline ->
            {:error, {:lock_timeout, lock}}

          true ->
            Process.sleep(@lock_poll_ms)
            acquire(lock, deadline)
        end
    end
  end

  defp stale?(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime > @lock_stale_s
      _ -> false
    end
  end

  defp ensure_worktree(repo, dir, full) do
    if File.exists?(Path.join(dir, ".git")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(dir))

      # A checkout deleted from <cache>/src stays registered in the clone and
      # blocks re-adding the same path; prune first.
      with {:ok, _} <- git(["-C", repo, "worktree", "prune"]),
           {:ok, _} <- git(["-C", repo, "worktree", "add", "--detach", dir, full]),
           do: :ok
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

  @doc """
  Unpack `<name>-<version>` from repo.hex.pm under `<cache>/hex/<name>-<version>`
  (reused when present). The tarball is extracted into a sibling temp dir and
  renamed into place, so the final path only ever holds a complete tree and
  another resolver's fast path can't see a half-extracted one.
  """
  @spec hex_unpack(atom(), String.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def hex_unpack(name, version, cache_dir) do
    dir = Path.join([cache_dir, "hex", "#{name}-#{version}"])

    if File.dir?(dir) do
      {:ok, dir}
    else
      locked(cache_dir, "hex-#{name}-#{version}", fn -> unpack(name, version, dir) end)
    end
  end

  defp unpack(name, version, dir) do
    if File.dir?(dir) do
      {:ok, dir}
    else
      File.mkdir_p!(Path.dirname(dir))

      tmp =
        Path.join(
          Path.dirname(dir),
          ".tmp-#{name}-#{version}-#{System.unique_integer([:positive])}"
        )

      tree = Path.join(tmp, "tree")
      File.mkdir_p!(tree)
      outer = Path.join(tmp, "package.tar")
      url = "https://repo.hex.pm/tarballs/#{name}-#{version}.tar"

      with {:ok, _} <- sh("curl", ["-sfL", "-o", outer, url]),
           {:ok, _} <- sh("tar", ["-xf", outer, "-C", tmp, "contents.tar.gz"]),
           {:ok, _} <- sh("tar", ["-xzf", Path.join(tmp, "contents.tar.gz"), "-C", tree]),
           :ok <- File.rename(tree, dir) do
        File.rm_rf!(tmp)
        {:ok, dir}
      else
        err ->
          File.rm_rf!(tmp)
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
