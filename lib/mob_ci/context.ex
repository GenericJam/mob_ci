defmodule MobCi.Context do
  @moduledoc """
  Everything one invariant run needs, assembled by the orchestrator across the
  layers: the activated plugin set, the build outcome (L2), the leased device
  (L1), and the per-plugin device metadata that can't be derived from a manifest
  alone (NIF probe exports, expected migration tables, host repo module).

  Invariants read this struct and never reach back into the farm or build layers
  directly — which is what lets the pure invariants (P1, P6) run in a unit test
  against a hand-built `%Context{}` with no device at all.
  """

  @enforce_keys [:set, :host]
  defstruct set: [],
            host: :harness,
            node: nil,
            repo: nil,
            build: %{status: :unknown, apk: nil, permissions: nil, conflicts: []},
            # nif module atom → {probe_fun, args} — a side-effect-free export used
            # to prove the NIF actually initialized on device (P3). The tier-1
            # scaffold ships `ping/0`.
            nif_probes: %{},
            # tier-3 plugin → list of table names its migrations create (P8).
            migration_tables: %{},
            # plugin → worker process name expected alive (P9). Defaults to the
            # supervised child module from the manifest; override when a worker
            # registers under a different name.
            worker_names: %{},
            # a generated screen embedding every activated component, for P5.
            showcase_screen: nil,
            artifacts_dir: nil

  @type build_status :: :unknown | :ok | {:conflict, [String.t()]} | {:error, term()}
  @type t :: %__MODULE__{
          set: [atom()],
          host: :harness | :sloppy_joe,
          node: node() | nil,
          repo: module() | nil,
          build: %{
            status: build_status(),
            apk: Path.t() | nil,
            permissions: MapSet.t(String.t()) | nil,
            conflicts: [String.t()]
          },
          nif_probes: %{atom() => {atom(), [term()]}},
          migration_tables: %{atom() => [String.t()]},
          worker_names: %{atom() => atom()},
          showcase_screen: module() | nil,
          artifacts_dir: Path.t() | nil
        }

  @doc "NIF probe MFAs for the milestone-1 sample set (all ship the tier-1 `ping/0`)."
  def default_nif_probes, do: %{mob_ci_haptic_nif: {:ping, []}}

  @doc "Migration tables the sample set's tier-3 plugin creates."
  def default_migration_tables, do: %{mob_ci_notes: ["mob_ci_notes_items"]}

  @doc "Supervised worker names the sample set's tier-4 plugin registers."
  def default_worker_names, do: %{mob_ci_pulse: MobCiPulse.Worker}
end
