defmodule MobCi.ReportTest do
  use ExUnit.Case, async: true

  alias MobCi.{Report, Result}

  @results [
    Result.pass(:p1, "build outcome"),
    Result.fail(:p3, "nif load", "mob_x_nif not linked", %{nif: :mob_x_nif}),
    Result.skip(:p8, "migrations", "no migration plugin"),
    Result.error(:p2, "boot", "no node leased")
  ]

  test "rollup is results-first so it pipes, and worst status wins" do
    items = [Result.pass(:i, "a"), Result.fail(:i, "b", "boom")]
    rolled = items |> Result.rollup(:p3, "nif load")
    assert rolled.id == :p3
    assert rolled.status == :fail
    assert Result.rollup([], :p8, "migrations").status == :skip
    assert ([Result.pass(:i, "a")] |> Result.rollup(:p4, "screens")).status == :pass
  end

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

  describe "grid/1 (mix ci.report)" do
    defp cell(row, set, path, outcome, layer \\ nil, at \\ "2026-10-08T22:00:00Z"),
      do: %{versions_row: row, set: set, path: path, outcome: outcome, layer: layer, started_at: at}

    test "one block per versions row (hex first), one line per set, one column per path" do
      grid =
        Report.grid([
          cell("master", "default", "deploy:android", :pass),
          cell("hex", "singleton:mob_location", "deploy:android", :pass),
          cell("hex", "default", "release:android", :fail, "build:release:android/mob_x", "2026-10-08T23:00:00Z"),
          cell("hex", "default", "deploy:android", :pass),
          cell("hex", "default", "deploy:ios_sim", :skip),
          cell("hex", "default", "static", :error, "static")
        ])

      [hex, master] = String.split(grid, "\n\n")
      lines = String.split(hex, "\n")

      assert hd(lines) =~ "versions: hex (latest run 2026-10-08T23:00:00Z)"
      # android paths first (static, deploy, release), then the other platforms.
      assert Enum.at(lines, 1) =~ ~r/^  set\s+static\s+deploy:android\s+release:android\s+deploy:ios_sim$/
      # named sets before singletons; every cell shows glyph, outcome and layer.
      assert Enum.at(lines, 2) =~
               ~r/^  default\s+! error @ static\s+✓ pass\s+✗ fail @ build:release:android\/mob_x\s+– skip$/

      # a cell that never ran is a dot, not a pass.
      assert Enum.at(lines, 3) =~ ~r/^  singleton:mob_location\s+·\s+✓ pass\s+·\s+·$/
      assert hex =~ "2 passed, 1 failed, 1 errored, 1 skipped"

      assert master =~ "versions: master"
      assert master =~ ~r/default\s+✓ pass/
    end

    test "an empty store says so" do
      assert Report.grid([]) == "no results in the store yet"
    end
  end
end
