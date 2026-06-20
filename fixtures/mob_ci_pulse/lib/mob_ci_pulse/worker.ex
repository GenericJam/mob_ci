defmodule MobCiPulse.Worker do
  @moduledoc "Supervised background worker for the tier-4 plugin."
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok), do: {:ok, %{}}
end
