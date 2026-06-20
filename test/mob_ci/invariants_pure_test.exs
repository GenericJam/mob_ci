defmodule MobCi.InvariantsPureTest do
  @moduledoc """
  The build-/manifest-only invariants (P1, P6) run with no device. These are the
  ones that catch a `cross_validate`↔build gap and a permission over/under-merge
  — exactly the regressions a static check should own before a farm slot is even
  leased.
  """
  use ExUnit.Case, async: true

  alias MobCi.{Context, Invariants, Plugins}
  alias MobDev.Plugin.Validator

  describe "P1 — build outcome matches static conflict analysis" do
    test "clean set + successful build → pass" do
      ctx = %Context{set: Plugins.sample_set(), host: :harness, build: %{status: :ok, apk: nil, permissions: nil, conflicts: []}}
      assert %{status: :pass} = Invariants.p1(ctx)
    end

    test "clean set that fails to build → fail (a build regression, not a conflict)" do
      ctx = %Context{set: Plugins.sample_set(), host: :harness, build: %{status: {:error, :linker_boom}, apk: nil, permissions: nil, conflicts: []}}
      assert %{status: :fail} = Invariants.p1(ctx)
    end

    test "conflicting set rejected with the conflicts named → pass" do
      set = [:mob_ci_clash_a, :mob_ci_clash_b]
      conflicts = Validator.cross_validate(Plugins.activated(set)).errors
      ctx = %Context{set: set, host: :harness, build: %{status: {:conflict, conflicts}, apk: nil, permissions: nil, conflicts: conflicts}}
      assert %{status: :pass} = Invariants.p1(ctx)
    end

    test "conflicting set that built anyway → fail (cross_validate/build gap)" do
      set = [:mob_ci_clash_a, :mob_ci_clash_b]
      ctx = %Context{set: set, host: :harness, build: %{status: :ok, apk: nil, permissions: nil, conflicts: []}}
      assert %{status: :fail, detail: detail} = Invariants.p1(ctx)
      assert detail =~ "built anyway"
    end

    test "conflicting set rejected WITHOUT naming the conflicts → fail" do
      set = [:mob_ci_clash_a, :mob_ci_clash_b]
      ctx = %Context{set: set, host: :harness, build: %{status: {:conflict, ["generic build error, no values"]}, apk: nil, permissions: nil, conflicts: []}}
      assert %{status: :fail} = Invariants.p1(ctx)
    end
  end

  describe "P6 — every activated-plugin permission reaches the APK (subset)" do
    test "the sample set's haptic VIBRATE is the one expected permission" do
      assert Plugins.expected_permissions(Plugins.sample_set()) ==
               MapSet.new(["android.permission.VIBRATE"])
    end

    test "plugin permission present (alongside app baseline perms) → pass" do
      set = Plugins.sample_set()
      # APK carries VIBRATE (the plugin's) + INTERNET (app baseline). Subset holds.
      actual = MapSet.new(["android.permission.VIBRATE", "android.permission.INTERNET"])
      ctx = %Context{set: set, host: :harness, build: %{status: :ok, apk: "x.apk", permissions: actual, conflicts: []}}
      assert %{status: :pass} = Invariants.p6(ctx)
    end

    test "a plugin permission missing from the APK → fail with the missing list" do
      set = Plugins.sample_set()
      actual = MapSet.new(["android.permission.INTERNET"])
      ctx = %Context{set: set, host: :harness, build: %{status: :ok, apk: "x.apk", permissions: actual, conflicts: []}}
      assert %{status: :fail, evidence: %{missing: ["android.permission.VIBRATE"]}} = Invariants.p6(ctx)
    end

    test "no expected perms + no perms read → skip" do
      ctx = %Context{set: [:mob_ci_palette], host: :harness, build: %{status: :ok, apk: nil, permissions: nil, conflicts: []}}
      assert %{status: :skip} = Invariants.p6(ctx)
    end
  end
end
