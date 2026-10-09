defmodule MobCi.MatrixTest do
  use ExUnit.Case, async: true

  alias MobCi.{Matrix, Store}

  @golden Path.expand("../fixtures/matrix", __DIR__)

  # ── a seeded store: two hex nights, master, an rc row, a fixture host, a replay ──

  defp pin(v), do: %{version: v, sha: nil, source: "hex", dir: "/home/kevin/.cache/mob_ci/hex/x-#{v}"}
  defp git(v, sha, repo), do: %{version: v, sha: sha, source: "git:https://github.com/GenericJam/#{repo}@#{sha}", dir: "/x/#{repo}/#{sha}"}

  defp record(row, core, plugins), do: %{row: row, repos: Map.merge(core, plugins)}

  @v1 %{mob: %{version: "0.9.15", sha: nil, source: "hex", dir: nil}, mob_dev: %{version: "0.7.17", sha: nil, source: "hex", dir: nil}}

  defp v1_core, do: Map.put(@v1, :mob_new, pin("0.6.8"))
  defp v2_core, do: v1_core() |> Map.put(:mob, %{version: "0.9.16", sha: nil, source: "hex", dir: nil})
  defp default_plugins, do: %{mob_location: pin("0.2.0"), mob_camera: pin("0.3.1")}
  defp all_plugins, do: Map.put(default_plugins(), :mob_whisper, pin("0.1.4"))

  @paths [
    {"all", "static"},
    {"android", "deploy:android"},
    {"android", "release:android"},
    {"ios", "deploy:ios_sim"},
    {"ios", "deploy:ios_device"},
    {"ios", "release:ios"}
  ]

  @doc false
  def seed(store) do
    run = fn row, at, trigger ->
      {:ok, id} = Store.record_run(store, %{trigger: trigger, versions_row: row, host: "nuc", mob_ci_sha: "abc", started_at: elem(DateTime.from_iso8601(at), 1)})
      id
    end

    cell = fn run_id, set, {platform, path}, outcome, layer, versions ->
      Store.record_cell(store, run_id, %{set: set, platform: platform, path: path, outcome: outcome, layer: layer, versions: versions, log_path: "/home/kevin/mob_ci_logs/x.log"})
      # an invariant row too: the reports must read summaries only
      Store.record_cell(store, run_id, %{set: set, platform: platform, path: path, invariant: "p2", outcome: :fail, layer: "boot"})
    end

    # Night 1, hex v1: default and all pass on every path (Android on the NUC,
    # iOS on the Mac: the records' dirs differ and must not split the tuple).
    n1 = run.("hex", "2026-10-07T02:00:00Z", "nightly")

    for {platform, _} = p <- @paths, {set, plugins} <- [{"default", default_plugins()}, {"all", all_plugins()}] do
      core = if platform == "ios", do: Map.put(v1_core(), :mob_new, %{pin("0.6.8") | dir: "/Users/kevin/x"}), else: v1_core()
      cell.(n1, set, p, :pass, nil, record("hex", core, plugins))
    end

    cell.(n1, "singleton:mob_location", {"android", "deploy:android"}, :pass, nil, record("hex", v1_core(), %{mob_location: pin("0.2.0")}))
    cell.(n1, "random:7", {"android", "deploy:android"}, :pass, nil, record("hex", v1_core(), default_plugins()))

    # Night 2, hex v2 (mob 0.9.16): release:android regresses, all's static gate fails.
    n2 = run.("hex", "2026-10-08T02:00:00Z", "nightly")
    v2d = record("hex", v2_core(), default_plugins())
    cell.(n2, "default", {"all", "static"}, :pass, nil, v2d)
    cell.(n2, "default", {"android", "deploy:android"}, :pass, nil, v2d)
    cell.(n2, "default", {"android", "release:android"}, :fail, "build:release:android/mob_camera", v2d)
    cell.(n2, "default", {"ios", "deploy:ios_sim"}, :pass, nil, v2d)
    cell.(n2, "default", {"ios", "deploy:ios_device"}, :skip, nil, v2d)
    cell.(n2, "default", {"ios", "release:ios"}, :error, "build:release:ios", v2d)
    cell.(n2, "all", {"all", "static"}, :fail, "static", record("hex", v2_core(), all_plugins()))
    cell.(n2, "singleton:mob_location", {"android", "deploy:android"}, :pass, nil, record("hex", v2_core(), %{mob_location: pin("0.2.0")}))
    cell.(n2, "random:7", {"android", "deploy:android"}, :fail, "conflict:mob_location,mob_camera", v2d)
    cell.(n2, "sweep:mob_location,mob_whisper", {"android", "deploy:android"}, :error, "build:/home/kevin/code/mob_ci/fixtures/_hosts/ci_x", v2d)
    cell.(n2, "sweep:all", {"all", "static"}, :pass, nil, nil)

    # master: git pins.
    m = run.("master", "2026-10-08T03:00:00Z", "nightly")
    master_core = %{mob: git("0.9.17", String.duplicate("a", 40), "mob"), mob_dev: git("0.7.18", String.duplicate("b", 40), "mob_dev"), mob_new: git("0.6.9", String.duplicate("c", 40), "mob_new")}
    cell.(m, "default", {"android", "deploy:android"}, :pass, nil, record("master", master_core, %{mob_location: git("0.2.1", String.duplicate("d", 40), "mob_location")}))

    # an rc row, a fixture host (not published) and a pinned replay of night 1.
    rc = run.("rc:mob@abcdef1", "2026-10-08T04:00:00Z", "rc")
    cell.(rc, "default", {"android", "deploy:android"}, :pass, nil, record("rc:mob@abcdef1", Map.put(v1_core(), :mob, git("0.9.17", "abcdef1" <> String.duplicate("0", 33), "mob")), default_plugins()))

    h = run.("harness", "2026-10-08T05:00:00Z", "ci.device")
    cell.(h, "harness:mob_ci_haptic", {"android", "deploy:android"}, :fail, "plugin:mob_ci_haptic", nil)

    r = run.("hex", "2026-10-08T06:00:00Z", "replay")
    cell.(r, "default", {"android", "release:android"}, :pass, nil, record("hex", v1_core(), default_plugins()))

    :ok
  end

  setup do
    path = Path.join(System.tmp_dir!(), "mob_ci_matrix_#{System.unique_integer([:positive])}/results.sqlite")
    store = Store.open!(path)
    seed(store)
    summaries = Store.query(store, invariant: nil)

    on_exit(fn ->
      Store.close(store)
      File.rm_rf!(Path.dirname(path))
    end)

    %{store: store, summaries: summaries}
  end

  defp golden(name, text) do
    file = Path.join(@golden, name)

    if System.get_env("MOB_CI_UPDATE_GOLDEN") == "1" do
      File.mkdir_p!(@golden)
      File.write!(file, text)
    end

    assert text == File.read!(file), "#{name} differs from #{file} (MOB_CI_UPDATE_GOLDEN=1 rewrites it; review the diff)"
  end

  describe "matrix.md" do
    test "renders the seeded store byte-for-byte (golden)", %{summaries: s} do
      golden("matrix.md", Matrix.matrix_md(s))
    end

    test "the grid is the newest non-replay cell; fixture hosts, sampled passes and private paths stay out", %{summaries: s} do
      md = Matrix.matrix_md(s)
      [_, hex] = Regex.run(~r/## hex\n(.*?)(?=\n## )/s, md)

      # night 2's failure, not night 1's pass nor the later pinned replay's pass
      assert hex =~ ~r/\| `default` \| ✓ pass \| ✓ pass \| ✗ fail @ `build:release:android\/mob_camera` \|/
      refute md =~ "harness"
      refute md =~ "/home/kevin"
      # a failing sampled set is listed with its cell id, outside the grid
      assert hex =~ ~r/\| \d+ \| `random:7` \| deploy:android \| ✗ fail @ `conflict:mob_location,mob_camera` \|/
      assert hex =~ "! error @ `build:ci_x`"
      refute hex =~ "| `random:7` | ·"
      # the static sweep of a named set is deterministic: a grid line
      assert hex =~ "| `sweep:all` |"
      assert md =~ ~r/## hex.*## master.*## rc:mob@abcdef1/s
    end

    test "is deterministic: input order and a reopened store don't change a byte", %{store: store, summaries: s} do
      md = Matrix.matrix_md(s)
      assert Matrix.matrix_md(Enum.shuffle(s)) == md
      assert Matrix.matrix_md(Enum.reverse(s)) == md
      reopened = Store.open!(store.path)
      assert Matrix.matrix_md(Store.query(reopened, invariant: nil)) == md
      assert Matrix.compatibility_md(Enum.shuffle(s)) == Matrix.compatibility_md(s)
      Store.close(reopened)
    end

    test "an empty store renders a valid page" do
      assert Matrix.matrix_md([]) =~ "No results on a version row yet."
      assert Matrix.compatibility_md([]) =~ "None yet"
    end
  end

  describe "COMPATIBILITY.md" do
    test "renders the seeded store byte-for-byte (golden)", %{summaries: s} do
      golden("COMPATIBILITY.md", Matrix.compatibility_md(s))
    end

    test "a tuple is verified only when default and all passed on every path with those exact pins", %{summaries: s} do
      [newest | _] = tuples = Matrix.tuples(s)

      # newest first: rc (04:00), master (03:00), hex v2 (02:00), hex v1 (night 1 + the 06:00 replay)
      assert Enum.map(tuples, &{&1.rows, &1.pins["mob"] |> elem(0)}) ==
               [{["hex"], "0.9.15"}, {["rc:mob@abcdef1"], "0.9.17"}, {["master"], "0.9.17"}, {["hex"], "0.9.16"}]

      # v1: the NUC and Mac records differ only in dir, and default's and all's
      # plugin lists differ: still one tuple, with all's plugins; the replay
      # (exact v1 pins) counts as evidence and makes it the newest.
      assert newest.verified
      assert Map.keys(newest.pins) |> Enum.sort() == ~w(mob mob_camera mob_dev mob_location mob_new mob_whisper)
      assert newest.newest == "2026-10-08T06:00:00Z"

      v2 = Enum.find(tuples, &(&1.pins["mob"] == {"0.9.16", nil, "hex"}))
      refute v2.verified
      assert v2.status[{"default", "release:android"}] == :fail
      assert v2.status[{"default", "deploy:ios_device"}] == :skip
      assert v2.status[{"all", "deploy:android"}] == nil
    end

    test "a release of a plugin outside default starts a new tuple without taking the older one's default results" do
      core = %{"mob" => %{"version" => "0.9.15", "source" => "hex"}, "mob_dev" => %{"version" => "0.7.17", "source" => "hex"}, "mob_new" => %{"version" => "0.6.8", "source" => "hex"}}
      loc = %{"mob_location" => %{"version" => "0.2.0", "source" => "hex"}}
      cam = fn v -> %{"mob_camera" => %{"version" => v, "source" => "hex"}} end
      rec = fn plugins -> %{"row" => "hex", "repos" => core |> Map.merge(loc) |> Map.merge(plugins)} end
      ids = Stream.iterate(1, &(&1 + 1))

      night_a =
        for {_, path} <- @paths, {set, plugins} <- [{"default", %{}}, {"all", cam.("0.3.1")}],
            do: %{set: set, path: path, outcome: :pass, at: "2026-10-07T02:00:00Z", versions: rec.(plugins)}

      # night B: mob_camera 0.3.2 (not in default) breaks all; default passes again
      night_b = [
        %{set: "all", path: "deploy:android", outcome: :fail, at: "2026-10-08T02:00:00Z", versions: rec.(cam.("0.3.2"))},
        %{set: "default", path: "deploy:android", outcome: :pass, at: "2026-10-08T02:00:00Z", versions: rec.(%{})}
      ]

      summaries =
        Enum.zip_with(night_a ++ night_b, ids, fn c, id ->
          Map.merge(c, %{id: id, versions_row: "hex", trigger: "nightly", started_at: c.at})
        end)

      by_camera = Map.new(Matrix.tuples(summaries), &{elem(&1.pins["mob_camera"], 0), &1})
      assert by_camera["0.3.1"].verified
      refute by_camera["0.3.2"].verified
      # B's tuple has night B's default result too
      assert by_camera["0.3.2"].status[{"default", "deploy:android"}] == :pass
    end

    test "the plugin table lists passing plugin versions per mob / mob_dev, newest first", %{summaries: s} do
      md = Matrix.compatibility_md(s)
      [_, plugins] = String.split(md, "## Plugins")

      # mob_location passed with mob 0.9.16 (singleton, default) and 0.9.15, and on master by git
      lines = plugins |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| `mob_location`"))

      assert [
               "| `mob_location` | 0.2.1 (git ddddddd) | 0.9.17 (git aaaaaaa) | 0.7.18 (git bbbbbbb) | `deploy:android` |",
               "| `mob_location` | 0.2.0 | 0.9.17 (git abcdef1) | 0.7.17 | `deploy:android` |",
               "| `mob_location` | 0.2.0 | 0.9.16 | 0.7.17 | `static`, `deploy:android`, `deploy:ios_sim` |",
               "| `mob_location` | 0.2.0 | 0.9.15 | 0.7.17 |" <> rest
             ] = lines

      assert rest == " `static`, `deploy:android`, `release:android`, `deploy:ios_sim`, `deploy:ios_device`, `release:ios` |"
      # random/sweep cells are not evidence; failures never are
      refute plugins =~ "conflict"
    end
  end

  test "public_layer cuts absolute paths to their last segment and leaves tokens alone" do
    assert Matrix.public_layer("build:/home/kevin/code/mob_ci/fixtures/_hosts/ci_all_hex") == "build:ci_all_hex"
    assert Matrix.public_layer("build:~/x/y/host") == "build:host"
    assert Matrix.public_layer("build:release:android/mob_x") == "build:release:android/mob_x"
    assert Matrix.public_layer("conflict:mob_a,mob_b") == "conflict:mob_a,mob_b"
    assert Matrix.public_layer("plugin:mob_x?") == "plugin:mob_x?"
    assert Matrix.public_layer(nil) == nil
  end

  test "sampled sets are random seeds and device-sweep subsets, not static sweeps of a named set" do
    assert Matrix.sampled_set?("random:42")
    assert Matrix.sampled_set?("sweep:mob_location,mob_camera")
    assert Matrix.sampled_set?("sweep:mob_location")
    refute Matrix.sampled_set?("sweep:all")
    refute Matrix.sampled_set?("sweep:fixtures")
    refute Matrix.sampled_set?("singleton:mob_location")
    refute Matrix.sampled_set?("default")
  end
end
