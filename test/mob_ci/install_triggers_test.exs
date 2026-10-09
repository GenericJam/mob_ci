defmodule MobCi.InstallTriggersTest do
  # Runs priv/install-triggers.sh against a throwaway copy of the repo, a
  # throwaway $HOME and stub systemctl/loginctl: no real unit is touched.
  use ExUnit.Case, async: true

  @priv Path.expand("../../priv", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "mob_ci_install_#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    home = Path.join(root, "home")
    bin = Path.join(root, "bin")
    calls = Path.join(root, "calls.log")

    for dir <- ["priv/systemd", "priv/hooks"], do: File.mkdir_p!(Path.join(repo, dir))
    File.mkdir_p!(home)
    File.mkdir_p!(bin)

    for file <- ["install-triggers.sh", "ci-run.sh", "hooks/pre-push"] ++
                  Enum.map(File.ls!(Path.join(@priv, "systemd")), &"systemd/#{&1}") do
      File.cp!(Path.join(@priv, file), Path.join([repo, "priv", file]))
    end

    {_, 0} = System.cmd("git", ["init", "-q", repo])

    # Stubs log every call; loginctl remembers enable-linger in a file.
    stub = fn name, body ->
      path = Path.join(bin, name)
      File.write!(path, "#!/usr/bin/env bash\necho \"#{name} $*\" >> #{calls}\n" <> body)
      File.chmod!(path, 0o755)
    end

    # systemctl remembers `enable --now` so `is-enabled` can answer.
    stub.("systemctl", """
    case "$2" in
      enable) touch #{root}/enabled ;;
      is-enabled) [ -f #{root}/enabled ] || exit 1 ;;
    esac
    exit 0
    """)

    stub.("loginctl", """
    case "$1" in
      show-user) [ -f #{root}/linger ] && echo yes || echo no ;;
      enable-linger) touch #{root}/linger ;;
    esac
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, repo: repo, home: home, bin: bin, calls: calls}
  end

  defp install(ctx, args) do
    System.cmd("bash", [Path.join(ctx.repo, "priv/install-triggers.sh") | args],
      env: [
        {"HOME", ctx.home},
        {"USER", "ci"},
        {"XDG_CONFIG_HOME", nil},
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH")}
      ],
      stderr_to_stdout: true
    )
  end

  defp calls(ctx), do: ctx |> Map.fetch!(:calls) |> File.read!() |> String.split("\n", trim: true)

  test "installs the rendered units and enables the timers, and a second run changes nothing", ctx do
    unit_dir = Path.join(ctx.home, ".config/systemd/user")
    # An installed copy of the retired sweep timer is removed.
    File.mkdir_p!(unit_dir)
    File.write!(Path.join(unit_dir, "mob-ci.timer"), "[Timer]\n")

    assert {out1, 0} = install(ctx, ["--enable"])
    assert out1 =~ "wrote"
    assert out1 =~ "removed obsolete mob-ci.timer"
    refute File.exists?(Path.join(unit_dir, "mob-ci.timer"))

    units = ~w(mob-ci-nightly.service mob-ci-nightly.timer mob-ci-poll.service mob-ci-poll.timer mob-ci-drain@.service)

    snapshot =
      for unit <- units, into: %{} do
        body = File.read!(Path.join(unit_dir, unit))
        refute body =~ "%h/code/mob_ci", "#{unit} still names the committed checkout path"
        {unit, body}
      end

    assert snapshot["mob-ci-drain@.service"] =~ "ExecStart=#{ctx.repo}/priv/ci-run.sh drain %i"
    assert snapshot["mob-ci-poll.service"] =~ "ExecStart=#{ctx.repo}/priv/ci-run.sh poll"
    assert snapshot["mob-ci-nightly.service"] =~ "ExecStart=#{ctx.repo}/priv/ci-run.sh nightly"

    assert {"priv/hooks\n", 0} = System.cmd("git", ["-C", ctx.repo, "config", "core.hooksPath"])

    assert {out2, 0} = install(ctx, ["--enable"])
    assert out2 =~ "units up to date"
    refute out2 =~ "wrote"
    assert snapshot == Map.new(units, &{&1, File.read!(Path.join(unit_dir, &1))})

    calls = calls(ctx)
    assert Enum.count(calls, &(&1 == "systemctl --user daemon-reload")) == 1
    assert Enum.count(calls, &(&1 == "loginctl enable-linger ci")) == 1
    assert Enum.count(calls, &(&1 == "systemctl --user enable --now mob-ci-nightly.timer mob-ci-poll.timer")) == 2
    assert "systemctl --user disable --now mob-ci.timer" in calls

    # a later plain install leaves the enabled timers alone and says so
    assert {out3, 0} = install(ctx, [])
    assert out3 =~ "timers already enabled"
    assert Enum.count(calls(ctx), &String.contains?(&1, "enable --now")) == 2
  end

  test "without --enable the timers are installed but not started", ctx do
    assert {out, 0} = install(ctx, [])
    assert out =~ "NOT started"
    refute Enum.any?(calls(ctx), &String.contains?(&1, "enable --now"))
  end
end
