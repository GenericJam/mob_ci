defmodule MobCi.Farm do
  @moduledoc """
  Layer 0/1: boot a redroid instance for a device run and launch the deployed app
  with a CI node identity, cooperatively sharing the box with the live sloppy_joe
  staging pool. Drives `priv/ci-farm.sh` (disjoint name + port band from staging,
  shared flock for box-level admission).

  Flow: `boot/1` (base redroid + adb connect) → caller runs
  `mix mob.deploy --native --device <serial>` (MobCi.Build) → `launch/2`
  (tunnels + relaunch with the CI node suffix/dist-port) → `await_node/2` →
  probe → `release/1`. The pure surface (node naming, port/suffix derivation,
  output parsing, admission parsing) is unit-tested; the shell-driving calls are
  `:integration`.

  Every instance carries an ownership record naming the BEAM that booted it
  (MOB-467): `reap/0` downs an instance whose owner died without releasing
  it, and the trigger queue reaps before every Android cell.
  """

  @script Path.expand("../../priv/ci-farm.sh", __DIR__)

  defmodule Instance do
    @moduledoc "A booted CI redroid instance (before/after the app is launched)."
    @enforce_keys [:index, :serial, :suffix, :dist_port]
    defstruct [:index, :serial, :suffix, :dist_port, :node]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            serial: String.t(),
            suffix: String.t(),
            dist_port: non_neg_integer(),
            node: node() | nil
          }
  end

  @doc "Path to the CI farm driver script."
  def script, do: @script

  @doc "Dist port for a CI instance index (CI band, disjoint from staging's 9101+)."
  @spec dist_port(non_neg_integer()) :: non_neg_integer()
  def dist_port(index), do: 9300 + index

  @doc "Node suffix for a CI instance index."
  @spec suffix(non_neg_integer()) :: String.t()
  def suffix(index), do: "ci#{index}"

  @doc """
  The device node name for a host app + suffix. Mob.Dist registers
  `<app>_android_<suffix>@127.0.0.1` (suffix from the `mob_node_suffix` intent).
  """
  @spec node_name(atom() | String.t(), String.t()) :: node()
  def node_name(app, suffix), do: :"#{app}_android_#{suffix}@127.0.0.1"

  @doc "Does the box have headroom for one more container right now?"
  @spec admit?() :: boolean()
  def admit?, do: parse_admit(sh(["admit"]))

  @doc "Parse `ci-farm.sh admit` output (`OK n/c` | `BUSY n/c`) → has-headroom?"
  @spec parse_admit(String.t()) :: boolean()
  def parse_admit(output), do: output |> String.trim() |> String.starts_with?("OK")

  # ── instance loss (layer `farm`) ─────────────────────────────────────────────

  # What adb and mob_dev print when the device under them went away: the
  # transport dropped, adbd died, the container is gone. Never a plugin's or
  # the build's doing — infrastructure, attributed to layer `farm`.
  @lost_patterns [
    ~r/Selected Android device\(s\) disconnected/,
    ~r/\bdevice offline\b/,
    ~r/\bdevice '[^']*' not found/,
    ~r/no devices\/emulators found/,
    ~r/\berror: closed\b/,
    ~r/\bdevice still connecting\b/
  ]

  @doc """
  Does `reason` (an orchestration error's reason, or any output) say the
  device itself went away mid-path? Matches mob_dev's "Selected Android
  device(s) disconnected" and adb's `device offline`, `device '…' not
  found`, `no devices/emulators found`, `error: closed`, `device still
  connecting`.
  """
  @spec lost_device?(term()) :: boolean()
  def lost_device?(reason) do
    text = if is_binary(reason), do: reason, else: inspect(reason, limit: :infinity, printable_limit: :infinity)
    Enum.any?(@lost_patterns, &Regex.match?(&1, text))
  end

  @doc """
  Is the instance still there? `ci-farm.sh alive <index>`: the container is
  running and adb sees the device (after up to 10 s for an adbd restart).
  `:alive`, `{:lost, why}`, or `:unknown` when the check itself couldn't run
  (then nothing is re-attributed: an unproven loss must not hide a failure).
  """
  @spec alive(Instance.t()) :: :alive | {:lost, String.t()} | :unknown
  def alive(%Instance{index: i}), do: parse_alive(sh(["alive", to_string(i)]))

  @doc "Parse `ci-farm.sh alive` output: its last `ALIVE` / `LOST <why>` line; none is `:unknown`."
  @spec parse_alive(String.t()) :: :alive | {:lost, String.t()} | :unknown
  def parse_alive(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reverse()
    |> Enum.find_value(:unknown, fn
      "ALIVE" -> :alive
      "LOST " <> why -> {:lost, why}
      _ -> nil
    end)
  end

  @doc "Parse `KEY=value` result lines (INDEX/SERIAL) out of script stdout."
  @spec parse_kv(String.t(), [String.t()]) :: %{optional(atom()) => term()}
  def parse_kv(output, keys) do
    for line <- String.split(output, "\n"),
        [k, v] <- [String.split(String.trim(line), "=", parts: 2)],
        k in keys,
        into: %{} do
      {kv_key(k), kv_val(k, v)}
    end
  end

  defp kv_key("INDEX"), do: :index
  defp kv_key("SERIAL"), do: :serial
  defp kv_val("INDEX", v), do: String.to_integer(v)
  defp kv_val(_k, v), do: v

  @doc """
  Boot a base redroid (admission-gated) and adb-connect it. Returns an
  `%Instance{}` with no node yet — the app isn't deployed/launched until `launch/2`.
  `{:error, :box_busy}` when admission refuses (caller backs off).

  The instance is recorded as this BEAM's (`ci-farm.sh` ownership record:
  `System.pid/0`, `:run` as its label, the queue's `MOB_CI_JOB_ID` /
  `MOB_CI_CELL_ID`), so `reap/0` leaves it alone while this BEAM lives and
  downs it once it is gone. A SIGTERM to this BEAM releases it first
  (`trap_sigterm/0`).
  """
  @spec boot(keyword()) :: {:ok, Instance.t()} | {:error, term()}
  def boot(opts \\ []) do
    {w, h, dpi} = Keyword.get(opts, :profile, {1080, 2340, 440})

    if admit?() do
      trap_sigterm()
      env = [{"MOB_CI_FARM_OWNER_PID", System.pid()}, {"MOB_CI_FARM_RUN", to_string(opts[:run] || "")}]

      case sh_status(["boot", to_string(w), to_string(h), to_string(dpi)], env) do
        {out, 0} ->
          %{index: i, serial: ser} = parse_kv(out, ["INDEX", "SERIAL"])
          {:ok, %Instance{index: i, serial: ser, suffix: suffix(i), dist_port: dist_port(i)}}

        {_out, 4} ->
          {:error, :box_busy}

        {out, code} ->
          {:error, {:boot_failed, code, String.slice(out, -400, 400)}}
      end
    else
      {:error, :box_busy}
    end
  end

  @doc """
  On SIGTERM (`systemctl stop` of a lane worker, `ci-run.sh pause`, the
  queue's cell timeout), release every instance this BEAM owns before the VM
  stops: the stop doesn't run the cell's `after` blocks. Installed once, by
  the first `boot/1`.
  """
  @spec trap_sigterm() :: :ok
  def trap_sigterm do
    _ = System.trap_signal(:sigterm, __MODULE__, fn -> release_owned() end)
    :ok
  end

  @doc "Release every instance owner `pid` (default this BEAM) has recorded (`ci-farm.sh down-owned`)."
  @spec release_owned(String.t()) :: :ok
  def release_owned(pid \\ System.pid()), do: (sh(["down-owned", pid]); :ok)

  @doc """
  Down every CI instance no live cell owns (`ci-farm.sh reap`): its owner
  process is gone, or it has no owner and is older than
  `MOB_CI_FARM_REAP_AFTER_MIN` (20) minutes. Never a live owner's, never a
  staging `redroid<N>`. Returns the script's `down|keep|forget` lines, or
  its `reap: …` error (docker couldn't list: nothing was touched).
  """
  @spec reap() :: [String.t()]
  def reap do
    sh(["reap"])
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.match?(&1, ~r/^(down|keep|forget|reap:) /))
  end

  @doc """
  Launch the deployed app on `instance` with the CI node identity (tunnels +
  relaunch), then wait for its node to register. `app` is the host `:app`, `pkg`
  the Android package. The node is dialled with `:cookies` (default
  `dist_cookies(pkg)`: the project's mob_dev-managed private cookie, then the
  legacy `:mob_secret`). Returns the instance with `:node` populated.
  """
  @spec launch(Instance.t(), keyword()) :: {:ok, Instance.t()} | {:error, term()}
  def launch(%Instance{} = inst, opts) do
    app = Keyword.fetch!(opts, :app)
    pkg = Keyword.fetch!(opts, :pkg)
    node = node_name(app, inst.suffix)
    cookies = Keyword.get_lazy(opts, :cookies, fn -> dist_cookies(pkg) end)

    case sh_status(["launch", to_string(inst.index), inst.suffix, to_string(inst.dist_port), pkg]) do
      {_out, 0} ->
        if await_node(node, Keyword.get(opts, :timeout_ms, 60_000), cookies),
          do: {:ok, %{inst | node: node}},
          else: {:error, {:node_never_registered, node}}

      {out, code} ->
        {:error, {:launch_failed, code, String.slice(out, -400, 400)}}
    end
  end

  @doc """
  The cookies a deployed app may answer to, most likely first: the private
  per-project cookie mob_dev writes at deploy (`~/.mob/dist_cookies/<sha256 of
  the bundle id>`, MOB-49 — the bundle id is the Android package for both
  hosts), then the public legacy `:mob_secret` of pre-MOB-49 apps.
  """
  @spec dist_cookies(String.t()) :: [atom(), ...]
  def dist_cookies(pkg) do
    managed = pkg |> MobDev.DistCookie.default_path() |> MobDev.DistCookie.load_or_create!()
    Enum.uniq([managed, MobDev.DistCookie.legacy_cookie()])
  end

  @doc "Poll until `node` accepts one of `cookies` over distribution, or the timeout elapses."
  @spec await_node(node(), non_neg_integer(), [atom(), ...]) :: boolean()
  def await_node(node, timeout_ms, cookies \\ [MobDev.DistCookie.legacy_cookie()]) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(node, cookies, deadline)
  end

  defp do_await(node, cookies, deadline) do
    cond do
      # Per-node cookies need a distributed host (`MobCi.Dist.ensure!/1`); without
      # one no cookie can be tried, so don't spin until the deadline.
      not Node.alive?() -> false
      match?({:ok, _}, MobDev.DistCookie.connect(node, cookies)) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(2_000); do_await(node, cookies, deadline)
    end
  end

  @doc "Release an instance (removes the container and its ownership record, frees the slot)."
  @spec release(Instance.t() | non_neg_integer()) :: :ok
  def release(%Instance{index: i}), do: release(i)
  def release(index) when is_integer(index), do: (sh(["down", to_string(index)]); :ok)

  # ── permissions and the release install (MOB-414) ───────────────────────────

  @doc """
  Grant the runtime permissions `plugins`' manifests declare to `pkg` on the
  instance (`MobDev.Plugin.SelfTest.grant_permissions/4`, `adb shell pm
  grant`). Must run after install and BEFORE the app launches: a self-test
  must never meet a system prompt, and changing a running app's grants can
  kill it. Returns the grant attempts (a non-runtime permission's refusal is
  recorded, not raised).
  """
  @spec grant_permissions(Instance.t(), list(), String.t(), (String.t(), [String.t()] -> {String.t(), integer()})) ::
          [MobDev.Plugin.SelfTest.grant()]
  def grant_permissions(%Instance{serial: serial}, plugins, pkg, cmd \\ &cmd/2) do
    device = %MobDev.Device{platform: :android, type: :emulator, serial: serial}
    MobDev.Plugin.SelfTest.grant_permissions(device, plugins, pkg, cmd)
  end

  @doc "Install an APK on the instance (`adb install -r`)."
  @spec install_apk(Instance.t(), Path.t()) :: :ok | {:error, term()}
  def install_apk(%Instance{serial: serial}, apk) do
    case cmd("adb", ["-s", serial, "install", "-r", apk]) do
      {out, 0} -> if out =~ "Success", do: :ok, else: {:error, {:install, String.slice(out, -400, 400)}}
      {out, code} -> {:error, {:install, code, String.slice(out, -400, 400)}}
    end
  end

  @doc """
  Make a freshly installed release build dialable. A release APK carries no
  dist cookie (mob_dev writes it at deploy, the release path never does) and
  unpacks its OTP tree on first launch, wiping `files/otp` — so: launch once,
  wait for `files/otp/.installed_version`, stop the app, then write the
  managed cookie as root (a release APK is not debuggable, `run-as` is
  refused; redroid's adb shell is uid shell, its `su` is root) with the app's
  owner and SELinux label. `launch/2` then starts it for real.
  """
  @spec provision_release(Instance.t(), keyword()) :: :ok | {:error, term()}
  def provision_release(%Instance{} = inst, opts) do
    app = Keyword.fetch!(opts, :app)
    pkg = Keyword.fetch!(opts, :pkg)
    [cookie | _] = Keyword.get_lazy(opts, :cookies, fn -> dist_cookies(pkg) end)
    timeout = Keyword.get(opts, :timeout_ms, 90_000)

    with {_out, 0} <- sh_status(["launch", to_string(inst.index), inst.suffix, to_string(inst.dist_port), pkg]),
         :ok <- await_extracted(inst.serial, pkg, System.monotonic_time(:millisecond) + timeout),
         {_out, 0} <- cmd("adb", ["-s", inst.serial, "shell", "am", "force-stop", pkg]),
         {_out, 0} <- cmd("adb", ["-s", inst.serial, "shell", as_root(write_cookie_script(pkg, app, cookie))]) do
      :ok
    else
      {:error, _} = err -> err
      {out, code} -> {:error, {:provision_release, code, String.slice(out, -400, 400)}}
    end
  end

  defp await_extracted(serial, pkg, deadline) do
    marker = "/data/data/#{pkg}/files/otp/.installed_version"

    case cmd("adb", ["-s", serial, "shell", as_root("test -f #{marker} && echo present")]) do
      {out, 0} when is_binary(out) ->
        if out =~ "present", do: :ok, else: retry_extracted(serial, pkg, deadline)

      _ ->
        retry_extracted(serial, pkg, deadline)
    end
  end

  defp retry_extracted(serial, pkg, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:otp_not_extracted, pkg}}
    else
      Process.sleep(2_000)
      await_extracted(serial, pkg, deadline)
    end
  end

  @doc """
  The device shell script writing `cookie` to
  `files/otp/<app>/mob_dist_cookie` (where `Mob.Dist` reads it), owned by the
  app's uid with mode 600 and its data dir's SELinux label. Pure; the cookie
  is mob_dev's 64-hex managed cookie, so it needs no quoting.
  """
  @spec write_cookie_script(String.t(), atom() | String.t(), atom() | String.t()) :: String.t()
  def write_cookie_script(pkg, app, cookie) do
    cookie = to_string(cookie)

    unless cookie =~ ~r/\A[A-Za-z0-9_]+\z/,
      do: raise(ArgumentError, "refusing to put a non-alphanumeric cookie in a shell script")

    dir = "/data/data/#{pkg}/files/otp/#{app}"
    file = "#{dir}/mob_dist_cookie"

    "mkdir -p #{dir} && printf %s #{cookie} > #{file} && " <>
      "chown $(stat -c %u:%g /data/data/#{pkg}) #{dir} #{file} && chmod 600 #{file} && " <>
      "chcon $(stat -c %C /data/data/#{pkg}/files) #{dir} #{file}"
  end

  @doc """
  `script` run as root through the device's `su` (redroid ships
  `/system/xbin/su`; `adb shell` itself is uid shell and can't read another
  app's data dir). The scripts mob_ci builds hold no single quote.
  """
  @spec as_root(String.t()) :: String.t()
  def as_root(script) do
    if String.contains?(script, "'"), do: raise(ArgumentError, "as_root: script must not contain a single quote")
    "su 0 sh -c '#{script}'"
  end

  defp cmd(exe, args) do
    System.cmd(System.find_executable(exe) || exe, args, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 127}
  end

  # ── shell plumbing ──────────────────────────────────────────────────────────

  defp sh(args), do: elem(sh_status(args), 0)

  defp sh_status(args, env \\ []) do
    System.cmd("bash", [@script | args], env: env, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 127}
  end
end
