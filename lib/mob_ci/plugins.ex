defmodule MobCi.Plugins do
  @moduledoc """
  The plugin registry the invariants reason about: where the sample plugins
  live, how to read a manifest, and the pure "expected" projections derived
  from a set of activated manifests (permission union, screen routes, NIF
  modules, components, supervised workers, …).

  These projections are the left-hand side of the device invariants: P6 asserts
  the built APK's permissions equal `expected_permissions/1`; P7 asserts the
  on-device `Mob.Plugins` view equals `expected_screens/1` ∪ the other
  runtime-manifest contributions; etc. Keeping them pure (manifest map in,
  value out) makes the invariant logic unit-testable with no device.
  """

  # fixtures/ lives at the repo root (not under priv/). Resolve relative to this
  # source file so it works whether mob_ci runs from its own dir or as a path dep.
  @fixtures_dir Path.expand("../../fixtures", __DIR__)
  # Real (published) plugins live as sibling repos under ~/code/<name> — the
  # realism gate (sloppy_joe host) reasons about these, not the fixtures.
  @ecosystem_dir Path.expand("../..", @fixtures_dir)

  @doc """
  The fixed sample set milestone 1 runs the full P1–P11 catalog against.

  Chosen to be hardware-free (boots clean on a headless x86_64 redroid) while
  touching every capability kind: a NIF (P3), a UI component (P5), screens +
  migration (P4/P7/P8), and a tier-4 sub-app with a supervised worker +
  settings + notifications (P9). The tier-0 plugin (`mob_ci_palette`) carries no
  manifest and contributes nothing — it's the "activation is a no-op" control.
  """
  @spec sample_set() :: [atom()]
  def sample_set,
    do: [:mob_ci_palette, :mob_ci_haptic, :mob_ci_gauge, :mob_ci_notes, :mob_ci_pulse]

  @doc """
  Absolute path to a plugin's root directory. A mob_ci fixture under `fixtures/`
  wins; otherwise it falls back to the sibling ecosystem repo `~/code/<name>` (so
  the realism gate can read real plugins like `mob_camera`).
  """
  @spec fixture_dir(atom()) :: Path.t()
  def fixture_dir(name) when is_atom(name) do
    fixture = Path.join(@fixtures_dir, Atom.to_string(name))

    cond do
      File.dir?(fixture) -> fixture
      dir = Map.get(resolved_dirs(), name) -> dir
      true -> Path.join(@ecosystem_dir, Atom.to_string(name))
    end
  end

  @doc """
  Point manifest lookup for real plugins at the version row's checkouts /
  unpacked tarballs (`MobCi.Versions.source_dirs/1`) for the rest of this VM,
  so projections reflect the pinned version rather than whatever sibling
  checkout `~/code` holds. Fixtures still win.
  """
  @spec put_resolved_dirs(%{atom() => Path.t()}) :: :ok
  def put_resolved_dirs(dirs), do: Application.put_env(:mob_ci, :plugin_dirs, dirs)

  @doc "The resolved plugin dirs set by `put_resolved_dirs/1` (empty by default)."
  @spec resolved_dirs() :: %{atom() => Path.t()}
  def resolved_dirs, do: Application.get_env(:mob_ci, :plugin_dirs, %{})

  @doc "Path to a fixture plugin's manifest (may not exist for tier-0 plugins)."
  @spec manifest_path(atom()) :: Path.t()
  def manifest_path(name), do: Path.join(fixture_dir(name), "priv/mob_plugin.exs")

  @doc """
  Loads a plugin's manifest map, or `nil` for a tier-0 plugin with no manifest.

  Tier-0 plugins legitimately ship no `priv/mob_plugin.exs`; that's `nil`, not an
  error (they contribute nothing to any shared namespace).
  """
  @spec load_manifest(atom()) :: map() | nil
  def load_manifest(name) do
    path = manifest_path(name)

    if File.exists?(path) do
      {manifest, _bindings} = Code.eval_file(path)
      manifest
    end
  end

  @doc """
  Loads `{name, manifest}` pairs for a set — the exact shape
  `MobDev.Plugin.Validator.cross_validate/1` expects (tier-0 → `nil` manifest).
  """
  @spec activated(Enumerable.t()) :: [{atom(), map() | nil}]
  def activated(names), do: for(name <- names, do: {name, load_manifest(name)})

  # ── pure projections over a set's manifests (invariant left-hand sides) ──────

  @doc "Set-union of declared Android permissions across the activated set (P6)."
  @spec expected_permissions(Enumerable.t()) :: MapSet.t(String.t())
  def expected_permissions(names) do
    for {_n, m} <- activated(names),
        is_map(m),
        perm <- get_in(m, [:android, :permissions]) || [],
        into: MapSet.new(),
        do: perm
  end

  @doc "All screen routes the activated set declares statically (P4/P7)."
  @spec expected_screens(Enumerable.t()) :: [String.t()]
  def expected_screens(names) do
    for {_n, m} <- activated(names),
        is_map(m),
        s <- Map.get(m, :screens, []),
        is_map(s),
        route = s[:default_route],
        is_binary(route),
        do: route
  end

  @doc "Screen modules the activated set declares (for push+render in P4)."
  @spec expected_screen_modules(Enumerable.t()) :: [module()]
  def expected_screen_modules(names) do
    for {_n, m} <- activated(names),
        is_map(m),
        s <- Map.get(m, :screens, []),
        is_map(s),
        mod = s[:module],
        is_atom(mod),
        do: mod
  end

  @doc "Erlang NIF module atoms the activated set contributes (P3)."
  @spec expected_nif_modules(Enumerable.t()) :: [atom()]
  def expected_nif_modules(names) do
    for {_n, m} <- activated(names),
        is_map(m),
        nif <- Map.get(m, :nifs, []),
        is_map(nif),
        mod = nif[:module],
        is_atom(mod),
        uniq: true,
        do: mod
  end

  @doc "UI component atoms the activated set contributes (P5)."
  @spec expected_components(Enumerable.t()) :: [atom()]
  def expected_components(names) do
    for {_n, m} <- activated(names),
        is_map(m),
        c <- Map.get(m, :ui_components, []),
        is_map(c),
        atom = c[:atom],
        is_atom(atom),
        do: atom
  end

  @doc "Migration repo namespaces the activated set contributes (P8)."
  @spec expected_migration_namespaces(Enumerable.t()) :: [String.t()]
  def expected_migration_namespaces(names) do
    for {_n, m} <- activated(names),
        is_map(m),
        ns = get_in(m, [:migrations, :repo_namespace]),
        is_binary(ns),
        do: ns
  end

  @doc "Supervised worker ids the activated set contributes (P9)."
  @spec expected_supervised(Enumerable.t()) :: [term()]
  def expected_supervised(names) do
    for {_n, m} <- activated(names),
        is_map(m),
        child <- get_in(m, [:lifecycle, :supervised]) || [],
        do: worker_id(child)
  end

  defp worker_id(mod) when is_atom(mod), do: mod
  defp worker_id({mod, _arg}) when is_atom(mod), do: mod
  defp worker_id(%{id: id}), do: id
  defp worker_id(other), do: other
end
