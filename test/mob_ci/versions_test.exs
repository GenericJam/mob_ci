defmodule MobCi.VersionsTest do
  use ExUnit.Case, async: true

  alias MobCi.Versions

  # A remote that never touches the network: Hex versions and git shas are
  # looked up in maps, "checkouts" are tmp dirs with a mix.exs declaring a
  # version, so `version_in/1` has something to read.
  defp stub_remote(tmp, opts \\ []) do
    hex =
      Keyword.get(opts, :hex, %{
        mob: "0.9.14",
        mob_dev: "0.7.16",
        mob_new: "0.6.7",
        mob_camera: "0.1.12",
        mob_midi: "0.1.2"
      })

    heads =
      Keyword.get(opts, :heads, %{
        "https://github.com/GenericJam/mob" => String.duplicate("a", 40)
      })

    %{
      hex_latest: fn name ->
        case Map.fetch(hex, name) do
          {:ok, v} -> {:ok, v}
          :error -> {:error, {:not_on_hex, name}}
        end
      end,
      git_head: fn url ->
        case Map.fetch(heads, url) do
          {:ok, sha} -> {:ok, sha}
          :error -> {:error, {:no_remote, url}}
        end
      end,
      checkout: fn name, _url, sha, cache ->
        full = String.pad_trailing(sha, 40, "f")
        dir = Path.join([cache, "src", to_string(name), full])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "mix.exs"), ~s|  @version "9.9.9-#{name}"\n|)
        {:ok, %{dir: dir, sha: full}}
      end,
      hex_unpack: fn name, version, cache ->
        dir = Path.join([cache, "hex", "#{name}-#{version}"])
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "mix.exs"), ~s|      version: "#{version}",\n|)
        {:ok, dir}
      end
    }
    |> then(&{&1, tmp})
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "mob_ci_versions_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {remote, _} = stub_remote(tmp)
    %{tmp: tmp, remote: remote}
  end

  describe "parse/1" do
    test "the three rows, nil defaulting to hex" do
      assert Versions.parse(nil) == {:ok, :hex}
      assert Versions.parse("hex") == {:ok, :hex}
      assert Versions.parse("master") == {:ok, :master}
      assert Versions.parse("rc:mob@0123abc") == {:ok, {:rc, :mob, "0123abc"}}

      assert Versions.parse("rc:mob_camera@" <> String.duplicate("0", 40)) ==
               {:ok, {:rc, :mob_camera, String.duplicate("0", 40)}}
    end

    test "rejects unknown rows, unknown repos and malformed shas with a message" do
      assert {:error, msg} = Versions.parse("latest")
      assert msg =~ "unknown --versions \"latest\""
      assert msg =~ "rc:<repo>@<sha>"

      assert {:error, msg} = Versions.parse("rc:phoenix@0123abc")
      assert msg =~ "unknown repo \"phoenix\""

      assert {:error, msg} = Versions.parse("rc:mob@v1.2")
      assert msg =~ "7–40 hex digits"

      assert {:error, msg} = Versions.parse("rc:mob")
      assert msg =~ "<repo>@<sha>"

      assert_raise Mix.Error, ~r/unknown --versions/, fn -> Versions.parse!("nope") end
    end

    test "row_to_string round-trips" do
      for s <- ["hex", "master", "rc:mob_dev@abcdef0"] do
        {:ok, row} = Versions.parse(s)
        assert Versions.row_to_string(row) == s
      end
    end
  end

  describe "the repo list" do
    test "priv/plugins.exs lists first-party plugins with GenericJam GitHub repos, no duplicates" do
      plugins = Versions.plugins()
      assert length(plugins) >= 20
      assert plugins == Enum.uniq(plugins)

      for {name, url} <- Versions.plugin_repos(),
          do: assert(url == "https://github.com/GenericJam/#{name}")

      refute :mob in plugins
      refute :mob_new in plugins
    end

    test "repos/0 puts the core first and every plugin after" do
      names = Enum.map(Versions.repos(), &elem(&1, 0))
      assert Enum.take(names, 3) == [:mob, :mob_dev, :mob_new]
      assert Enum.drop(names, 3) == Versions.plugins()
    end
  end

  describe "resolve/2 (network stubbed)" do
    test "hex pins every repo to the latest Hex version exactly; only mob_new and plugins get a source dir",
         %{remote: remote, tmp: tmp} do
      assert {:ok, r} =
               Versions.resolve(:hex,
                 remote: remote,
                 cache_dir: tmp,
                 names: [:mob, :mob_dev, :mob_camera]
               )

      assert r.row == :hex
      assert r.repos.mob == %{version: "0.9.14", sha: nil, source: :hex, dir: nil}
      assert r.repos.mob_dev == %{version: "0.7.16", sha: nil, source: :hex, dir: nil}
      assert %{version: "0.6.7", source: :hex, dir: dir} = r.repos.mob_new
      assert dir == Path.join([tmp, "hex", "mob_new-0.6.7"])
      assert r.repos.mob_camera.dir == Path.join([tmp, "hex", "mob_camera-0.1.12"])
      assert Versions.mob_new_dir(r) == dir
    end

    test "master pins every repo to its remote HEAD sha with a checkout", %{tmp: tmp} do
      sha_mob = String.duplicate("1", 40)
      sha_new = String.duplicate("2", 40)

      {remote, _} =
        stub_remote(tmp,
          heads: %{
            "https://github.com/GenericJam/mob" => sha_mob,
            "https://github.com/GenericJam/mob_new" => sha_new
          }
        )

      assert {:ok, r} = Versions.resolve(:master, remote: remote, cache_dir: tmp, names: [:mob])
      assert r.repos.mob.sha == sha_mob
      assert r.repos.mob.source == {:git, "https://github.com/GenericJam/mob"}
      assert r.repos.mob.dir == Path.join([tmp, "src", "mob", sha_mob])
      # the version comes from the checkout's mix.exs
      assert r.repos.mob.version == "9.9.9-mob"
      assert r.repos.mob_new.sha == sha_new
    end

    test "rc pins exactly one repo to the given sha (expanded to 40) and the rest to Hex", %{
      remote: remote,
      tmp: tmp
    } do
      assert {:ok, r} =
               Versions.resolve({:rc, :mob_camera, "abc1234"},
                 remote: remote,
                 cache_dir: tmp,
                 names: [:mob, :mob_camera, :mob_midi]
               )

      assert r.repos.mob.source == :hex

      assert r.repos.mob_midi == %{
               version: "0.1.2",
               sha: nil,
               source: :hex,
               dir: Path.join([tmp, "hex", "mob_midi-0.1.2"])
             }

      assert r.repos.mob_new.source == :hex

      assert %{source: {:git, _}, sha: "abc1234" <> _, version: "9.9.9-mob_camera"} =
               r.repos.mob_camera

      assert String.length(r.repos.mob_camera.sha) == 40
    end

    test "a repo the remote cannot answer for fails resolution, naming the repo", %{
      remote: remote,
      tmp: tmp
    } do
      assert {:error, {:mob_whisper, {:not_on_hex, :mob_whisper}}} =
               Versions.resolve(:hex, remote: remote, cache_dir: tmp, names: [:mob, :mob_whisper])

      {remote_with_new, _} =
        stub_remote(tmp,
          heads: %{"https://github.com/GenericJam/mob_new" => String.duplicate("3", 40)}
        )

      assert {:error, {:mob_dev, {:no_remote, _}}} =
               Versions.resolve(:master,
                 remote: remote_with_new,
                 cache_dir: tmp,
                 names: [:mob_dev]
               )
    end

    test "mob_new is resolved even when not asked for, unless mob_new: false", %{
      remote: remote,
      tmp: tmp
    } do
      assert {:ok, r} = Versions.resolve(:hex, remote: remote, cache_dir: tmp, names: [:mob])
      assert Map.keys(r.repos) |> Enum.sort() == [:mob, :mob_new]

      assert {:ok, r} =
               Versions.resolve(:hex,
                 remote: remote,
                 cache_dir: tmp,
                 names: [:mob],
                 mob_new: false
               )

      assert Map.keys(r.repos) == [:mob]
    end
  end

  describe "deps" do
    test "hex pins become exact `==` requirements, mob_dev dev-only", %{remote: remote, tmp: tmp} do
      {:ok, r} =
        Versions.resolve(:hex,
          remote: remote,
          cache_dir: tmp,
          names: [:mob, :mob_dev, :mob_camera]
        )

      assert Versions.core_deps(r) == [
               {:mob, "== 0.9.14"},
               {:mob_dev, "== 0.7.16", only: :dev, runtime: false}
             ]

      assert Versions.plugin_deps(r, [:mob_camera]) == [{:mob_camera, "== 0.1.12"}]
    end

    test "git pins become path deps with override, mob_dev dev-only", %{tmp: tmp} do
      {remote, _} =
        stub_remote(tmp,
          heads: %{
            "https://github.com/GenericJam/mob" => String.duplicate("1", 40),
            "https://github.com/GenericJam/mob_dev" => String.duplicate("2", 40),
            "https://github.com/GenericJam/mob_new" => String.duplicate("3", 40),
            "https://github.com/GenericJam/mob_camera" => String.duplicate("4", 40)
          }
        )

      {:ok, r} =
        Versions.resolve(:master,
          remote: remote,
          cache_dir: tmp,
          names: [:mob, :mob_dev, :mob_camera]
        )

      assert [
               {:mob, path: mob_dir, override: true},
               {:mob_dev, path: dev_dir, only: :dev, runtime: false, override: true}
             ] =
               Versions.core_deps(r)

      assert mob_dir == r.repos.mob.dir
      assert dev_dir == r.repos.mob_dev.dir
      assert [{:mob_camera, path: _, override: true}] = Versions.plugin_deps(r, [:mob_camera])
    end

    test "plugin_deps refuses a plugin the row did not resolve", %{remote: remote, tmp: tmp} do
      {:ok, r} = Versions.resolve(:hex, remote: remote, cache_dir: tmp, names: [:mob])
      assert_raise ArgumentError, ~r/mob_camera/, fn -> Versions.plugin_deps(r, [:mob_camera]) end
    end

    test "render_dep writes valid mix.exs source for each tuple shape" do
      assert Versions.render_dep({:mob, "== 0.9.14"}) == ~s|{:mob, "== 0.9.14"}|

      assert Versions.render_dep({:mob_dev, "== 0.7.16", only: :dev, runtime: false}) ==
               ~s|{:mob_dev, "== 0.7.16", only: :dev, runtime: false}|

      assert Versions.render_dep({:mob, path: "/x/mob", override: true}) ==
               ~s|{:mob, path: "/x/mob", override: true}|

      for dep <- [
            {:mob, "== 0.9.14"},
            {:mob_dev, "== 0.7.16", only: :dev, runtime: false},
            {:mob, path: "/x/mob", override: true}
          ] do
        {parsed, _} = Code.eval_string(Versions.render_dep(dep))
        assert parsed == dep
      end
    end
  end

  describe "record/1 and summary/1" do
    test "the record is plain data with the row and each pin's version, sha, source and dir", %{
      remote: remote,
      tmp: tmp
    } do
      {:ok, r} =
        Versions.resolve({:rc, :mob, "abc1234"},
          remote: remote,
          cache_dir: tmp,
          names: [:mob, :mob_camera]
        )

      rec = Versions.record(r)

      assert rec.row == "rc:mob@abc1234"

      assert rec.repos.mob_camera == %{
               version: "0.1.12",
               sha: nil,
               source: "hex",
               dir: Path.join([tmp, "hex", "mob_camera-0.1.12"])
             }

      assert rec.repos.mob.source == "git:https://github.com/GenericJam/mob@" <> r.repos.mob.sha
      assert rec.repos.mob.version == "9.9.9-mob"
      # serialisable: survives a term round-trip and inspect/eval
      assert rec == :erlang.binary_to_term(:erlang.term_to_binary(rec))
      {back, _} = Code.eval_string(inspect(rec, limit: :infinity))
      assert back == rec
    end

    test "summary lists the core first, then plugins, with hex versions and short shas", %{
      remote: remote,
      tmp: tmp
    } do
      {:ok, r} =
        Versions.resolve({:rc, :mob, "abc1234"},
          remote: remote,
          cache_dir: tmp,
          names: [:mob_camera, :mob]
        )

      lines = r |> Versions.summary() |> String.split("\n")
      assert hd(lines) == "versions: rc:mob@abc1234"
      assert Enum.at(lines, 1) =~ ~r/^  mob\s+9\.9\.9-mob \(git abc1234fffff\)$/
      assert Enum.at(lines, 2) =~ ~r/^  mob_new\s+0\.6\.7 \(hex\)$/
      assert Enum.at(lines, 3) =~ ~r/^  mob_camera\s+0\.1\.12 \(hex\)$/
    end
  end

  test "version_in/1 reads @version and version: forms, nil otherwise", %{tmp: tmp} do
    a = Path.join(tmp, "a")
    File.mkdir_p!(a)
    File.write!(Path.join(a, "mix.exs"), ~s|defmodule X do\n  @version "1.2.3"\nend\n|)
    assert Versions.version_in(a) == "1.2.3"

    b = Path.join(tmp, "b")
    File.mkdir_p!(b)
    File.write!(Path.join(b, "mix.exs"), ~s|  version: "4.5.6",\n|)
    assert Versions.version_in(b) == "4.5.6"

    assert Versions.version_in(Path.join(tmp, "missing")) == nil
    assert Versions.version_in(nil) == nil
  end
end
