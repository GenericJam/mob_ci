defmodule MobCi.FarmReaperTest do
  # priv/ci-farm.sh for real (bash) over stub `sudo docker`, `ps`, `adb` and
  # `flock`: who owns an instance, and what `reap` downs (MOB-467).
  use ExUnit.Case, async: true

  alias MobCi.Farm

  @moduletag :tmp_dir

  # docker: containers live in $STUB_DIR/containers as `name|created|status`;
  # `rm -f` and `run` are logged. ps: `ps -o lstart= -p <pid>` answers from
  # $STUB_DIR/pids (`pid|lstart`), else exits 1 like a gone pid.
  @stubs %{
    "sudo" => ~S"""
    #!/usr/bin/env bash
    exec "$@"
    """,
    "docker" => ~S"""
    #!/usr/bin/env bash
    db="$STUB_DIR/containers"; touch "$db"
    case "$1" in
      ps)
        fmt=""
        while [ $# -gt 0 ]; do [ "$1" = --format ] && fmt=$2; shift; done
        while IFS='|' read -r n c s; do
          [ -n "$n" ] || continue
          case "$fmt" in
            *Status*) printf '%s\t%s\t%s\n' "$n" "$s" "127.0.0.1:5700->5555/tcp" ;;
            *) echo "$n" ;;
          esac
        done <"$db" ;;
      inspect)
        line=$(grep "^$4|" "$db") || { echo; exit 1; }
        echo "$line" | cut -d'|' -f2 ;;
      rm)
        echo "$3" >>"$STUB_DIR/rm.log"
        grep -v "^$3|" "$db" >"$db.tmp"; mv "$db.tmp" "$db" ;;
      run)
        while [ "$1" != --name ]; do shift; done
        [ -n "$STUB_RUN_FAIL" ] && exit 125
        echo "$2|$(date -u +%Y-%m-%dT%H:%M:%SZ)|Up 1 second" >>"$db" ;;
    esac
    """,
    "ps" => ~S"""
    #!/usr/bin/env bash
    pid=${@: -1}
    line=$(grep "^$pid|" "$STUB_DIR/pids" 2>/dev/null) || exit 1
    echo "  ${line#*|}"
    """,
    "adb" => ~S"""
    #!/usr/bin/env bash
    case "$*" in *boot_completed*) echo 1 ;; esac
    exit 0
    """,
    "flock" => ~S"""
    #!/usr/bin/env bash
    exit 0
    """
  }

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for {name, body} <- @stubs do
      File.write!(Path.join(bin, name), body)
      File.chmod!(Path.join(bin, name), 0o755)
    end

    for f <- ~w(containers pids), do: File.write!(Path.join(dir, f), "")

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"STUB_DIR", dir},
      {"MOB_CI_FARM_LOCK", Path.join(dir, "farm.lock")},
      {"MOB_CI_FARM_STATE", Path.join(dir, "state")},
      {"MOB_CI_FARM_OWNER_PID", nil},
      {"MOB_CI_JOB_ID", nil},
      {"MOB_CI_CELL_ID", nil}
    ]

    %{dir: dir, env: env}
  end

  defp farm(ctx, args, extra_env \\ []) do
    {out, code} = System.cmd("bash", [Farm.script() | args], env: ctx.env ++ extra_env, stderr_to_stdout: true)
    assert code == 0, out
    out
  end

  defp container(ctx, name, minutes_old, status \\ "Up 5 minutes") do
    created = DateTime.utc_now() |> DateTime.add(-minutes_old * 60) |> DateTime.to_iso8601()
    File.write!(Path.join(ctx.dir, "containers"), "#{name}|#{created}|#{status}\n", [:append])
  end

  defp live_pid(ctx, pid, lstart), do: File.write!(Path.join(ctx.dir, "pids"), "#{pid}|#{lstart}\n", [:append])

  defp owner(ctx, index, pid, pid_start) do
    state = Path.join(ctx.dir, "state")
    File.mkdir_p!(state)
    File.write!(Path.join(state, "ci-redroid#{index}.owner"), "pid=#{pid}\npid_start=#{pid_start}\nrun=7\njob=3\ncell=11\nbooted=0\n")
  end

  defp record(ctx, index), do: Path.join([ctx.dir, "state", "ci-redroid#{index}.owner"])

  defp removed(ctx) do
    case File.read(Path.join(ctx.dir, "rm.log")) do
      {:ok, s} -> s |> String.split("\n", trim: true) |> Enum.sort()
      {:error, :enoent} -> []
    end
  end

  defp remaining(ctx) do
    ctx.dir |> Path.join("containers") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&hd(String.split(&1, "|"))) |> Enum.sort()
  end

  describe "reap" do
    test "downs a dead owner's instance and old orphans; keeps live owners, young orphans and staging", ctx do
      live_pid(ctx, 100, "Thu Oct  9 12:00:00 2026")
      live_pid(ctx, 300, "Thu Oct  9 13:30:00 2026")

      # live owner, booted hours ago: a long cell is still a live cell
      container(ctx, "ci-redroid0", 300)
      owner(ctx, 0, 100, "Thu Oct 9 12:00:00 2026")
      # owner's pid is gone
      container(ctx, "ci-redroid1", 2)
      owner(ctx, 1, 200, "Thu Oct 9 12:05:00 2026")
      # the pid runs, but it is another process now (reused pid)
      container(ctx, "ci-redroid2", 2)
      owner(ctx, 2, 300, "Thu Oct 9 12:10:00 2026")
      # no record: young (a boot from a checkout without ownership) and old
      container(ctx, "ci-redroid3", 5)
      container(ctx, "ci-redroid4", 45, "Exited (137) 30 minutes ago")
      # staging and look-alikes: never touched, however old
      container(ctx, "redroid0", 600)
      container(ctx, "redroid12", 600)
      container(ctx, "ci-redroid-x", 600)
      container(ctx, "my-ci-redroid5", 600)
      # a record whose container is already gone
      owner(ctx, 9, 200, "")

      out = farm(ctx, ["reap"])

      assert removed(ctx) == ~w(ci-redroid1 ci-redroid2 ci-redroid4)
      assert remaining(ctx) == Enum.sort(~w(ci-redroid0 ci-redroid3 ci-redroid-x my-ci-redroid5 redroid0 redroid12))
      assert out =~ "keep ci-redroid0: owner pid 100 alive, run 7, job 3, cell 11"
      assert out =~ "down ci-redroid1: owner pid 200 DEAD"
      assert out =~ "down ci-redroid2: owner pid 300 DEAD"
      assert out =~ ~r/keep ci-redroid3: no owner record, [45] min old \(reaped at 20\)/
      assert out =~ ~r/down ci-redroid4: no owner record, 4[45] min old/
      assert out =~ "forget ci-redroid9: no container"
      assert out =~ "REAPED 3"
      assert File.exists?(record(ctx, 0))
      for i <- [1, 2, 9], do: refute(File.exists?(record(ctx, i)))
    end

    test "the orphan age is configurable", ctx do
      container(ctx, "ci-redroid0", 5)
      farm(ctx, ["reap"], [{"MOB_CI_FARM_REAP_AFTER_MIN", "3"}])
      assert removed(ctx) == ["ci-redroid0"]
    end
  end

  describe "ownership" do
    test "boot records the owner; down clears it", ctx do
      live_pid(ctx, 4242, "Fri Oct 10 01:02:03 2026")

      out =
        farm(ctx, ["boot"], [
          {"MOB_CI_FARM_OWNER_PID", "4242"},
          {"MOB_CI_FARM_RUN", "812"},
          {"MOB_CI_JOB_ID", "45"},
          {"MOB_CI_CELL_ID", "67"}
        ])

      assert out =~ "INDEX=0"
      rec = File.read!(record(ctx, 0))
      assert rec =~ "pid=4242\n"
      assert rec =~ "pid_start=Fri Oct 10 01:02:03 2026\n"
      assert rec =~ "run=812\njob=45\ncell=67\n"
      assert rec =~ ~r/booted=\d+\n/

      # the live owner keeps it through a reap; status names the owner
      assert farm(ctx, ["reap"]) =~ "keep ci-redroid0"
      assert farm(ctx, ["status"]) =~ ~r/ci-redroid0\tUp 1 second\t\S+\towner: pid 4242 alive, run 812, job 45, cell 67, booted 0 min ago/

      farm(ctx, ["down", "0"])
      assert removed(ctx) == ["ci-redroid0"]
      refute File.exists?(record(ctx, 0))
    end

    test "a failed docker run leaves no record", ctx do
      {_out, code} = System.cmd("bash", [Farm.script(), "boot"], env: ctx.env ++ [{"STUB_RUN_FAIL", "1"}], stderr_to_stdout: true)
      assert code != 0
      refute File.exists?(record(ctx, 0))
    end

    test "status says when an instance has no owner record", ctx do
      container(ctx, "ci-redroid1", 3)
      container(ctx, "redroid0", 3)
      out = farm(ctx, ["status"])
      assert out =~ "ci-redroid1\tUp 5 minutes\t127.0.0.1:5700->5555/tcp\towner: none (no record: reaped once 20 min old)"
      refute out =~ "redroid0\t"
    end

    test "down-owned releases only that pid's instances", ctx do
      for i <- 0..2, do: container(ctx, "ci-redroid#{i}", 1)
      owner(ctx, 0, 500, "")
      owner(ctx, 1, 501, "")
      owner(ctx, 2, 500, "")

      farm(ctx, ["down-owned", "500"])

      assert removed(ctx) == ~w(ci-redroid0 ci-redroid2)
      assert File.exists?(record(ctx, 1))
    end
  end

  # A BEAM that booted an instance and then gets SIGTERM (systemctl stop,
  # `ci-run.sh pause`, the cell timeout) releases it before it stops.
  test "SIGTERM to a BEAM that booted an instance releases it", ctx do
    elixir = System.find_executable("elixir")
    ebin = Mix.Project.compile_path()

    code = ~S"""
    {:ok, inst} = MobCi.Farm.boot()
    IO.puts("BOOTED #{inst.index} #{System.pid()}")
    Process.sleep(:infinity)
    """

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 1024},
        args: ["-pa", ebin, "-e", code],
        env: for({k, v} <- ctx.env, do: {String.to_charlist(k), if(v, do: String.to_charlist(v), else: false)})
      ])

    os_pid =
      receive do
        {^port, {:data, {:eol, "BOOTED 0 " <> pid}}} -> pid
      after
        30_000 -> flunk("the child never booted")
      end

    assert File.read!(record(ctx, 0)) =~ "pid=#{os_pid}\n"
    System.cmd("kill", ["-TERM", os_pid])

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      30_000 -> flunk("the child did not stop on SIGTERM")
    end

    assert removed(ctx) == ["ci-redroid0"]
    refute File.exists?(record(ctx, 0))
  end
end
