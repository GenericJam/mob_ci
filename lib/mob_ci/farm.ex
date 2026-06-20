defmodule MobCi.Farm do
  @moduledoc """
  Layer 0/1: lease a redroid instance for a device run, cooperatively sharing the
  box with the live sloppy_joe staging pool. Drives `priv/ci-farm.sh`, which keeps
  CI containers on a disjoint name + port band from staging and shares the staging
  flock for box-level admission.

  The pure surface — admission parsing, lease-output parsing, node-name derivation
  — is unit-tested; the `lease/1` / `release/1` shell-driving calls are
  `:integration` (they boot a real container).
  """

  @script Path.expand("../../priv/ci-farm.sh", __DIR__)

  defmodule Lease do
    @moduledoc "A leased CI redroid instance."
    @enforce_keys [:index, :serial, :suffix, :dist_port, :node]
    defstruct [:index, :serial, :suffix, :dist_port, :node]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            serial: String.t(),
            suffix: String.t(),
            dist_port: non_neg_integer(),
            node: node()
          }
  end

  @doc "Path to the CI farm driver script."
  def script, do: @script

  @doc """
  The device node name for a host app + node suffix.

  Mob.Dist registers `<app>_android_<suffix>@127.0.0.1` (the suffix comes from the
  `mob_node_suffix` launch intent extra — see `.redroid-farm/farm.sh`). `app` is
  the host project's `:app` (e.g. `:mob_ci_harness` or `:sloppy_joe`).
  """
  @spec node_name(atom() | String.t(), String.t()) :: node()
  def node_name(app, suffix), do: :"#{app}_android_#{suffix}@127.0.0.1"

  @doc "Does the box have headroom for one more container right now?"
  @spec admit?() :: boolean()
  def admit?, do: parse_admit(sh(["admit"]))

  @doc "Parse `ci-farm.sh admit` output (`OK n/c` | `BUSY n/c`) → has-headroom?"
  @spec parse_admit(String.t()) :: boolean()
  def parse_admit(output), do: output |> String.trim() |> String.starts_with?("OK")

  @doc """
  Parse `ci-farm.sh up-auto` stdout (the `KEY=value` result lines) into a map.

  Tolerates the human-readable `>>` progress lines on the same stream.
  """
  @spec parse_lease(String.t()) :: %{optional(atom()) => term()}
  def parse_lease(output) do
    for line <- String.split(output, "\n"),
        [k, v] <- [String.split(String.trim(line), "=", parts: 2)],
        k in ~w(INDEX SERIAL SUFFIX DIST_PORT),
        into: %{} do
      {lease_key(k), lease_val(k, v)}
    end
  end

  defp lease_key("INDEX"), do: :index
  defp lease_key("SERIAL"), do: :serial
  defp lease_key("SUFFIX"), do: :suffix
  defp lease_key("DIST_PORT"), do: :dist_port

  defp lease_val(k, v) when k in ["INDEX", "DIST_PORT"], do: String.to_integer(v)
  defp lease_val(_k, v), do: v

  @doc """
  Lease an instance: boot a base redroid, install `apk`, inject `otp_dir`, launch
  the host app with a CI node suffix, and connect to its node.

  Opts: `:apk` (path), `:otp_dir` (path), `:app` (host `:app` atom), `:suffix_base`
  (default `"ci"`), `:profile` (`{w, h, dpi}`, default a 1080×2340 phone).
  Returns `{:ok, %Lease{}}` or `{:error, reason}` (including `:box_busy` when
  admission refuses — the caller backs off rather than oversubscribing staging).
  """
  @spec lease(keyword()) :: {:ok, Lease.t()} | {:error, term()}
  def lease(opts) do
    apk = Keyword.fetch!(opts, :apk)
    otp = Keyword.fetch!(opts, :otp_dir)
    app = Keyword.fetch!(opts, :app)
    base = Keyword.get(opts, :suffix_base, "ci")
    {w, h, dpi} = Keyword.get(opts, :profile, {1080, 2340, 440})

    if admit?() do
      case sh_status(["up-auto", apk, otp, base, to_string(w), to_string(h), to_string(dpi)]) do
        {out, 0} ->
          fields = parse_lease(out)
          lease = struct!(Lease, Map.put(fields, :node, node_name(app, fields.suffix)))
          if Node.connect(lease.node), do: {:ok, lease}, else: {:ok, lease}

        {out, 4} ->
          _ = out
          {:error, :box_busy}

        {out, code} ->
          {:error, {:lease_failed, code, String.slice(out, -400, 400)}}
      end
    else
      {:error, :box_busy}
    end
  end

  @doc "Release a leased instance (removes the container, frees the slot)."
  @spec release(Lease.t() | non_neg_integer()) :: :ok
  def release(%Lease{index: i}), do: release(i)
  def release(index) when is_integer(index), do: (sh(["down", to_string(index)]); :ok)

  # ── shell plumbing ──────────────────────────────────────────────────────────

  defp sh(args), do: elem(sh_status(args), 0)

  defp sh_status(args) do
    {out, code} = System.cmd("bash", [@script | args], stderr_to_stdout: true)
    {out, code}
  rescue
    e -> {Exception.message(e), 127}
  end
end
