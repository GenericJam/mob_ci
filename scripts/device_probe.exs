# Drive the device invariants (P2–P10) against an already-launched harness node.
#
# Run from ~/code/mob_ci as a DISTRIBUTED node so it can reach the device:
#
#   elixir --name ci_probe@127.0.0.1 --cookie mob_secret -S mix run \
#     scripts/device_probe.exs mob_ci_harness_android_ci0@127.0.0.1
#
# Assumes the app is launched with the CI node suffix + dist-port intent extras
# and the adb tunnels are up (reverse 4369, forward <dist_port>). P1/P6 (build
# layer) and P11 (post-release) are driven by MobCi.Run in the full pipeline;
# this script is the device-layer slice for the first manual run.

alias MobCi.{Context, Invariants, Report}

[node_str | _] = System.argv()
node = String.to_atom(node_str)

IO.puts("connecting to #{node} ...")
connected = Node.connect(node)
IO.puts("Node.connect → #{inspect(connected)}; Node.list → #{inspect(Node.list())}")

ctx = %Context{
  set: MobCi.Plugins.sample_set(),
  host: :harness,
  node: node,
  repo: MobCiHarness.Repo,
  build: %{status: :ok, apk: nil, permissions: nil, conflicts: []},
  nif_probes: Context.default_nif_probes(),
  migration_tables: Context.default_migration_tables(),
  worker_names: Context.default_worker_names()
}

results = Invariants.run(ctx, [:device])
IO.puts("\n" <> Report.console(results, title: "device probe #{node_str}"))
File.mkdir_p!("artifacts")
File.write!("artifacts/device_probe.xml", Report.junit(results, suite: "mob_ci.device_probe"))
IO.puts("\nwrote artifacts/device_probe.xml")
