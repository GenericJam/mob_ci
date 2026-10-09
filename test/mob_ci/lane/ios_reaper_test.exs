defmodule MobCi.Lane.Ios.ReaperTest do
  # Not async: one test runs a whole cell, which sets TMPDIR while it runs.
  use ExUnit.Case, async: false

  alias MobCi.Lane.Ios.{Reaper, Spec, Worker}

  @moduletag :tmp_dir

  @resolved %{
    row: :hex,
    repos: %{
      mob: %{version: "0.9.15", sha: nil, source: :hex, dir: nil},
      mob_dev: %{version: "0.7.17", sha: nil, source: :hex, dir: nil},
      mob_new: %{version: "0.6.7", sha: nil, source: :hex, dir: "/hex/mob_new-0.6.7"},
      mob_camera: %{version: "0.1.12", sha: nil, source: :hex, dir: nil}
    }
  }

  @daemon "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/agent-device/dist/src/internal/daemon.js"
  @now 1_000_000

  defp spec(path, stamp) do
    cell = %{set: "default", plugins: [:mob_camera], resolved: @resolved}
    udid = if path == "deploy:ios_device", do: "UDID-1"
    {:ok, spec} = Spec.from_cell(cell, path, stamp: stamp, udid: udid)
    spec
  end

  # A fake process table: `ps` lists what is in the Agent, `kill` records the
  # signal and removes the process unless it ignores that signal.
  defp procs(list) do
    {:ok, table} = Agent.start_link(fn -> list end)
    table
  end

  # As macOS prints it: a platform binary (`platform: true`) shows no environment.
  defp ps_line(%{pid: pid, cmd: cmd} = p) do
    env =
      cond do
        p[:platform] -> ""
        p[:run] -> " HOME=/Users/kevin MOB_CI_RUN=#{p.run} MOB_CI_RUN_DIR=/runs/#{p.run}"
        true -> " HOME=/Users/kevin"
      end

    "#{String.pad_leading(to_string(pid), 6)} #{String.pad_leading(to_string(p[:ppid] || 1), 6)} #{cmd}#{env}"
  end

  defp deps(dir, table, overrides \\ %{}) do
    me = self()

    worker = %{
      log: fn _ -> :ok end,
      release: fn session ->
        send(me, {:release, session})
        {"", 0}
      end,
      uninstall: fn path, udid, app ->
        send(me, {:uninstall, path, udid, app})
        {"", 0}
      end,
      rm_rf: fn path ->
        send(me, {:rm_rf, path})
        File.rm_rf!(path)
      end,
      mob_home: Path.join(dir, "mob_home"),
      darwin_tmp: Path.join(dir, "T")
    }

    Map.merge(
      %{
        log: fn _ -> :ok end,
        ps: fn -> table |> Agent.get(& &1) |> Enum.map_join("\n", &ps_line/1) end,
        kill: fn pid, sig ->
          send(me, {:kill, pid, sig})

          Agent.update(table, fn ps ->
            Enum.reject(ps, &(&1.pid == pid and (sig == "KILL" or not Map.get(&1, :ignores_term, false))))
          end)
        end,
        alive?: fn pid -> pid in [111, 222] end,
        sleep: fn _ -> :ok end,
        now: fn -> @now end,
        grace_ms: 1_000,
        reap_after_s: 600,
        claims: fn -> [] end,
        release: worker.release,
        rm_rf: worker.rm_rf,
        runs_root: Path.join(dir, "runs"),
        scratch_root: Path.join(dir, "scratch"),
        lease_root: Path.join(dir, "agents"),
        mob_home: worker.mob_home,
        darwin_tmp: worker.darwin_tmp,
        worker: worker
      },
      overrides
    )
  end

  # A dir, last modified age_s ago.
  defp touch(path, age_s) do
    File.mkdir_p!(path)
    File.touch!(path, @now - age_s)
    path
  end

  # A file, last modified age_s ago.
  defp stamp(path, age_s) do
    File.mkdir_p!(Path.dirname(path))
    File.touch!(path, @now - age_s)
    path
  end

  # A run dir as guard.sh leaves it: guard.pid, a fresh `alive`, and the
  # manifest of a cell that was building on a leased simulator.
  defp run_dir(dir, id, guard_pid, cell \\ nil) do
    run = Path.join([dir, "runs", id])
    File.mkdir_p!(Path.join(run, "cells"))
    File.write!(Path.join(run, "guard.pid"), "#{guard_pid}\n")
    stamp(Path.join(run, "guard.pid"), 5)
    stamp(Path.join(run, "alive"), 1)

    if cell do
      scratch = touch(Path.join([dir, "scratch", cell.cell_id]), 3_000)

      File.write!(
        Worker.manifest_path(run, cell.cell_id),
        JSON.encode!(%{
          "schema" => 1,
          "spec" => JSON.decode!(Spec.to_json(cell)),
          "scratch" => scratch,
          "lease_tried" => true,
          "leased" => true,
          "device" => %{"udid" => "SIM-1", "name" => "iPhone 18 Pro"},
          "host" => %{"dir" => Path.join(scratch, "ci_default_hex"), "app" => "ci_default_hex", "pkg" => "com.example.ci_default_hex"}
        })
      )
    end

    run
  end

  describe "the process table" do
    test "reads each process's parent and run (from the environment ps -E prints after the command)" do
      out = """
        501     1 /bin/bash guard.sh supervise --run-dir /x/runs/r1 HOME=/Users/kevin
        502   501 /Users/kevin/zig build binary HOME=/Users/kevin MOB_CI_RUN=r1 MOB_CI_RUN_DIR=/x/runs/r1
        503   502 /usr/bin/env MOB_CI_RUN_DIR=/x/runs/r2 PATH=/bin
        504     1 java -cp gradle MOB_CI_RUN=r2
        505   502 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme App
      """

      assert [
               %{pid: 501, ppid: 1, run: nil},
               %{pid: 502, ppid: 501, run: "r1"},
               %{pid: 503, run: nil},
               %{pid: 504, run: "r2", command: "java -cp gradle MOB_CI_RUN=r2"},
               %{pid: 505, ppid: 502, run: nil}
             ] = Reaper.parse_ps(out)
    end

    test "a run's processes: its tagged ones and all their descendants, platform binaries included; nothing else" do
      procs =
        Reaper.parse_ps(
          Enum.map_join(
            [
              %{pid: 10, ppid: 1, cmd: "beam.smp -- mix ci.ios_cell", run: "r1"},
              %{pid: 11, ppid: 10, cmd: "erl_child_setup 256", run: "r1"},
              # a port program in a session of its own; Apple binaries show no environment
              %{pid: 12, ppid: 11, cmd: "/bin/sh -c xcodebuild", platform: true},
              %{pid: 13, ppid: 12, cmd: "xcodebuild -scheme App", platform: true},
              %{pid: 14, ppid: 13, cmd: "clang -c x.m", platform: true},
              # started by the cell, shared by everyone
              %{pid: 15, ppid: 11, cmd: "adb -L tcp:5037 fork-server server", run: "r1"},
              %{pid: 16, ppid: 11, cmd: "adb -s R5CT shell getprop", run: "r1"},
              %{pid: 17, ppid: 1, cmd: @daemon, run: "r1"},
              %{pid: 18, ppid: 17, cmd: "/usr/bin/xcrun simctl list", platform: true},
              %{pid: 20, ppid: 1, cmd: "xcodebuild -scheme Theirs", platform: true},
              %{pid: 21, ppid: 1, cmd: "zig build", run: "r2"}
            ],
            "\n",
            &ps_line/1
          )
        )

      pids = &Enum.map(Reaper.run_processes(procs, fn p -> p.run == "r1" end, &1), fn p -> p.pid end)
      assert pids.(false) == [10, 11, 12, 13, 14, 16]
      assert pids.(true) == [10, 11, 12, 13, 14, 16, 17, 18]
    end

    test "the adb server and epmd are shared, whoever started them; an agent-device daemon is a lease daemon" do
      assert Reaper.shared?("adb -L tcp:5037 fork-server server --reply-fd 4 HOME=/x")
      assert Reaper.shared?("/Users/kevin/.local/share/mise/installs/erlang/29.0/erts-17.0/bin/epmd -daemon HOME=/x")
      refute Reaper.shared?("adb -s R5CT install app.apk HOME=/x")
      refute Reaper.shared?("/usr/bin/xcodebuild -scheme App")
      assert Reaper.lease_daemon?(@daemon)
      refute Reaper.lease_daemon?("/opt/homebrew/bin/node agent-device open --session x")
    end
  end

  describe "teardown_run/2 (a worker that died, or the guard's normal end)" do
    test "stops the run's processes, undoes its cells, then stops its lease daemon; other runs and shared daemons stay",
         %{tmp_dir: dir} do
      cell = spec("deploy:ios_sim", "T1")
      run = run_dir(dir, "r1", 111, cell)

      table =
        procs([
          %{pid: 10, cmd: "beam.smp -- mix ci.ios_cell", run: "r1"},
          %{pid: 11, ppid: 10, cmd: "zig build binary", run: "r1", ignores_term: true},
          %{pid: 14, ppid: 11, cmd: "xcodebuild -scheme App", platform: true},
          %{pid: 12, cmd: @daemon, run: "r1"},
          %{pid: 13, cmd: "adb -L tcp:5037 fork-server server", run: "r1"},
          %{pid: 20, cmd: "xcodebuild -scheme Other", run: "r2"},
          %{pid: 30, cmd: "java GradleDaemon"}
        ])

      cells = Reaper.teardown_run(run, deps(dir, table))

      assert %{"default-hex-deploy_ios_sim-t1" => {:ok, teardown}} = cells
      assert Enum.map(teardown, & &1["name"]) == ~w(uninstall release_lease delete_app_state delete_scratch)
      refute File.exists?(Path.join([dir, "scratch", cell.cell_id]))
      refute File.exists?(Worker.manifest_path(run, cell.cell_id))

      # The build first (TERM, then KILL for the one ignoring it), then the
      # cell's teardown, then the lease daemon, after its lease was released.
      assert messages() == [
               {:kill, 10, "TERM"},
               {:kill, 11, "TERM"},
               {:kill, 14, "TERM"},
               {:kill, 11, "KILL"},
               {:uninstall, "deploy:ios_sim", "SIM-1", "com.genericjam.mobci"},
               {:release, "mob_ci_ios_default-hex-deploy_ios_sim-t1"},
               {:rm_rf, Path.join([dir, "scratch", cell.cell_id])},
               {:kill, 12, "TERM"}
             ]

      assert Agent.get(table, &Enum.map(&1, fn p -> p.pid end)) == [13, 20, 30]
    end

    test "a cell killed mid-build leaves a manifest that teardown undoes exactly as the worker would have",
         %{tmp_dir: dir} do
      run = Path.join(dir, "runs/r1")
      snapshot = Path.join(dir, "manifest-at-build.json")
      me = self()
      cell = spec("deploy:android_physical", "T2")

      worker_deps = %{
        log: fn _ -> :ok end,
        free_kb: fn -> {:ok, 20 * 1024 * 1024} end,
        resolve: fn _ -> {:ok, @resolved} end,
        generate: fn _, _, _, opts ->
          dir = Path.join(opts[:root], "ci_default_hex")
          File.mkdir_p!(dir)
          {:ok, %{dir: dir, app: :ci_default_hex, pkg: "com.example.ci_default_hex"}}
        end,
        mix: fn
          ["mob.deploy" | _], _ ->
            # The moment the NUC side would vanish: keep the manifest as it is now.
            File.cp!(Worker.manifest_path(run, cell.cell_id), snapshot)
            {"", 0}

          _, _ ->
            {"", 0}
        end,
        android_devices: fn -> [%{"udid" => "R5CT", "name" => "moto", "sdk" => 34, "attached" => true}] end,
        lease: fn _ -> :ok end,
        release: fn s -> send(me, {:release, s}) && {"", 0} end,
        uninstall: fn path, id, app -> send(me, {:uninstall, path, id, app}) && {"", 0} end,
        probe: fn _, _, _, _ -> {:ok, %{"found" => true, "alive" => true, "entries" => [], "findings" => []}} end,
        rm_rf: fn p -> send(me, {:rm_rf, p}) && File.rm_rf!(p) end,
        mob_home: Path.join(dir, "mob_home"),
        darwin_tmp: nil
      }

      root = Path.join(dir, "scratch")
      r = Worker.run(cell, root: root, run_dir: run, deps: worker_deps)
      assert r["outcome"] == "pass"
      # A worker that ends removes its manifest...
      refute File.exists?(Worker.manifest_path(run, cell.cell_id))
      flush()

      # ...one that was killed mid-build left this one: replay it.
      File.mkdir_p!(Path.join([root, cell.cell_id, "ci_default_hex/_build"]))
      assert {:ok, teardown} = Worker.teardown_manifest(snapshot, worker_deps)

      assert Enum.map(teardown, &{&1["name"], &1["result"]}) ==
               Enum.map(~w(uninstall release_lease delete_app_state delete_scratch), &{&1, "ok"})

      assert_received {:uninstall, "deploy:android_physical", "R5CT", "com.example.ci_default_hex"}
      assert_received {:release, "mob_ci_ios_default-hex-deploy_android_physical-t2"}
      refute File.exists?(Path.join(root, cell.cell_id))
      refute File.exists?(snapshot)
    end

    test "a manifest whose scratch is not its cell's own dir deletes nothing", %{tmp_dir: dir} do
      cell = spec("deploy:ios_sim", "T1")
      victim = touch(Path.join(dir, "not-a-cell"), 0)
      path = Path.join(dir, "m.json")

      File.write!(
        path,
        JSON.encode!(%{"schema" => 1, "spec" => JSON.decode!(Spec.to_json(cell)), "scratch" => victim, "leased" => false})
      )

      assert {:error, msg} = Worker.teardown_manifest(path, deps(dir, procs([])).worker)
      assert msg =~ "is not the cell's"
      assert File.dir?(victim)
      refute File.exists?(path)
    end
  end

  describe "reap/2 (what the next cell runs first)" do
    test "tears down dead runs, leaves live ones and the reaping run alone", %{tmp_dir: dir} do
      dead_cell = spec("deploy:ios_sim", "DEAD")
      live_cell = spec("deploy:ios_sim", "LIVE")
      dead = run_dir(dir, "r-dead", 999, dead_cell)
      live = run_dir(dir, "r-live", 111, live_cell)
      own = run_dir(dir, "r-own", 4242)
      # Its guard is alive but has said nothing for 5 minutes: wedged, dead.
      silent = run_dir(dir, "r-silent", 222)
      stamp(Path.join(silent, "alive"), 300)
      stamp(Path.join(silent, "guard.pid"), 300)

      table =
        procs([
          %{pid: 10, cmd: "zig build", run: "r-dead"},
          %{pid: 11, cmd: "xcodebuild", run: "r-live"},
          %{pid: 12, cmd: "beam.smp mix ci.ios_cell", run: "r-own"},
          %{pid: 13, cmd: "java GradleDaemon", run: "r-gone"}
        ])

      result = Reaper.reap("r-own", deps(dir, table))

      assert Enum.sort(result.runs) == ["r-dead", "r-silent"]
      refute File.exists?(dead)
      assert File.dir?(live) and File.dir?(own)
      refute File.exists?(Path.join([dir, "scratch", dead_cell.cell_id]))
      assert File.dir?(Path.join([dir, "scratch", live_cell.cell_id]))
      assert_received {:release, "mob_ci_ios_default-hex-deploy_ios_sim-dead"}
      refute_received {:release, "mob_ci_ios_default-hex-deploy_ios_sim-live"}

      assert Agent.get(table, &Enum.map(&1, fn p -> p.pid end)) == [11, 12]
    end

    test "releases only mob_ci's orphaned leases, idle long enough, and prunes their state dirs", %{tmp_dir: dir} do
      live_cell = spec("deploy:ios_device", "LIVE")
      run_dir(dir, "r-live", 111, live_cell)
      agents = Path.join(dir, "agents")

      orphan = stamp(Path.join(agents, "mob_ci_ios_all-hex-deploy_android_physical-old/lease"), 3_600) |> Path.dirname()
      touch(orphan, 3_600)
      pruned = touch(Path.join(agents, "mob_ci_ios_all-master-deploy_ios_sim-old"), 3_600)
      young = touch(Path.join(agents, "mob_ci_ios_all-hex-deploy_ios_sim-young"), 60)
      stamp(Path.join(young, "lease"), 60)
      owned = touch(Path.join(agents, "mob_ci_ios_#{live_cell.cell_id}"), 3_600)
      other = touch(Path.join(agents, "SensorsSelfTest-ios"), 3_600)
      stamp(Path.join(other, "lease"), 3_600)

      claims = fn ->
        ["Scene3dIos", "mob_ci_ios_#{live_cell.cell_id}", "mob_ci_ios_all-hex-deploy_ios_device-nodir"]
      end

      result = Reaper.reap("r-own", deps(dir, procs([]), %{claims: claims}))

      assert Enum.sort(Enum.map(result.leases, &elem(&1, 0))) ==
               ["mob_ci_ios_all-hex-deploy_android_physical-old", "mob_ci_ios_all-hex-deploy_ios_device-nodir"]

      refute File.exists?(orphan)
      refute File.exists?(pruned)
      assert File.dir?(young) and File.dir?(owned) and File.dir?(other)
      refute_received {:release, "Scene3dIos"}
      refute_received {:release, "SensorsSelfTest-ios"}
    end

    test "removes stale scratch and ci_* app state nobody owns; keeps young, live and foreign dirs", %{tmp_dir: dir} do
      live_cell = spec("deploy:ios_sim", "LIVE")
      run_dir(dir, "r-live", 111, live_cell)
      mob = Path.join(dir, "mob_home")
      t = Path.join(dir, "T")

      stale_scratch = touch(Path.join([dir, "scratch", "all-hex-deploy_ios_sim-old"]), 3_600)
      young_scratch = touch(Path.join([dir, "scratch", "all-hex-deploy_ios_sim-new"]), 30)
      not_a_cell = touch(Path.join([dir, "scratch", "Kevin's notes"]), 3_600)
      stale_app = touch(Path.join([mob, "cache/otp-ios-sim-abc/ci_all_hex"]), 3_600)
      stale_runtime = touch(Path.join([mob, "runtime/ios-sim/ci_all_hex"]), 3_600)
      live_app = touch(Path.join([mob, "runtime/ios-sim/ci_default_hex"]), 3_600)
      shared_otp = touch(Path.join([mob, "cache/otp-ios-sim-abc/erts-17.0"]), 3_600)
      other_app = touch(Path.join([mob, "runtime/ios-sim/io"]), 3_600)
      leaked = touch(Path.join(t, "tmp.Wm8qifonVw"), 3_600)
      touch(Path.join(leaked, "CiAllHex.app"), 3_600)
      touch(leaked, 3_600)
      foreign_tmp = touch(Path.join(t, "tmp.Other"), 3_600)
      touch(Path.join(foreign_tmp, "Io.app"), 3_600)
      touch(foreign_tmp, 3_600)

      result = Reaper.reap("r-own", deps(dir, procs([])))

      assert Enum.sort(result.dirs) == Enum.sort([stale_scratch, stale_app, stale_runtime, leaked])
      for d <- result.dirs, do: refute(File.exists?(d))

      for d <- [young_scratch, not_a_cell, live_app, shared_otp, other_app, foreign_tmp, Path.join([dir, "scratch", live_cell.cell_id])],
          do: assert(File.dir?(d), d)
    end

    test "a leftover a running process still names is in use (a cell of a worker that keeps no run); a lease daemon doesn't count",
         %{tmp_dir: dir} do
      agents = Path.join(dir, "agents")
      scratch = Path.join(dir, "scratch")
      busy = touch(Path.join(scratch, "all-master-deploy_ios_sim-busy"), 3_600)
      idle = touch(Path.join(scratch, "all-hex-deploy_ios_device-idle"), 3_600)
      busy_lease = stamp(Path.join(agents, "mob_ci_ios_all-master-deploy_ios_sim-busy/lease"), 3_600) |> Path.dirname()
      touch(busy_lease, 3_600)
      idle_lease = stamp(Path.join(agents, "mob_ci_ios_all-hex-deploy_ios_device-idle/lease"), 3_600) |> Path.dirname()
      touch(idle_lease, 3_600)

      table =
        procs([
          # An untagged build, its TMPDIR inside the busy cell's scratch.
          %{pid: 10, cmd: "zig build binary TMPDIR=#{busy}/tmp"},
          # The idle cell's lease daemon outlived it: no reason to keep the cell.
          %{pid: 11, cmd: "#{@daemon} AGENT_DEVICE_STATE_DIR=#{idle_lease} TMPDIR=#{idle}/tmp"}
        ])

      claims = fn -> ["mob_ci_ios_all-master-deploy_ios_sim-busy", "mob_ci_ios_all-hex-deploy_ios_device-idle"] end
      result = Reaper.reap("r-own", deps(dir, table, %{claims: claims}))

      assert result.leases == [{"mob_ci_ios_all-hex-deploy_ios_device-idle", {"", 0}}]
      assert Enum.sort(result.dirs) == Enum.sort([idle, idle_lease])
      assert File.dir?(busy) and File.dir?(busy_lease)
      assert result.processes == []
    end

    test "a process whose run is not live is stopped; untagged and shared ones never are", %{tmp_dir: dir} do
      table =
        procs([
          %{pid: 10, cmd: "zig build", run: "r-gone"},
          %{pid: 11, cmd: @daemon, run: "r-gone"},
          %{pid: 12, cmd: "epmd -daemon", run: "r-gone"},
          %{pid: 13, cmd: "java GradleDaemon"},
          %{pid: 14, cmd: @daemon}
        ])

      assert Enum.sort(Reaper.reap("r-own", deps(dir, table)).processes) == [10, 11]
      assert Agent.get(table, &Enum.map(&1, fn p -> p.pid end)) == [12, 13, 14]
    end
  end

  describe "for real (macOS ps -E)" do
    @describetag skip: if(:os.type() != {:unix, :darwin}, do: "needs macOS ps -E")

    test "stop_run/3 stops a run's BEAM and its port programs (own sessions, Apple binaries, TERM-proof), and nothing else" do
      run = "test-#{System.unique_integer([:positive])}"
      elixir = System.find_executable("elixir")

      spawn_bg = fn env, code ->
        port = Port.open({:spawn_executable, elixir}, [:exit_status, args: ["-e", code], env: env])
        {:os_pid, pid} = Port.info(port, :os_pid)
        pid
      end

      # As a cell's BEAM runs xcodebuild: a port program, in a session of its
      # own, an Apple binary (no environment in ps), here ignoring SIGTERM.
      cell = spawn_bg.([{~c"MOB_CI_RUN", String.to_charlist(run)}], ~S|System.cmd("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 61"])|)
      other = spawn_bg.([{~c"MOB_CI_RUN", ~c"another-run"}], "Process.sleep(60_000)")
      untagged = spawn_bg.([], "Process.sleep(60_000)")
      Process.sleep(3_000)

      deps = %{Reaper.default_deps() | log: fn _ -> :ok end, grace_ms: 1_000}
      before = Reaper.parse_ps(deps.ps.())
      command = fn pid -> Enum.find_value(before, &(&1.pid == pid && &1.command)) end

      stopped = Reaper.stop_run(run, deps)
      assert cell in stopped
      assert Enum.any?(stopped, &(command.(&1) =~ ~r{^/bin/sleep 61}))
      assert Enum.any?(stopped, &(command.(&1) =~ ~r{^/bin/sh -c trap}))
      refute other in stopped or untagged in stopped

      Process.sleep(200)
      for pid <- stopped, do: refute(deps.alive?.(pid), "#{pid} #{command.(pid)} still alive")
      assert deps.alive?.(other) and deps.alive?.(untagged)

      for pid <- [other, untagged], do: System.cmd("kill", ["-KILL", "#{pid}"])
    end
  end

  defp messages(acc \\ []) do
    receive do
      m -> messages([m | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush, do: messages() && :ok
end
