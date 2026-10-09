defmodule MobCi.Lane.IosKeychainTest do
  # worker/mac/mob_ci_ios_cell.sh with its ci_keychain.sh and bin/codesign,
  # run by bash with `security`, `codesign` and `mix` stubbed: no keychain,
  # Mac or Elixir build needed.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @identity "Apple Development: someone@example.com (ABCDE12345)"
  @password "s3cret pass"

  setup %{tmp_dir: tmp} do
    stubs = Path.join(tmp, "stubs")
    File.mkdir_p!(stubs)

    # `security` records its argv and stdin; SECURITY_EXIT sets its status.
    stub!(stubs, "security", """
    #!/bin/sh
    printf '%s\\n' "$@" > "$LOG_DIR/security.args"
    cat > "$LOG_DIR/security.stdin"
    [ "${SECURITY_EXIT:-0}" = 0 ] || echo "security: wrong password" >&2
    exit "${SECURITY_EXIT:-0}"
    """)

    # The codesign PATH finds without the shim, and the one the shim execs.
    for {name, tag} <- [{"codesign", "path"}, {"real_codesign", "real"}] do
      stub!(stubs, name, """
      #!/bin/sh
      { echo #{tag}; printf '%s\\n' "$@"; } > "$LOG_DIR/codesign.args"
      """)
    end

    home = Path.join(tmp, "home")
    kc = Path.join(home, "Library/Keychains/mob_ci.keychain-db")
    pw_file = Path.join(home, ".config/mob_ci/ci-keychain-password")
    File.mkdir_p!(Path.dirname(kc))
    File.write!(kc, "")
    File.mkdir_p!(Path.dirname(pw_file))
    File.write!(pw_file, @password)

    # `mix` as the cell script finds it ($HOME/.local/bin): deps.get and
    # compile succeed; `mix ci.ios_cell` signs the way mob_dev does,
    # `codesign` by name with the inherited environment.
    stub!(Path.join(home, ".local/bin"), "mix", """
    #!/bin/sh
    [ "$1" = ci.ios_cell ] || exit 0
    codesign --force --sign "#{@identity}" app.app
    echo "MOB_CI_CODESIGN_KEYCHAIN=${MOB_CI_CODESIGN_KEYCHAIN:-}"
    """)

    %{stubs: stubs, home: home, kc: kc, pw_file: pw_file, log: tmp}
  end

  test "unlocks the CI keychain from the file on stdin and signs from it", ctx do
    {out, 0} = run(ctx)

    assert read_lines(ctx.log, "security.args") == ["unlock-keychain", ctx.kc]
    assert File.read!(Path.join(ctx.log, "security.stdin")) == @password

    assert read_lines(ctx.log, "codesign.args") ==
             ["real", "--keychain", ctx.kc, "--force", "--sign", @identity, "app.app"]

    assert out =~ "MOB_CI_CODESIGN_KEYCHAIN=#{ctx.kc}\n"
    refute out =~ @password
  end

  test "a failed unlock leaves codesign and the environment alone", ctx do
    {out, 0} = run(ctx, [{"SECURITY_EXIT", "51"}])

    assert out =~ "could not unlock #{ctx.kc}"
    assert out =~ "wrong password"

    assert read_lines(ctx.log, "codesign.args") == [
             "path",
             "--force",
             "--sign",
             @identity,
             "app.app"
           ]

    assert out =~ "MOB_CI_CODESIGN_KEYCHAIN=\n"
  end

  test "without the password file nothing is unlocked and codesign is the system one", ctx do
    File.rm!(ctx.pw_file)
    {out, 0} = run(ctx)

    assert out =~ "no CI keychain"
    refute File.exists?(Path.join(ctx.log, "security.args"))

    assert read_lines(ctx.log, "codesign.args") == [
             "path",
             "--force",
             "--sign",
             @identity,
             "app.app"
           ]
  end

  test "without the keychain nothing is unlocked", ctx do
    File.rm!(ctx.kc)
    {out, 0} = run(ctx)

    assert out =~ "no CI keychain"
    refute File.exists?(Path.join(ctx.log, "security.args"))
    assert hd(read_lines(ctx.log, "codesign.args")) == "path"
  end

  test "MOB_CI_KEYCHAIN and MOB_CI_KEYCHAIN_PASSWORD_FILE point elsewhere", ctx do
    kc = Path.join(ctx.log, "other.keychain-db")
    pw_file = Path.join(ctx.log, "other-password")
    File.write!(kc, "")
    File.write!(pw_file, "other")

    {_out, 0} =
      run(ctx, [{"MOB_CI_KEYCHAIN", kc}, {"MOB_CI_KEYCHAIN_PASSWORD_FILE", pw_file}])

    assert read_lines(ctx.log, "security.args") == ["unlock-keychain", kc]
    assert File.read!(Path.join(ctx.log, "security.stdin")) == "other"
    assert Enum.take(read_lines(ctx.log, "codesign.args"), 3) == ["real", "--keychain", kc]
  end

  # The worker half of the script (what guard.sh runs detached): the keychain
  # set-up happens there.
  defp run(ctx, env \\ []) do
    System.cmd("bash", ["worker/mac/mob_ci_ios_cell.sh", "--worker", "--spec-b64", "e30="],
      cd: File.cwd!(),
      stderr_to_stdout: true,
      env:
        [
          {"HOME", ctx.home},
          {"PATH", "#{ctx.stubs}:/usr/bin:/bin"},
          {"LOG_DIR", ctx.log},
          {"MOB_CI_REAL_CODESIGN", Path.join(ctx.stubs, "real_codesign")},
          {"MOB_CI_KEYCHAIN", nil},
          {"MOB_CI_KEYCHAIN_PASSWORD_FILE", nil},
          {"MOB_CI_CODESIGN_KEYCHAIN", nil}
        ] ++ env
    )
  end

  defp stub!(dir, name, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp read_lines(dir, name),
    do: dir |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
end
