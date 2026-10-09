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

  describe "deps_block/2" do
    test "core first, ecto, then the plugins; each line is the rendered tuple" do
      block =
        Host.deps_block(
          [{:mob, "== 0.9.14"}, {:mob_dev, "== 0.7.16", only: :dev, runtime: false}],
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
      generated = """
      defmodule CiX.MixProject do
        use Mix.Project

        def project, do: [app: :ci_x, version: "0.1.0", deps: deps()]

        defp deps do
          [
            {:mob,     "~> 0.9.8"},
            {:mob_dev, "~> 0.7.7", only: :dev, runtime: false},
            {:ecto_sqlite3, "~> 0.18"}
          ]
        end

        defp aliases, do: []
      end
      """

      resolved = %{row: :master, repos: @git_pins}

      block =
        Host.deps_block(
          Versions.core_deps(resolved),
          Versions.plugin_deps(resolved, [:mob_camera])
        )

      patched = Host.splice_deps(generated, block)

      refute patched =~ "~> 0.9.8"
      assert patched =~ ~s|{:mob, path: "/cache/src/mob/#{@sha}", override: true}|
      assert patched =~ ~s|{:mob_camera, path: "/cache/src/mob_camera/#{@sha}", override: true}|
      assert patched =~ "defp aliases, do: []"
      assert {:ok, _} = Code.string_to_quoted(patched)
    end
  end

  describe "mob_exs/3 and trust/2" do
    test "activates the set, trusts every plugin on the first-party key, acknowledges the unsigned" do
      body =
        Host.mob_exs(
          [:mob_camera, :mob_midi],
          %{mob_camera: Host.first_party_key(), mob_midi: Host.first_party_key()},
          [:mob_midi]
        )

      assert body =~ "config :mob, :plugins, [:mob_camera, :mob_midi]"

      assert body =~
               ~s|config :mob, :trusted_plugins, %{mob_camera: "#{Host.first_party_key()}", mob_midi: "#{Host.first_party_key()}"}|

      assert body =~ "config :mob, :acknowledge_unsafe_plugins, [:mob_midi]"
      assert body =~ ~s|mob_dir: Path.join(File.cwd!(), "deps/mob")|
      refute body =~ "mob.local.exs"
      assert {:ok, _} = Code.string_to_quoted(body)
    end

    test "the first-party key is the one mob_new's template pre-trusts" do
      assert Host.first_party_key() == "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
    end

    test "trust reads deps/<p>/priv/mob_plugin.sig: signed → trusted only, unsigned → also acknowledged" do
      deps =
        Path.join(System.tmp_dir!(), "mob_ci_host_deps_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(deps) end)
      File.mkdir_p!(Path.join(deps, "mob_signed/priv"))
      File.write!(Path.join(deps, "mob_signed/priv/mob_plugin.sig"), "sig")
      File.mkdir_p!(Path.join(deps, "mob_path/priv"))

      {trusted, unsigned} = Host.trust([:mob_signed, :mob_path, :mob_missing], deps)

      assert trusted == %{
               mob_signed: Host.first_party_key(),
               mob_path: Host.first_party_key(),
               mob_missing: Host.first_party_key()
             }

      assert unsigned == [:mob_path, :mob_missing]
    end
  end

  describe "the generator invocation" do
    test "is blank, Android-only, without deps.get, and --local only on master" do
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
    assert File.dir?(Path.join(host.dir, "_build/dev/lib/mob"))

    for p <- cell.plugins,
        do: assert(File.dir?(Path.join(host.dir, "_build/dev/lib/#{p}")), "#{p} did not compile")

    IO.puts("\n[integration] generated #{host.dir}\n" <> Cell.describe(cell))
    IO.puts("[integration] mob.exs:\n" <> mob_exs)
    IO.puts("[integration] deps: " <> (Regex.run(~r/defp deps do\n.*?\n  end/s, mix_exs) |> hd()))
    assert Sets.name(cell.spec) == "default"
  end
end
