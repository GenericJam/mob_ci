defmodule MobCi.BootDiagTest do
  use ExUnit.Case, async: true

  alias MobCi.{BootDiag, Farm, Run, Store}

  @pkg "com.example.ci_all_master"
  @node :"ci_all_master_android_ci0@127.0.0.1"
  @epmd_up "epmd: up and running on port 4369 with data:\nname mob_ci_2545977 at port 44689\n"
  @epmd_registered @epmd_up <> "name ci_all_master_android_ci0 at port 9300\n"

  # Lines as `adb logcat -v threadtime` printed them on ci-redroid0 (cell 709):
  # redroid's bluetooth HAL aborts at every boot, mob_dev's install-time start
  # dies on a missing boot file, then the CI launch's start.
  @boot_noise """
  --------- beginning of main
  10-13 07:14:40.293    81   977 F libc    : Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 977 (bluetooth@1.1-s), pid 81 (bluetooth@1.1-s)
  10-13 07:14:40.459   996   996 F DEBUG   : pid: 81, tid: 977, name: bluetooth@1.1-s  >>> /vendor/bin/hw/android.hardware.bluetooth@1.1-service.sim <<<
  10-13 07:14:40.460   996   996 F DEBUG   : Abort message: 'bluetooth HAL gone'
  10-13 07:18:31.482   225   256 I ActivityManager: Start proc 2258:com.example.ci_all_master/u0a77 for next-top-activity {com.example.ci_all_master/com.example.ci_all_master.MainActivity}
  10-13 07:18:32.821  2258  2287 I BEAMout : Runtime terminating during boot ({'cannot get bootfile','/data/user/0/com.example.ci_all_master/files/otp/releases/29/start_clean.boot'})
  10-13 07:18:32.987   225   606 I ActivityManager: Process com.example.ci_all_master (pid 2258) has died: fg  TOP
  10-13 07:18:48.882   225   510 I ActivityManager: Force stopping com.example.ci_all_master appid=10077 user=0: from pid 2321
  10-13 07:18:49.980   225   256 I ActivityManager: Start proc 2701:com.example.ci_all_master/u0a77 for next-top-activity {com.example.ci_all_master/com.example.ci_all_master.MainActivity}
  10-13 07:18:50.100   312   312 I SomeService: unrelated chatter
  """

  defp diag(after_start, opts \\ []) do
    BootDiag.new(@pkg, Keyword.get(opts, :node, @node), %{
      pid: Keyword.get(opts, :pid, {"2701\n", 0}),
      logcat: {@boot_noise <> after_start, 0},
      epmd: Keyword.get(opts, :epmd, {@epmd_up, 0})
    })
  end

  @not_running {"", 1}

  describe "the cause, from the last start's process" do
    test "a Java crash names the exception, not the Process: line" do
      d =
        diag(
          """
          10-13 07:18:51.000  2701  2701 E AndroidRuntime: FATAL EXCEPTION: main
          10-13 07:18:51.000  2701  2701 E AndroidRuntime: Process: com.example.ci_all_master, PID: 2701
          10-13 07:18:51.000  2701  2701 E AndroidRuntime: java.lang.UnsatisfiedLinkError: dlopen failed: library "libmob_whisper_nif.so" not found
          10-13 07:18:51.100   225   606 I ActivityManager: Process com.example.ci_all_master (pid 2701) has died: fg  TOP
          """,
          pid: @not_running
        )

      assert d.cause =~ ~s{the app crashed (Java): java.lang.UnsatisfiedLinkError: dlopen failed: library "libmob_whisper_nif.so" not found}
      assert d.pid == nil
    end

    test "the app's native crash with its tombstone's abort message; other processes' crashes are not blamed" do
      d =
        diag(
          """
          10-13 07:18:52.000  2701  2730 F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 2730 (erts_sched_1), pid 2701 (e.ci_all_master)
          10-13 07:18:52.050  3001  3001 F DEBUG   : pid: 2999, tid: 2999, name: bluetooth@1.1-s  >>> /vendor/bin/hw/android.hardware.bluetooth@1.1-service.sim <<<
          10-13 07:18:52.051  3001  3001 F DEBUG   : Abort message: 'bluetooth HAL gone again'
          10-13 07:18:52.100  2790  2790 F DEBUG   : pid: 2701, tid: 2730, name: erts_sched_1  >>> com.example.ci_all_master <<<
          10-13 07:18:52.100  2790  2790 F DEBUG   : Abort message: 'mob_nif: null env'
          """,
          pid: @not_running
        )

      assert d.cause =~ "the app crashed (native): Fatal signal 11 (SIGSEGV)"
      assert d.cause =~ "abort message: 'mob_nif: null env'"
      refute d.cause =~ "bluetooth"
      refute Enum.any?(d.lines, &(&1 =~ "bluetooth"))
    end

    test "the BEAM stopping during boot, but only the last start's (mob_dev's install-time start always dies)" do
      assert diag("10-13 07:18:53.000  2701  2724 I BEAMout : Kernel pid terminated (application_controller) ({application_start_failure,mob_mishka,bad})\n").cause =~
               "the BEAM stopped: Kernel pid terminated (application_controller) ({application_start_failure,mob_mishka,bad})"

      # the install-time start's "Runtime terminating during boot" is before the last start
      refute diag("").cause =~ "the BEAM stopped"
    end

    test "an earlier start's late lines after the last start are not the cause" do
      d =
        diag("""
        10-13 07:18:50.200  2258  2287 I BEAMout : Crash dump is being written to: /data/user/0/com.example.ci_all_master/files/erl_crash.dump...done
        10-13 07:18:50.300   225   606 I ActivityManager: Process com.example.ci_all_master (pid 2258) has died: fg  TOP
        10-13 07:18:55.942  2701  2742 I Elixir  : Mob.Dist: distribution started
        """)

      assert d.cause =~ "Mob.Dist started distribution, but mob_ci never connected"

      gone = diag("10-13 07:18:50.300   225   606 I ActivityManager: Process com.example.ci_all_master (pid 2258) has died: fg  TOP\n", pid: @not_running)
      assert gone.cause =~ "the app is not running and logcat has no crash for it"
    end

    test "Mob.Dist skipping distribution for want of the EPMD tunnel" do
      d =
        diag("""
        10-13 07:18:55.911  2701  2742 I Elixir  : Mob.Dist: waiting for EPMD (adb reverse tcp:4369 tcp:4369)...
        10-13 07:19:05.911  2701  2742 I Elixir  : Mob.Dist: no EPMD on port 4369 after 10s -- skipping dist (run mix mob.connect to enable)
        """)

      assert d.cause =~ "Mob.Dist skipped distribution: no EPMD on the device's 127.0.0.1:4369"
      assert d.cause =~ "(host EPMD: ci_all_master_android_ci0 not registered)"
    end

    test "Mob.Dist failing to start distribution quotes its result" do
      d =
        diag("""
        10-13 07:18:55.917  2701  2742 I Elixir  : Mob.Dist: EPMD reachable, starting dist
        10-13 07:18:55.942  2701  2742 I Elixir  : Mob.Dist: result={:error, {{:shutdown, {:failed_to_start_child, :net_kernel, {:EXIT, :nodistribution}}}, {:child, :undefined, :net_sup_dynamic, {:erl_distribution, :start_link, []}, :permanent, false, 1000, :supervisor, [:erl_distribution]}}}
        """)

      assert d.cause =~ "Mob.Dist could not start distribution: Mob.Dist: result={:error,"
      assert d.cause =~ ":nodistribution"
    end

    test "distribution started and registered, yet never connected: the host EPMD port says it was there" do
      d =
        diag(
          """
          10-13 07:18:55.942  2701  2742 I Elixir  : Mob.Dist: result={:ok, #PID<0.324.0>}
          10-13 07:18:55.942  2701  2742 I Elixir  : Mob.Dist: distribution started
          """,
          epmd: {@epmd_registered, 0}
        )

      assert d.cause ==
               "Mob.Dist started distribution, but mob_ci never connected to the node (host EPMD: ci_all_master_android_ci0 at port 9300)"

      assert BootDiag.detail(d).epmd_port == 9300
    end

    test "a process that died without a crash, one not running, one running that never reached Mob.Dist" do
      died = diag("10-13 07:18:53.000   225   606 I ActivityManager: Process com.example.ci_all_master (pid 2701) has died: fg  TOP\n", pid: @not_running)
      assert died.cause =~ "the app's process died with no crash in logcat: Process com.example.ci_all_master (pid 2701) has died"

      assert diag("", pid: @not_running).cause =~ "the app is not running and logcat has no crash for it"
      assert diag("").cause =~ "the app is running (pid 2701) but its BEAM never reached Mob.Dist"
    end

    test "without an expected node (the release install's first launch) there is no EPMD note" do
      refute diag("", node: nil).cause =~ "host EPMD"
    end
  end

  describe "a capture that failed proves nothing" do
    test "an unreadable logcat says so instead of guessing" do
      d = BootDiag.new(@pkg, @node, %{pid: {"error: device offline", 1}, logcat: {"error: device offline\n", 1}, epmd: {@epmd_up, 0}})
      assert d.cause =~ "logcat unavailable: exit 1: error: device offline"
      assert d.pid == :unknown
    end

    test "a pidof that failed or timed out is unknown, not 'not running'" do
      d = diag("", pid: {"", 124})
      assert d.pid == :unknown
      assert d.cause =~ "the app's state is unknown (pidof failed)"
      assert "pidof: timed out ((no output))" in d.problems
    end

    test "an epmd that didn't answer is unreadable, not 'not registered'" do
      d = diag("", epmd: {"epmd: Cannot connect to local epmd", 1})
      assert d.cause =~ "(host EPMD unreadable for ci_all_master_android_ci0)"
      assert BootDiag.detail(d).epmd_port == :unknown
    end

    test "a logcat cut short by the timeout is used, and marked partial" do
      d =
        BootDiag.new(@pkg, @node, %{
          pid: {"2701", 0},
          logcat: {@boot_noise <> "10-13 07:18:55.942  2701  2742 I Elixir  : Mob.Dist: distribution started\n", 124},
          epmd: {@epmd_up, 0}
        })

      assert d.cause =~ "Mob.Dist started distribution"
      assert "logcat: timed out, the dump is partial" in d.problems
    end
  end

  describe "attribution" do
    test "the app's own words in a diagnosis never make a boot error the farm's" do
      d =
        diag(
          """
          10-13 07:18:51.000  2701  2701 E AndroidRuntime: FATAL EXCEPTION: main
          10-13 07:18:51.000  2701  2701 E AndroidRuntime: java.lang.IllegalStateException: device offline mode is unsupported
          """,
          pid: @not_running
        )

      assert d.cause =~ "device offline"
      assert Run.error_layer({:launch_failed, {:node_never_registered, @node, d}}) == :boot
      refute Farm.lost_device?({:node_never_registered, @node, d})
    end

    test "a reason carrying a diagnosis inspects as its cause and is found at any depth" do
      d = diag("")
      reason = {:instance_lost, "gone", {:launch_failed, {:node_never_registered, @node, d}}}

      assert BootDiag.find(reason) == d
      assert BootDiag.find({:launch_failed, {:node_never_registered, @node}}) == nil
      assert inspect(reason) =~ "#BootDiag<the app is running (pid 2701)"
      refute inspect(reason) =~ "Start proc"
    end
  end

  test "the app's lines are its own since the last start, plus lines naming the package" do
    d = diag("10-13 07:18:55.911  2701  2742 I Elixir  : Mob.Dist: waiting for EPMD (adb reverse tcp:4369 tcp:4369)...\n")

    assert [first | _] = d.lines
    assert first =~ "Start proc 2701:"
    assert Enum.any?(d.lines, &(&1 =~ "Mob.Dist: waiting for EPMD"))
    refute Enum.any?(d.lines, &(&1 =~ "unrelated chatter"))
    refute Enum.any?(d.lines, &(&1 =~ "cannot get bootfile"))
  end

  describe "write/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "boot_diag_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "appends the diagnosis to the path log and keeps the full dump beside it", %{dir: dir} do
      log = Path.join(dir, "deploy.log")
      File.write!(log, "BUILD SUCCESSFUL\n")

      text = BootDiag.write(diag(""), log)

      body = File.read!(log)
      assert String.starts_with?(body, "BUILD SUCCESSFUL\n")
      assert body =~ "cause: the app is running (pid 2701)"
      assert body =~ "full dump: deploy.logcat.log"
      assert text =~ "Start proc 2701:"
      assert File.read!(Path.join(dir, "deploy.logcat.log")) =~ "unrelated chatter"
    end

    test "never raises when the log can't be written: the boot error must still be recorded", %{dir: dir} do
      # the log's directory is a file
      File.write!(Path.join(dir, "artifacts"), "")
      text = BootDiag.write(diag(""), Path.join([dir, "artifacts", "deploy.log"]))

      assert text =~ "cause: the app is running (pid 2701)"
      assert text =~ "mob_ci could not keep this beside"
    end
  end

  test "the store keeps a boot error's cause and logcat tail under detail.boot" do
    path = Path.join(System.tmp_dir!(), "boot_diag_store_#{System.unique_integer([:positive])}.sqlite")
    on_exit(fn -> File.rm(path) end)
    store = Store.open!(path)

    try do
      {:ok, run_id} = Store.record_run(store, %{trigger: "test", versions_row: "master", host: "test", mob_ci_sha: nil})
      # invalid UTF-8 from an app's log must not break the JSON detail
      d = diag("10-13 07:18:56.000  2701  2742 I Elixir  : bad bytes \xff\xfe\n")
      meta = %{set: "all", platform: :android, path: "deploy:android", versions: nil, duration_ms: 1, log_path: nil}

      :ok = Store.record_results(store, run_id, meta, {:error, {:launch_failed, {:node_never_registered, @node, d}}, :boot})

      [cell] = Store.query(store, run_id: run_id)
      assert cell.detail["error"] =~ "#BootDiag<the app is running (pid 2701)"
      assert cell.detail["boot"]["cause"] == d.cause
      assert cell.detail["boot"]["pid"] == "2701"
      assert Enum.any?(cell.detail["boot"]["logcat"], &(&1 =~ "bad bytes"))
    after
      Store.close(store)
    end
  end
end
