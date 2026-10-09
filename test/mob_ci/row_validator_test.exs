defmodule MobCi.RowValidatorTest do
  # The static gate asks the row's mob_dev, not mob_ci's: proven with two fake
  # mob_dev checkouts whose validators answer differently (path deps, so no
  # network), run through the real throwaway Mix project.
  use ExUnit.Case, async: true

  alias MobCi.RowValidator

  setup do
    root = Path.join(System.tmp_dir!(), "mob_ci_row_validator_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp hex(v), do: %{row: :hex, repos: %{mob_dev: %{version: v, sha: nil, source: :hex, dir: nil}}}

  defp git(sha, dir),
    do: %{row: :master, repos: %{mob_dev: %{version: "0.7.99", sha: sha, source: {:git, "https://github.com/GenericJam/mob_dev"}, dir: dir}}}

  # A mob_dev whose validator says who it is and what it was given.
  defp fake_mob_dev(root, name) do
    dir = Path.join(root, name)
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule FakeMobDev.MixProject do
      use Mix.Project
      def project, do: [app: :mob_dev, version: "0.0.1", elixir: "~> 1.17", deps: []]
    end
    """)

    File.write!(Path.join(dir, "lib/validator.ex"), """
    defmodule MobDev.Plugin.Validator do
      def cross_validate(activated) do
        names = Enum.map_join(activated, ",", fn {n, _m} -> Atom.to_string(n) end)
        %{errors: ["#{name} saw " <> names]}
      end
    end
    """)

    dir
  end

  test "a hex row and a master row with different mob_dev pins validate with different mob_devs" do
    hex = RowValidator.source(hex("0.7.18"))
    master = RowValidator.source(git(String.duplicate("a", 40), "/cache/src/mob_dev/aaaa"))

    assert hex.dep == {:mob_dev, "== 0.7.18"}
    assert master.dep == {:mob_dev, path: "/cache/src/mob_dev/aaaa", override: true}
    assert RowValidator.project_dir(hex, "/c") == "/c/validators/mob_dev-hex-0.7.18"
    assert RowValidator.project_dir(master, "/c") == "/c/validators/mob_dev-git-#{String.duplicate("a", 40)}"
    assert RowValidator.mix_exs(hex) =~ ~s({:mob_dev, "== 0.7.18"})
    assert RowValidator.mix_exs(master) =~ ~s({:mob_dev, path: "/cache/src/mob_dev/aaaa", override: true})

    # another Hex release is another project
    assert RowValidator.project_dir(RowValidator.source(hex("0.7.17")), "/c") != RowValidator.project_dir(hex, "/c")
  end

  test "conflicts/3 runs cross_validate in the row's mob_dev, per pin, and reuses the built project", %{root: root} do
    cache = Path.join(root, "cache")
    activated = [{:mob_a, %{nifs: [%{module: :mob_a_nif}]}}, {:mob_b, nil}]
    row1 = git(String.duplicate("1", 40), fake_mob_dev(root, "mob_dev_one"))
    row2 = git(String.duplicate("2", 40), fake_mob_dev(root, "mob_dev_two"))

    assert RowValidator.conflicts(activated, row1, cache: cache) == {:ok, ["mob_dev_one saw mob_a,mob_b"]}
    assert RowValidator.conflicts(activated, row2, cache: cache) == {:ok, ["mob_dev_two saw mob_a,mob_b"]}

    # built once per pin, then reused
    ready = Path.join(RowValidator.project_dir(RowValidator.source(row1), cache), ".mob_ci_ready")
    assert File.exists?(ready)
    assert RowValidator.conflicts([{:mob_c, nil}], row1, cache: cache) == {:ok, ["mob_dev_one saw mob_c"]}
  end

  test "a mob_dev that can't be built is an error naming it, not a verdict", %{root: root} do
    broken = Path.join(root, "broken")
    File.mkdir_p!(broken)
    File.write!(Path.join(broken, "mix.exs"), "this is not elixir (")

    assert {:error, msg} = RowValidator.conflicts([], git(String.duplicate("3", 40), broken), cache: Path.join(root, "cache"))
    assert msg =~ "mob_dev 333333333333 (git"
  end

  test "prune drops master-sha projects unused for a week, never hex ones or recent ones", %{root: root} do
    v = Path.join(root, "validators")
    old = System.os_time(:second) - 8 * 86_400

    for {name, mtime} <- [{"mob_dev-git-old", old}, {"mob_dev-git-new", nil}, {"mob_dev-hex-0.7.10", old}] do
      File.mkdir_p!(Path.join(v, name))
      ready = Path.join([v, name, ".mob_ci_ready"])
      File.write!(ready, "x\n")
      if mtime, do: File.touch!(ready, mtime)
    end

    assert RowValidator.prune(root, 7) == [Path.join(v, "mob_dev-git-old")]
    assert File.ls!(v) |> Enum.sort() == ["mob_dev-git-new", "mob_dev-hex-0.7.10"]
  end
end
