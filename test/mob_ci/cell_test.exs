defmodule MobCi.CellTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ci.Device
  alias MobCi.{Cell, Plugins, Result, Sets, Versions}

  # A fully stubbed remote: every plugin and core repo is on "Hex" at 1.0.0 and
  # at sha "c"×40 on git; mob_new's "tarball"/checkout is a fake project whose
  # ProjectGenerator says the default set is [:mob_location, :mob_camera].
  # mob_bluetooth and mob_midi get a manifest declaring the same iOS plist key
  # (the F9 collision), so the static gate has something to reject.
  @colliding [:mob_bluetooth, :mob_midi]

  defp write_colliding_manifest(dir, name) do
    File.mkdir_p!(Path.join(dir, "priv"))

    File.write!(Path.join(dir, "priv/mob_plugin.exs"), """
    %{
      name: #{inspect(name)},
      mob_version: "~> 0.9",
      plugin_spec_version: 1,
      ios: %{plist_keys: %{NSBluetoothAlwaysUsageDescription: "#{name} needs Bluetooth."}}
    }
    """)
  end

  defp remote do
    sha = String.duplicate("c", 40)

    write_fake_mob_new = fn dir ->
      File.mkdir_p!(Path.join(dir, "lib"))

      File.write!(
        Path.join(dir, "mix.exs"),
        "defmodule F.MixProject do\n  use Mix.Project\n  def project, do: [app: :f, version: \"0.6.9\", deps: []]\nend\n"
      )

      File.write!(
        Path.join(dir, "lib/g.ex"),
        "defmodule MobNew.ProjectGenerator do\n  def assigns(_, _), do: %{mob_plugins: [:mob_location, :mob_camera]}\nend\n"
      )
    end

    %{
      hex_latest: fn _name -> {:ok, "1.0.0"} end,
      git_head: fn _url -> {:ok, sha} end,
      checkout: fn name, _url, sha, cache ->
        dir = Path.join([cache, "src", to_string(name), sha])
        if name == :mob_new, do: write_fake_mob_new.(dir), else: File.mkdir_p!(dir)
        {:ok, %{dir: dir, sha: sha}}
      end,
      hex_unpack: fn name, version, cache ->
        dir = Path.join([cache, "hex", "#{name}-#{version}"])

        cond do
          name == :mob_new -> write_fake_mob_new.(dir)
          name in @colliding -> write_colliding_manifest(dir, name)
          true -> File.mkdir_p!(dir)
        end

        {:ok, dir}
      end
    }
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "mob_ci_cell_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    before = Plugins.resolved_dirs()

    on_exit(fn ->
      Plugins.put_resolved_dirs(before)
      File.rm_rf!(tmp)
    end)

    %{opts: [remote: remote(), cache_dir: tmp], tmp: tmp}
  end

  describe "plan/3" do
    test "nil/nil is default × hex; the default set is read from the row's mob_new", %{opts: opts} do
      assert {:ok, cell} = Cell.plan(nil, nil, opts)
      assert cell.row == :hex
      assert cell.spec == :default
      assert cell.set == "default"
      assert cell.plugins == [:mob_location, :mob_camera]
      assert cell.resolved.row == :hex

      assert Map.keys(cell.resolved.repos) |> Enum.sort() == [
               :mob,
               :mob_camera,
               :mob_dev,
               :mob_location,
               :mob_new
             ]

      assert cell.resolved.repos.mob_camera.version == "1.0.0"
    end

    test "resolves exactly the set's plugins plus the core, on the asked row", %{
      opts: opts,
      tmp: tmp
    } do
      assert {:ok, cell} = Cell.plan("singleton:mob_midi", "master", opts)
      assert cell.set == "singleton:mob_midi"
      assert cell.plugins == [:mob_midi]
      assert Map.keys(cell.resolved.repos) |> Enum.sort() == [:mob, :mob_dev, :mob_midi, :mob_new]

      assert cell.resolved.repos.mob_midi.dir ==
               Path.join([tmp, "src", "mob_midi", String.duplicate("c", 40)])

      assert Versions.record(cell.resolved).row == "master"
    end

    test "blank resolves only the core", %{opts: opts} do
      assert {:ok, cell} = Cell.plan("blank", "rc:mob@abc1234", opts)
      assert cell.plugins == []
      assert Map.keys(cell.resolved.repos) |> Enum.sort() == [:mob, :mob_dev, :mob_new]
      assert cell.resolved.repos.mob.source == {:git, "https://github.com/GenericJam/mob"}
      assert cell.resolved.repos.mob_dev.source == :hex
    end

    test "points manifest lookup at the resolved sources (fixtures still win)", %{
      opts: opts,
      tmp: tmp
    } do
      assert {:ok, _} = Cell.plan("singleton:mob_midi", "hex", opts)
      assert Plugins.resolved_dirs()[:mob_midi] == Path.join([tmp, "hex", "mob_midi-1.0.0"])
      assert Plugins.fixture_dir(:mob_midi) == Path.join([tmp, "hex", "mob_midi-1.0.0"])
      assert Plugins.fixture_dir(:mob_ci_haptic) =~ "fixtures/mob_ci_haptic"
    end

    test "bad set or row names fail with the parser's message; plan! raises Mix.Error", %{
      opts: opts
    } do
      assert {:error, msg} = Cell.plan("pairwise:999", "hex", opts)
      assert msg =~ "out of range"
      assert {:error, msg} = Cell.plan("all", "nightly", opts)
      assert msg =~ "unknown --versions \"nightly\""
      assert_raise Mix.Error, ~r/unknown --set/, fn -> Cell.plan!("nope", "hex", opts) end
    end

    test "a repo that cannot be resolved fails the plan naming it", %{opts: opts} do
      failing = %{
        opts[:remote]
        | hex_latest: fn name ->
            if name == :mob_dev, do: {:error, :down}, else: {:ok, "1.0.0"}
          end
      }

      assert {:error, msg} = Cell.plan("blank", "hex", Keyword.put(opts, :remote, failing))
      assert msg =~ "could not resolve mob_dev for row hex"
    end

    test "all leaves the committed exclusions out, so the host composes; --static plans them back in and the gate still reports the pair",
         %{opts: opts} do
      excluded = Keyword.keys(Sets.exclusions())
      assert :mob_midi in excluded

      {:ok, built} = Cell.plan("all", "hex", opts)
      refute :mob_midi in built.plugins
      assert :mob_bluetooth in built.plugins
      refute Map.has_key?(built.resolved.repos, :mob_midi)
      assert MobDev.Plugin.Validator.cross_validate(Plugins.activated(built.plugins)).errors == []

      {:ok, static} = Cell.plan("all", "hex", Keyword.put(opts, :include_excluded, true))
      assert :mob_midi in static.plugins
      assert static.plugins == Sets.pool(include_excluded: true)
      assert [error] = MobDev.Plugin.Validator.cross_validate(Plugins.activated(static.plugins)).errors
      assert error =~ "NSBluetoothAlwaysUsageDescription"
      assert error =~ ":mob_bluetooth"
      assert error =~ ":mob_midi"

      text = Cell.describe(static)
      assert text =~ "mob_midi: included for the static gate — F9"
      assert Cell.describe(built) =~ "mob_midi: excluded from built sets — F9"
    end

    test "describe/1 prints the set name, its plugins and the versions", %{opts: opts} do
      {:ok, cell} = Cell.plan("singleton:mob_midi", "hex", opts)
      text = Cell.describe(cell)
      assert text =~ "set: singleton:mob_midi (1 plugin)"
      assert text =~ "\n  mob_midi\n"
      assert text =~ "versions: hex"
      assert text =~ ~r/mob_dev\s+1\.0\.0 \(hex\)/
    end
  end

  describe "mix ci.device option parsing" do
    test "--plugins / --host cannot be combined with a cell" do
      assert_raise Mix.Error, ~r/--plugins is for the harness/, fn ->
        Device.reject_harness_flags!(plugins: "haptic", set: "all")
      end

      assert_raise Mix.Error, ~r/--host is for the harness/, fn ->
        Device.reject_harness_flags!(host: "sloppy_joe", versions: "hex")
      end

      assert Device.reject_harness_flags!(set: "all", versions: "hex", static: true) == :ok
    end

    test "--set and --versions values go through the parsers (bad input is a Mix.Error with the reason)" do
      assert_raise Mix.Error, ~r/unknown --set "every"/, fn -> Sets.parse!("every") end
      assert_raise Mix.Error, ~r/rc sha must be/, fn -> Versions.parse!("rc:mob@HEAD") end
    end
  end

  describe "results carry the cell" do
    test "Result.stamp/3 sets the set name and the version record on every result", %{opts: opts} do
      {:ok, cell} = Cell.plan("singleton:mob_midi", "hex", opts)
      record = Versions.record(cell.resolved)

      results = [Result.pass(:p1, "composes"), Result.skip(:p8, "migrations", "none")]
      assert Enum.all?(results, &is_nil(&1.set))

      stamped = Result.stamp(results, cell.set, record)
      assert Enum.map(stamped, & &1.set) == ["singleton:mob_midi", "singleton:mob_midi"]
      assert Enum.all?(stamped, &(&1.versions == record))
      assert hd(stamped).versions.repos.mob_midi.version == "1.0.0"
      # nothing else changes
      assert Enum.map(stamped, &{&1.id, &1.status}) == [{:p1, :pass}, {:p8, :skip}]
    end

    test "summary.json records the set and versions of a stamped run", %{opts: opts, tmp: tmp} do
      {:ok, cell} = Cell.plan("blank", "master", opts)

      results =
        Result.stamp([Result.pass(:p2, "boots")], cell.set, Versions.record(cell.resolved))

      dir = Path.join(tmp, "artifacts")
      MobCi.Report.write_artifacts(dir, cell.plugins, results)
      {summary, _} = Code.eval_file(Path.join(dir, "summary.json"))
      assert summary.set == "blank"
      assert summary.versions.row == "master"
      assert summary.versions.repos.mob.sha == String.duplicate("c", 40)
    end
  end
end
