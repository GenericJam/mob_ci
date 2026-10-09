defmodule Mix.Tasks.Ci.Poll do
  @shortdoc "One git-remote poll cycle: new default-branch shas → static gate + queued master cells"
  @moduledoc """
  The poller (`MobCi.Poller`): `git ls-remote` over mob, mob_dev, mob_new
  and every plugin in `priv/plugins.exs`; a moved default branch runs the
  static gate at once and queues `default` + `singleton:<plugin>` (a core
  repo: `blank` + `default`) + `all` on the `master` row, Android and iOS.
  Pre-push notices (`mix ci.queue push`) are settled in the same cycle.
  `priv/ci-run.sh poll` runs it every 10 minutes and then starts the lane
  workers.

      mix ci.poll                        # one cycle
      mix ci.poll --await-pushes         # wait (≤15 min) for pending pushes to land, cycling when one does
      mix ci.poll --heads                # print the stored heads
      mix ci.poll --reset mob_camera@<sha>   # rewind one stored head (the next cycle sees a change)
      mix ci.poll --store PATH           # default $MOB_CI_STORE or ~/.local/share/mob_ci/results.sqlite

  The first cycle records every repo's sha as a baseline and queues nothing.
  """
  use Mix.Task

  alias MobCi.{Poller, Store, Versions}

  @switches [store: :string, await_pushes: :boolean, heads: :boolean, reset: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unknown option(s): #{Enum.map_join(invalid, " ", &elem(&1, 0))}")
    store = Store.open!(opts[:store] || Store.default_path())

    try do
      cond do
        opts[:heads] -> print_heads(store)
        opts[:reset] -> reset(store, opts[:reset])
        opts[:await_pushes] -> store |> Poller.await_pushes() |> Enum.each(&report/1)
        true -> report(Poller.cycle(store))
      end
    after
      Store.close(store)
    end
  end

  defp print_heads(store) do
    for {repo, sha} <- Enum.sort(Poller.heads(store)), do: Mix.shell().info("#{repo} #{sha}")
  end

  defp reset(store, arg) do
    with [repo, sha] <- String.split(arg, "@", parts: 2),
         {:ok, {:rc, name, sha}} <- Versions.parse("rc:#{repo}@#{sha}"),
         {^name, url} <- List.keyfind(Versions.repos(), name, 0) do
      Poller.put_head(store, name, url, sha, DateTime.utc_now())
      Mix.shell().info("head of #{name} reset to #{sha}; the next cycle compares against it")
    else
      {:error, msg} -> Mix.raise(msg)
      _ -> Mix.raise("--reset takes <repo>@<sha>, got #{inspect(arg)}")
    end
  end

  defp report(result) do
    info = fn msg -> Mix.shell().info(msg) end
    info.("poll: #{length(result.baseline)} new baseline(s), #{length(result.changes)} change(s), #{length(result.errors)} unreachable")
    for %{repo: r, old: o, new: n} <- result.changes, do: info.("  #{r}: #{o} → #{n}")
    for {r, msg} <- result.errors, do: Mix.shell().error("  #{r}: #{msg}")
    for {row, gate} <- result.static, {set, code} <- gate, do: info.("  static #{row} #{set}: exit #{code}")
    for {id, status} <- result.pushes, do: info.("  push #{id}: #{status}")
    for id <- result.jobs, do: info.("  queued job #{id}")
  end
end
