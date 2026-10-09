defmodule MobCi.SetsTest do
  use ExUnit.Case, async: true

  alias MobCi.{DeviceCaps, Sets, Versions}

  describe "the pool" do
    test "is the first-party plugins minus unbuildable (device_caps) minus the committed exclusions, in committed order" do
      pool = Sets.pool()
      excluded = Keyword.keys(Sets.exclusions())

      assert pool ==
               Enum.filter(
                 Versions.plugins(),
                 &(DeviceCaps.buildable?(&1) and &1 not in excluded)
               )

      assert :mob_camera in pool
      # mob_screencast's manifest <service> can't build on an unmodified host (F4).
      refute :mob_screencast in pool
    end

    test "every exclusion names a buildable first-party plugin and a FINDINGS entry" do
      for {plugin, reason} <- Sets.exclusions() do
        assert plugin in Versions.plugins()

        assert DeviceCaps.buildable?(plugin),
               "#{plugin} is unbuildable; device_caps already excludes it"

        assert reason =~ ~r/^F\d+: /
      end
    end

    test "include_excluded: true keeps the parked plugins in (what --static plans with)" do
      excluded = Keyword.keys(Sets.exclusions())
      assert excluded != []
      full = Sets.pool(include_excluded: true)
      assert full == DeviceCaps.buildable(Versions.plugins())
      for p <- excluded, do: assert(p in full)
      for p <- excluded, do: refute(p in Sets.pool())
    end
  end

  describe "pairwise/1" do
    test "covers every pair in all four activation combinations" do
      plugins = ~w(a b c d e f g h i j k l m)a
      rows = Sets.pairwise(plugins)
      assert Sets.uncovered_pairs(plugins, rows) == []
      assert Sets.covers_all_pairs?(plugins, rows)
      # rows draw from the input only, in input order, without repeats
      for row <- rows, do: assert(row == Enum.filter(plugins, &(&1 in row)))
    end

    test "is a pure function of the input (same plugins → identical rows)" do
      plugins = Sets.pool()
      assert Sets.pairwise(plugins) == Sets.pairwise(plugins)
      assert Sets.pairwise(Enum.reverse(plugins)) != Sets.pairwise(plugins)
    end

    test "is far smaller than the pair count (log-ish, not quadratic)" do
      plugins = Sets.pool()
      rows = Sets.pairwise(plugins)
      assert length(rows) <= 16
      assert length(rows) >= 6
    end

    test "fewer than two plugins have no pairs" do
      assert Sets.pairwise([]) == []
      assert Sets.pairwise([:only]) == []
      assert Sets.covers_all_pairs?([:a, :b], Sets.pairwise([:a, :b]))
    end

    test "uncovered_pairs names what an incomplete array misses" do
      rows = [[:a, :b], []]

      assert Sets.uncovered_pairs([:a, :b], rows) == [
               {:a, :b, true, false},
               {:a, :b, false, true}
             ]
    end
  end

  describe "the committed array (priv/sets/pairwise.exs)" do
    test "was generated for the current pool and matches the generator exactly" do
      committed = Sets.committed_pairwise()
      assert committed.plugins == Sets.pool(), "pool changed: run `mix ci.sets --regen`"

      assert committed.sets == Sets.pairwise(Sets.pool()),
             "array stale: run `mix ci.sets --regen`"
    end

    test "covers every pair of the pool" do
      assert Sets.uncovered_pairs(Sets.pool(), Sets.pairwise_rows()) == []
    end

    test "the file is byte-identical to what --regen writes" do
      assert File.read!(Sets.pairwise_path()) == Sets.pairwise_source(Sets.pool())
    end
  end

  describe "random/2" do
    test "replays the same set for the same seed, 3–8 plugins in pool order" do
      pool = Sets.pool()

      for seed <- [0, 1, 41_723, 999_999] do
        set = Sets.random(seed, pool)
        assert set == Sets.random(seed, pool)
        assert length(set) in 3..8
        assert set == Enum.filter(pool, &(&1 in set))
        assert set == Enum.uniq(set)
      end
    end

    test "different seeds give different sets" do
      pool = Sets.pool()
      sets = for seed <- 0..19, do: Sets.random(seed, pool)
      assert length(Enum.uniq(sets)) > 15
    end

    test "a pool smaller than the drawn size is returned whole" do
      assert Sets.random(7, [:a, :b]) |> Enum.sort() == [:a, :b]
    end
  end

  describe "parse/1" do
    test "the fixed names and nil → default" do
      assert Sets.parse(nil) == {:ok, :default}
      assert Sets.parse("blank") == {:ok, :blank}
      assert Sets.parse("default") == {:ok, :default}
      assert Sets.parse("all") == {:ok, :all}
      assert Sets.parse("demo") == {:ok, :demo}
    end

    test "singleton:<plugin> must name a first-party plugin" do
      assert Sets.parse("singleton:mob_camera") == {:ok, {:singleton, :mob_camera}}
      assert {:error, msg} = Sets.parse("singleton:mob_nope")
      assert msg =~ "unknown plugin \"mob_nope\""
    end

    test "pairwise:<i> must index the committed array" do
      rows = length(Sets.pairwise_rows())
      assert Sets.parse("pairwise:0") == {:ok, {:pairwise, 0}}
      assert Sets.parse("pairwise:#{rows - 1}") == {:ok, {:pairwise, rows - 1}}
      assert {:error, msg} = Sets.parse("pairwise:#{rows}")
      assert msg =~ "out of range"
      assert {:error, msg} = Sets.parse("pairwise:x")
      assert msg =~ "must be an integer"
    end

    test "random:<seed> must be a non-negative integer" do
      assert Sets.parse("random:41723") == {:ok, {:random, 41_723}}
      assert {:error, msg} = Sets.parse("random:-1")
      assert msg =~ "non-negative integer"
      assert {:error, _} = Sets.parse("random:abc")
    end

    test "anything else is an error listing the accepted forms; parse! raises Mix.Error" do
      assert {:error, msg} = Sets.parse("everything")
      assert msg =~ "unknown --set \"everything\""
      assert msg =~ "singleton:<plugin>"
      assert msg =~ "random:<seed>"
      assert_raise Mix.Error, ~r/unknown --set/, fn -> Sets.parse!("everything") end
      # path-ish names never reach the filesystem
      assert {:error, _} = Sets.parse("../pairwise")
    end

    test "name/1 round-trips every spec" do
      for s <- [
            "blank",
            "default",
            "all",
            "demo",
            "singleton:mob_camera",
            "pairwise:1",
            "random:5"
          ] do
        {:ok, spec} = Sets.parse(s)
        assert Sets.name(spec) == s
      end
    end
  end

  describe "resolve/2" do
    test "blank is empty, all is the pool, a singleton is itself, a pairwise row is the committed row" do
      assert Sets.resolve(:blank, []) == {:ok, []}
      assert Sets.resolve(:all, []) == {:ok, Sets.pool()}

      assert Sets.resolve(:all, include_excluded: true) ==
               {:ok, Sets.pool(include_excluded: true)}

      # an excluded plugin still has its singleton: alone it doesn't collide
      [{excluded, _} | _] = Sets.exclusions()
      assert Sets.resolve({:singleton, excluded}, []) == {:ok, [excluded]}
      assert Sets.parse("singleton:#{excluded}") == {:ok, {:singleton, excluded}}
      assert "singleton:#{excluded}" in Sets.nightly()
      for row <- Sets.pairwise_rows(), do: refute(excluded in row)
      assert Sets.resolve({:singleton, :mob_camera}, []) == {:ok, [:mob_camera]}
      assert Sets.resolve({:pairwise, 2}, []) == {:ok, Enum.at(Sets.pairwise_rows(), 2)}
      assert Sets.resolve({:random, 3}, []) == {:ok, Sets.random(3, Sets.pool())}
    end

    test "demo is the first-party, buildable part of mob_plugin_demo's list in its order" do
      demo = Sets.demo_plugins()
      assert length(demo) == 18
      assert :mob_demo_kit in demo
      {:ok, set} = Sets.resolve(:demo, [])
      assert set == Enum.filter(demo, &(&1 in Sets.pool()))
      refute :mob_demo_kit in set
      refute :mob_screencast in set
      assert :mob_camera in set
    end

    test "default needs the row's mob_new and reads its generator (fake mob_new project)" do
      assert Sets.resolve(:default, []) == {:error, :default_needs_mob_new_dir}

      dir =
        Path.join(System.tmp_dir!(), "mob_ci_fake_mob_new_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(dir) end)
      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(Path.join(dir, "mix.exs"), """
      defmodule FakeMobNew.MixProject do
        use Mix.Project
        def project, do: [app: :fake_mob_new, version: "0.0.1", deps: []]
      end
      """)

      File.write!(Path.join(dir, "lib/project_generator.ex"), """
      defmodule MobNew.ProjectGenerator do
        def assigns(_app, _opts), do: %{mob_plugins: [:mob_location, :mob_nope, :mob_camera]}
      end
      """)

      assert Sets.default_plugins(dir) == {:ok, [:mob_location, :mob_nope, :mob_camera]}
      # generator order kept, non-pool entries dropped
      assert Sets.resolve(:default, mob_new_dir: dir) == {:ok, [:mob_location, :mob_camera]}
    end

    test "default reports a generator that cannot be run" do
      assert {:error, {:default_plugins, "deps.get", 1, _}} =
               Sets.default_plugins(System.tmp_dir!())
    end
  end

  test "nightly/0 lists every set once, blank and default first, all after the singletons" do
    names = Sets.nightly()
    assert names == Enum.uniq(names)
    assert Enum.take(names, 2) == ["blank", "default"]
    singletons = Enum.filter(names, &String.starts_with?(&1, "singleton:"))
    assert length(singletons) == length(Sets.pool(include_excluded: true))

    assert Enum.find_index(names, &(&1 == "all")) >
             Enum.find_index(names, &(&1 == List.last(singletons)))

    # every pairwise row except the one identical to `all` (the greedy array's first)
    pool = Sets.pool()

    assert Enum.count(names, &String.starts_with?(&1, "pairwise:")) ==
             Enum.count(Sets.pairwise_rows(), &(&1 != pool))

    assert "pairwise:0" not in names and Enum.at(Sets.pairwise_rows(), 0) == pool

    assert "demo" in names
    for name <- names, do: assert({:ok, _} = Sets.parse(name))

    # priv/sets/exclusions.exs is config, not a regression set: it must not
    # cost the nightly a cell (it resolved to an empty set, a second `blank`).
    assert "exclusions" not in names
    assert {:error, _} = Sets.parse("exclusions")
  end
end
