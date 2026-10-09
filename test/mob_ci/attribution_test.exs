defmodule MobCi.AttributionTest do
  @moduledoc """
  Every non-passing outcome names the layer it belongs to
  (`static | build:<path> | boot | farm | plugin:<p> | conflict:<set> | health`). A
  result that can't say which layer failed is a bug in mob_ci, so these pin the
  attribution of each invariant and of the orchestration error paths, with no
  device: a dead node stands in for every RPC failure.
  """
  use ExUnit.Case, async: true

  alias MobCi.{Context, Invariants, Plugins, Report, Result, Run}

  @dead :"nonexistent_mob_ci@127.0.0.1"
  @build %{status: :ok, apk: nil, permissions: nil, conflicts: []}

  defp ctx(fields) do
    struct!(Context, Keyword.merge([set: Plugins.sample_set(), host: :harness, host_dir: "/h", build: @build], fields))
  end

  describe "Result.at/attribute/rollup" do
    test "at tags fail/error only; pass and skip carry no layer" do
      assert Result.at(Result.fail(:x, "t", "d"), :boot).layer == :boot
      assert Result.at(Result.error(:x, "t", "d"), {:plugin, :p}).layer == {:plugin, :p}
      assert Result.at(Result.pass(:x, "t"), :boot).layer == nil
      assert Result.at(Result.skip(:x, "t", "d"), :boot).layer == nil
    end

    test "attribute: one layer stays; several plugins become a conflict; mixed keeps the first" do
      assert Result.attribute([]) == nil
      assert Result.attribute([Result.at(Result.fail(:i, "", ""), {:plugin, :a})]) == {:plugin, :a}

      two = [Result.at(Result.fail(:i, "", ""), {:plugin, :a}), Result.at(Result.fail(:i, "", ""), {:plugin, :b})]
      assert Result.attribute(two) == {:conflict, [:a, :b]}

      mixed = [Result.at(Result.error(:i, "", ""), :boot), Result.at(Result.fail(:i, "", ""), {:plugin, :a})]
      assert Result.attribute(mixed) == :boot
    end

    test "rollup attributes the worst items, not the passing ones" do
      items = [
        Result.pass(:i, "ok"),
        Result.at(Result.fail(:i, "bad", "x"), {:plugin, :mob_a}),
        Result.at(Result.error(:i, "meh", "y"), :boot)
      ]

      rolled = Result.rollup(items, :p3, "nifs")
      assert rolled.status == :fail
      assert rolled.layer == {:plugin, :mob_a}

      only_errors = Result.rollup(tl(tl(items)), :p3, "nifs")
      assert only_errors.status == :error and only_errors.layer == :boot
      assert Result.rollup([hd(items)], :p3, "nifs").layer == nil
    end
  end

  describe "P1 splits static from build" do
    test "a clean set that fails to build is the build layer of the host dir" do
      r = Invariants.p1(ctx(build: %{@build | status: {:error, :linker}}))
      assert {:fail, {:build, "/h"}} = {r.status, r.layer}
    end

    test "a conflict the build found but cross_validate missed is static" do
      r = Invariants.p1(ctx(build: %{@build | status: {:conflict, ["x declare the same"]}}))
      assert {:fail, :static} = {r.status, r.layer}
    end

    test "a conflicting set that built anyway is static" do
      r = Invariants.p1(ctx(set: [:mob_ci_clash_a, :mob_ci_clash_b]))
      assert {:fail, :static} = {r.status, r.layer}
    end

    test "no build status is a build-layer error" do
      r = Invariants.p1(ctx(build: %{@build | status: :unknown}))
      assert {:error, {:build, "/h"}} = {r.status, r.layer}
    end
  end

  describe "P6 blames the plugins whose permissions are missing" do
    test "one plugin's permission missing → plugin:<p>" do
      r = Invariants.p6(ctx(build: %{@build | permissions: MapSet.new(["android.permission.INTERNET"])}))
      assert {:fail, {:plugin, :mob_ci_haptic}} = {r.status, r.layer}
    end

    test "permissions expected but none read → build layer" do
      r = Invariants.p6(ctx(build: %{@build | permissions: nil}))
      assert {:error, {:build, "/h"}} = {r.status, r.layer}
    end
  end

  describe "device invariants without a node are boot-layer errors" do
    test "P2/P3/P4/P5/P7/P8/P9/P10 all say :boot" do
      c =
        ctx(
          node: nil,
          showcase_screen: MobCiHarness.CiShowcase,
          repo: MobCiHarness.Repo,
          migration_tables: Context.default_migration_tables(),
          worker_names: Context.default_worker_names()
        )

      for p <- [:p2, :p3, :p4, :p5, :p7, :p8, :p9, :p10] do
        r = apply(Invariants, p, [c])
        assert r.status == :error, "#{p} should error with no node"
        assert r.layer == :boot, "#{p} should be attributed to :boot, got #{inspect(r.layer)}"
      end
    end
  end

  describe "device invariants against a dead node" do
    test "P2 fails at boot; P3 items are boot errors (not plugin failures) when the node is gone" do
      c = ctx(node: @dead)
      assert %{status: :fail, layer: :boot} = Invariants.p2(c)
      assert %{status: :error, layer: :boot} = Invariants.p3(c)
    end

    test "P4 against a dead node is a boot error, never blamed on the screen's plugin" do
      assert %{status: :error, layer: :boot} = Invariants.p4(ctx(node: @dead))
    end

    test "P4 attributes per-screen outcomes to the declaring plugin (owner projection)" do
      owners = Plugins.screen_owners(Plugins.sample_set())
      assert owners[MobCiNotes.ListScreen] == :mob_ci_notes
      assert Enum.uniq(Map.values(owners)) == [:mob_ci_notes]
      assert Result.attribute([Result.at(Result.fail(:i, "", ""), {:plugin, :mob_ci_notes})]) == {:plugin, :mob_ci_notes}
    end

    test "P5 and P7 against a dead node are boot errors" do
      assert %{status: :error, layer: :boot} = Invariants.p5(ctx(node: @dead, showcase_screen: MobCiHarness.CiShowcase))
      assert %{status: :error, layer: :boot} = Invariants.p7(ctx(node: @dead))
    end

    test "P5 without a showcase on the harness is a build error; a real component plugin alone is a skip" do
      assert %{status: :error, layer: {:build, "/h"}} = Invariants.p5(ctx(node: @dead, showcase_screen: nil))
      # mob_scene3d contributes :scene3d but has no `widget/1` convention → honest skip
      r = Invariants.p5(ctx(set: [:mob_scene3d], host: :sloppy_joe, node: @dead, showcase_screen: nil))
      assert {:skip, nil} = {r.status, r.layer}
      assert r.detail =~ "mob_scene3d"
    end

    test "P8/P9 against a dead node are boot errors (plugin attribution needs a live node)" do
      c = ctx(node: @dead, repo: MobCiHarness.Repo, migration_tables: Context.default_migration_tables(), worker_names: Context.default_worker_names())
      # dead node → boot, not the tier-3/tier-4 plugin
      assert %{status: :error, layer: :boot} = Invariants.p8(c)
      assert %{status: :error, layer: :boot} = Invariants.p9(c)
    end

    test "P10/P11 are app health" do
      assert %{status: :fail, layer: :health} = Invariants.p10(ctx(node: @dead, set: [:mob_ci_palette]))
      # P11 passes against a dead node (torn down) — nothing to attribute
      assert %{status: :pass, layer: nil} = Invariants.p11(ctx(node: @dead))
    end
  end

  describe "Run.error_layer" do
    test "host preparation failures are the host's build layer; build paths are build:<path>" do
      assert Run.error_layer({:prepare_failed, "/sj", {:sloppy_joe_prep, 1, "boom"}}) == {:build, "/sj"}
      assert Run.error_layer({:build_failed, :deploy, {:native_build, "zig"}}) == {:build, "deploy:android"}
      assert Run.error_layer({:build_failed, :release, {:release_build, "gradle"}}) == {:build, "release:android"}
    end

    test "farm admission, boot and launch failures are the boot layer" do
      assert Run.error_layer(:box_busy) == :boot
      assert Run.error_layer({:boot_failed, {:boot_failed, 1, "docker"}}) == :boot
      assert Run.error_layer({:launch_failed, {:node_never_registered, :x}}) == :boot
    end

    test "an unknown reason is unattributed (nil), never a guess" do
      assert Run.error_layer(:something_else) == nil
    end

    test "a build, install or launch that lost its device is the farm, not the code" do
      # mob_ci run 38 (2026-10-09): adbd restarted under `adb root`, the OTP push
      # found no device; gradle and zig had succeeded.
      lost =
        "warning: parameter 'pid' is never used\nBUILD SUCCESSFUL in 1m 56s\n  Installing APK on 127.0.0.1:5700...\n" <>
          "  Pushing OTP release to device(s)...\n  ✗ Android native build failed: Selected Android device(s) disconnected: 127.0.0.1:5700"

      assert Run.error_layer({:build_failed, :deploy, {:native_build, lost}}) == :farm
      assert Run.error_layer({:install_failed, :release, "adb: device offline"}) == :farm
      assert Run.error_layer({:launch_failed, {:launch_failed, {:launch, 1, "error: device '127.0.0.1:5701' not found"}}}) == :farm
      assert Run.error_layer({:instance_lost, "container ci-redroid0: false", {:launch_failed, :timeout}}) == :farm

      # a genuine build or launch failure stays where it was
      assert Run.error_layer({:build_failed, :deploy, {:native_build, "zig: error: undefined symbol"}}) == {:build, "deploy:android"}
      assert Run.error_layer({:launch_failed, {:node_never_registered, :x}}) == :boot
    end

    test "a probe that lost its instance re-attributes its failures (not its passes) to the farm" do
      results = [
        Result.pass(:p2, "boots"),
        Result.fail(:p12, "self-tests", "node … is not reachable") |> Result.at({:plugin, :mob_x}),
        Result.error(:p10, "sweep", "nodedown") |> Result.at(:health),
        Result.skip(:p5, "showcase", "none")
      ]

      {:fail, marked} = Run.mark_lost({:fail, results}, "adb 127.0.0.1:5700: offline")
      assert Enum.map(marked, & &1.layer) == [nil, :farm, :farm, nil]
      assert Enum.at(marked, 1).detail =~ "instance lost: adb 127.0.0.1:5700: offline"
      assert Run.mark_lost({:error, {:launch_failed, :timeout}}, "gone") == {:error, {:instance_lost, "gone", {:launch_failed, :timeout}}}
    end

    test "farm_lost/1 names the paths that lost their instance (what makes ci.device exit 3)" do
      lost = "Selected Android device(s) disconnected: 127.0.0.1:5700"

      runs = [
        %{path: "deploy:android", outcome: {:error, {:build_failed, :deploy, {:native_build, lost}}}},
        %{path: "release:android", outcome: {:ok, [Result.pass(:p2, "boots")]}}
      ]

      assert Run.farm_lost(runs) == ["deploy:android"]
      probe_lost = [%{path: "deploy:android", outcome: {:fail, [Result.fail(:p2, "b", "x") |> Result.at(:farm)]}}]
      assert Run.farm_lost(probe_lost) == ["deploy:android"]
      assert Run.farm_lost([%{path: "deploy:android", outcome: {:error, {:build_failed, :deploy, {:native_build, "zig"}}}}]) == []
    end
  end

  describe "Report renders the layer" do
    test "format_layer is the canonical one-token form" do
      assert Report.format_layer(:static) == "static"
      assert Report.format_layer({:build, "/h"}) == "build:/h"
      assert Report.format_layer({:plugin, :mob_x}) == "plugin:mob_x"
      assert Report.format_layer({:conflict, [:a, :b]}) == "conflict:a,b"
      assert Report.format_layer(:health) == "health"
      assert Report.format_layer(:farm) == "farm"
    end

    test "console shows @ <layer> on failing lines only" do
      out =
        Report.console([
          Result.pass(:p1, "ok"),
          Result.at(Result.fail(:p3, "nif", "x"), {:plugin, :mob_x})
        ])

      assert out =~ "p3  nif  @ plugin:mob_x"
      refute out =~ "p1  ok  @"
    end
  end
end
