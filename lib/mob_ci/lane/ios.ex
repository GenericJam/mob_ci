defmodule MobCi.Lane.Ios do
  @moduledoc """
  The iOS lane, NUC side. iOS builds cannot leave the Mac mini, so the NUC
  plans the cell (`MobCi.Cell.plan/3`: set, version row resolved to exact
  pins), runs the static gate, and hands each path to the Mac over ssh as a
  `MobCi.Lane.Ios.Spec`; `MobCi.Lane.Ios.Worker` runs it there and prints its
  result as one `#{"MOB_CI_RESULT"} <json>` line.

      mix ci.device --platform ios --set default --versions hex
      mix ci.device --platform ios --set singleton:mob_camera --versions master \\
        --paths deploy:ios_sim,release:ios

  Per run:

    1. **sync** — one ssh session runs `worker/mac/sync.sh` (shipped inline,
       base64 on the command line) on the Mac: clone or fetch the worker's own
       checkouts under `~/.cache/mob_ci/worker/` and check out the NUC's
       mob_ci sha (which must be pushed), mob_dev at its default branch.
    2. **cells** — one ssh session per path runs
       `worker/mac/mob_ci_ios_cell.sh --spec-b64 <spec>`. The whole session is
       streamed to `~/mob_ci_logs/ios/<cell_id>.log`; the result line is taken
       from it and written beside it as `<cell_id>.json`.

  A session that ends without a result line (ssh refused, the worker died) is
  an `error` cell at layer `error:ssh` with the exit code and the log tail. A
  set the static gate rejects is an `error` at `static` for every path,
  without an ssh hop.

  The transport is `opts[:ssh]` (`(argv, log_path) -> exit_code`), so
  everything here is tested without ssh.
  """

  alias MobCi.{Cell, Invariants, Plugins, Result, Store}
  alias MobCi.Lane.Ios.{Spec, Tee}
  alias MobDev.Plugin.Validator

  @marker "MOB_CI_RESULT "
  @default_host "kevin@10.0.0.71"
  @worker_root "$HOME/.cache/mob_ci/worker"
  @sync_script Path.expand("../../../worker/mac/sync.sh", __DIR__)
  @external_resource @sync_script

  # Kevin's iPhone SE. Simulators are picked on the Mac (newest runtime at or
  # above the spec's min_runtime that can be leased) unless one is named.
  @default_device "00008110-001E1C3A34F8401E"

  @doc "The line prefix the worker prints its result JSON after."
  def marker, do: @marker

  @doc "The Mac the lane runs on (`MOB_CI_IOS_HOST` overrides)."
  def default_host, do: System.get_env("MOB_CI_IOS_HOST", @default_host)

  @doc "Where the NUC keeps iOS logs and result files."
  def default_log_dir, do: Path.expand("~/mob_ci_logs/ios")

  @doc "The udid a path runs on unless told otherwise (`nil`: the worker picks a simulator)."
  @spec default_udid(Spec.path()) :: String.t() | nil
  def default_udid("deploy:ios_device"), do: @default_device
  def default_udid(_), do: nil

  @doc "The udid for `path` given `opts[:sim_udid]` / `opts[:device_udid]`."
  @spec udid_for(Spec.path(), keyword()) :: String.t() | nil
  def udid_for("deploy:ios_sim", opts), do: opts[:sim_udid]
  def udid_for("deploy:ios_device", opts), do: opts[:device_udid] || default_udid("deploy:ios_device")
  def udid_for(_release, _opts), do: nil

  # ── commands (pure) ──────────────────────────────────────────────────────────

  @doc "ssh argv for one remote command: key auth only, fail fast on connect, keepalive for long builds."
  @spec ssh_argv(String.t(), String.t()) :: [String.t()]
  def ssh_argv(host, command) do
    [
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=15",
      "-o",
      "ServerAliveInterval=30",
      "-o",
      "ServerAliveCountMax=10",
      host,
      command
    ]
  end

  @doc """
  The remote command that syncs the worker checkouts to `sha`: the sync
  script travels base64-encoded on the command line, so the Mac needs nothing
  installed beforehand and no remote quoting is involved.
  """
  @spec sync_command(String.t(), String.t()) :: String.t()
  def sync_command(sha, script \\ File.read!(@sync_script)) do
    unless sha =~ ~r/^[0-9a-f]{7,40}$/, do: raise(ArgumentError, "not a sha: #{inspect(sha)}")
    "echo #{Base.encode64(script)} | base64 -d | bash -s -- #{sha}"
  end

  @doc "The remote command that runs one cell from its spec (base64 JSON argument)."
  @spec cell_command(Spec.t()) :: String.t()
  def cell_command(%Spec{} = spec) do
    "\"#{@worker_root}/mob_ci/worker/mac/mob_ci_ios_cell.sh\" --spec-b64 " <>
      Base.encode64(Spec.to_json(spec))
  end

  # ── results (pure) ───────────────────────────────────────────────────────────

  @doc "The last result line in a session log, decoded."
  @spec parse_log(String.t()) :: {:ok, map()} | :none
  def parse_log(log) do
    log
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(:none, fn line ->
      with @marker <> json <- String.trim_leading(line),
           {:ok, %{"schema" => 1} = result} <- JSON.decode(String.trim(json)) do
        {:ok, result}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  A session's result: the worker's, or — when the session ended without one —
  an `error` at layer `error:ssh` carrying the exit code and the log tail.
  """
  @spec collect(Spec.t(), non_neg_integer(), String.t()) :: map()
  def collect(%Spec{} = spec, exit_code, log) do
    case parse_log(log) do
      {:ok, result} ->
        result

      :none ->
        tail = log |> String.slice(-1_500, 1_500) |> String.trim()

        error_result(
          spec,
          "error:ssh",
          "ssh session exited #{exit_code} without a result#{if tail != "", do: ": " <> tail, else: ""}"
        )
    end
  end

  @doc "A result for a cell that never reached (or never came back from) the worker."
  @spec error_result(Spec.t(), String.t(), String.t()) :: map()
  def error_result(%Spec{} = spec, layer, reason) do
    %{
      "schema" => 1,
      "cell_id" => spec.cell_id,
      "set" => spec.set,
      "plugins" => Enum.map(spec.plugins, &to_string/1),
      "platform" => "ios",
      "path" => spec.path,
      "udid" => spec.udid,
      "versions" => spec.versions,
      "mob_ci_sha" => spec.mob_ci_sha,
      "outcome" => "error",
      "layer" => layer,
      "reason" => reason,
      "steps" => [],
      "invariants" => [],
      "artifacts" => %{},
      "teardown" => [],
      "disk" => %{},
      "duration_ms" => 0
    }
  end

  @doc """
  A worker result as the outcome the results store records
  (`MobCi.Store.record_results/4`'s last argument):

    * a step that failed or errored (generate, doctor, build, …) →
      `{:error, reason, layer}`: the cell did not get as far as its invariants;
    * a skipped cell (`device_absent`) → `{:ok, [skip p2]}`;
    * a release → `{:ok, [pass ipa]}` with the archive's name, size and sha256;
    * a device run → `{:ok | :fail, results}`: `p2`, `p12` (one item per
      plugin under `evidence.items`, titled with the plugin) and `health`.
  """
  @spec to_outcome(map()) :: {:ok | :fail, [Result.t()]} | {:error, String.t(), String.t()}
  def to_outcome(%{"outcome" => outcome, "invariants" => []} = r) when outcome in ["fail", "error"] do
    {:error, r["reason"] || "#{outcome} with no reason", r["layer"] || "error:worker"}
  end

  def to_outcome(%{"outcome" => "skip"} = r) do
    {:ok, [Result.skip(:p2, "BEAM boots and the node registers", r["reason"])]}
  end

  def to_outcome(%{"path" => "release:ios", "artifacts" => %{"ipa" => ipa}}) do
    detail = "#{ipa["name"]} (#{ipa["app"]}, #{ipa["bytes"]} bytes, sha256 #{ipa["sha256"]})"
    {:ok, [%{Result.pass(:ipa, "signed .ipa from mix mob.release --ios", detail) | evidence: ipa}]}
  end

  def to_outcome(%{"invariants" => invs}) do
    {p12, rest} = Enum.split_with(invs, &String.starts_with?(&1["id"], "p12:"))

    results =
      Enum.map(rest, &invariant_result/1) ++
        if(p12 == [], do: [], else: [p12_result(p12)])

    verdict = if Enum.any?(results, &(&1.status in [:fail, :error])), do: :fail, else: :ok
    {verdict, results}
  end

  defp invariant_result(%{"id" => "p2"} = i), do: result(:p2, "BEAM boots and the node registers", i)
  defp invariant_result(%{"id" => "health"} = i), do: result(:health, "Mob.Diag.health/0 held across the self-tests", i)
  defp invariant_result(%{"id" => id} = i), do: result(String.to_atom(id), id, i)

  @doc """
  Settle every provisional `plugin:<p>?` P12 item of a set's outcome against
  the plugin's singleton cell (`singleton.(plugin)`, its newest self-test
  outcome on the same row, platform and path, or nil), as the Android path
  does: failing alone too is `plugin:<p>`, passing alone is
  `conflict:<set>`, unknown stays `plugin:<p>?` (`Invariants.p12_layer/3`).
  """
  @spec settle_p12(term(), [atom()], (atom() -> atom() | nil)) :: term()
  def settle_p12({verdict, results}, set, singleton) when verdict in [:ok, :fail] do
    {verdict,
     Enum.map(results, fn
       %Result{id: :p12, evidence: %{items: items}} = r ->
         items = Enum.map(items, &settle_item(&1, set, singleton))
         %{Result.rollup(items, :p12, r.title) | evidence: %{items: items}}

       other ->
         other
     end)}
  end

  def settle_p12(outcome, _set, _singleton), do: outcome

  defp settle_item(%Result{status: :fail, title: name} = item, set, singleton) do
    plugin = String.to_atom(name)
    %{item | layer: Invariants.p12_layer(plugin, set, singleton.(plugin))}
  end

  defp settle_item(item, _set, _singleton), do: item

  @doc """
  Record a lane run in the results store: one run row, then each path's
  outcome (`to_outcome/1`, P12 settled by `settle_p12/3`) with
  `MobCi.Store.record_results/4`.
  """
  @spec record(Store.t(), Cell.t(), [map()], keyword()) :: {:ok, pos_integer()}
  def record(store, cell, results, opts \\ []) do
    row = MobCi.Versions.row_to_string(cell.resolved.row)

    {:ok, run_id} =
      Store.record_run(store, %{
        trigger: "ci.device --platform ios",
        versions_row: row,
        host: Keyword.get(opts, :host, default_host()),
        mob_ci_sha: Keyword.get(opts, :mob_ci_sha)
      })

    for r <- results do
      singleton = fn plugin ->
        Store.singleton_selftest(store, plugin, versions_row: row, platform: :ios, path: r["path"])
      end

      meta = %{
        set: cell.set,
        platform: :ios,
        path: r["path"],
        versions: r["versions"],
        duration_ms: r["duration_ms"],
        log_path: r["log_path"]
      }

      Store.record_results(store, run_id, meta, settle_p12(to_outcome(r), cell.plugins, singleton))
    end

    {:ok, run_id}
  end

  defp p12_result(items) do
    items =
      Enum.map(items, fn %{"id" => "p12:" <> plugin} = i -> result(:p12_item, plugin, i) end)

    %{Result.rollup(items, :p12, "every plugin's self-test passes on device") | evidence: %{items: items}}
  end

  defp result(id, title, %{"status" => status} = i) do
    %Result{
      id: id,
      title: title,
      status: String.to_existing_atom(status),
      detail: i["detail"],
      layer: if(status in ["fail", "error"], do: i["layer"])
    }
  end

  # ── the run ──────────────────────────────────────────────────────────────────

  @doc """
  Run `paths` of a planned cell on the Mac and return one worker result per
  path. Options: `:host`, `:sim_udid` (pin the simulator; default: the worker
  picks), `:device_udid` (default Kevin's iPhone), `:min_runtime` (lowest
  simulator iOS, default `Spec.default_min_runtime/0`), `:log_dir`,
  `:mob_ci_sha` (default: this checkout's HEAD), `:ssh` (transport), `:stamp`
  (cell id suffix), `:static` (`[atom()] -> [String.t()]` conflicts, default
  `MobDev.Plugin.Validator.cross_validate/1`).
  """
  @spec run(Cell.t(), [Spec.path()], keyword()) :: [map()]
  def run(cell, paths, opts \\ []) do
    host = Keyword.get(opts, :host, default_host())
    log_dir = Keyword.get(opts, :log_dir, default_log_dir())
    ssh = Keyword.get(opts, :ssh, &ssh/2)
    static = Keyword.get(opts, :static, &static_conflicts/1)
    sha = Keyword.get_lazy(opts, :mob_ci_sha, &head_sha/0)
    File.mkdir_p!(log_dir)

    specs =
      for path <- paths do
        spec_opts =
          [udid: udid_for(path, opts), mob_ci_sha: sha] ++ Keyword.take(opts, [:stamp, :min_runtime])

        case Spec.from_cell(cell, path, spec_opts) do
          {:ok, spec} -> spec
          {:error, msg} -> raise ArgumentError, msg
        end
      end

    case static.(cell.plugins) do
      [] ->
        sync_log = Path.join(log_dir, "sync-#{hd(specs).cell_id}.log")
        sync_exit = ssh.(ssh_argv(host, sync_command(sha)), sync_log)

        if sync_exit == 0 do
          Enum.map(specs, &run_spec(&1, host, log_dir, ssh))
        else
          reason = "worker sync to #{sha} on #{host} exited #{sync_exit}: #{tail(sync_log)}"
          Enum.map(specs, &write_result(error_result(&1, "error:ssh", reason), log_dir))
        end

      conflicts ->
        reason = "static gate: " <> Enum.join(conflicts, "; ")
        Enum.map(specs, &write_result(error_result(&1, "static", reason), log_dir))
    end
  end

  # ── mix ci.device --platform ios ─────────────────────────────────────────────

  @cli_switches [
    platform: :string,
    set: :string,
    versions: :string,
    paths: :string,
    sim_udid: :string,
    device_udid: :string,
    min_runtime: :string,
    host: :string,
    log_dir: :string,
    store: :string
  ]

  @doc """
  `mix ci.device --platform ios …`: plan, run every path on the Mac, print a
  line per cell and the result files. Exits 1 when a cell failed, 2 when one
  errored.
  """
  @spec cli([String.t()], keyword()) :: :ok
  def cli(argv, opts \\ []) do
    {o, rest, invalid} = OptionParser.parse(argv, strict: @cli_switches)

    if rest != [] or invalid != [] do
      bad = Enum.map(invalid, &elem(&1, 0)) ++ rest
      Mix.raise(
        "--platform ios takes --set --versions --paths --sim-udid --device-udid --min-runtime --host --log-dir --store; got #{Enum.join(bad, " ")}"
      )
    end

    paths = parse_paths!(o[:paths])
    cell = Cell.plan!(o[:set], o[:versions])
    Mix.shell().info("── mob_ci iOS lane (#{o[:host] || default_host()}) ──\n" <> Cell.describe(cell))

    run_opts =
      [
        host: o[:host],
        sim_udid: o[:sim_udid],
        device_udid: o[:device_udid],
        min_runtime: o[:min_runtime],
        log_dir: o[:log_dir]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    results = run(cell, paths, run_opts ++ opts)

    store = Store.open!(o[:store] || Store.default_path())

    try do
      {:ok, run_id} = record(store, cell, results, Keyword.take(run_opts, [:host]))
      Mix.shell().info("\nrecorded as run #{run_id} in #{o[:store] || Store.default_path()}")
    after
      Store.close(store)
    end

    Mix.shell().info("\nresults:")
    Enum.each(results, &Mix.shell().info(summary_line(&1)))

    Enum.each(results, fn r ->
      Mix.shell().info("  #{r["path"]}: #{r["log_path"] || "(no log)"} → #{r["cell_id"]}.json")
    end)

    outcomes = Enum.map(results, & &1["outcome"])

    cond do
      "error" in outcomes -> exit({:shutdown, 2})
      "fail" in outcomes -> exit({:shutdown, 1})
      true -> :ok
    end
  end

  @doc "`--paths` → the iOS paths (nil: all of them, in order)."
  @spec parse_paths!(String.t() | nil) :: [Spec.path()]
  def parse_paths!(nil), do: Spec.paths()

  def parse_paths!(csv) do
    paths = csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    case paths -- Spec.paths() do
      [] when paths != [] -> paths
      [] -> Mix.raise("--paths is empty")
      bad -> Mix.raise("unknown iOS path(s) #{Enum.join(bad, ", ")} (expected: #{Enum.join(Spec.paths(), ", ")})")
    end
  end

  defp run_spec(spec, host, log_dir, ssh) do
    log = Path.join(log_dir, "#{spec.cell_id}.log")
    exit_code = ssh.(ssh_argv(host, cell_command(spec)), log)
    body = if File.regular?(log), do: File.read!(log), else: ""
    spec |> collect(exit_code, body) |> Map.put("log_path", log) |> write_result(log_dir)
  end

  defp write_result(result, log_dir) do
    File.write!(Path.join(log_dir, "#{result["cell_id"]}.json"), JSON.encode!(result))
    result
  end

  defp tail(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.slice(-800, 800) |> String.trim()
      _ -> ""
    end
  end

  defp static_conflicts(plugins), do: Validator.cross_validate(Plugins.activated(plugins)).errors

  defp head_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: Path.expand("../../..", __DIR__))
    String.trim(sha)
  end

  @doc false
  # The real transport: ssh with its output streamed to stdout and the log.
  def ssh(argv, log_path) do
    File.mkdir_p!(Path.dirname(log_path))
    file = File.open!(log_path, [:write, :binary])

    try do
      {_tee, code} = System.cmd("ssh", argv, into: %Tee{file: file}, stderr_to_stdout: true)
      code
    after
      File.close(file)
    end
  end

  # ── console ──────────────────────────────────────────────────────────────────

  @doc "One line per cell for the console."
  @spec summary_line(map()) :: String.t()
  def summary_line(r) do
    layer = if r["layer"], do: " [#{r["layer"]}]", else: ""
    reason = if r["outcome"] != "pass" and r["reason"], do: " — #{String.slice(r["reason"], 0, 300)}", else: ""
    invs = Enum.map_join(r["invariants"] || [], " ", &"#{&1["id"]}=#{&1["status"]}")
    ipa = get_in(r, ["artifacts", "ipa", "name"])

    "  #{String.pad_trailing(r["path"], 18)} #{String.upcase(r["outcome"])}#{layer}" <>
      if(invs != "", do: "  #{invs}", else: "") <>
      if(ipa, do: "  #{ipa}", else: "") <> reason
  end
end
