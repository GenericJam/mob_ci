defmodule MobCi.Dist do
  @moduledoc """
  Bring the current BEAM up as a distributed node so the host can reach a device
  node over Erlang distribution.

  The device runs (`MobCi.Run`/`MobCi.Sweep`) connect to the on-device node by
  name, which requires the host BEAM to be alive with the shared cookie. When a
  run is launched via `elixir --name … --cookie …` that is already true; when it
  is launched as a plain `mix ci.device`, it is not. `ensure!/1` makes either
  path work: it is a no-op when distribution is already up, and otherwise starts
  EPMD + `net_kernel` and sets the cookie.
  """

  @cookie :mob_secret

  @doc """
  The host node name for this OS process: `mob_ci_<os pid>@127.0.0.1`. Two
  runs on the same box (a realism gate next to a harness run) must not fight
  over one fixed name, and the device never needs to know ours.
  """
  @spec default_name() :: node()
  def default_name, do: :"mob_ci_#{System.pid()}@127.0.0.1"

  @doc """
  Ensure the node is distributed with the `mob_secret` cookie. Idempotent.
  Starts EPMD and `net_kernel` under `name` only if not already alive; always
  (re)asserts the cookie. Raises if distribution cannot be started.
  """
  @spec ensure!(node()) :: :ok
  def ensure!(name \\ default_name()) do
    _ = System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)

    unless Node.alive?() do
      case :net_kernel.start([name, :longnames]) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "could not start distribution as #{name}: #{inspect(reason)}"
      end
    end

    Node.set_cookie(@cookie)
    :ok
  end
end
