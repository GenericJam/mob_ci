defmodule MobCi.BootDiag do
  @moduledoc """
  Why a launched app's node never came up, in the device's own words.

  When `MobCi.Farm.launch/2` gives up waiting for the node, or a release
  install's first launch never unpacks OTP, `MobCi.Farm.boot_diag/4`
  captures, before the instance is released: the app's pid (`pidof`), the
  logcat dump (main, system and crash buffers) and the host's `epmd -names`.
  This module is the pure part. It keeps the app's own lines since its last
  start (its pids, lines naming the package, the crash_dump tombstone of
  the package) and names the likeliest cause, first match wins:

    1. a Java crash (`AndroidRuntime: FATAL EXCEPTION`),
    2. a native crash of the app (`libc: Fatal signal`, the tombstone's
       abort message),
    3. the BEAM stopping (`Kernel pid terminated`, `Runtime terminating`,
       `init terminating in do_boot`, `Crash dump is being written`),
    4. what `Mob.Dist` said last (no EPMD through `adb reverse tcp:4369`, a
       failed `Node.start`, distribution started but never answered),
    5. the process dying without a crash, or not running,
    6. a running app whose BEAM never reached `Mob.Dist`.

  Each cause ends with what the host's EPMD knows of the node, which
  separates "never registered" from "registered but unreachable".

  The error reason carries the struct (`{:node_never_registered, node,
  diag}`, `{:otp_not_extracted, pkg, diag}`); it inspects as
  `#BootDiag<cause>`, so log lines and the store's `detail.error` stay
  short. `MobCi.Run` appends `render/2` to the path's log and writes the
  full dump next to it; `MobCi.Store` keeps `detail/1` under
  `detail.boot`.
  """

  @enforce_keys [:cause]
  defstruct [:cause, :pid, :node, epmd: "", lines: [], logcat: ""]

  @type t :: %__MODULE__{
          cause: String.t(),
          pid: String.t() | nil,
          node: node() | nil,
          epmd: String.t(),
          lines: [String.t()],
          logcat: String.t()
        }

  # `logcat -v threadtime`: date time pid tid level tag: message
  @line ~r/^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+(\d+)\s+\d+\s+[VDIWEFS]\s+(.*?)\s*: (.*)$/
  @beam_stop ~r/Kernel pid terminated|Runtime terminating|init terminating in do_boot|Crash dump is being written/
  @detail_lines 60
  @render_lines 200

  @doc """
  Build a diagnosis of `pkg` (whose node is `node`, `nil` when none was
  expected yet) from the raw captures: `pid` (`pidof` output), `logcat`
  (a `-v threadtime` dump) and `epmd` (`epmd -names` output).
  """
  @spec new(String.t(), node() | nil, %{pid: String.t(), logcat: String.t(), epmd: String.t()}) :: t()
  def new(pkg, node, %{pid: pid_out, logcat: logcat, epmd: epmd}) do
    # logcat carries whatever bytes apps log; the store's detail is JSON.
    logcat = String.replace_invalid(logcat)
    pid = parse_pid(pid_out)
    parsed = logcat |> String.split("\n") |> Enum.map(&parse_line/1) |> Enum.reject(&is_nil/1)
    lines = app_lines(parsed, pkg, pid)
    epmd = epmd |> String.replace_invalid() |> String.trim()

    cause =
      if parsed == [],
        do: "logcat unavailable: #{first_line(logcat)}",
        else: cause(lines, pkg, pid)

    %__MODULE__{
      cause: cause <> epmd_note(node, epmd),
      pid: pid,
      node: node,
      epmd: epmd,
      lines: Enum.map(lines, & &1.raw),
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
  What the results store keeps of a diagnosis under `detail.boot`: the
  cause, the app's pid, the node's port in the host's EPMD (nil: not
  registered) and the app's last #{@detail_lines} logcat lines.
  """
  @spec detail(t()) :: map()
  def detail(%__MODULE__{} = d) do
    %{cause: d.cause, pid: d.pid, epmd_port: epmd_port(d.node, d.epmd), logcat: Enum.take(d.lines, -@detail_lines)}
  end

  @doc """
  The diagnosis as a block of the path's log: the cause, the pid, the
  host's EPMD and the app's last #{@render_lines} logcat lines.
  `dump` names the file holding the full logcat, if one was written.
  """
  @spec render(t(), String.t() | nil) :: String.t()
  def render(%__MODULE__{} = d, dump \\ nil) do
    shown = Enum.take(d.lines, -@render_lines)

    """

    ── mob_ci boot diagnostics ──
    cause: #{d.cause}
    app pid: #{d.pid || "not running"}
    host epmd: #{if d.epmd == "", do: "(no answer)", else: String.replace(d.epmd, "\n", " | ")}
    app logcat since its last start (#{length(shown)} of #{length(d.lines)} lines#{if dump, do: "; full dump: #{dump}", else: ""}):
    #{Enum.join(shown, "\n")}
    """
  end

  @doc """
  Keep the diagnosis with the path's log `log` (the cell's `log_path`):
  append `render/2` to it and write the full logcat dump beside it as
  `<log without .log>.logcat.log` (a `*.log`, so the publish's 30-day log
  prune takes it too). Returns the rendered block; with no log, only renders.
  """
  @spec write(t(), Path.t() | nil) :: String.t()
  def write(%__MODULE__{} = d, nil), do: render(d)

  def write(%__MODULE__{} = d, log) do
    dump = Path.rootname(log) <> ".logcat.log"
    text = render(d, Path.basename(dump))
    File.mkdir_p!(Path.dirname(log))
    File.write!(dump, d.logcat)
    File.write!(log, text, [:append])
    text
  end

  # ── the app's lines ──────────────────────────────────────────────────────────

  defp parse_line(raw) do
    case Regex.run(@line, String.trim_trailing(raw, "\r")) do
      [raw, pid, tag, msg] -> %{raw: raw, pid: pid, tag: tag, msg: msg}
      nil -> nil
    end
  end

  # The lines since the app's last start: its pids, any line naming the
  # package (ActivityManager's start/kill/death lines), and the crash_dump
  # tombstone written for it. Other processes' crashes (redroid's bluetooth
  # HAL aborts at every boot) stay out.
  defp app_lines(parsed, pkg, pid) do
    start = ~r/Start proc (\d+):#{Regex.escape(pkg)}\//
    starts = for %{msg: m} <- parsed, [_, p] <- [Regex.run(start, m)], do: p
    pids = MapSet.new(if(pid, do: String.split(pid), else: []) ++ starts)
    tombstones = MapSet.new(for %{tag: "DEBUG", msg: m, pid: p} <- parsed, String.contains?(m, ">>> #{pkg} <<<"), do: p)

    parsed
    |> since_last(&Regex.match?(start, &1.msg))
    |> Enum.filter(fn l ->
      MapSet.member?(pids, l.pid) or String.contains?(l.msg, pkg) or
        (l.tag == "DEBUG" and MapSet.member?(tombstones, l.pid))
    end)
  end

  defp since_last(lines, pred) do
    case lines |> Enum.reverse() |> Enum.find_index(pred) do
      nil -> lines
      i -> Enum.take(lines, -(i + 1))
    end
  end

  # ── the cause ────────────────────────────────────────────────────────────────

  defp cause(lines, pkg, pid) do
    java_crash(lines) || native_crash(lines) || beam_stop(lines) || dist(lines) || process(lines, pkg, pid)
  end

  defp java_crash(lines) do
    case Enum.drop_while(lines, &(not (&1.tag == "AndroidRuntime" and String.contains?(&1.msg, "FATAL EXCEPTION")))) do
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

  defp native_crash(lines) do
    with %{msg: m} <- Enum.find(lines, &(&1.tag == "libc" and String.contains?(&1.msg, "Fatal signal"))) do
      abort =
        Enum.find_value(lines, "", fn
          %{tag: "DEBUG", msg: "Abort message: " <> a} -> " — abort message: #{a}"
          _ -> nil
        end)

      "the app crashed (native): #{m}#{abort}"
    end
  end

  defp beam_stop(lines) do
    with %{msg: m} <- Enum.find(lines, &Regex.match?(@beam_stop, &1.msg)), do: "the BEAM stopped: #{m}"
  end

  defp dist(lines) do
    case lines |> Enum.filter(&String.contains?(&1.msg, "Mob.Dist:")) |> List.last() do
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

  defp process(lines, pkg, pid) do
    died = Enum.find(lines, &String.contains?(&1.msg, "Process #{pkg} (pid"))

    cond do
      pid == nil and died != nil -> "the app's process died with no crash in logcat: #{died.msg}"
      pid == nil -> "the app is not running and logcat has no crash for it"
      true -> "the app is running (pid #{pid}) but its BEAM never reached Mob.Dist"
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp parse_pid(out) do
    out = String.trim(out)
    if out =~ ~r/\A\d+( \d+)*\z/, do: out
  end

  defp epmd_note(nil, _epmd), do: ""

  defp epmd_note(node, epmd) do
    case epmd_port(node, epmd) do
      nil -> " (host EPMD: #{short_name(node)} not registered)"
      port -> " (host EPMD: #{short_name(node)} at port #{port})"
    end
  end

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
