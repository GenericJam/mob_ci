defmodule MobCi.SweepCellTest do
  use ExUnit.Case, async: true

  alias MobCi.Sweep

  describe "static_conflicts/1" do
    test "shrinks every rejected subset of a real pool to its minimal core (the fixture clash pair)" do
      assert Sweep.static_conflicts(pool: Sweep.static_pool(), count: 150) == [
               [:mob_ci_clash_a, :mob_ci_clash_b]
             ]
    end

    test "a pool with no conflicts has no cores (the full pool is always sampled)" do
      assert Sweep.static_conflicts(pool: Sweep.device_pool(), count: 50) == []
    end
  end

  describe "device_sweep/1 with a cell" do
    test "sweeps the cell's plugins (not the fixture pool), always including the whole set" do
      cell = %{
        spec: :demo,
        set: "demo",
        plugins: [:mob_x, :mob_y, :mob_z],
        resolved: %{row: :hex, repos: %{}}
      }

      me = self()

      summary =
        Sweep.device_sweep(
          cell: cell,
          runs: 3,
          run_subset: fn subset ->
            send(me, {:ran, subset})
            {:pass, []}
          end
        )

      subsets = for {subset, _} <- summary.ran, do: subset
      assert [:mob_x, :mob_y, :mob_z] in subsets
      for s <- subsets, do: assert(s -- [:mob_x, :mob_y, :mob_z] == [])
      assert summary.minimal_failures == []
    end
  end
end
