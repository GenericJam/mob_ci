defmodule MobCi.Publish do
  @moduledoc """
  `mix ci.report --publish`: render the reports from the results store, write
  them, push them to the public `matrix` branch, post one Muster summary, then
  prune the store.

  1. `matrix.md` and `COMPATIBILITY.md` (`MobCi.Matrix`) are written into
     `:out_dir` (the checkout's root, where both are gitignored). A write
     failure is the only error: everything after it is best effort.
  2. They are committed to the branch `matrix` of the checkout's `origin`
     with git plumbing (no working tree is touched, so the NUC's checkout of
     `main` stays clean), with a README saying what the branch is, and pushed;
     an unchanged tree is not committed. Readers find them at
     `https://github.com/GenericJam/mob_ci/blob/matrix/COMPATIBILITY.md`.
  3. The cells recorded since the previous successful post (a marker file
     beside the store holds the last reported summary id) become one Muster
     `#mob` post (`MobCi.Matrix.post/3`); the marker advances only when the
     post went out, so `--no-post` or a failed post folds those cells into
     the next one and every cell is reported exactly once.
  4. `MobCi.Store.prune/2` (30 days) and the log files it releases, plus
     `*.log` files older than that under `:log_dirs` that no remaining cell
     points at.

  The side effects are injectable (`:pusher`, `:poster`) so tests build the
  post without sending it.
  """

  alias MobCi.{Matrix, Store}

  @branch "matrix"
  @repo_url "https://github.com/GenericJam/mob_ci"
  @files ["matrix.md", "COMPATIBILITY.md"]

  @doc "The public URL of a published file."
  @spec url(String.t()) :: String.t()
  def url(file), do: "#{@repo_url}/blob/#{@branch}/#{file}"

  @doc """
  Publish. Options: `:out_dir` (default cwd), `:repo` (the git checkout to
  push from, default cwd), `:push` / `:post` / `:prune` (default true),
  `:pusher` (`fn files -> {:ok, info} | {:error, reason} end`), `:poster`
  (`fn text -> :ok | {:error, reason} end`), `:now`, `:days` (30),
  `:log_dirs` (`[~/mob_ci_logs]`), `:marker` (default beside the store).

  Returns `{:ok, report}` (what happened at each step, for the console) or
  `{:error, reason}` when a file could not be written.
  """
  @spec run(Store.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(store, opts \\ []) do
    out = Keyword.get_lazy(opts, :out_dir, &File.cwd!/0)
    summaries = Store.query(store, invariant: nil)
    files = %{"matrix.md" => Matrix.matrix_md(summaries), "COMPATIBILITY.md" => Matrix.compatibility_md(summaries)}

    with :ok <- write_files(out, files) do
      pushed = if Keyword.get(opts, :push, true), do: push(opts, files), else: :skipped
      posted = post(store, summaries, opts)
      pruned = if Keyword.get(opts, :prune, true), do: prune(store, opts), else: :skipped
      {:ok, %{written: Enum.map(@files, &Path.join(out, &1)), pushed: pushed, posted: posted, pruned: pruned}}
    end
  end

  defp write_files(out, files) do
    Enum.reduce_while(@files, :ok, fn name, :ok ->
      path = Path.join(out, name)

      case File.mkdir_p(out) do
        :ok ->
          case File.write(path, files[name]) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:write, path, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:write, out, reason}}}
      end
    end)
  end

  defp push(opts, files) do
    repo = Keyword.get_lazy(opts, :repo, &File.cwd!/0)
    pusher = Keyword.get(opts, :pusher, &git_push(&1, repo))
    pusher.(Map.put(files, "README.md", branch_readme()))
  end

  # ── the Muster post ──────────────────────────────────────────────────────────

  defp post(store, summaries, opts) do
    marker = Keyword.get_lazy(opts, :marker, fn -> marker_path(store) end)
    since = read_marker(marker)
    window = Enum.filter(summaries, &(&1.id > since))
    text = Matrix.post(window, Matrix.regressions(window, summaries), url("matrix.md"))

    cond do
      is_nil(text) ->
        :nothing_new

      not Keyword.get(opts, :post, true) ->
        {:held, text}

      true ->
        poster = Keyword.get(opts, :poster, &muster_post/1)

        case poster.(text) do
          :ok ->
            File.write!(marker, "#{window |> Enum.map(& &1.id) |> Enum.max()}\n")
            {:posted, text}

          {:error, reason} ->
            {:failed, text, reason}
        end
    end
  end

  @doc "The marker file of `store`: the last summary cell id a post reported."
  @spec marker_path(Store.t()) :: Path.t()
  def marker_path(%Store{path: path}), do: Path.join(Path.dirname(path), "published_cell_id")

  defp read_marker(path) do
    with {:ok, body} <- File.read(path),
         {id, _} <- Integer.parse(String.trim(body)) do
      id
    else
      _ -> 0
    end
  end

  @doc """
  Post `text` to Muster `#mob` as the bot `$MOB_CI_MUSTER_BOT` (default
  `mob_ci-nightly`) with the `muster` CLI (`~/.local/bin/muster`; its server
  from `~/.config/muster/url`, the bot's token under
  `~/.config/muster/bots/`).
  """
  @spec muster_post(String.t()) :: :ok | {:error, term()}
  def muster_post(text) do
    bot = System.get_env("MOB_CI_MUSTER_BOT") |> blank_to("mob_ci-nightly")

    case System.find_executable("muster") do
      nil ->
        {:error, :muster_not_on_path}

      exe ->
        case System.cmd(exe, ["post", "#mob", text], env: [{"MUSTER_BOT", bot}], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, code} -> {:error, {:muster, code, String.trim(out)}}
        end
    end
  end

  defp blank_to(nil, default), do: default
  defp blank_to("", default), do: default
  defp blank_to(v, _), do: v

  # ── the matrix branch ────────────────────────────────────────────────────────

  @doc """
  Commit `files` (name → content) as the whole tree of branch `matrix` on top
  of `origin/matrix` (or as its first commit) and push it, with git plumbing
  in `repo` (a temporary index; the working tree and HEAD are untouched).
  Returns `{:ok, {:pushed, sha}}`, `{:ok, :unchanged}` or `{:error, reason}`.
  A rejected push (another publish won the race) is retried once on the new tip.
  """
  @spec git_push(%{String.t() => String.t()}, Path.t()) :: {:ok, term()} | {:error, term()}
  def git_push(files, repo, attempts \\ 2) do
    tmp = Path.join(System.tmp_dir!(), "mob_ci_publish_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      with {:ok, _} <- git(repo, ["fetch", "--quiet", "origin", "+refs/heads/#{@branch}:refs/remotes/origin/#{@branch}"], allow_fail: true),
           parent = tip(repo),
           {:ok, tree} <- write_tree(repo, tmp, files) do
        if parent && tree_of(repo, parent) == tree do
          {:ok, :unchanged}
        else
          with {:ok, commit} <- commit(repo, tree, parent) do
            case git(repo, ["push", "--quiet", "origin", "#{commit}:refs/heads/#{@branch}"]) do
              {:ok, _} -> {:ok, {:pushed, commit}}
              {:error, _} when attempts > 1 -> git_push(files, repo, attempts - 1)
              {:error, _} = err -> err
            end
          end
        end
      end
    after
      File.rm_rf(tmp)
    end
  end

  defp tip(repo) do
    case git(repo, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{@branch}^{commit}"], allow_fail: true) do
      {:ok, sha} when sha != "" -> sha
      _ -> nil
    end
  end

  defp tree_of(repo, commit) do
    {:ok, tree} = git(repo, ["rev-parse", "#{commit}^{tree}"])
    tree
  end

  defp write_tree(repo, tmp, files) do
    index = Path.join(tmp, "index")
    env = [{"GIT_INDEX_FILE", index}]

    entries =
      for {name, content} <- Enum.sort(files) do
        path = Path.join(tmp, name)
        File.write!(path, content)

        with {:ok, blob} <- git(repo, ["hash-object", "-w", path]),
             do: git(repo, ["update-index", "--add", "--cacheinfo", "100644,#{blob},#{name}"], env: env)
      end

    case Enum.find(entries, &match?({:error, _}, &1)) do
      nil -> git(repo, ["write-tree"], env: env)
      err -> err
    end
  end

  defp commit(repo, tree, parent) do
    who = [
      {"GIT_AUTHOR_NAME", "mob_ci"},
      {"GIT_AUTHOR_EMAIL", "mob_ci@users.noreply.github.com"},
      {"GIT_COMMITTER_NAME", "mob_ci"},
      {"GIT_COMMITTER_EMAIL", "mob_ci@users.noreply.github.com"}
    ]

    parents = if parent, do: ["-p", parent], else: []
    git(repo, ["commit-tree", tree] ++ parents ++ ["-m", "matrix: regenerated from the results store"], env: who)
  end

  defp git(repo, args, opts \\ []) do
    case System.cmd("git", ["-C", repo | args], env: Keyword.get(opts, :env, []), stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> if opts[:allow_fail], do: {:ok, ""}, else: {:error, {:git, hd(args), code, String.trim(out)}}
    end
  end

  defp branch_readme do
    """
    # mob_ci results

    This branch is written by [mob_ci](#{@repo_url})'s publish step
    (`mix ci.report --publish` on the CI host after every run), never by
    hand: each commit regenerates the files below from the results store.

    - [COMPATIBILITY.md](COMPATIBILITY.md): the verified version combinations
      of mob, mob_dev, mob_new and the first-party plugins.
    - [matrix.md](matrix.md): the latest result of every cell, per version row.
    """
  end

  # ── pruning ──────────────────────────────────────────────────────────────────

  @doc """
  `MobCi.Store.prune/2`, then delete log files: those only the pruned cells
  pointed at, and `*.log` files under `:log_dirs` (default `~/mob_ci_logs`),
  in both cases only when older than the cutoff and not referenced by a
  remaining cell. Empty directories left under `:log_dirs` go too.
  """
  @spec prune(Store.t(), keyword()) :: map()
  def prune(store, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    days = Keyword.get(opts, :days, 30)
    cutoff = DateTime.to_unix(now) - days * 86_400
    log_dirs = Keyword.get(opts, :log_dirs, [Path.expand("~/mob_ci_logs")])

    pruned = Store.prune(store, now: now, days: days)
    referenced = store |> Store.query() |> Enum.map(& &1.log_path) |> Enum.reject(&is_nil/1) |> MapSet.new()

    candidates =
      pruned.log_paths ++ Enum.flat_map(log_dirs, &Path.wildcard(Path.join(&1, "**/*.log")))

    deleted =
      for path <- Enum.uniq(candidates),
          not MapSet.member?(referenced, path),
          old_file?(path, cutoff),
          File.rm(path) == :ok,
          do: path

    for dir <- log_dirs, do: remove_empty_dirs(dir)
    Map.put(pruned, :logs_deleted, Enum.sort(deleted))
  end

  defp old_file?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} -> mtime < cutoff
      _ -> false
    end
  end

  # Depth first; never removes the root itself.
  defp remove_empty_dirs(root) do
    root
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort_by(&(-length(Path.split(&1))))
    |> Enum.each(fn dir -> if File.ls(dir) == {:ok, []}, do: File.rmdir(dir) end)
  end
end
