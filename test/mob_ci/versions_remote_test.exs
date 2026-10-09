defmodule MobCi.Versions.RemoteTest do
  # The git side of Remote against a local repository (no network): HEAD
  # lookup, the cached clone + per-sha worktree, reuse, abbreviated shas, and
  # concurrent resolvers sharing one cache.
  use ExUnit.Case, async: true

  alias MobCi.Versions.Remote

  setup do
    tmp = Path.join(System.tmp_dir!(), "mob_ci_remote_#{System.unique_integer([:positive])}")
    origin = Path.join(tmp, "origin")
    cache = Path.join(tmp, "cache")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf!(tmp) end)

    git!(origin, ["init", "-q", "-b", "master"])
    git!(origin, ["config", "user.email", "ci@example"])
    git!(origin, ["config", "user.name", "ci"])
    File.write!(Path.join(origin, "mix.exs"), ~s|  @version "1.0.0"\n|)
    git!(origin, ["add", "."])
    git!(origin, ["commit", "-q", "-m", "one"])
    sha1 = git!(origin, ["rev-parse", "HEAD"]) |> String.trim()

    %{origin: origin, cache: cache, sha1: sha1}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  test "git_head returns the remote's default-branch sha", %{origin: origin, sha1: sha1} do
    assert Remote.git_head(origin) == {:ok, sha1}
    assert {:error, _} = Remote.git_head(Path.join(origin, "nope"))
  end

  test "checkout clones once, materialises a detached worktree per sha, and reuses it", %{
    origin: origin,
    cache: cache,
    sha1: sha1
  } do
    assert {:ok, %{dir: dir, sha: ^sha1}} = Remote.checkout(:mob, origin, sha1, cache)
    assert dir == Path.join([cache, "src", "mob", sha1])
    assert File.read!(Path.join(dir, "mix.exs")) =~ "1.0.0"
    assert File.dir?(Path.join([cache, "repos", "mob", ".git"]))
    assert git!(dir, ["rev-parse", "HEAD"]) |> String.trim() == sha1

    # an abbreviated sha resolves to the same full-sha checkout
    assert {:ok, %{dir: ^dir, sha: ^sha1}} =
             Remote.checkout(:mob, origin, String.slice(sha1, 0, 7), cache)

    # a new upstream commit is fetched (not re-cloned) and gets its own worktree
    File.write!(Path.join(origin, "mix.exs"), ~s|  @version "1.1.0"\n|)
    git!(origin, ["commit", "-qam", "two"])
    sha2 = git!(origin, ["rev-parse", "HEAD"]) |> String.trim()
    assert {:ok, %{dir: dir2, sha: ^sha2}} = Remote.checkout(:mob, origin, sha2, cache)
    assert dir2 != dir
    assert File.read!(Path.join(dir2, "mix.exs")) =~ "1.1.0"
    assert File.read!(Path.join(dir, "mix.exs")) =~ "1.0.0"

    assert {:error, _} = Remote.checkout(:mob, origin, String.duplicate("0", 40), cache)
    assert File.ls!(Path.join(cache, "locks")) == []
  end

  test "concurrent resolvers sharing a cache all get the same checkout", %{
    origin: origin,
    cache: cache,
    sha1: sha1
  } do
    results =
      1..6
      |> Task.async_stream(fn _ -> Remote.checkout(:mob, origin, sha1, cache) end,
        max_concurrency: 6,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.uniq(results) == [
             {:ok, %{dir: Path.join([cache, "src", "mob", sha1]), sha: sha1}}
           ]

    assert File.ls!(Path.join(cache, "locks")) == []
  end
end
