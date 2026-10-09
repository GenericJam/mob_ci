# discovery — the device_caps baseline run against a real host.
#
# Activates a plugin set on a headless x86_64 ci-redroid, runs the P1–P12
# catalog, and prints per-result detail so `priv/device_caps.exs` is refined to
# what the emulator actually does (never guessed):
#
#   mix run scripts/discovery.exs                      # sloppy_joe host, its buildable deps
#   mix run scripts/discovery.exs --host harness \
#       --plugins mob_midi,mob_nfc,mob_speech          # a --blank harness with these Hex plugins
#
# `--host harness` generates `fixtures/_harness/mob_ci_h_<hash>` with the plugins
# as latest-Hex deps (see Build.plugin_dep/2) — the way to cover plugins
# sloppy_joe does not depend on. Every run tears its ci-redroid down (P11) and
# restores any transient host mutation.

{opts, _, _} = OptionParser.parse(System.argv(), switches: [host: :string, plugins: :string, artifacts: :string])

host = if opts[:host] == "harness", do: :harness, else: :sloppy_joe

set =
  case {host, opts[:plugins]} do
    {_, csv} when is_binary(csv) ->
      csv |> String.split(",", trim: true) |> Enum.map(&String.to_atom(String.trim(&1)))

    {:sloppy_joe, nil} ->
      MobCi.DeviceCaps.buildable(MobCi.Build.sloppy_joe_plugins())

    {:harness, nil} ->
      raise "--host harness needs --plugins a,b,c"
  end

MobCi.Dist.ensure!()
IO.puts("discovery host=#{host} set (#{length(set)} plugins): #{inspect(set)}")

runs = MobCi.Run.run(set, host: host, artifacts_dir: opts[:artifacts] || "artifacts/discovery")

for %{path: path, outcome: outcome} <- runs do
  case outcome do
    {verdict, results} when verdict in [:ok, :fail] ->
      IO.puts("\n=== discovery #{path} verdict: #{verdict} ===")

      for r <- results do
        IO.puts("#{r.id}\t#{r.status}\t#{r.detail}")
        if r.evidence, do: IO.puts("\tevidence: #{inspect(r.evidence, limit: 40)}")
      end

    {:error, reason} ->
      IO.puts("\n=== discovery #{path} ERROR (layer #{inspect(MobCi.Run.error_layer(reason))}): #{inspect(reason)} ===")
  end
end

if MobCi.Run.verdict(runs) == :error, do: System.halt(1)
