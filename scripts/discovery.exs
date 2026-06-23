# discovery — the device_caps baseline run against the REAL sloppy_joe app.
#
# Activates the full buildable sloppy_joe plugin set (everything in its mix.exs
# deps except mob_screencast, which has a hard host_requirement) on a headless
# x86_64 ci-redroid, runs the P1–P11 catalog, and prints per-result status so the
# `priv/device_caps.exs` `screen:` expectations (currently HYPOTHESES) can be
# refined to what the emulator actually does.
#
# Run from ~/code/mob_ci as a DISTRIBUTED node (~8min build):
#
#   cp ~/code/sloppy_joe/mob.exs /tmp/sj.bak   # belt-and-suspenders; run also restores it
#   elixir --name disco@127.0.0.1 --cookie mob_secret -S mix run scripts/discovery.exs
#
# The run swaps sloppy_joe's gitignored mob.exs transiently and restores it via a
# guaranteed cleanup; the ci-redroid is torn down by P11.

set = MobCi.DeviceCaps.buildable(MobCi.Build.sloppy_joe_plugins())

IO.puts("discovery set (#{length(set)} plugins): #{inspect(set)}")

case MobCi.Run.run(set, host: :sloppy_joe, artifacts_dir: "artifacts/discovery") do
  {verdict, results} when verdict in [:ok, :fail] ->
    IO.puts("\n=== discovery verdict: #{verdict} ===")

    for r <- results do
      IO.puts("#{r.id}\t#{r.status}\t#{r.detail}")
    end

  {:error, reason} ->
    IO.puts("\n=== discovery ERROR: #{inspect(reason)} ===")
    System.halt(1)
end
