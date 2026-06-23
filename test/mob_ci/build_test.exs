defmodule MobCi.BuildTest do
  use ExUnit.Case, async: true

  alias MobCi.{Build, Plugins}

  test "mob_exs activates only manifest-bearing plugins + the unsigned gate" do
    body = Build.mob_exs(Plugins.sample_set())
    assert body =~ "config :mob, :plugins,"
    assert body =~ "acknowledge_unsafe_plugins"
    assert body =~ ":mob_ci_haptic"
    assert body =~ ":mob_ci_notes"
    refute body =~ ":mob_ci_palette"
  end

  test "deps_block wires mob + ecto + a path dep per activated fixture" do
    block = Build.deps_block(Plugins.sample_set(), "/home/kevin/code/mob_ci/fixtures/_harness/mob_ci_harness")
    assert block =~ "defp deps do"
    assert block =~ "{:mob,     \"~> 0.7\"}"
    # self-test harness pins mob_dev to known-good 0.6.5 (F5/F6 — see Build)
    assert block =~ "{:mob_dev, \"== 0.6.5\", only: :dev, runtime: false}"
    assert block =~ "{:mob_ci_haptic, path:"
    # tier-0 palette is included as a dep (so it compiles) but isn't activated.
    assert block =~ "{:mob_ci_palette, path:"
  end

  test "local_properties references the discovered OTP cache + sdk" do
    props = Build.local_properties("/tmp/h")
    assert props =~ "sdk.dir=/home/kevin/Android/Sdk"
    assert props =~ "mob.otp_release_x86_64=/home/kevin/.mob/cache/otp-android-x86_64-"
    assert props =~ "mob.mob_dir=/tmp/h/deps/mob"
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

  test "sloppy_joe_plugins is the real activation set" do
    set = Build.sloppy_joe_plugins()
    assert :mob_camera in set and :mob_touch in set
    refute :mob_ci_haptic in set
  end

  test "sloppy_joe_mob_exs clears the signature gate for signed AND unsigned plugins" do
    body = Build.sloppy_joe_mob_exs([:mob_touch, :mob_notify])
    assert body =~ "config :mob, :plugins, [:mob_touch, :mob_notify]"
    # signed plugins (mob_touch) need a trust fingerprint...
    assert body =~ ":trusted_plugins"
    assert body =~ "mob_touch:"
    assert body =~ "ed25519:"
    # ...unsigned ones (mob_notify) need acknowledge_unsafe; list both for all.
    assert body =~ "acknowledge_unsafe_plugins, [:mob_touch, :mob_notify]"
  end

  test "sloppy_joe_mob_exs derives each signed plugin's REAL fingerprint (distinct keys, F3)" do
    # mob_touch + mob_bluetooth are signed with DIFFERENT keys; a single pinned
    # fingerprint would trip the gate's key-rotation check for whichever isn't on
    # it. Each must appear in trusted_plugins with its own real fingerprint, and
    # the two must differ.
    touch_fp = Build.plugin_fingerprint(:mob_touch)
    bt_fp = Build.plugin_fingerprint(:mob_bluetooth)
    assert touch_fp =~ "ed25519:"
    assert bt_fp =~ "ed25519:"
    assert touch_fp != bt_fp

    body = Build.sloppy_joe_mob_exs([:mob_touch, :mob_bluetooth, :mob_notify])
    assert body =~ "mob_touch: #{inspect(touch_fp)}"
    assert body =~ "mob_bluetooth: #{inspect(bt_fp)}"
    # unsigned mob_notify ships no pubkey → dropped from trusted, cleared via ack.
    refute body =~ "mob_notify: \"ed25519"
  end

  test "plugin_fingerprint returns nil for an unsigned plugin" do
    assert Build.plugin_fingerprint(:mob_notify) == nil
  end

  test "deploy_args targets a native build on a specific device" do
    assert Build.deploy_args("127.0.0.1:5700") == ["mob.deploy", "--native", "--device", "127.0.0.1:5700"]
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
