defmodule MobCi.SweepTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MobCi.Sweep

  describe "minimize — greedy delta-debug (pure, synthetic oracle)" do
    test "shrinks any superset of a failing pair down to exactly that pair" do
      # Oracle: 'fails' iff both clash plugins are present.
      oracle = fn s -> :mob_ci_clash_a in s and :mob_ci_clash_b in s end
      big = [:mob_ci_palette, :mob_ci_clash_a, :mob_ci_haptic, :mob_ci_clash_b, :mob_ci_notes]

      assert oracle.(big)
      assert Enum.sort(Sweep.minimize(big, oracle)) == [:mob_ci_clash_a, :mob_ci_clash_b]
    end

    test "a single-element cause shrinks to the singleton" do
      oracle = fn s -> :mob_ci_pulse in s end
      assert Sweep.minimize([:mob_ci_haptic, :mob_ci_pulse, :mob_ci_notes], oracle) == [:mob_ci_pulse]
    end

    test "an irreducible set is returned unchanged" do
      oracle = fn s -> length(s) >= 2 end
      assert length(Sweep.minimize([:a, :b], oracle)) == 2
    end
  end

  describe "static sweep — cross_validate soundness over the subset space" do
    property "cross_validate flags a conflict iff the subset actually collides" do
      check all subset <- Sweep.subset_gen(Sweep.static_pool()), max_runs: 300 do
        assert Sweep.rejected?(subset) == Sweep.colliding?(subset),
               "cross_validate disagreed with the independent collision oracle for #{inspect(subset)}"
      end
    end

    test "static_findings reports no inconsistencies over the fixture pool" do
      assert Sweep.static_findings(count: 300) == []
    end

    test "the clash pair is the minimal conflicting subset" do
      assert Sweep.rejected?([:mob_ci_clash_a, :mob_ci_clash_b])
      refute Sweep.rejected?([:mob_ci_clash_a])
      refute Sweep.rejected?([:mob_ci_clash_b, :mob_ci_haptic, :mob_ci_notes])
    end
  end

  describe "device_sweep — orchestration with an injected oracle (no farm)" do
    test "runs each subset and shrinks failures to the minimal core" do
      # Inject a fake run_subset: a subset 'fails' iff it contains both clash ids.
      run = fn subset ->
        if :mob_ci_clash_a in subset and :mob_ci_clash_b in subset,
          do: {:fail, []},
          else: {:pass, []}
      end

      subsets = [
        [:mob_ci_haptic],
        [:mob_ci_clash_a, :mob_ci_clash_b, :mob_ci_notes],
        [:mob_ci_gauge, :mob_ci_pulse]
      ]

      %{ran: ran, minimal_failures: minimal} = Sweep.device_sweep(subsets: subsets, run_subset: run)

      assert length(ran) == 3
      assert minimal == [[:mob_ci_clash_a, :mob_ci_clash_b]]
    end
  end
end
