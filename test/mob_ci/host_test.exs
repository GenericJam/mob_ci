defmodule MobCi.HostTest do
  use ExUnit.Case, async: true

  alias MobCi.{Cell, Host, Sets, Versions}

  @hex_pins %{
    mob: %{version: "0.9.14", sha: nil, source: :hex, dir: nil},
    mob_dev: %{version: "0.7.16", sha: nil, source: :hex, dir: nil},
    mob_new: %{version: "0.6.7", sha: nil, source: :hex, dir: "/cache/hex/mob_new-0.6.7"},
    mob_camera: %{version: "0.1.12", sha: nil, source: :hex, dir: "/cache/hex/mob_camera-0.1.12"}
  }

  @sha String.duplicate("a", 40)
  @git_pins %{
    mob: %{version: "0.9.15", sha: @sha, source: {:git, "u"}, dir: "/cache/src/mob/#{@sha}"},
    mob_dev: %{
      version: "0.7.17",
      sha: @sha,
      source: {:git, "u"},
      dir: "/cache/src/mob_dev/#{@sha}"
    },
    mob_new: %{
      version: "0.6.8",
      sha: @sha,
      source: {:git, "u"},
      dir: "/cache/src/mob_new/#{@sha}"
    },
    mob_camera: %{
      version: "0.1.13",
      sha: @sha,
      source: {:git, "u"},
      dir: "/cache/src/mob_camera/#{@sha}"
    }
  }

  describe "app_name/2" do
    test "is deterministic, mob.new-valid, and distinct per set and row" do
      assert Host.app_name("default", :hex) == :ci_default_hex
      assert Host.app_name("singleton:mob_camera", :master) == :ci_singleton_mob_camera_master
      assert Host.app_name("pairwise:3", {:rc, :mob, "abc1234"}) == :ci_pairwise_3_rc_mob_abc1234
      assert Host.app_name("random:41723", :hex) == :ci_random_41723_hex

      for {set, row} <- [{"all", :hex}, {"all", :master}, {"blank", :hex}] do
        assert Host.app_name(set, row) |> to_string() =~ ~r/^[a-z][a-z0-9_]*$/
      end

      assert Host.app_name("all", :hex) != Host.app_name("all", :master)
    end
  end

  @generated """
  defmodule CiX.MixProject do
    use Mix.Project

    def project, do: [app: :ci_x, version: "0.1.0", deps: deps()]

    defp deps do
      [
        {:mob,     "~> 0.9.8"},
        {:mob_dev, "~> 0.7.7", only: :dev, runtime: false},
        {:ecto_sqlite3, "~> 0.18"},
        # Code quality
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
      ]
    end

    defp aliases, do: []
  end
  """

  describe "deps_block/3 and generated_extras/1" do
    test "extras are the generated deps the row doesn't pin (ecto, credo, …), never mob/mob_dev/plugins" do
      assert Host.generated_extras(@generated) == [
               ~s|{:ecto_sqlite3, "~> 0.18"}|,
               ~s|{:credo, "~> 1.7", only: [:dev, :test], runtime: false}|,
               ~s|{:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}|
             ]

      with_plugin =
        String.replace(
          @generated,
          ~s|{:ecto_sqlite3, "~> 0.18"},|,
          ~s|{:ecto_sqlite3, "~> 0.18"},\n      {:mob_camera, "~> 0.1"},|
        )

      refute Enum.any?(Host.generated_extras(with_plugin), &(&1 =~ "mob_camera"))
      assert Host.generated_extras("defmodule X do\nend\n") == []
    end

    test "core first, then the extras, then the plugins; each line is the rendered tuple" do
      block =
        Host.deps_block(
          [{:mob, "== 0.9.14"}, {:mob_dev, "== 0.7.16", only: :dev, runtime: false}],
          [~s|{:ecto_sqlite3, "~> 0.18"}|],
          [{:mob_camera, "== 0.1.12"}]
        )

      assert block ==
               Enum.join(
                 [
                   "  defp deps do",
                   "    [",
                   ~s|      {:mob, "== 0.9.14"},|,
                   ~s|      {:mob_dev, "== 0.7.16", only: :dev, runtime: false},|,
                   ~s|      {:ecto_sqlite3, "~> 0.18"},|,
                   ~s|      {:mob_camera, "== 0.1.12"}|,
                   "    ]",
                   "  end"
                 ],
                 "\n"
               )
    end

    test "splice_deps replaces only the generated deps block and the result is valid Elixir" do
      resolved = %{row: :master, repos: @git_pins}

      block =
        Host.deps_block(
          Versions.core_deps(resolved),
          Host.generated_extras(@generated),
          Versions.plugin_deps(resolved, [:mob_camera])
        )

      assert {:ok, patched} = Host.splice_deps(@generated, block)

      refute patched =~ "~> 0.9.8"
      assert patched =~ ~s|{:mob, path: "/cache/src/mob/#{@sha}", override: true}|
      assert patched =~ ~s|{:mob_camera, path: "/cache/src/mob_camera/#{@sha}", override: true}|
      assert patched =~ ~s|{:ecto_sqlite3, "~> 0.18"}|
      assert patched =~ ~s|{:credo, "~> 1.7"|
      assert patched =~ "defp aliases, do: []"
      assert {:ok, _} = Code.string_to_quoted(patched)
    end

    test "a template without a recognisable deps block is a mob_new-layer error, not a silent fallback" do
      assert Host.splice_deps(
               "defmodule X do\n  defp deps, do: []\nend\n",
               "  defp deps do\n    []\n  end"
             ) ==
               {:error, {:mob_new, :deps_block_not_found}}
    end
  end

  describe "mob_exs/4, mob_dir/2 and trust/2" do
    test "activates the set, trusts every plugin on the first-party key, acknowledges the checkouts" do
      body =
        Host.mob_exs(
          "/h/deps/mob",
          [:mob_camera, :mob_midi],
          %{mob_camera: Host.first_party_key(), mob_midi: Host.first_party_key()},
          [:mob_midi]
        )

      assert body =~ "config :mob, :plugins, [:mob_camera, :mob_midi]"

      assert body =~
               ~s|config :mob, :trusted_plugins, %{mob_camera: "#{Host.first_party_key()}", mob_midi: "#{Host.first_party_key()}"}|

      assert body =~ "config :mob, :acknowledge_unsafe_plugins, [:mob_midi]"
      assert body =~ ~s|mob_dir: "/h/deps/mob"|
      refute body =~ "mob.local.exs"
      assert {:ok, _} = Code.string_to_quoted(body)
    end

    test "extra :mob_dev entries (the iOS lane's bundle id and team) land in the config block" do
      body =
        Host.mob_exs("/h/deps/mob", [], %{}, [],
          ios_bundle_id: "com.genericjam.mobci",
          ios_team_id: "Q89CW299G8"
        )

      # Evaluated as a config file, the entries are :mob_dev config, not stray text.
      path = Path.join(System.tmp_dir!(), "mob_exs_#{System.unique_integer([:positive])}.exs")
      File.write!(path, body)

      try do
        cfg = Config.Reader.read!(path)
        assert cfg[:mob_dev][:ios_bundle_id] == "com.genericjam.mobci"
        assert cfg[:mob_dev][:ios_team_id] == "Q89CW299G8"
        assert cfg[:mob_dev][:mob_dir] == "/h/deps/mob"
      after
        File.rm(path)
      end
    end

    test "mob_dir is deps/mob for a Hex mob and the pinned checkout for a git mob (path deps never land under deps/)" do
      assert Host.mob_dir("/h", %{row: :hex, repos: @hex_pins}) == "/h/deps/mob"
      assert Host.mob_dir("/h", %{row: :master, repos: @git_pins}) == "/cache/src/mob/#{@sha}"
      # rc on another repo: mob is still Hex
      assert Host.mob_dir("/h", %{
               row: {:rc, :mob_camera, "abc"},
               repos: %{@hex_pins | mob_camera: @git_pins.mob_camera}
             }) == "/h/deps/mob"
    end

    test "the first-party key is the one mob_new's template pre-trusts" do
      assert Host.first_party_key() == "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
    end

    test "trust acknowledges exactly the plugins the row supplies as git checkouts; a Hex release never" do
      mixed =
        %{@hex_pins | mob_camera: @git_pins.mob_camera}
        |> Map.put(:mob_midi, @hex_pins.mob_camera)

      {trusted, acknowledged} =
        Host.trust([:mob_camera, :mob_midi], %{row: {:rc, :mob_camera, "a"}, repos: mixed})

      assert trusted == %{mob_camera: Host.first_party_key(), mob_midi: Host.first_party_key()}
      assert acknowledged == [:mob_camera]

      assert {_, []} = Host.trust([:mob_camera], %{row: :hex, repos: @hex_pins})
      assert {_, [:mob_camera]} = Host.trust([:mob_camera], %{row: :master, repos: @git_pins})
    end

    test "generator_id is the mob_new pin, so a new mob_new release or sha regenerates a reused host" do
      assert Host.generator_id(%{row: :hex, repos: @hex_pins}) == "0.6.7 hex"
      assert Host.generator_id(%{row: :master, repos: @git_pins}) == "0.6.8 #{@sha}"

      assert Host.generator_id(%{row: :hex, repos: @hex_pins}) !=
               Host.generator_id(%{row: :hex, repos: put_in(@hex_pins.mob_new.version, "0.6.8")})
    end
  end

  describe "the generator invocation" do
    test "is blank, one platform (Android by default), without deps.get, and --local only on master" do
      assert Host.mob_new_args(:ci_all_hex, :hex) == [
               "mob.new",
               "ci_all_hex",
               "--blank",
               "--android",
               "--no-install",
               "--dest",
               Host.hosts_root()
             ]

      assert List.last(Host.mob_new_args(:ci_all_master, :master)) == "--local"
      refute "--local" in Host.mob_new_args(:ci_all_rc_mob_abc, {:rc, :mob, "abc1234"})
    end

    test "the iOS lane generates iOS-only under its own scratch root" do
      args = Host.mob_new_args(:ci_default_hex, :hex, :ios, "/tmp/cell")
      assert "--ios" in args
      refute "--android" in args
      assert ["--dest", "/tmp/cell"] == Enum.drop(args, 5)
    end

    test "env runs mob_new in prod and, on master, points --local at the checkouts" do
      assert Host.mob_new_env(%{row: :hex, repos: @hex_pins}) == [{"MIX_ENV", "prod"}]

      assert Host.mob_new_env(%{row: {:rc, :mob, "abc1234"}, repos: @git_pins}) == [
               {"MIX_ENV", "prod"}
             ]

      assert Host.mob_new_env(%{row: :master, repos: @git_pins}) == [
               {"MIX_ENV", "prod"},
               {"MOB_DIR", "/cache/src/mob/#{@sha}"},
               {"MOB_DEV_DIR", "/cache/src/mob_dev/#{@sha}"},
               {"MOB_NEW_DIR", "/cache/src/mob_new/#{@sha}"}
             ]
    end
  end

  # Really generates: the hex row's mob_new (downloaded + unpacked), the
  # `default` set read from it, exact Hex pins, deps.get and compile.
  # ~minutes on a cold cache; `mix test --include integration`.
  @tag :integration
  @tag timeout: 1_800_000
  test "a generated host for `default` on the `hex` row compiles" do
    assert {:ok, cell} = Cell.plan("default", "hex")
    assert cell.set == "default"
    assert cell.plugins != []
    assert cell.resolved.repos.mob.source == :hex

    assert {:ok, host} = Host.generate(cell.spec, cell.plugins, cell.resolved, fresh: true)
    assert host.app == :ci_default_hex
    assert host.set == "default"
    assert host.versions == Versions.record(cell.resolved)

    mix_exs = File.read!(Path.join(host.dir, "mix.exs"))
    assert mix_exs =~ ~s|{:mob, "== #{cell.resolved.repos.mob.version}"}|

    for p <- cell.plugins,
        do: assert(mix_exs =~ ~s|{:#{p}, "== #{cell.resolved.repos[p].version}"}|)

    mob_exs = File.read!(Path.join(host.dir, "mob.exs"))
    assert mob_exs =~ "config :mob, :plugins, #{inspect(cell.plugins)}"
    assert mob_exs =~ ~s|mob_dir: "#{Path.join(host.dir, "deps/mob")}"|
    assert mob_exs =~ "config :mob, :acknowledge_unsafe_plugins, []"

    # the deploy prep the harness does: local.properties with the real mob_dir, icons, reuse marker
    props = File.read!(Path.join(host.dir, "android/local.properties"))
    assert props =~ "mob.mob_dir=#{Path.join(host.dir, "deps/mob")}"
    refute props =~ "/path/to/"

    assert Path.wildcard(
             Path.join(host.dir, "android/app/src/main/res/mipmap-*/ic_launcher*.png")
           ) != []

    assert File.read!(Path.join(host.dir, ".mob_ci_generator")) ==
             Host.generator_id(cell.resolved)

    # the row's mob_new extras survive the deps rewrite
    assert mix_exs =~ "{:ecto_sqlite3,"
    assert File.dir?(Path.join(host.dir, "_build/dev/lib/mob"))

    for p <- cell.plugins,
        do: assert(File.dir?(Path.join(host.dir, "_build/dev/lib/#{p}")), "#{p} did not compile")

    IO.puts("\n[integration] generated #{host.dir}\n" <> Cell.describe(cell))
    IO.puts("[integration] mob.exs:\n" <> mob_exs)
    IO.puts("[integration] deps: " <> (Regex.run(~r/defp deps do\n.*?\n  end/s, mix_exs) |> hd()))
    assert Sets.name(cell.spec) == "default"
  end
end
