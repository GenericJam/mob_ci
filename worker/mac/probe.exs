# The device half of an iOS cell, run by MobCi.Lane.Ios.Worker inside the
# generated host project (so it uses the row's own mob_dev and the host's
# mob.exs):
#
#     MIX_ENV=dev mix run --no-start <this file> <udid> <out.json> <timeout_ms>
#
# It records facts and judges nothing: the worker maps them to invariants.
#
#   1. find the device (simulator or physical) by udid;
#   2. grant every permission the activated manifests declare, BEFORE the app
#      is (re)launched (a simulator may terminate an app whose privacy settings
#      change under it; MobDev.Plugin.SelfTest.grant_permissions/4);
#   3. relaunch the app and attach over dist (MobDev.Connector, as
#      `mix mob.selftest` does);
#   4. read Mob.Diag.health/0, run every plugin's self-test
#      (MobDev.Plugin.SelfTest.run_all/3), read health again and compare
#      (MobDev.Smoke.health_findings/2, as `mix mob.smoke` does).
#
# The result is one JSON object written to <out.json>.

[udid, out, timeout] = System.argv()
timeout = String.to_integer(timeout)

alias MobDev.{Connector, Device, Smoke}
alias MobDev.Plugin.SelfTest

rpc_timeout = 10_000

snapshot = fn
  nil ->
    %{health: {:unreachable, "node not reachable"}, beam: {:unreachable, "node not reachable"}}

  node ->
    %{
      health: Smoke.classify_reply(:rpc.call(node, Mob.Diag, :health, [], rpc_timeout)),
      beam: Smoke.classify_reply(:rpc.call(node, :os, :getpid, [], rpc_timeout))
    }
end

result_json = fn
  :pass -> %{status: "pass"}
  {:fail, reason} -> %{status: "fail", reason: to_string(reason)}
  {:skip, reason} -> %{status: "skip", reason: to_string(reason)}
  other -> %{status: "fail", reason: "outside the contract: #{inspect(other)}"}
end

name_of = fn
  name when is_atom(name) -> Atom.to_string(name)
  dir when is_binary(dir) -> Path.basename(dir)
end

write = fn facts ->
  File.write!(out, JSON.encode!(facts))
  IO.puts("probe: wrote #{out}")
end

plugins = MobDev.Plugin.activated_with_verify()
bundle_id = MobDev.Config.ios_bundle_id()

device =
  Mix.Tasks.Mob.Deploy.discover_devices([:ios])
  |> Enum.find(&(&1.serial == udid))

case device do
  nil ->
    write.(%{found: false, node: nil, grants: [], entries: [], findings: []})

  %Device{} = device ->
    grants =
      SelfTest.grant_permissions(device, plugins, bundle_id, fn exe, argv ->
        System.cmd(exe, argv, stderr_to_stdout: true)
      end)

    Enum.each(grants, fn g -> IO.puts("probe: grant #{g.permission} (#{g.plugin}): #{inspect(g.status)}") end)

    {connected, failed} =
      Connector.connect_all(only: [udid], platforms: [:ios], restart: true)

    node =
      case Enum.find(connected, &(&1.serial == udid)) do
        %Device{node: node} -> node
        nil -> nil
      end

    connect_error =
      case Enum.find(failed, &(&1.serial == udid)) do
        %Device{error: e, status: s} -> inspect(e || s)
        nil -> if(node, do: nil, else: "not found when connecting")
      end

    alive = node != nil and :rpc.call(node, :erlang, :node, [], rpc_timeout) == node

    {entries, findings} =
      if alive do
        before = snapshot.(node)
        ctx = %{platform: :ios, device: device.type || :physical}
        entries = SelfTest.run_all(node, ctx, plugins: plugins, timeout_ms: timeout)
        Enum.each(SelfTest.table(entries), &IO.puts("probe:   " <> &1))
        IO.puts("probe:   " <> SelfTest.summary(entries))
        {entries, Smoke.health_findings(before, snapshot.(node))}
      else
        {[], []}
      end

    write.(%{
      found: true,
      device_type: to_string(device.type || :physical),
      node: node && Atom.to_string(node),
      alive: alive,
      connect_error: connect_error,
      grants:
        Enum.map(grants, fn g ->
          %{
            plugin: name_of.(g.plugin),
            permission: g.permission,
            status: if(g.status == :ok, do: "ok", else: inspect(g.status))
          }
        end),
      entries:
        Enum.map(entries, fn e ->
          Map.merge(
            %{plugin: name_of.(e.plugin), module: e.module && inspect(e.module), ms: e.ms},
            result_json.(e.result)
          )
        end),
      findings: Enum.map(findings, fn {kind, msg} -> %{kind: Atom.to_string(kind), message: msg} end)
    })
end
