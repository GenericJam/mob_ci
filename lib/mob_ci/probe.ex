defmodule MobCi.Probe do
  @moduledoc """
  Thin device-side RPC surface: everything the invariants need to read or drive
  on a booted mob app, over Erlang distribution. Wraps `Mob.Plugins` (the
  on-device runtime-manifest authority) and `Mob.Test` (BEAM-state driving).

  Every call returns `{:ok, value}` or `{:error, reason}` — a dead node, a
  `:badrpc`, or an exception on the device side becomes a tagged error, never a
  raise, so an invariant can turn it into a `:fail`/`:error` result rather than
  crashing the whole run.

  The exact MFAs here are the load-bearing contract with the mob runtime; they
  were read off `mob/lib/mob/plugins.ex` and `mob/lib/mob/test.ex`. The
  `:integration`-tagged suites are what verify them against a live node.
  """

  @rpc_timeout 15_000

  @doc "Connect to a device node (idempotent). Returns whether it's reachable."
  @spec connect(node()) :: boolean()
  def connect(node), do: Node.connect(node) == true

  @doc "Is the node currently reachable over distribution? (P2)"
  @spec node_up?(node()) :: boolean()
  def node_up?(node), do: node in Node.list() or connect(node)

  @doc "Raw RPC, normalized to `{:ok, value} | {:error, reason}`."
  @spec call(node(), module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def call(node, mod, fun, args) do
    case :rpc.call(node, mod, fun, args, @rpc_timeout) do
      {:badrpc, reason} -> {:error, {:badrpc, reason}}
      value -> {:ok, value}
    end
  end

  @doc "Is a module loaded on the device? (the cheap half of P3)"
  @spec module_loaded?(node(), module()) :: boolean()
  def module_loaded?(node, mod) do
    match?({:ok, true}, call(node, Code, :ensure_loaded?, [mod]))
  end

  @doc """
  Did a NIF actually initialize on device (not just its stub module load)?

  A NIF stub loads even when the native code isn't linked — its functions then
  raise `nif_not_loaded`. So the real check is to invoke the NIF's probe export
  and confirm it does *not* raise that. `probe_mfa` is `{fun, args}` for a
  side-effect-free export the plugin guarantees (the tier-1 scaffold ships
  `ping/0`). Returns `:loaded`, `:not_loaded`, `:no_export` (the module loaded
  but this version doesn't export the probe: `device_caps.exs` names the
  newest release's read-only export, which an older locked release may
  predate), or `{:error, reason}`. (P3)
  """
  @spec nif_initialized?(node(), atom(), {atom(), [term()]}) ::
          :loaded | :not_loaded | :no_export | {:error, term()}
  def nif_initialized?(node, nif_module, {fun, args}) do
    case call(node, nif_module, fun, args) do
      {:ok, _value} -> :loaded
      {:error, {:badrpc, {:EXIT, {:nif_not_loaded, _}}}} -> :not_loaded
      {:error, {:badrpc, {:EXIT, {%ErlangError{original: :nif_not_loaded}, _}}}} -> :not_loaded
      {:error, {:badrpc, {:EXIT, {:undef, [{^nif_module, ^fun, _, _} | _]}}}} -> :no_export
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The on-device runtime plugin manifest (`Mob.Plugins.manifest/0`). (P7)"
  @spec runtime_manifest(node()) :: {:ok, map()} | {:error, term()}
  def runtime_manifest(node), do: call(node, Mob.Plugins, :manifest, [])

  @doc "Screen routes the device's runtime manifest knows about. (P4/P7)"
  @spec runtime_screens(node()) :: {:ok, term()} | {:error, term()}
  def runtime_screens(node), do: call(node, Mob.Plugins, :screens, [])

  @doc "Push a screen module and read back what's showing (P4/P5)."
  @spec push_and_read(node(), module(), map()) ::
          {:ok, %{screen: module(), assigns: map()}} | {:error, term()}
  def push_and_read(node, screen_module, params \\ %{}) do
    with {:ok, _} <- call(node, Mob.Test, :navigate, [node, screen_module, params]),
         {:ok, current} <- call(node, Mob.Test, :screen, [node]),
         {:ok, assigns} <- call(node, Mob.Test, :assigns, [node]) do
      {:ok, %{screen: current, assigns: assigns}}
    end
  end

  @doc "Read a per-plugin setting on device (`Mob.Plugins.get_setting/2`). (P9)"
  @spec get_setting(node(), atom(), atom()) :: {:ok, term()} | {:error, term()}
  def get_setting(node, plugin, key), do: call(node, Mob.Plugins, :get_setting, [plugin, key])

  @doc "Is a named process (e.g. a supervised plugin worker) alive on device? (P9)"
  @spec process_alive?(node(), atom()) :: boolean()
  def process_alive?(node, name) do
    match?({:ok, pid} when is_pid(pid), call(node, Process, :whereis, [name]))
  end

  @doc """
  Does a table exist in the device app's SQLite DB? (P8)

  `repo` is the host app's Ecto repo module. Runs a `sqlite_master` lookup over
  RPC — a plain map/string round-trips across the dist boundary (unlike an
  `%Ecto.Query.t/0` result with structs, which can carry opaque refs).
  """
  @spec table_exists?(node(), module(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def table_exists?(node, repo, table) do
    sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?1"

    case call(node, repo, :query, [sql, [table]]) do
      {:ok, {:ok, %{rows: rows}}} -> {:ok, rows != []}
      {:ok, {:ok, %{num_rows: n}}} -> {:ok, n > 0}
      {:ok, other} -> {:error, {:unexpected_query_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Capture a screenshot artifact on failure (best-effort, never raises)."
  @spec screenshot(node()) :: {:ok, binary()} | {:error, term()}
  def screenshot(node), do: call(node, Mob.Test, :screenshot, [node])
end
