defmodule MobCi.Farm do
  @moduledoc """
  Layer 0/1: boot a redroid instance for a device run and launch the deployed app
  with a CI node identity, cooperatively sharing the box with the live sloppy_joe
  staging pool. Drives `priv/ci-farm.sh` (disjoint name + port band from staging,
  shared flock for box-level admission).

  Flow: `boot/1` (base redroid + adb connect) → caller runs
  `mix mob.deploy --native --device <serial>` (MobCi.Build) → `launch/2`
  (tunnels + relaunch with the CI node suffix/dist-port) → `await_node/2` →
  probe → `release/1`. The pure surface (node naming, port/suffix derivation,
  output parsing, admission parsing) is unit-tested; the shell-driving calls are
  `:integration`.
  """

  @script Path.expand("../../priv/ci-farm.sh", __DIR__)

  defmodule Instance do
    @moduledoc "A booted CI redroid instance (before/after the app is launched)."
    @enforce_keys [:index, :serial, :suffix, :dist_port]
    defstruct [:index, :serial, :suffix, :dist_port, :node]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            serial: String.t(),
            suffix: String.t(),
            dist_port: non_neg_integer(),
            node: node() | nil
          }
  end

  @doc "Path to the CI farm driver script."
  def script, do: @script

  @doc "Dist port for a CI instance index (CI band, disjoint from staging's 9101+)."
  @spec dist_port(non_neg_integer()) :: non_neg_integer()
  def dist_port(index), do: 9300 + index

  @doc "Node suffix for a CI instance index."
  @spec suffix(non_neg_integer()) :: String.t()
  def suffix(index), do: "ci#{index}"

  @doc """
  The device node name for a host app + suffix. Mob.Dist registers
  `<app>_android_<suffix>@127.0.0.1` (suffix from the `mob_node_suffix` intent).
  """
  @spec node_name(atom() | String.t(), String.t()) :: node()
  def node_name(app, suffix), do: :"#{app}_android_#{suffix}@127.0.0.1"

  @doc "Does the box have headroom for one more container right now?"
  @spec admit?() :: boolean()
  def admit?, do: parse_admit(sh(["admit"]))

  @doc "Parse `ci-farm.sh admit` output (`OK n/c` | `BUSY n/c`) → has-headroom?"
  @spec parse_admit(String.t()) :: boolean()
  def parse_admit(output), do: output |> String.trim() |> String.starts_with?("OK")

  @doc "Parse `KEY=value` result lines (INDEX/SERIAL) out of script stdout."
  @spec parse_kv(String.t(), [String.t()]) :: %{optional(atom()) => term()}
  def parse_kv(output, keys) do
    for line <- String.split(output, "\n"),
        [k, v] <- [String.split(String.trim(line), "=", parts: 2)],
        k in keys,
        into: %{} do
      {kv_key(k), kv_val(k, v)}
    end
  end

  defp kv_key("INDEX"), do: :index
  defp kv_key("SERIAL"), do: :serial
  defp kv_val("INDEX", v), do: String.to_integer(v)
  defp kv_val(_k, v), do: v

  @doc """
  Boot a base redroid (admission-gated) and adb-connect it. Returns an
  `%Instance{}` with no node yet — the app isn't deployed/launched until `launch/2`.
  `{:error, :box_busy}` when admission refuses (caller backs off).
  """
  @spec boot(keyword()) :: {:ok, Instance.t()} | {:error, term()}
  def boot(opts \\ []) do
    {w, h, dpi} = Keyword.get(opts, :profile, {1080, 2340, 440})

    if admit?() do
      case sh_status(["boot", to_string(w), to_string(h), to_string(dpi)]) do
        {out, 0} ->
          %{index: i, serial: ser} = parse_kv(out, ["INDEX", "SERIAL"])
          {:ok, %Instance{index: i, serial: ser, suffix: suffix(i), dist_port: dist_port(i)}}

        {_out, 4} ->
          {:error, :box_busy}

        {out, code} ->
          {:error, {:boot_failed, code, String.slice(out, -400, 400)}}
      end
    else
      {:error, :box_busy}
    end
  end

  @doc """
  Launch the deployed app on `instance` with the CI node identity (tunnels +
  relaunch), then wait for its node to register. `app` is the host `:app`, `pkg`
  the Android package. The node is dialled with `:cookies` (default
  `dist_cookies(pkg)`: the project's mob_dev-managed private cookie, then the
  legacy `:mob_secret`). Returns the instance with `:node` populated.
  """
  @spec launch(Instance.t(), keyword()) :: {:ok, Instance.t()} | {:error, term()}
  def launch(%Instance{} = inst, opts) do
    app = Keyword.fetch!(opts, :app)
    pkg = Keyword.fetch!(opts, :pkg)
    node = node_name(app, inst.suffix)
    cookies = Keyword.get_lazy(opts, :cookies, fn -> dist_cookies(pkg) end)

    case sh_status(["launch", to_string(inst.index), inst.suffix, to_string(inst.dist_port), pkg]) do
      {_out, 0} ->
        if await_node(node, Keyword.get(opts, :timeout_ms, 60_000), cookies),
          do: {:ok, %{inst | node: node}},
          else: {:error, {:node_never_registered, node}}

      {out, code} ->
        {:error, {:launch_failed, code, String.slice(out, -400, 400)}}
    end
  end

  @doc """
  The cookies a deployed app may answer to, most likely first: the private
  per-project cookie mob_dev writes at deploy (`~/.mob/dist_cookies/<sha256 of
  the bundle id>`, MOB-49 — the bundle id is the Android package for both
  hosts), then the public legacy `:mob_secret` of pre-MOB-49 apps.
  """
  @spec dist_cookies(String.t()) :: [atom(), ...]
  def dist_cookies(pkg) do
    managed = pkg |> MobDev.DistCookie.default_path() |> MobDev.DistCookie.load_or_create!()
    Enum.uniq([managed, MobDev.DistCookie.legacy_cookie()])
  end

  @doc "Poll until `node` accepts one of `cookies` over distribution, or the timeout elapses."
  @spec await_node(node(), non_neg_integer(), [atom(), ...]) :: boolean()
  def await_node(node, timeout_ms, cookies \\ [MobDev.DistCookie.legacy_cookie()]) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(node, cookies, deadline)
  end

  defp do_await(node, cookies, deadline) do
    cond do
      # Per-node cookies need a distributed host (`MobCi.Dist.ensure!/1`); without
      # one no cookie can be tried, so don't spin until the deadline.
      not Node.alive?() -> false
      match?({:ok, _}, MobDev.DistCookie.connect(node, cookies)) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(2_000); do_await(node, cookies, deadline)
    end
  end

  @doc "Release an instance (removes the container, frees the slot)."
  @spec release(Instance.t() | non_neg_integer()) :: :ok
  def release(%Instance{index: i}), do: release(i)
  def release(index) when is_integer(index), do: (sh(["down", to_string(index)]); :ok)

  # ── shell plumbing ──────────────────────────────────────────────────────────

  defp sh(args), do: elem(sh_status(args), 0)

  defp sh_status(args) do
    System.cmd("bash", [@script | args], stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 127}
  end
end
