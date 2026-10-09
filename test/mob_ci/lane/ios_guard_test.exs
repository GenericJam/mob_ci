defmodule MobCi.Lane.Ios.GuardTest do
  # worker/mac/guard.sh for real (bash, perl), with a stand-in worker and
  # teardown: whatever ends the session, the teardown runs.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @guard Path.expand("../../../worker/mac/guard.sh", __DIR__)

  # A worker that records its pid and environment, says it is up, then runs
  # for `secs` and exits with `code`.
  defp worker(dir, secs, code) do
    script = Path.join(dir, "worker.sh")

    File.write!(script, """
    #!/bin/bash
    echo $$ > "#{dir}/worker.pid.seen"
    echo "run=$MOB_CI_RUN dir=$MOB_CI_RUN_DIR" > "#{dir}/worker.env"
    echo "worker up"
    sleep #{secs}
    echo "worker done"
    exit #{code}
    """)

    File.chmod!(script, 0o755)
    script
  end

  # A teardown that records the run dir it was given and why the cell stopped.
  defp teardown(dir) do
    script = Path.join(dir, "teardown.sh")

    File.write!(script, """
    #!/bin/bash
    echo "teardown $1" >> "#{dir}/teardown.log"
    cat "$1/abort" >> "#{dir}/teardown.log" 2>/dev/null || echo "no abort" >> "#{dir}/teardown.log"
    """)

    File.chmod!(script, 0o755)
    # The guard evals the teardown command: quote the path (test dirs hold ' and ( ).
    ~s("#{script}")
  end

  defp start(dir, worker, hb_timeout) do
    run_dir = Path.join(dir, "runs/r1")

    args = [
      @guard,
      "start",
      "--run-dir",
      run_dir,
      "--log",
      Path.join(dir, "worker.log"),
      "--heartbeat-timeout",
      to_string(hb_timeout),
      "--teardown",
      teardown(dir),
      "--",
      worker
    ]

    port = Port.open({:spawn_executable, "/bin/bash"}, [:binary, :exit_status, :stderr_to_stdout, args: args])
    {:os_pid, pid} = Port.info(port, :os_pid)
    %{port: port, pid: pid, run_dir: run_dir}
  end

  defp heartbeat(%{port: port}), do: Port.command(port, "hb\n")

  defp await_exit(%{port: port}, out \\ "") do
    receive do
      {^port, {:data, chunk}} -> await_exit(%{port: port}, out <> chunk)
      {^port, {:exit_status, code}} -> {code, out}
    after
      30_000 -> flunk("guard.sh start did not exit; output so far: #{out}")
    end
  end

  defp await_file(path, ms \\ 10_000) do
    cond do
      File.exists?(path) -> :ok
      ms <= 0 -> flunk("#{path} never appeared")
      true -> Process.sleep(100) && await_file(path, ms - 100)
    end
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  # A killed worker is a zombie until its parent (the exiting guard) is gone.
  defp gone?(pid, ms \\ 3_000) do
    cond do
      not alive?(pid) -> true
      ms <= 0 -> false
      true -> Process.sleep(100) && gone?(pid, ms - 100)
    end
  end

  defp worker_pid(dir), do: dir |> Path.join("worker.pid.seen") |> File.read!() |> String.trim()

  test "a worker that finishes: its output streams back, its exit code is the session's, and teardown still runs",
       %{tmp_dir: dir} do
    g = start(dir, worker(dir, 0, 3), 30)
    heartbeat(g)

    assert {3, out} = await_exit(g)
    assert out =~ "worker up\nworker done\n"
    assert File.read!(Path.join(dir, "teardown.log")) == "teardown #{g.run_dir}\nno abort\n"
    # The worker carries the run's tag, which teardown finds its processes by.
    assert File.read!(Path.join(dir, "worker.env")) == "run=r1 dir=#{g.run_dir}\n"
    refute File.exists?(g.run_dir)
  end

  test "SIGHUP to the ssh side (the session went away) stops the worker and runs teardown", %{tmp_dir: dir} do
    g = start(dir, worker(dir, 300, 0), 30)
    heartbeat(g)
    await_file(Path.join(dir, "worker.pid.seen"))
    wpid = worker_pid(dir)

    System.cmd("kill", ["-HUP", to_string(g.pid)])

    assert {2, out} = await_exit(g)
    assert out =~ "stopping the cell: SIGHUP"
    assert File.read!(Path.join(dir, "teardown.log")) =~ "teardown #{g.run_dir}\nSIGHUP"
    assert gone?(wpid)
  end

  test "SIGTERM to the guard runs teardown", %{tmp_dir: dir} do
    g = start(dir, worker(dir, 300, 0), 30)
    heartbeat(g)
    await_file(Path.join(dir, "worker.pid.seen"))
    guard = g.run_dir |> Path.join("guard.pid") |> File.read!() |> String.trim()

    System.cmd("kill", ["-TERM", guard])

    assert {2, _} = await_exit(g)
    assert File.read!(Path.join(dir, "teardown.log")) =~ "SIGTERM"
    assert gone?(worker_pid(dir))
  end

  test "the session's stdin closing (the NUC process died) runs teardown", %{tmp_dir: dir} do
    g = start(dir, worker(dir, 300, 0), 30)
    heartbeat(g)
    await_file(Path.join(dir, "worker.pid.seen"))
    log = Path.join(dir, "worker.log")

    # Closing the port closes the session's stdin; the guard lives on alone.
    Port.close(g.port)
    await_file(Path.join(g.run_dir, "exit"))

    assert File.read!(Path.join(dir, "teardown.log")) =~ "SIGHUP"
    assert File.read!(log) =~ "stopping the cell"
    assert gone?(worker_pid(dir))
  end

  test "heartbeats keep the cell running; when they stop, the guard stops it and runs teardown",
       %{tmp_dir: dir} do
    g = start(dir, worker(dir, 300, 0), 3)
    await_file(Path.join(dir, "worker.pid.seen"))

    for _ <- 1..4 do
      heartbeat(g)
      Process.sleep(1_000)
    end

    # 4 s of heartbeats: past the 3 s limit, still running.
    refute File.exists?(Path.join(dir, "teardown.log"))
    assert alive?(worker_pid(dir))

    assert {2, out} = await_exit(g)
    assert out =~ "heartbeat lost"
    assert File.read!(Path.join(dir, "teardown.log")) =~ "heartbeat lost: nothing from the NUC"
    assert gone?(worker_pid(dir))
  end
end
