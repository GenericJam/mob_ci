defmodule MobCi.Lane.Ios.HostLockTest do
  use ExUnit.Case, async: true

  alias MobCi.Lane.Ios.HostLock

  @moduletag :tmp_dir
  # The lock is macOS's /usr/bin/lockf (the iOS lane's Mac).
  @moduletag skip: not File.exists?("/usr/bin/lockf")

  test "a second holder waits until the first returns", %{tmp_dir: dir} do
    lock = Path.join(dir, "install.lock")
    me = self()

    first =
      Task.async(fn ->
        HostLock.with_lock(lock, fn ->
          send(me, :first_in)
          Process.sleep(500)
          send(me, :first_out)
          :first
        end)
      end)

    assert_receive :first_in, 5_000

    second =
      Task.async(fn ->
        HostLock.with_lock(lock, fn ->
          send(me, :second_in)
          :second
        end)
      end)

    # The second waits for the first, not the other way round.
    assert_receive :first_out, 5_000
    assert_receive :second_in, 5_000
    assert Task.await(first) == :first
    assert Task.await(second) == :second
  end

  test "a holder that dies releases the lock", %{tmp_dir: dir} do
    lock = Path.join(dir, "install.lock")
    me = self()

    holder =
      spawn(fn ->
        HostLock.with_lock(lock, fn ->
          send(me, :held)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :held, 5_000
    Process.exit(holder, :kill)

    assert HostLock.with_lock(lock, fn -> :taken end, 10) == :taken
  end

  test "a lock not freed in time is an error, not a run", %{tmp_dir: dir} do
    lock = Path.join(dir, "install.lock")
    me = self()

    holder =
      spawn(fn ->
        HostLock.with_lock(lock, fn ->
          send(me, :held)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :held, 5_000
    assert {:error, msg} = HostLock.with_lock(lock, fn -> send(me, :ran) end, 1)
    assert msg =~ "not taken"
    refute_received :ran
    Process.exit(holder, :kill)
  end
end
