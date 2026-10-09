defmodule MobCi.P12Test do
  @moduledoc """
  P12 — every active plugin's self-test passes (or skips honestly) — with
  `MobDev.Plugin.SelfTest.run_all/3` stubbed: how each entry maps to a result,
  and how a failure is attributed against the plugin's singleton cell in a
  seeded store.
  """
  use ExUnit.Case, async: true

  alias MobCi.{Context, Invariants, Result, Run, Store}

  @node :"fake_android_ci0@127.0.0.1"

  defp entry(plugin, result, module \\ Fake.SelfTest, ms \\ 12),
    do: %{plugin: plugin, module: module, result: result, ms: ms}

  defp ctx(set, entries, fields \\ []) do
    parent = self()

    run_all = fn node, device, opts ->
      send(parent, {:run_all, node, device, opts})
      entries
    end

    struct!(Context, [set: set, host: :generated, node: @node, selftest_run_all: run_all] ++ fields)
  end

  defp items(result), do: Map.new(result.evidence.items, &{&1.title, &1})

  describe "entry mapping" do
    test "pass, skip (atom and text), no selftest, failure and timeout each map to their status" do
      set = [:mob_a, :mob_b, :mob_c, :mob_d, :mob_e, :mob_f]

      entries = [
        entry(:mob_a, :pass),
        entry(:mob_b, {:skip, :needs_hardware}),
        entry(:mob_c, {:skip, "no camera on a headless emulator"}),
        entry(:mob_d, {:skip, "no selftest in manifest"}, nil, 0),
        entry(:mob_e, {:fail, "GPS fix returned nil"}),
        entry(:mob_f, {:fail, "timed out after 30000 ms"}, Fake.SelfTest, 30_001)
      ]

      r = Invariants.p12(ctx(set, entries))
      i = items(r)

      assert %{status: :pass, layer: nil} = i["mob_a"]
      assert %{status: :skip, detail: "needs_hardware", layer: nil} = i["mob_b"]
      assert %{status: :skip, detail: "no camera on a headless emulator"} = i["mob_c"]
      assert %{status: :skip, detail: "no_selftest"} = i["mob_d"]
      assert %{status: :fail, detail: "mob_e: GPS fix returned nil"} = i["mob_e"]
      assert %{status: :fail, detail: "mob_f: timed out after 30000 ms"} = i["mob_f"]
      assert i["mob_f"].evidence == %{ms: 30_001, module: Fake.SelfTest}

      # Rolled up: any failure fails P12; skips never do.
      assert %Result{id: :p12, status: :fail} = r
      assert r.detail =~ "mob_e: GPS fix returned nil"
      assert r.detail =~ "mob_f: timed out"
    end

    test "skips and passes only: P12 passes; skips only (e.g. no plugin has a selftest): P12 skips" do
      assert %{status: :pass} =
               Invariants.p12(ctx([:mob_a, :mob_b], [entry(:mob_a, :pass), entry(:mob_b, {:skip, :needs_user})]))

      skipped =
        Invariants.p12(
          ctx([:mob_a, :mob_b], [
            entry(:mob_a, {:skip, "no selftest in manifest"}, nil, 0),
            entry(:mob_b, {:skip, "no selftest in manifest"}, nil, 0)
          ])
        )

      assert %{status: :skip, layer: nil} = skipped
      assert Enum.all?(skipped.evidence.items, &(&1.detail == "no_selftest"))
    end

    test "a self-test the device never received is the boot layer's error, not the plugin's failure" do
      r = Invariants.p12(ctx([:mob_a], [entry(:mob_a, {:fail, "node #{@node} is not reachable"})]))
      assert %{status: :error, layer: :boot} = r
      assert %{status: :error, layer: :boot} = items(r)["mob_a"]

      r = Invariants.p12(ctx([:mob_a], [entry(:mob_a, {:fail, "could not spawn on #{@node}: :noconnection"})]))
      assert %{status: :error, layer: :boot} = r
    end

    test "a runner that raises is an error, and no node at all is the boot layer's" do
      crash = fn _, _, _ -> raise "boom" end
      assert %{status: :error, layer: :boot, detail: "self-test runner crashed: ** (RuntimeError) boom"} =
               Invariants.p12(%Context{set: [:mob_a], host: :generated, node: @node, selftest_run_all: crash})

      assert %{status: :error, layer: :boot} = Invariants.p12(%Context{set: [:mob_a], host: :generated, node: nil})
    end

    test "run_all gets the node, the device ctx, the set's plugins and the per-test timeout" do
      Invariants.p12(ctx([:mob_a, :mob_b], [], selftest_timeout_ms: 5_000))

      assert_received {:run_all, @node, %{platform: :android, device: :emulator}, opts}
      assert opts[:timeout_ms] == 5_000
      assert Enum.map(opts[:plugins], &elem(&1, 0)) == [:mob_a, :mob_b]
    end
  end

  describe "p12_layer/3" do
    test "the singleton cell itself is always the plugin's" do
      assert Invariants.p12_layer(:mob_a, [:mob_a], nil) == {:plugin, :mob_a}
      assert Invariants.p12_layer(:mob_a, [:mob_a], :pass) == {:plugin, :mob_a}
    end

    test "fails alone too → plugin; passes alone → conflict of the set; unknown → unconfirmed plugin" do
      set = [:mob_a, :mob_b]
      assert Invariants.p12_layer(:mob_a, set, :fail) == {:plugin, :mob_a}
      assert Invariants.p12_layer(:mob_a, set, :pass) == {:conflict, set}

      for unknown <- [nil, :skip, :error],
          do: assert(Invariants.p12_layer(:mob_a, set, unknown) == {:plugin_unconfirmed, :mob_a})
    end
  end

  describe "attribution against a seeded store" do
    setup do
      path = Path.join(System.tmp_dir!(), "mob_ci_p12_#{System.unique_integer([:positive])}.sqlite")
      {:ok, store} = Store.open(path)

      on_exit(fn ->
        Store.close(store)
        for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f)
      end)

      %{store: store}
    end

    defp seed_singleton(store, plugin, outcome, row \\ "hex", path \\ "deploy:android") do
      {:ok, run} = Store.record_run(store, %{trigger: "test", versions_row: row, host: "t", mob_ci_sha: nil})

      item = %{Result.at(%Result{id: :p12_item, title: "#{plugin}", status: outcome}, {:plugin, plugin}) | evidence: %{ms: 3}}
      p12 = %{Result.rollup([item], :p12, "self-tests") | evidence: %{items: [item]}}
      verdict = if outcome == :pass, do: :ok, else: :fail

      Store.record_results(
        store,
        run,
        %{set: "singleton:#{plugin}", platform: :android, path: path, versions: nil, duration_ms: 1, log_path: nil},
        {verdict, [p12]}
      )
    end

    test "fails alone → plugin:<p>; passes alone → conflict:<set>; never ran → plugin:<p>?", %{store: store} do
      seed_singleton(store, :mob_a, :fail)
      seed_singleton(store, :mob_b, :pass)
      # Same plugin, other row and other path: must not be consulted.
      seed_singleton(store, :mob_c, :pass, "master")
      seed_singleton(store, :mob_c, :pass, "hex", "release:android")

      set = [:mob_a, :mob_b, :mob_c]
      fails = for p <- set, do: entry(p, {:fail, "broken"})
      lookup = Run.singleton_lookup(:deploy, store: store, versions_row: "hex")

      i = items(Invariants.p12(ctx(set, fails, singleton_selftest: lookup)))

      assert i["mob_a"].layer == {:plugin, :mob_a}
      assert i["mob_b"].layer == {:conflict, set}
      assert i["mob_c"].layer == {:plugin_unconfirmed, :mob_c}
      assert MobCi.Report.format_layer(i["mob_c"].layer) == "plugin:mob_c?"
    end

    test "the newest singleton result wins", %{store: store} do
      seed_singleton(store, :mob_a, :fail)
      seed_singleton(store, :mob_a, :pass)

      lookup = Run.singleton_lookup(:deploy, store: store, versions_row: "hex")
      assert lookup.(:mob_a) == :pass
      assert Store.singleton_selftest(store, :mob_a, versions_row: "hex", path: "deploy:android") == :pass
    end

    test "with no store nothing is known" do
      assert Run.singleton_lookup(:deploy, []).(:mob_a) == nil
    end
  end
end
