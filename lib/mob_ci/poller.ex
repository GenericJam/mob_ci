defmodule MobCi.Poller do
  @moduledoc """
  The git-remote poller (`mix ci.poll`, every 10 minutes from
  `priv/systemd/mob-ci-poll.timer`): `git ls-remote` over the origin of mob,
  mob_dev, mob_new and every plugin in `priv/plugins.exs` — plain git, no
  forge API, so any host works. Last-seen default-branch shas live in the
  store's `heads` table.

  One `cycle/2`:

    1. ls-remote every repo (`HEAD`; all refs for a repo with a pending push
       notice). A repo that can't be reached is skipped this cycle, its stored
       sha untouched.
    2. Diff against `heads`: a repo whose `HEAD` moved is a change; a repo
       seen for the first time is only recorded (a baseline, never a flood of
       jobs on the first run).
    3. Settle pending pre-push notices (`record_push/5`, from the Mac): a sha
       that is now the remote `HEAD` is `covered` by the poll job (the poller
       dedups the push); a sha on another ref of the remote (a branch push)
       gets its own `rc:<repo>@<sha>` job; a sha not on the remote yet stays
       pending, and `expired` after an hour (the push was refused or never
       happened).
    4. Run the static gate for each new job's sets at once
       (`MobCi.Triggers.static_gate/2`), then enqueue: the changes as one
       `master` job (`MobCi.Triggers.poll_job/2`).
    5. Store the new heads.

  The caller (`priv/ci-run.sh poll`) then starts the lane workers.
  """

  alias MobCi.{Queue, Store, Triggers, Versions}

  @push_ttl_s 3600

  # ── ls-remote ────────────────────────────────────────────────────────────────

  @doc """
  Parse `git ls-remote` output into `%{ref => sha}` (`"HEAD"`,
  `"refs/heads/master"`, …). Peeled tag lines (`^{}`) are kept as their own
  ref; blank and malformed lines are ignored.
  """
  @spec parse_ls_remote(String.t()) :: %{String.t() => String.t()}
  def parse_ls_remote(output) do
    for line <- String.split(output, "\n", trim: true),
        [sha, ref] <- [String.split(String.trim(line), ~r/\s+/, parts: 2)],
        Regex.match?(~r/^[0-9a-f]{40}$/, sha),
        into: %{},
        do: {ref, sha}
  end

  @doc "`git ls-remote <url> [HEAD]` with prompts off and a 45 s cap."
  @spec ls_remote(String.t(), :head | :all) :: {:ok, String.t()} | {:error, String.t()}
  def ls_remote(url, which) do
    args = ["ls-remote", url] ++ if(which == :head, do: ["HEAD"], else: [])

    {cmd, argv} =
      case System.find_executable("timeout") do
        nil -> {"git", args}
        t -> {t, ["45", "git" | args]}
      end

    case System.cmd(cmd, argv, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}]) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "git ls-remote #{url} exited #{code}: #{String.trim(out)}"}
    end
  end

  # ── diffing ──────────────────────────────────────────────────────────────────

  @doc """
  Compare stored heads with the current ones (both `%{repo => sha}`).
  Returns `{changes, baseline}`: `changes` are `%{repo, old, new}` for repos
  whose sha moved, in `order`; `baseline` the repos seen for the first time.
  A repo absent from `current` (unreachable) is neither.
  """
  @spec diff(%{atom() => String.t()}, %{atom() => String.t()}, [atom()]) ::
          {[%{repo: atom(), old: String.t(), new: String.t()}], [atom()]}
  def diff(stored, current, order) do
    present = Enum.filter(order, &Map.has_key?(current, &1))

    changes =
      for repo <- present, old = stored[repo], old != nil, old != current[repo],
          do: %{repo: repo, old: old, new: current[repo]}

    {changes, Enum.reject(present, &Map.has_key?(stored, &1))}
  end

  @doc "The stored heads, `%{repo => sha}`."
  @spec heads(Store.t()) :: %{atom() => String.t()}
  def heads(store) do
    store
    |> Store.rows!("SELECT repo, sha FROM heads", [])
    |> Map.new(fn [repo, sha] -> {String.to_atom(repo), sha} end)
  end

  @doc "Store `repo`'s last-seen default-branch sha (what `mix ci.poll --reset` rewinds)."
  @spec put_head(Store.t(), atom(), String.t(), String.t(), DateTime.t()) :: :ok
  def put_head(store, repo, url, sha, now) do
    Store.exec!(
      store,
      "INSERT INTO heads (repo, url, sha, seen_at) VALUES (?1, ?2, ?3, ?4) " <>
        "ON CONFLICT(repo) DO UPDATE SET url = excluded.url, sha = excluded.sha, seen_at = excluded.seen_at",
      [to_string(repo), url, sha, iso(now)]
    )
  end

  # ── pre-push notices ─────────────────────────────────────────────────────────

  @doc """
  Record a pre-push notice from the Mac: `repo` (a core repo or a listed
  plugin), `sha` (7–40 hex), the remote `ref` it is being pushed to. Returns
  the push id; `cycle/2` settles it once the sha is on the remote.
  """
  @spec record_push(Store.t(), String.t(), String.t(), String.t() | nil, DateTime.t()) ::
          {:ok, pos_integer()} | {:error, String.t()}
  def record_push(store, repo, sha, ref, now) do
    with {:ok, {:rc, name, sha}} <- Versions.parse("rc:#{repo}@#{String.downcase(sha)}") do
      Store.exec!(
        store,
        "INSERT INTO pushes (repo, sha, ref, received_at, status) VALUES (?1, ?2, ?3, ?4, 'pending')",
        [to_string(name), sha, ref, iso(now)]
      )

      {:ok, Store.last_id(store)}
    end
  end

  @doc "Pending pushes, oldest first: `%{id, repo, sha, ref, received_at}`."
  @spec pending_pushes(Store.t()) :: [map()]
  def pending_pushes(store) do
    store
    |> Store.rows!("SELECT id, repo, sha, ref, received_at FROM pushes WHERE status = 'pending' ORDER BY id", [])
    |> Enum.map(fn [id, repo, sha, ref, at] ->
      %{id: id, repo: String.to_atom(repo), sha: sha, ref: ref, received_at: at}
    end)
  end

  @doc """
  What to do with one pending push given the repo's current refs (`nil` when
  the repo was unreachable): `:covered` (the sha is the default branch's
  head), `:branch` (on another ref: run it as an rc row), `:pending`, or
  `:expired` (not on the remote an hour after the notice). A short sha
  matches by prefix.
  """
  @spec settle(map(), %{String.t() => String.t()} | nil, DateTime.t()) :: :covered | :branch | :pending | :expired
  def settle(push, refs, now) do
    on_remote = refs && Enum.filter(refs, fn {_ref, sha} -> String.starts_with?(sha, push.sha) end)

    cond do
      refs && String.starts_with?(refs["HEAD"] || "", push.sha) -> :covered
      on_remote not in [nil, []] -> :branch
      expired?(push, now) -> :expired
      true -> :pending
    end
  end

  defp expired?(push, now) do
    {:ok, at, _} = DateTime.from_iso8601(push.received_at)
    DateTime.diff(now, at) >= @push_ttl_s
  end

  defp resolve_push(store, id, status, job_id, now) do
    Store.exec!(
      store,
      "UPDATE pushes SET status = ?2, job_id = ?3, resolved_at = ?4 WHERE id = ?1",
      [id, status, job_id, iso(now)]
    )
  end

  # ── a cycle ──────────────────────────────────────────────────────────────────

  @doc """
  One poll cycle. Options (the defaults do the real thing):

    * `:repos` — `[{repo, url}]` (default `MobCi.Versions.repos/0`).
    * `:ls_remote` — `fn url, :head | :all -> {:ok, output} | {:error, msg} end`.
    * `:static` — `fn job -> [{set, code}] end` (default the static gate).
    * `:now` — `DateTime`.

  Returns `%{changes, baseline, errors, jobs: [job_id], static, pushes: [{id, status}]}`.
  """
  @spec cycle(Store.t(), keyword()) :: map()
  def cycle(store, opts \\ []) do
    repos = Keyword.get_lazy(opts, :repos, &Versions.repos/0)
    ls = Keyword.get(opts, :ls_remote, &ls_remote/2)
    static = Keyword.get(opts, :static, &Triggers.static_gate/1)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    pending = pending_pushes(store)
    want_all = MapSet.new(pending, & &1.repo)
    order = Enum.map(repos, &elem(&1, 0))

    fetched =
      repos
      |> Task.async_stream(
        fn {repo, url} ->
          which = if repo in want_all, do: :all, else: :head
          {repo, url, ls.(url, which)}
        end,
        max_concurrency: 8,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(repos)
      |> Enum.map(fn
        {{:ok, result}, _} -> result
        {{:exit, reason}, {repo, url}} -> {repo, url, {:error, "ls-remote #{inspect(reason)}"}}
      end)

    refs = for {repo, _url, {:ok, out}} <- fetched, into: %{}, do: {repo, parse_ls_remote(out)}

    errors =
      for({repo, _url, {:error, msg}} <- fetched, do: {repo, msg}) ++
        for {repo, r} <- refs, is_nil(r["HEAD"]), do: {repo, "no HEAD in ls-remote output"}

    current = for {repo, r} <- refs, r["HEAD"], into: %{}, do: {repo, r["HEAD"]}
    {changes, baseline} = diff(heads(store), current, order)

    # Push notices: which of them landed, and how.
    settled = for push <- pending, do: {push, settle(push, refs[push.repo], now)}
    pushed_head? = Enum.any?(settled, fn {p, s} -> s == :covered and Enum.any?(changes, &(&1.repo == p.repo)) end)

    poll =
      if changes != [],
        do: [{:poll, Triggers.poll_job(changes, if(pushed_head?, do: "pre-push", else: "poll"))}],
        else: []

    branches =
      for {push, :branch} <- settled do
        {:ok, job} = Triggers.rc_job("#{push.repo}@#{full_sha(refs[push.repo], push.sha)}", "pre-push")
        {{:push, push.id}, job}
      end

    planned = poll ++ branches
    static_results = for {_, job} <- planned, do: {job.versions_row, static.(job)}

    enqueued =
      for {tag, job} <- planned do
        {:ok, job_id, _cells} = Queue.enqueue(store, job, now: now)
        {tag, job_id}
      end

    poll_job_id = Enum.find_value(enqueued, fn {tag, id} -> if tag == :poll, do: id end)

    push_results =
      for {push, status} <- settled, status != :pending do
        job_id =
          case status do
            # the poll job only if this cycle saw the repo move (else an
            # earlier cycle's job already ran or queued that head)
            :covered -> if Enum.any?(changes, &(&1.repo == push.repo)), do: poll_job_id
            :branch -> Enum.find_value(enqueued, fn {tag, id} -> if tag == {:push, push.id}, do: id end)
            :expired -> nil
          end

        stored = if status == :branch, do: "enqueued", else: Atom.to_string(status)
        resolve_push(store, push.id, stored, job_id, now)
        {push.id, status}
      end

    url_of = Map.new(repos)
    for repo <- baseline, do: put_head(store, repo, url_of[repo], current[repo], now)
    for %{repo: repo, new: sha} <- changes, do: put_head(store, repo, url_of[repo], sha, now)

    %{
      changes: changes,
      baseline: baseline,
      errors: errors,
      jobs: Enum.map(enqueued, &elem(&1, 1)),
      static: static_results,
      pushes: push_results
    }
  end

  defp full_sha(refs, short) do
    Enum.find_value(refs, short, fn {_ref, sha} -> if String.starts_with?(sha, short), do: sha end)
  end

  @doc """
  Wait for a pending push to reach its remote (`priv/ci-run.sh confirm`,
  started right after a notice): every `interval_ms`, ls-remote the repos
  with pending pushes. Returns `:landed` as soon as one is visible (the
  caller then runs a cycle under the poll lock, so it never races the timer's
  cycle), `:settled` when nothing is pending, `:timeout` after `max_ms` (the
  10-minute poller takes over). Options: `:repos`, `:ls_remote`, `:now` as
  `cycle/2`, plus `:sleep` (`fn ms -> :ok end`), `:interval_ms`, `:max_ms`.
  """
  @spec await_pushes(Store.t(), keyword()) :: :landed | :settled | :timeout
  def await_pushes(store, opts \\ []) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    interval = Keyword.get(opts, :interval_ms, 15_000)
    await(store, opts, sleep, interval, Keyword.get(opts, :max_ms, 15 * 60_000))
  end

  defp await(store, opts, sleep, interval, left) do
    ls = Keyword.get(opts, :ls_remote, &ls_remote/2)
    urls = Map.new(Keyword.get_lazy(opts, :repos, &Versions.repos/0))
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case pending_pushes(store) do
      [] ->
        :settled

      pending ->
        landed? =
          Enum.any?(pending, fn push ->
            case urls[push.repo] && ls.(urls[push.repo], :all) do
              {:ok, out} -> settle(push, parse_ls_remote(out), now) in [:covered, :branch]
              _ -> false
            end
          end)

        cond do
          landed? -> :landed
          left <= 0 -> :timeout
          true ->
            sleep.(interval)
            await(store, opts, sleep, interval, left - interval)
        end
    end
  end

  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
