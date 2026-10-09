defmodule MobCi.ReleaseCellTest do
  @moduledoc """
  The release cell (`mix mob.release --android` → universal APK on redroid):
  path labels, how a failed build path is attributed (naming mob_dev's
  failing plugin when it named one), the signing inputs, the cookie
  provisioning script, and how a run's paths roll up into the exit verdict.
  """
  use ExUnit.Case, async: true

  alias MobCi.{Build, Farm, Report, Result, Run}
  alias Mix.Tasks.Ci.{Device, Sweep}

  describe "path labels" do
    test "the dev APK is deploy:android, the release bundle release:android" do
      assert Build.path_label(:deploy) == "deploy:android"
      assert Build.path_label(:release) == "release:android"
    end

    test "results are stamped with their path, and JUnit names carry it" do
      [r] = Result.stamp([Result.fail(:p2, "boots", "down")], "default", %{row: "hex"}, "release:android")
      assert %{set: "default", path: "release:android"} = r
      assert Report.junit([r]) =~ ~s(name="[release:android] p2 — boots")
    end

    test "--paths parses deploy,release and rejects anything else" do
      assert Device.parse_paths(nil, [:deploy, :release]) == [:deploy, :release]
      assert Device.parse_paths("release", [:deploy]) == [:release]
      assert Device.parse_paths("deploy, release,deploy", []) == [:deploy, :release]
      assert_raise Mix.Error, ~r/unknown path "ios"/, fn -> Device.parse_paths("ios", []) end
    end
  end

  describe "build failure attribution" do
    @gate """
    ** (Mix) plugin signature check failed — refusing to build
      - plugin :mob_biometric ships a legacy v1 signature, which mob_dev does not
    """

    test "a path that failed to build is build:<path>, with mob_dev's named plugin when there is one" do
      {:error, gate} = Build.classify_failure(@gate)
      assert Build.path_failure_layer(:release, gate) == {:build, "release:android", :mob_biometric}
      assert Report.format_layer(Build.path_failure_layer(:release, gate)) == "build:release:android/mob_biometric"

      named = {:native_build, "error: plugin :mob_camera: android.factory Foo must be fully qualified"}
      assert Build.path_failure_layer(:deploy, named) == {:build, "deploy:android", :mob_camera}

      # A compiler error inside a plugin's sources names it by path; mob_dev/mob_new are tooling, not plugins.
      zig = {:release_build, "deps/mob_dev/lib/x.ex ok\n/h/deps/mob_whisper/android/jni/w.zig:12: error: expected ';'"}
      assert Build.path_failure_layer(:release, zig) == {:build, "release:android", :mob_whisper}

      assert Build.path_failure_layer(:deploy, {:toolchain, "zig version mismatch"}) == {:build, "deploy:android"}
      assert Build.path_failure_layer(:release, {:release_build, "Gradle bundleRelease failed (exit 1)"}) ==
               {:build, "release:android"}
    end

    test "Run.error_layer routes each build path, and a refused release APK, to its path" do
      assert Run.error_layer({:build_failed, :release, {:signature_gate, ["- plugin :mob_nfc is not signed"]}}) ==
               {:build, "release:android", :mob_nfc}

      assert Run.error_layer({:install_failed, :release, {:install, 1, "INSTALL_FAILED_NO_MATCHING_ABIS"}}) ==
               {:build, "release:android"}
    end

    test "a release build's unknown failure is the release build's tail, not the native build's" do
      assert {:error, {:release_build, "Gradle bundleRelease failed (exit 1)\n"}} =
               Build.classify_release_failure("Gradle bundleRelease failed (exit 1)\n")

      assert {:conflict, _} = Build.classify_release_failure("plugins a and b declare the same route /x\n")
      assert {:error, {:signature_gate, _}} = Build.classify_release_failure(@gate)
    end

    test "a sweep subset that never reached the catalog is stored with its layer" do
      assert {:error, _, :boot} = Sweep.stored_outcome({:error, {:node_never_registered, :n}})
      assert {:error, _, {:build, "deploy:android"}} = Sweep.stored_outcome({:error, {:native_build, "gradle"}})
      assert {:ok, []} = Sweep.stored_outcome({:pass, []})
      assert {:fail, [_]} = Sweep.stored_outcome({:error, [Result.error(:p2, "", "")]})
      # the row's validator project couldn't be built: Elixir, as ci.device records it
      assert {:error, _, :elixir} = Sweep.stored_outcome({:error, {:row_validator, "mob_dev 0.7.19 (hex): mix deps exited 1"}})
    end
  end

  describe "signing and installing the release" do
    test "the CI upload key has the shape the generated build.gradle reads" do
      props = Build.keystore_properties()
      assert props =~ "storeFile=upload_jks.keystore\n"
      assert props =~ "keyAlias=upload\n"
      assert props =~ ~r/^storePassword=\S+$/m
      assert props =~ ~r/^keyPassword=\S+$/m

      args = Build.keytool_args("/h/android/upload_jks.keystore")
      assert ["-genkeypair", "-keystore", "/h/android/upload_jks.keystore", "-storetype", "JKS", "-alias", "upload" | _] = args
    end

    test "bundletool builds one universal APK signed with the host's key" do
      signing = %{ks: "/h/android/upload_jks.keystore", alias: "upload", store_pass: "sp", key_pass: "kp"}
      args = Build.bundletool_args("/bt.jar", "/a.aab", "/o.apks", signing)
      assert ["-jar", "/bt.jar", "build-apks" | _] = args
      assert "--mode=universal" in args
      assert "--bundle=/a.aab" in args
      assert "--output=/o.apks" in args
      assert "--ks=/h/android/upload_jks.keystore" in args
      assert "--ks-key-alias=upload" in args
      assert "--ks-pass=pass:sp" in args
      assert "--key-pass=pass:kp" in args
    end

    @tag :tmp_dir
    test "a host's own keystore.properties is read, never rewritten", %{tmp_dir: dir} do
      android = Path.join(dir, "android")
      File.mkdir_p!(android)
      props = Path.join(android, "keystore.properties")
      real = "# the app's real upload key\nstoreFile=keys/real.jks\nstorePassword=s3cret\nkeyAlias=release\nkeyPassword=k3y\n"
      File.write!(props, real)

      assert {:ok, %{ks: ks, alias: "release", store_pass: "s3cret", key_pass: "k3y"}} = Build.release_signing(dir)
      assert ks == Path.join(android, "keys/real.jks")
      assert File.read!(props) == real
      refute File.exists?(Path.join(android, "upload_jks.keystore"))
    end

    @tag :tmp_dir
    test "an upload keystore without its properties is left alone, not overwritten", %{tmp_dir: dir} do
      android = Path.join(dir, "android")
      File.mkdir_p!(android)
      File.write!(Path.join(android, "upload_jks.keystore"), "binary")

      assert {:error, {:keystore_properties, _}} = Build.release_signing(dir)
      refute File.exists?(Path.join(android, "keystore.properties"))
      assert File.read!(Path.join(android, "upload_jks.keystore")) == "binary"
    end

    test "keystore.properties missing a key is an error, not a guess" do
      assert {:error, {:keystore_properties, _}} = Build.parse_keystore_properties("storeFile=a.jks\nkeyAlias=x\n", "/h/android")
      assert {:ok, %{ks: "/h/android/upload_jks.keystore"}} = Build.parse_keystore_properties(Build.keystore_properties(), "/h/android")
    end

    test "the shared sloppy_joe checkout refuses the release path; mob_ci's own hosts take it" do
      assert_raise Mix.Error, ~r/not on the shared sloppy_joe checkout/, fn -> Device.host_paths!(:sloppy_joe, [:deploy, :release]) end
      assert Device.host_paths!(:sloppy_joe, [:deploy]) == [:deploy]
      assert Device.host_paths!(:harness, [:deploy, :release]) == [:deploy, :release]
    end

    test "the cookie script writes Mob.Dist's file with the app's owner and label, and refuses shell metacharacters" do
      script = Farm.write_cookie_script("com.example.ci_default_hex", :ci_default_hex, String.duplicate("ab", 32))
      file = "/data/data/com.example.ci_default_hex/files/otp/ci_default_hex/mob_dist_cookie"

      assert script =~ "printf %s #{String.duplicate("ab", 32)} > #{file}"
      assert script =~ "chown $(stat -c %u:%g /data/data/com.example.ci_default_hex)"
      assert script =~ "chmod 600 #{file}"
      assert script =~ "chcon $(stat -c %C /data/data/com.example.ci_default_hex/files)"

      assert_raise ArgumentError, fn -> Farm.write_cookie_script("p", :a, "x; rm -rf /") end
    end

    test "device scripts run as root through su (adb shell is uid shell), never with an embedded quote" do
      assert Farm.as_root("test -f /data/data/p/files/otp/.installed_version && echo present") ==
               "su 0 sh -c 'test -f /data/data/p/files/otp/.installed_version && echo present'"

      assert_raise ArgumentError, fn -> Farm.as_root("echo 'x'") end
    end
  end

  describe "a run's verdict over its paths" do
    defp path(outcome), do: %{path: "p", outcome: outcome, duration_ms: 0, log_path: nil}

    test "any orchestration error wins, then any failure, else ok" do
      ok = path({:ok, [Result.pass(:p2, "")]})
      fail = path({:fail, [Result.fail(:p12, "", "")]})
      err = path({:error, :box_busy})

      assert Run.verdict([ok, ok]) == :ok
      assert Run.verdict([ok, fail]) == :fail
      assert Run.verdict([fail, err]) == :error
      assert Run.verdict([]) == :ok
    end

    test "an errored path still shows in the artifacts, as an error at its layer, so junit can't read green" do
      ok = %{path: "deploy:android", outcome: {:ok, [Result.pass(:p2, "boots")]}, duration_ms: 0, log_path: nil}
      err = %{path: "release:android", outcome: {:error, {:build_failed, :release, {:release_build, "gradle"}}}, duration_ms: 0, log_path: nil}

      results = Run.artifact_results([ok, err], set_name: "default", versions: nil)

      assert [%{id: :p2, status: :pass}, %{id: :path, status: :error, path: "release:android", set: "default"} = e] = results
      assert e.layer == {:build, "release:android"}
      refute Report.ok?(results)
      assert Report.junit(results) =~ ~s(errors="1")
    end

    test "a harness/sloppy_joe set is stored under <host>:<plugins>; a cell under its set name" do
      assert Run.set_name([:mob_ci_haptic, :mob_ci_notes], :harness, []) == "harness:mob_ci_haptic,mob_ci_notes"
      assert Run.set_name([:mob_location], :generated, set_name: "singleton:mob_location") == "singleton:mob_location"
    end
  end
end
