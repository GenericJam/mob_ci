defmodule MobCi.ReportTest do
  use ExUnit.Case, async: true

  alias MobCi.{Report, Result}

  @results [
    Result.pass(:p1, "build outcome"),
    Result.fail(:p3, "nif load", "mob_x_nif not linked", %{nif: :mob_x_nif}),
    Result.skip(:p8, "migrations", "no migration plugin"),
    Result.error(:p2, "boot", "no node leased")
  ]

  test "tally counts by status" do
    assert Report.tally(@results) == %{pass: 1, fail: 1, error: 1, skip: 1}
  end

  test "ok? is false when any fail or error" do
    refute Report.ok?(@results)
    assert Report.ok?([Result.pass(:p1, "x"), Result.skip(:p8, "y", "n/a")])
  end

  test "junit xml reflects statuses and escapes content" do
    xml = Report.junit(@results)
    assert xml =~ ~s(failures="1")
    assert xml =~ ~s(errors="1")
    assert xml =~ ~s(skipped="1")
    assert xml =~ "<failure message=\"mob_x_nif not linked\""
    assert xml =~ "<skipped"
    assert xml =~ "<error message=\"no node leased\""
  end

  test "console summary renders glyphs and a footer" do
    out = Report.console(@results, title: "demo")
    assert out =~ "demo"
    assert out =~ "1 passed, 1 failed, 1 errored, 1 skipped"
  end

  test "write_artifacts emits junit + summary with the failing set" do
    dir = Path.join(System.tmp_dir!(), "mob_ci_report_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = Report.write_artifacts(dir, [:mob_ci_haptic, :mob_ci_notes], @results)
    assert File.exists?(Path.join(dir, "junit.xml"))
    summary = File.read!(Path.join(dir, "summary.json"))
    assert summary =~ "mob_ci_haptic"
    assert summary =~ "p3"
  end
end
