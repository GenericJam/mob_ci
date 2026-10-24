defmodule MobCi.Lane.Ios.HostLock do
  @moduledoc """
  A lock every process on the Mac shares, held only while a function runs.

  The iPhone install cache (`MobCi.Lane.Ios.Worker.install_cache_copies/3`)
  is one directory per bundle id for the whole Mac, whichever iPhone a cell
  leased, and a hand-run cell (`mix ci.ios_cell --device-udid …`) is not
  serialized with the queue's. So an iPhone cell's install and its teardown's
  cache cleanup take this lock: cleanup never runs while another install is
  reading or writing a copy.

  It is the kernel's `flock` through macOS's `/usr/bin/lockf`, held by a
  `lockf … /bin/sh -c 'echo locked; read _'` port: the lock is released when
  the function returns (the port closes, `read` sees EOF) or when this BEAM
  dies (the kernel drops it), so a crashed worker never leaves it stuck.
  """

  @lockf "/usr/bin/lockf"

  @doc """
  Run `fun` holding the lock file `path`, waiting up to `timeout_s` for it.
  Returns `fun`'s result, or `{:error, reason}` when the lock is not taken.
  """
  @spec with_lock(Path.t(), (-> result), pos_integer()) :: result | {:error, String.t()} when result: term()
  def with_lock(path, fun, timeout_s \\ 3600) do
    File.mkdir_p!(Path.dirname(path))

    port =
      Port.open({:spawn_executable, @lockf}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-k", "-t", Integer.to_string(timeout_s), path, "/bin/sh", "-c", "echo locked; read _"]
      ])

    receive do
      {^port, {:data, "locked" <> _}} ->
        try do
          fun.()
        after
          close(port)
        end

      {^port, {:exit_status, code}} ->
        {:error, "lock #{path} not taken (lockf exited #{code})"}
    after
      (timeout_s + 10) * 1000 ->
        close(port)
        {:error, "lock #{path} not taken in #{timeout_s} s"}
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
