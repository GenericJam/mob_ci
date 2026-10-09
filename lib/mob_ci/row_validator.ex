defmodule MobCi.RowValidator do
  @moduledoc """
  The static gate with the version row's own mob_dev.

  `MobDev.Plugin.Validator.cross_validate/1` decides whether a plugin set
  composes, and it is mob_dev code. mob_ci itself is built against one
  mob_dev (its `../mob_dev` path dep, i.e. master), so calling the validator
  in mob_ci's VM answers for that mob_dev, not the row's: a `hex` row's
  `static` column would say what mob_dev master thinks, not what the Hex
  release a user has will do. So a cell's static verdict comes from a small
  throwaway Mix project per mob_dev pin, under
  `~/.cache/mob_ci/validators/mob_dev-<hex-x.y.z | git-<sha>>`, that depends on
  exactly the row's mob_dev (`== x.y.z` from Hex, or a `path:` dep on the
  row's per-sha checkout, the same pin `MobCi.Versions` gives the generated
  host) and runs `cross_validate` there over the manifests mob_ci loaded.

  The project is created, `deps.get` and compiled once per pin (under the
  `MobCi.Versions.Remote` lock, so concurrent gates don't race), then reused;
  each verdict is one `mix run --no-start` (a few seconds).

  Not covered: the StreamData sweep's static soundness check (`mix ci.sweep
  --static`) calls the validator thousands of times and keeps using mob_ci's
  own mob_dev — it tests that validator, not a row.
  """

  alias MobCi.Versions
  alias MobCi.Versions.Remote

  @type source :: %{key: String.t(), deps: [Versions.dep()], label: String.t()}

  @ready ".mob_ci_ready"
  # A master sha's validator project unused this long is deleted (prune/2).
  @stale_days 7

  # Runs in the validator project: manifests in (a term file), errors out.
  @script ~S"""
  [input, output] = System.argv()
  activated = input |> File.read!() |> :erlang.binary_to_term()
  %{errors: errors} = MobDev.Plugin.Validator.cross_validate(activated)
  File.write!(output, :erlang.term_to_binary(Enum.map(errors, &to_string/1)))
  """

  @doc """
  Where a resolved row's mob_dev comes from — a Hex release (`{:mob_dev, "==
  x.y.z"}`) or the row's checkout of a sha (`path:`) — plus the row's mob,
  pinned the way the generated host pins it (`MobCi.Versions.dep/2`), so a
  mob_dev sha that needs an unreleased mob resolves here as it does there.
  Returns the deps, the cache key (both pins) and a console label.
  """
  @spec source(Versions.resolved()) :: source()
  def source(%{repos: repos}) do
    {dev_key, dev_dep, label} =
      case Map.fetch!(repos, :mob_dev) do
        %{source: :hex, version: v} ->
          {"hex-#{v}", {:mob_dev, "== #{v}"}, "mob_dev #{v} (hex)"}

        %{source: {:git, _}, sha: sha, dir: dir} ->
          {"git-#{sha}", {:mob_dev, path: dir, override: true}, "mob_dev #{String.slice(sha, 0, 12)} (git #{dir})"}
      end

    case Map.get(repos, :mob) do
      nil ->
        %{key: dev_key, deps: [dev_dep], label: label}

      %{source: :hex, version: v} = pin ->
        %{key: "#{dev_key}-mob-hex-#{v}", deps: [Versions.dep(:mob, pin), dev_dep], label: label}

      %{source: {:git, _}, sha: sha} = pin ->
        %{key: "#{dev_key}-mob-git-#{sha}", deps: [Versions.dep(:mob, pin), dev_dep], label: label}
    end
  end

  @doc "The validator project for `source` under `cache` (default `MobCi.Versions.cache_dir/0`)."
  @spec project_dir(source(), Path.t()) :: Path.t()
  def project_dir(%{key: key}, cache \\ Versions.cache_dir()),
    do: Path.join([cache, "validators", "mob_dev-" <> key])

  @doc "The validator project's `mix.exs`: nothing but the row's mob_dev (and mob)."
  @spec mix_exs(source()) :: String.t()
  def mix_exs(%{deps: deps}) do
    """
    defmodule MobCiRowValidator.MixProject do
      use Mix.Project

      def project do
        [app: :mob_ci_row_validator, version: "0.0.0", elixir: "~> 1.17", deps: [#{Enum.map_join(deps, ", ", &Versions.render_dep/1)}]]
      end
    end
    """
  end

  @doc """
  The cross-plugin conflicts of `activated` (`{plugin, manifest | nil}`
  pairs, `MobCi.Plugins.activated/1`) according to the row's mob_dev.
  Options: `:cache` (default `MobCi.Versions.cache_dir/0`).
  """
  @spec conflicts([{atom(), map() | nil}], Versions.resolved(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def conflicts(activated, resolved, opts \\ []) do
    cache = Keyword.get(opts, :cache, Versions.cache_dir())
    source = source(resolved)
    dir = project_dir(source, cache)

    with :ok <- ensure_project(dir, source, cache) do
      # Unique across OS processes: both lanes may run a gate at once.
      tmp = Path.join(System.tmp_dir!(), "mob_ci_validate_#{System.pid()}_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      input = Path.join(tmp, "in.term")
      output = Path.join(tmp, "out.term")
      File.write!(input, :erlang.term_to_binary(activated))

      try do
        case mix(dir, ["run", "--no-start", "-e", @script, input, output]) do
          {_, 0} -> {:ok, output |> File.read!() |> :erlang.binary_to_term()}
          {out, code} -> {:error, "cross_validate with #{source.label} exited #{code}: #{tail(out)}"}
        end
      after
        File.rm_rf(tmp)
      end
    end
  end

  # Create, fetch and compile the project once per pin; a ready marker says
  # it's done (a pin's mob_dev never changes: a Hex version or a sha) and its
  # mtime when the pin was last used.
  defp ensure_project(dir, source, cache) do
    ready = Path.join(dir, @ready)

    if File.exists?(ready) do
      File.touch(ready)
      :ok
    else
      result =
        Remote.locked(cache, "validator-mob_dev-#{source.key}", fn ->
          if File.exists?(ready), do: :ok, else: build_project(dir, source, cache)
        end)

      case result do
        :ok -> :ok
        {:error, {:lock_timeout, lock}} -> {:error, "timed out waiting for #{lock}"}
        {:error, _} = err -> err
      end
    end
  end

  defp build_project(dir, source, cache) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), mix_exs(source))

    with {:deps, {_, 0}} <- {:deps, mix(dir, ["deps.get"])},
         {:compile, {_, 0}} <- {:compile, mix(dir, ["compile"])} do
      File.write!(Path.join(dir, @ready), source.label <> "\n")
      prune(cache, @stale_days)
      :ok
    else
      {step, {out, code}} -> {:error, "#{source.label}: mix #{step} exited #{code}: #{tail(out)}"}
    end
  end

  @doc """
  Delete the validator projects of git pins (a `master` or `rc:` sha of mob_dev
  or mob) not used for `days`: each is ~40 MB, and master moves several times
  a day. All-Hex projects stay: there are few, and the `hex` row uses the
  newest every night. Runs after each new build.
  """
  @spec prune(Path.t(), non_neg_integer()) :: [Path.t()]
  def prune(cache, days) do
    cutoff = System.os_time(:second) - days * 86_400

    for dir <- Path.wildcard(Path.join([cache, "validators", "mob_dev-*"])),
        String.contains?(Path.basename(dir), "git-"),
        last_used(dir) < cutoff do
      File.rm_rf!(dir)
      dir
    end
  end

  defp last_used(dir) do
    case File.stat(Path.join(dir, @ready), time: :posix) do
      {:ok, %{mtime: t}} -> t
      _ -> dir |> File.stat!(time: :posix) |> Map.fetch!(:mtime)
    end
  end

  # A clean Mix environment: never the caller's MIX_ENV (mix test sets
  # `test`) or build/deps overrides.
  defp mix(dir, args) do
    env = [
      {"MIX_ENV", "dev"},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil},
      {"MIX_LOCKFILE", nil},
      {"MIX_EXS", nil}
    ]

    System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true)
  end

  defp tail(out), do: out |> String.split("\n") |> Enum.take(-15) |> Enum.join("\n")
end
