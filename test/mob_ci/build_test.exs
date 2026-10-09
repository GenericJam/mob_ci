defmodule MobCi.BuildTest do
  use ExUnit.Case, async: true

  alias MobCi.{Build, Plugins}

  test "mob_exs activates only manifest-bearing plugins + the unsigned gate" do
    body = Build.mob_exs(Plugins.sample_set(), "/x/mob")
    assert body =~ "config :mob, :plugins,"
    assert body =~ "acknowledge_unsafe_plugins"
    assert body =~ ":mob_ci_haptic"
    assert body =~ ":mob_ci_notes"
    refute body =~ ":mob_ci_palette"
    assert body =~ ~s(mob_dir: "/x/mob")
  end

  test "core_deps is the master row: path deps on the ecosystem's mob + mob_dev" do
    assert [{:mob, mob}, {:mob_dev, dev}] = Build.core_deps("/eco")
    assert mob[:path] == "/eco/mob"
    assert dev[:path] == "/eco/mob_dev"
    assert dev[:only] == :dev and dev[:runtime] == false
  end

  test "render_dep emits a dep tuple as mix.exs source" do
    assert Build.render_dep({:mob, "== 0.9.14"}) == ~s({:mob, "== 0.9.14"})
    assert Build.render_dep({:mob_dev, path: "/x/mob_dev", only: :dev}) == ~s({:mob_dev, path: "/x/mob_dev", only: :dev})
  end

  test "deps_block wires the core deps + ecto + a path dep per activated fixture" do
    hdir = "/home/kevin/code/mob_ci/fixtures/_harness/mob_ci_harness"
    block = Build.deps_block(Plugins.sample_set(), hdir, Build.core_deps("/eco"))
    assert block =~ "defp deps do"
    assert block =~ ~s({:mob, path: "/eco/mob", override: true})
    assert block =~ ~s({:mob_dev, path: "/eco/mob_dev", only: :dev, runtime: false, override: true})
    assert block =~ ~s({:ecto_sqlite3, "~> 0.18"})
    assert block =~ "{:mob_ci_haptic, path:"
    # tier-0 palette is included as a dep (so it compiles) but isn't activated.
    assert block =~ "{:mob_ci_palette, path:"

    # a hex row renders version requirements instead (the MobCi.Versions seam)
    hex = Build.deps_block(Plugins.sample_set(), hdir, [{:mob, "== 0.9.14"}, {:mob_dev, "== 0.7.16", only: :dev, runtime: false}])
    assert hex =~ ~s({:mob, "== 0.9.14"})
    refute hex =~ "/eco/mob"
  end

  test "mob_dir follows the :mob path dep, else <host>/deps/mob" do
    assert Build.mob_dir("/h", Build.core_deps("/eco")) == "/eco/mob"
    assert Build.mob_dir("/h", [{:mob, "~> 0.9"}, {:mob_dev, "~> 0.7", only: :dev}]) == "/h/deps/mob"
    assert Build.mob_dir("/h", [{:mob, "~> 0.9", override: true}]) == "/h/deps/mob"
  end

  test "local_properties references the discovered OTP cache + this machine's sdk + mob_dir" do
    previous = System.get_env("ANDROID_HOME")
    System.put_env("ANDROID_HOME", "/mac/Library/Android/sdk")

    on_exit(fn ->
      if previous, do: System.put_env("ANDROID_HOME", previous), else: System.delete_env("ANDROID_HOME")
    end)

    props = Build.local_properties("/eco/mob")
    assert props =~ "sdk.dir=/mac/Library/Android/sdk"
    assert props =~ "mob.otp_release_x86_64=" <> Path.expand("~/.mob/cache/otp-android-x86_64-")
    assert props =~ "mob.mob_dir=/eco/mob"
  end

  test "reusable? rejects a harness whose mix.exs was generated against other core deps" do
    dir = Path.join(System.tmp_dir!(), "mob_ci_reuse_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)
    set = Plugins.sample_set()
    now = Build.core_deps("/eco")
    File.write!(Path.join(dir, "mob.exs"), "import Config\n")
    File.write!(Path.join(dir, "mix.exs"), "defmodule X do\n" <> Build.deps_block(set, dir, now) <> "\nend\n")
    assert Build.reusable?(dir, set, now)
    # the June pin (mob_dev == 0.6.5) is stale against the path-dep baseline
    refute Build.reusable?(dir, set, [{:mob, "~> 0.7"}, {:mob_dev, "== 0.6.5", only: :dev, runtime: false}])
    # no mob.exs → never reusable
    File.rm!(Path.join(dir, "mob.exs"))
    refute Build.reusable?(dir, set, now)
  end

  test "package_name and harness_app_name are deterministic" do
    assert Build.package_name(:mob_ci_harness) == "com.example.mob_ci_harness"
    assert Build.harness_app_name(Plugins.sample_set()) == :mob_ci_harness
    other = Build.harness_app_name([:mob_ci_haptic])
    assert other != :mob_ci_harness
    assert to_string(other) =~ ~r/^mob_ci_h_\d+$/
  end

  test "showcase embeds each activated component's widget (P5 subject)" do
    assert Build.component_widgets(Plugins.sample_set()) == [{MobCiGauge, :mob_ci_gauge}]
    src = Build.showcase_source(Plugins.sample_set(), :mob_ci_harness)
    assert src =~ "defmodule MobCiHarness.CiShowcase do"
    assert src =~ "MobCiGauge.widget(id: :mob_ci_gauge)"
    assert Build.showcase_module(:mob_ci_harness) == MobCiHarness.CiShowcase
  end

  test "host_package: sloppy_joe owns its package; harness uses com.example" do
    assert Build.host_package(:sloppy_joe, :sloppy_joe) == "com.genericjam.sloppyjoe"
    assert Build.host_package(:harness, :mob_ci_harness) == "com.example.mob_ci_harness"
  end

  @sj_mix_exs """
  defmodule SloppyJoe.MixProject do
    defp deps do
      [
        {:mob, "~> 0.9.1"},
        {:mob_dev, path: "/Users/kevin/code/mob_dev", only: :dev, runtime: false},
        {:mob_biometric, "~> 0.1.4"},
        {:mob_camera, "~> 0.1.8"},
        # {:mob_commented, "~> 0.1.0"} stays out: it's a comment, not a dep
        {:mob_wake, path: "/Users/kevin/code/mob_wake"},
        {:ecto_sqlite3, "~> 0.18"},
        {:mobile_thing_not_a_plugin, "~> 1.0"}
      ]
    end
  end
  """

  test "plugin_deps reads the mob_* plugin deps out of a mix.exs, not mob/mob_dev" do
    assert Build.plugin_deps(@sj_mix_exs) == [:mob_biometric, :mob_camera, :mob_wake]
  end

  test "relocate_path_deps rewrites Mac-absolute path deps to the local ecosystem (F7)" do
    exists? = fn p -> p in ["/home/kevin/code/mob_dev", "/home/kevin/code/mob_wake"] end
    out = Build.relocate_path_deps(@sj_mix_exs, "/home/kevin/code", exists?)
    assert out =~ ~s({:mob_dev, path: "/home/kevin/code/mob_dev", only: :dev, runtime: false})
    assert out =~ ~s({:mob_wake, path: "/home/kevin/code/mob_wake"})
    refute out =~ "/Users/kevin"

    # a path that resolves locally is left alone; one with no sibling is left alone too
    assert Build.relocate_path_deps(@sj_mix_exs, "/home/kevin/code", fn p -> String.starts_with?(p, "/Users") end) == @sj_mix_exs
    assert Build.relocate_path_deps(@sj_mix_exs, "/home/kevin/code", fn _ -> false end) == @sj_mix_exs
  end

  # A fake host dir with two signed plugins (distinct keys) and one unsigned.
  defp fake_host(_ctx) do
    dir = Path.join(System.tmp_dir!(), "mob_ci_host_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    for {p, key} <- [touch: :binary.copy(<<1>>, 32), bluetooth: :binary.copy(<<2>>, 32)] do
      priv = Path.join([dir, "deps", "mob_#{p}", "priv"])
      File.mkdir_p!(priv)
      File.write!(Path.join(priv, "mob_plugin.pub"), Base.encode64(key) <> "\n")
    end

    File.mkdir_p!(Path.join([dir, "deps", "mob_ci_unsigned", "priv"]))
    %{host: dir}
  end

  describe "sloppy_joe trust config" do
    setup :fake_host

    test "plugin_fingerprint is ed25519:base64(sha256(pubkey)); nil when unsigned", %{host: host} do
      expected = "ed25519:" <> Base.encode64(:crypto.hash(:sha256, :binary.copy(<<1>>, 32)))
      assert Build.plugin_fingerprint(:mob_touch, host) == expected
      assert Build.plugin_fingerprint(:mob_ci_unsigned, host) == nil
      assert Build.plugin_fingerprint(:mob_nonexistent_zz, host) == nil
    end

    test "sloppy_joe_mob_exs trusts each signed plugin by its OWN fingerprint (F3) and acks all", %{host: host} do
      body = Build.sloppy_joe_mob_exs([:mob_touch, :mob_bluetooth, :mob_ci_unsigned], host)
      touch_fp = Build.plugin_fingerprint(:mob_touch, host)
      bt_fp = Build.plugin_fingerprint(:mob_bluetooth, host)
      assert touch_fp != bt_fp
      assert body =~ "config :mob, :plugins, [:mob_touch, :mob_bluetooth, :mob_ci_unsigned]"
      assert body =~ "mob_touch: #{inspect(touch_fp)}"
      assert body =~ "mob_bluetooth: #{inspect(bt_fp)}"
      # unsigned mob_ci_unsigned ships no pubkey → dropped from trusted, cleared via ack.
      refute body =~ "mob_ci_unsigned: \"ed25519"
      assert body =~ "acknowledge_unsafe_plugins, [:mob_touch, :mob_bluetooth, :mob_ci_unsigned]"
      assert body =~ ~s(mob_dir: "#{host}/deps/mob")
    end
  end

  test "deploy_args targets a native build on a specific device" do
    assert Build.deploy_args("127.0.0.1:5700") == ["mob.deploy", "--native", "--device", "127.0.0.1:5700"]
  end

  test "classify_failure names the cause: conflict, signature gate, toolchain, else native tail" do
    assert {:conflict, [line]} = Build.classify_failure("ok\n  plugins a and b declare the same route /x\n")
    assert line =~ "declare the same"

    gate = """
    ** (Mix) plugin signature check failed — refusing to build
      - plugin :mob_biometric ships a legacy v1 signature, which mob_dev does not
        accept.
      - plugin :mob_bluetooth ships a legacy v1 signature, which mob_dev does not
    """

    assert {:error, {:signature_gate, ["- plugin :mob_biometric ships a legacy v1 signature, which mob_dev does not", "- plugin :mob_bluetooth" <> _]}} =
             Build.classify_failure(gate)

    assert {:error, {:toolchain, "✗ Android native build failed: zig version mismatch: found 0.16.0, but Mob requires 0.17.0"}} =
             Build.classify_failure("  Building Android APK...\n  ✗ Android native build failed: zig version mismatch: found 0.16.0, but Mob requires 0.17.0\n")

    assert {:error, {:native_build, "zig build for x86_64 exited 1\n"}} = Build.classify_failure("zig build for x86_64 exited 1\n")
  end

  test "a JVM crash anywhere in the output is a jvm_crash, even when the tail lost it (MOB-468)" do
    # the daemon dies first: its banner is near the top, then Gradle's failure
    # report and mob_dev's trailer push it far past the kept tail
    crash = """
      Running Gradle assembleDebug...
    #
    # A fatal error has been detected by the Java Runtime Environment:
    #
    #  SIGSEGV (0xb) at pc=0x00000000000020a6, pid=417109, tid=417136
    # Problematic frame:
    # C  [ld-linux-x86-64.so.2+0x10f2]
    # An error report file with more information is saved as:
    # /home/kevin/hosts/android/hs_err_pid417109.log
    """

    out = crash <> String.duplicate("FAILURE: Build failed with an exception. The daemon disappeared.\n", 40)

    assert {:error, {:jvm_crash, lines}} = Build.classify_failure(out)
    assert "# A fatal error has been detected by the Java Runtime Environment:" in lines
    assert "# C  [ld-linux-x86-64.so.2+0x10f2]" in lines
    assert "# /home/kevin/hosts/android/hs_err_pid417109.log" in lines
    refute Enum.any?(lines, &(&1 =~ "daemon disappeared"))

    # the release path keeps the shape, and both paths attribute it to the toolchain
    assert {:error, {:jvm_crash, ^lines} = reason} = Build.classify_release_failure(out)
    for path <- [:deploy, :release], do: assert(MobCi.Run.error_layer({:build_failed, path, reason}) == :toolchain)
  end

  test "parse_permissions reads aapt's uses-permission lines (P6 actual side)" do
    aapt = """
    package: name='com.example.app'
    uses-permission: name='android.permission.CAMERA'
    uses-permission: name='android.permission.BLUETOOTH_CONNECT'
    """

    assert Build.parse_permissions(aapt) ==
             MapSet.new(["android.permission.CAMERA", "android.permission.BLUETOOTH_CONNECT"])
  end

  test "parse_permissions is empty when none declared" do
    assert Build.parse_permissions("package: name='x'") == MapSet.new()
  end
end
