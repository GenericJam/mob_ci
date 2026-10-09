defmodule MobCi.TriggersTest do
  use ExUnit.Case, async: true

  alias MobCi.{DeviceCaps, Sets, Triggers, Versions}

  describe "trigger → sets" do
    test "a core repo asks for blank + default + all" do
      for repo <- [:mob, :mob_dev, :mob_new],
          do: assert(Triggers.sets_for_repos([repo]) == ["blank", "default", "all"])
    end

    test "a plugin asks for default + its singleton + all; several keep committed order, no repeats" do
      assert Triggers.sets_for_repos([:mob_camera]) == ["default", "singleton:mob_camera", "all"]

      assert Triggers.sets_for_repos([:mob_whisper, :mob, :mob_camera]) ==
               ["blank", "default", "singleton:mob_camera", "singleton:mob_whisper", "all"]
    end

    test "an excluded plugin keeps its singleton; an unbuildable one has no cell of its own" do
      [{excluded, _} | _] = Sets.exclusions()
      assert "singleton:#{excluded}" in Triggers.sets_for_repos([excluded])

      [unbuildable | _] = Versions.plugins() -- DeviceCaps.buildable(Versions.plugins())
      assert Triggers.sets_for_repos([unbuildable]) == ["default", "all"]
    end

    test "every set a trigger asks for parses" do
      for repo <- Keyword.keys(Versions.repos()), set <- Triggers.sets_for_repos([repo]),
          do: assert({:ok, _} = Sets.parse(set))
    end
  end

  describe "rc_job/2" do
    test "<repo>@<sha> becomes an rc row with the repo's sets on both platforms" do
      assert {:ok, job} = Triggers.rc_job("mob_camera@1A2b3c4" |> String.downcase())

      assert %{
               trigger: "rc",
               versions_row: "rc:mob_camera@1a2b3c4",
               sets: ["default", "singleton:mob_camera", "all"],
               platforms: ["android", "ios"],
               priority: 10
             } = job

      assert {:ok, %{versions_row: "rc:mob@abcdef1", sets: ["blank", "default", "all"]}} =
               Triggers.rc_job("rc:mob@abcdef1")
    end

    test "a bad repo, sha or shape is Versions.parse's error" do
      assert {:error, msg} = Triggers.rc_job("nope@abcdef1")
      assert msg =~ "unknown repo"
      assert {:error, msg} = Triggers.rc_job("mob@xyz")
      assert msg =~ "7–40 hex"
      assert {:error, msg} = Triggers.rc_job("mob")
      assert msg =~ "<repo>@<sha>"
    end
  end

  describe "nightly" do
    test "hex then master, Android and iOS; pairwise rows only on master, on the deploy path" do
      not_after = ~U[2026-10-10 13:00:00Z]
      [hex, master] = Triggers.nightly_jobs(not_after)

      assert %{trigger: "nightly", versions_row: "hex", platforms: ["android", "ios"], priority: 0, not_after: ^not_after} = hex
      assert master.versions_row == "master"
      assert master.sets == Sets.nightly()
      assert hex.sets == Enum.reject(Sets.nightly(), &String.starts_with?(&1, "pairwise:"))
      assert Enum.any?(master.sets, &String.starts_with?(&1, "pairwise:"))

      assert Triggers.cell_paths("pairwise:3", "android") == "deploy"
      assert Triggers.cell_paths("pairwise:3", "ios") == "deploy:ios_sim"
      assert Triggers.cell_paths("all", "android") == nil
    end

    test "fits the window on every lane, worst case (a new plugin or set must be pruned deliberately)" do
      window = Triggers.nightly_window_minutes()
      assert window == 9 * 60

      for {lane, minutes} <- Triggers.estimate_minutes(Triggers.nightly_jobs(nil)) do
        assert minutes <= window, "#{lane} lane: #{minutes} worst-case minutes > the #{window}-minute window"
      end
    end

    test "next_local/2 is the next occurrence of the time, never now" do
      assert Triggers.next_local(~N[2026-10-09 22:00:05], ~T[07:00:00]) == ~N[2026-10-10 07:00:00]
      assert Triggers.next_local(~N[2026-10-09 06:59:00], ~T[07:00:00]) == ~N[2026-10-09 07:00:00]
      assert Triggers.next_local(~N[2026-10-09 07:00:00], ~T[07:00:00]) == ~N[2026-10-10 07:00:00]
    end
  end

  test "manual_job/4 validates the row, sets and platforms" do
    assert {:ok, %{trigger: "manual", versions_row: "hex", sets: ["default"]}} =
             Triggers.manual_job("hex", ["default"], ["android"])

    assert {:error, _} = Triggers.manual_job("nightly", ["default"], ["android"])
    assert {:error, _} = Triggers.manual_job("hex", ["nope"], ["android"])
    assert {:error, msg} = Triggers.manual_job("hex", ["default"], ["windows"])
    assert msg =~ "unknown platform"
  end

  test "the static gate runs ci.device --static per set with the trigger in the env" do
    me = self()
    job = %{trigger: "poll", versions_row: "master", sets: ["default", "all"]}

    result =
      Triggers.static_gate(job,
        runner: fn argv, env ->
          send(me, {:ran, argv, env})
          if "all" in argv, do: 1, else: 0
        end
      )

    assert result == [{"default", 0}, {"all", 1}]
    assert_received {:ran, ~w(ci.device --static --set default --versions master), [{"MOB_CI_TRIGGER", "poll"}]}
  end
end
