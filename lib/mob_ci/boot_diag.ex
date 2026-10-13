defmodule MobCi.BootDiag do
  @moduledoc """
  Why a launched app's node never came up, in the device's own words.

  When `MobCi.Farm.launch/2` gives up waiting for the node, or a release
  install's first launch never unpacks OTP, `MobCi.Farm.boot_diag/4`
  captures, before the instance is released: the app's pid (`pidof`), the
  logcat dump (main, system and crash buffers) and the host's `epmd -names`,
  each with its exit status. This module is the pure part. It keeps the
  lines since the app's last `Start proc` (that process's own lines, lines
  naming the package, that process's crash_dump tombstone) and names the
  likeliest cause, first match wins:

    1. a Java crash (`AndroidRuntime: FATAL EXCEPTION`),
    2. a native crash (`libc: Fatal signal`, the tombstone's abort message),
    3. the BEAM stopping (`Kernel pid terminated`, `Runtime terminating`,
       `init terminating in do_boot`, `Crash dump is being written`),
    4. what `Mob.Dist` said last (no EPMD through `adb reverse tcp:4369`, a
       failed `Node.start`, distribution started but never answered),
    5. the process dying without a crash, or not running,
    6. a running app whose BEAM never reached `Mob.Dist`.

  Only the last start's process counts: an earlier start's late lines
  (mob_dev's install-time start always dies on a missing boot file) and
  other processes' crashes (redroid's bluetooth HAL aborts at every boot)
  are not the cause. Each cause ends with what the host's EPMD knows of the
  node, which separates "never registered" from "registered but
  unreachable". A capture that failed or timed out says so (`problems`);
  it is never read as "not running" or "not registered".

  The error reason carries the struct (`{:node_never_registered, node,
  diag}`, `{:otp_not_extracted, pkg, diag}`); it inspects as
  `#BootDiag<cause>`, so log lines and the store's `detail.error` stay
  short. The cause quotes the app's own log lines, so layer attribution
  must not read it: `strip/1` is what `MobCi.Farm.lost_device?/1` sees. A
  device that really went away is caught by the post-path liveness check.
  `MobCi.Run` keeps it with the path's log (`write/2`); `MobCi.Store` keeps
  `detail/1` under `detail.boot`.
  """

  @enforce_keys [:cause]
  defstruct [:cause, :pid, :node, :epmd_port, epmd: "", problems: [], lines: [], logcat: ""]

  @type capture :: {String.t(), integer()}
  @type t :: %__MODULE__{
          cause: String.t(),
          pid: String.t() | nil | :unknown,
          node: node() | nil,
          epmd_port: pos_integer() | nil | :unknown,
          epmd: String.t(),
          problems: [String.t()],
          lines: [String.t()],
          logcat: String.t()
        }

  # `logcat -v threadtime`: date time pid tid level tag: message
  @line ~r/^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+(\d+)\s+\d+\s+[VDIWEFS]\s+(.*?)\s*: (.*)$/
  @beam_stop ~r/Kernel pid terminated|Runtime terminating|init terminating in do_boot|Crash dump is being written/
  # coreutils `timeout`: 124 when it timed the command out, 137 when it had to KILL it
  @timed_out [124, 137]
  @detail_lines 60
  @render_lines 200

  @doc """
  Build a diagnosis of `pkg` (whose node is `node`, `nil` when none was
  expected yet) from the captures, each `{output, exit status}`: `pid`
  (`pidof <pkg>`), `logcat` (a `-v threadtime` dump) and `epmd`
  (`epmd -names`).
  """
  @spec new(String.t(), node() | nil, %{pid: capture(), logcat: capture(), epmd: capture()}) :: t()
  def new(pkg, node, %{pid: {pid_out, pid_status}, logcat: {logcat, logcat_status}, epmd: {epmd, epmd_status}}) do
    # logcat carries whatever bytes apps log; the store's detail is JSON.
    logcat = String.replace_invalid(logcat)
    epmd = epmd |> String.replace_invalid() |> String.trim()
    {pid, pid_problem} = parse_pid(pid_out, pid_status)
    parsed = logcat |> String.split("\n") |> Enum.map(&parse_line/1) |> Enum.reject(&is_nil/1)
    app = app_lines(parsed, pkg, pid)
    epmd_port = if epmd_status == 0, do: epmd_port(node, epmd), else: :unknown

    problems =
      Enum.reject(
        [
          pid_problem,
          logcat_problem(logcat, logcat_status, parsed),
          if(epmd_status != 0, do: "epmd -names: #{status_text(epmd, epmd_status)}")
        ],
        &is_nil/1
      )

    cause =
      if parsed == [],
        do: "logcat unavailable: #{status_text(logcat, logcat_status)}",
        else: cause(app, pkg, pid)

    %__MODULE__{
      cause: cause <> epmd_note(node, epmd_port),
      pid: pid,
      node: node,
      epmd_port: epmd_port,
      epmd: epmd,
      problems: problems,
      lines: Enum.map(app.shown, & &1.raw),
      logcat: logcat
    }
  end

  @doc "The first `#{inspect(__MODULE__)}` inside an orchestration error reason (any depth of tuples and lists), else nil."
  @spec find(term()) :: t() | nil
  def find(%__MODULE__{} = diag), do: diag
  def find(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> find()
  def find([h | t]), do: find(h) || find(t)
  def find(_other), do: nil

  @doc """
  `reason` with every diagnosis replaced by `:boot_diag`: what pattern-based
  attribution may read. The cause quotes the app's own log, which must not
  decide a layer (an app logging "device offline" is not a lost device).
  """
  @spec strip(term()) :: term()
  def strip(%__MODULE__{}), do: :boot_diag
  def strip(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&strip/1) |> List.to_tuple()
  def strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  def strip(other), do: other

  @doc """
  What the results store keeps of a diagnosis under `detail.boot`: the
  cause, the app's pid, the node's port in the host's EPMD (`nil`: not
  registered), any capture that failed, and the app's last
  #{@detail_lines} logcat lines.
  """
  @spec detail(t()) :: map()
  def detail(%__MODULE__{} = d) do
    %{
      cause: d.cause,
      pid: d.pid,
      epmd_port: d.epmd_port,
      problems: d.problems,
      logcat: Enum.take(d.lines, -@detail_lines)
    }
  end

  @doc """
  The diagnosis as a block of the path's log: the cause, the pid, the
  host's EPMD, failed captures and the app's last #{@render_lines} logcat
  lines. `dump` names the file holding the full logcat, if one was written.
  """
  @spec render(t(), String.t() | nil) :: String.t()
  def render(%__MODULE__{} = d, dump \\ nil) do
    shown = Enum.take(d.lines, -@render_lines)

    pid =
      case d.pid do
        nil -> "not running"
        :unknown -> "unknown"
        pid -> pid
      end

    problems = Enum.map_join(d.problems, "", &"capture problem: #{&1}\n")

    """

    ── mob_ci boot diagnostics ──
    cause: #{d.cause}
    app pid: #{pid}
    host epmd: #{if d.epmd == "", do: "(no answer)", else: String.replace(d.epmd, "\n", " | ")}
    #{problems}app logcat since its last start (#{length(shown)} of #{length(d.lines)} lines#{if dump, do: "; full dump: #{dump}", else: ""}):
    #{Enum.join(shown, "\n")}
    """
  end

  @doc """
  Keep the diagnosis with the path's log `log` (the cell's `log_path`):
  append `render/2` to it and write the full logcat dump beside it as
  `<log without .log>.logcat.log` (a `*.log`, so the publish's 30-day log
  prune takes it too). Returns the rendered block; with no log, only
  renders. Never raises: the boot error it explains must still be
  recorded, so a write that fails is noted in the returned block.
  """
  @spec write(t(), Path.t() | nil) :: String.t()
  def write(%__MODULE__{} = d, nil), do: render(d)

  def write(%__MODULE__{} = d, log) do
    dump = Path.rootname(log) <> ".logcat.log"
    text = render(d, Path.basename(dump))

    with :ok <- File.mkdir_p(Path.dirname(log)),
         :ok <- File.write(log, text, [:append]),
         :ok <- File.write(dump, d.logcat) do
      text
    else
      {:error, reason} -> text <> "(mob_ci could not keep this beside #{log}: #{:file.format_error(reason)})\n"
    end
  end

  # ── the app's lines ──────────────────────────────────────────────────────────

  defp parse_line(raw) do
    case Regex.run(@line, String.trim_trailing(raw, "\r")) do
      [raw, pid, tag, msg] -> %{raw: raw, pid: pid, tag: tag, msg: msg}
      nil -> nil
    end
  end

  # From the app's last start: `own`, the lines of its process (the started
  # pid, or what `pidof` answers now); `am`, other processes' lines naming
  # the package (ActivityManager's start/kill/death); `tombstone`, the
  # crash_dump lines written for that process. `shown` is all three, in
  # order: an earlier start's late lines and other crashes stay out.
  defp app_lines(parsed, pkg, pid) do
    start = ~r/Start proc (\d+):#{Regex.escape(pkg)}\//
    window = since_last(parsed, &Regex.match?(start, &1.msg))

    # `since_last/2` puts the last start line first, when there is one
    started =
      case window do
        [%{msg: m} | _] ->
          case Regex.run(start, m) do
            [_, p] -> [p]
            nil -> []
          end

        [] ->
          []
      end

    pids = MapSet.new(started ++ if(is_binary(pid), do: String.split(pid), else: []))
    crashed = ~r/^pid: (\d+), .*>>> #{Regex.escape(pkg)} <<</

    dumpers =
      MapSet.new(
        for %{tag: "DEBUG", msg: m, pid: dumper} <- window,
            [_, p] <- [Regex.run(crashed, m)],
            MapSet.member?(pids, p),
            do: dumper
      )

    own = Enum.filter(window, &MapSet.member?(pids, &1.pid))
    tombstone = Enum.filter(window, &(&1.tag == "DEBUG" and MapSet.member?(dumpers, &1.pid)))

    shown =
      Enum.filter(window, fn l ->
        MapSet.member?(pids, l.pid) or String.contains?(l.msg, pkg) or
          (l.tag == "DEBUG" and MapSet.member?(dumpers, l.pid))
      end)

    am = Enum.filter(shown, &(not MapSet.member?(pids, &1.pid)))
    %{own: own, am: am, tombstone: tombstone, pids: pids, shown: shown}
  end

  defp since_last(lines, pred) do
    case lines |> Enum.reverse() |> Enum.find_index(pred) do
      nil -> lines
      i -> Enum.take(lines, -(i + 1))
    end
  end

  # ── the cause ────────────────────────────────────────────────────────────────

  defp cause(app, pkg, pid) do
    java_crash(app.own) || native_crash(app.own, app.tombstone) || beam_stop(app.own) || dist(app.own) ||
      process(app, pkg, pid)
  end

  defp java_crash(own) do
    case Enum.drop_while(own, &(not (&1.tag == "AndroidRuntime" and String.contains?(&1.msg, "FATAL EXCEPTION")))) do
      [] ->
        nil

      [_fatal | rest] ->
        exception =
          Enum.find_value(rest, "?", fn
            %{tag: "AndroidRuntime", msg: "Process: " <> _} -> nil
            %{tag: "AndroidRuntime", msg: m} -> m
            _ -> nil
          end)

        "the app crashed (Java): #{exception}"
    end
  end

  defp native_crash(own, tombstone) do
    with %{msg: m} <- Enum.find(own, &(&1.tag == "libc" and String.contains?(&1.msg, "Fatal signal"))) do
      abort =
        Enum.find_value(tombstone, "", fn
          %{msg: "Abort message: " <> a} -> " — abort message: #{a}"
          _ -> nil
        end)

      "the app crashed (native): #{m}#{abort}"
    end
  end

  defp beam_stop(own) do
    with %{msg: m} <- Enum.find(own, &Regex.match?(@beam_stop, &1.msg)), do: "the BEAM stopped: #{m}"
  end

  defp dist(own) do
    case own |> Enum.filter(&String.contains?(&1.msg, "Mob.Dist:")) |> List.last() do
      nil ->
        nil

      %{msg: m} ->
        cond do
          m =~ "no EPMD on port 4369" ->
            "Mob.Dist skipped distribution: no EPMD on the device's 127.0.0.1:4369 (adb reverse tcp:4369) within its 10 s wait"

          m =~ "result={:error" ->
            "Mob.Dist could not start distribution: #{m}"

          m =~ "distribution started" or m =~ "result={:ok" ->
            "Mob.Dist started distribution, but mob_ci never connected to the node"

          true ->
            "Mob.Dist had not finished starting distribution (last: #{m})"
        end
    end
  end

  defp process(app, pkg, pid) do
    died =
      Enum.find(app.am, fn l ->
        Enum.any?(app.pids, &String.contains?(l.msg, "Process #{pkg} (pid #{&1}) has died"))
      end)

    cond do
      pid == :unknown -> "the app's state is unknown (pidof failed) and logcat has no crash for it"
      pid == nil and died != nil -> "the app's process died with no crash in logcat: #{died.msg}"
      pid == nil -> "the app is not running and logcat has no crash for it"
      true -> "the app is running (pid #{pid}) but its BEAM never reached Mob.Dist"
    end
  end

  # ── captures ─────────────────────────────────────────────────────────────────

  # `pidof` answers 0 with the pid(s) or 1 with nothing when no process has
  # the name; anything else (adb's own error, a timeout) proves nothing.
  defp parse_pid(out, status) do
    out = String.trim(out)

    cond do
      status == 0 and out =~ ~r/\A\d+( \d+)*\z/ -> {out, nil}
      status == 1 and out == "" -> {nil, nil}
      true -> {:unknown, "pidof: #{status_text(out, status)}"}
    end
  end

  defp logcat_problem(_logcat, 0, _parsed), do: nil
  defp logcat_problem(_logcat, status, [_ | _]) when status in @timed_out, do: "logcat: timed out, the dump is partial"
  defp logcat_problem(logcat, status, _parsed), do: "logcat: #{status_text(logcat, status)}"

  defp status_text(out, status) when status in @timed_out, do: "timed out (#{first_line(out)})"
  defp status_text(out, status), do: "exit #{status}: #{first_line(out)}"

  defp epmd_note(nil, _port), do: ""
  defp epmd_note(node, :unknown), do: " (host EPMD unreadable for #{short_name(node)})"
  defp epmd_note(node, nil), do: " (host EPMD: #{short_name(node)} not registered)"
  defp epmd_note(node, port), do: " (host EPMD: #{short_name(node)} at port #{port})"

  defp epmd_port(nil, _epmd), do: nil

  defp epmd_port(node, epmd) do
    name = Regex.escape(short_name(node))

    case Regex.run(~r/^name #{name} at port (\d+)/m, epmd) do
      [_, port] -> String.to_integer(port)
      nil -> nil
    end
  end

  defp short_name(node), do: node |> Atom.to_string() |> String.split("@") |> hd()

  defp first_line(text) do
    case text |> String.trim() |> String.split("\n", parts: 2) do
      [""] -> "(no output)"
      [line | _] -> line
    end
  end

  defimpl Inspect do
    def inspect(%{cause: cause}, _opts), do: "#BootDiag<#{cause}>"
  end
end
