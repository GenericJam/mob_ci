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

  @type source :: %{key: String.t(), dep: Versions.dep(), label: String.t()}

  @ready ".mob_ci_ready"

  # Runs in the validator project: manifests in (a term file), errors out.
  @script ~S"""
  [input, output] = System.argv()
  activated = input |> File.read!() |> :erlang.binary_to_term()
  %{errors: errors} = MobDev.Plugin.Validator.cross_validate(activated)
  File.write!(output, :erlang.term_to_binary(Enum.map(errors, &to_string/1)))
  """

  @doc """
  Where a resolved row's mob_dev comes from: a Hex release (`{:mob_dev, "==
  x.y.z"}`) or the row's checkout of a sha (`path:`), with the cache key and a
  label for the console.
  """
  @spec source(Versions.resolved()) :: source()
  def source(%{repos: %{mob_dev: %{source: :hex, version: v}}}),
    do: %{key: "hex-#{v}", dep: {:mob_dev, "== #{v}"}, label: "mob_dev #{v} (hex)"}

  def source(%{repos: %{mob_dev: %{source: {:git, _}, sha: sha, dir: dir}}}),
    do: %{
      key: "git-#{sha}",
      dep: {:mob_dev, path: dir, override: true},
      label: "mob_dev #{String.slice(sha, 0, 12)} (git #{dir})"
    }

  @doc "The validator project for `source` under `cache` (default `MobCi.Versions.cache_dir/0`)."
  @spec project_dir(source(), Path.t()) :: Path.t()
  def project_dir(%{key: key}, cache \\ Versions.cache_dir()),
    do: Path.join([cache, "validators", "mob_dev-" <> key])

  @doc "The validator project's `mix.exs`: nothing but the row's mob_dev."
  @spec mix_exs(source()) :: String.t()
  def mix_exs(%{dep: dep}) do
    """
    defmodule MobCiRowValidator.MixProject do
      use Mix.Project

      def project do
        [app: :mob_ci_row_validator, version: "0.0.0", elixir: "~> 1.17", deps: [#{Versions.render_dep(dep)}]]
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
      tmp = Path.join(System.tmp_dir!(), "mob_ci_validate_#{System.unique_integer([:positive])}")
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
  # it's done (a pin's mob_dev never changes: a Hex version or a sha).
  defp ensure_project(dir, source, cache) do
    if File.exists?(Path.join(dir, @ready)) do
      :ok
    else
      result =
        Remote.locked(cache, "validator-mob_dev-#{source.key}", fn ->
          if File.exists?(Path.join(dir, @ready)), do: :ok, else: build_project(dir, source)
        end)

      case result do
        :ok -> :ok
        {:error, {:lock_timeout, lock}} -> {:error, "timed out waiting for #{lock}"}
        {:error, _} = err -> err
      end
    end
  end

  defp build_project(dir, source) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), mix_exs(source))

    with {:deps, {_, 0}} <- {:deps, mix(dir, ["deps.get"])},
         {:compile, {_, 0}} <- {:compile, mix(dir, ["compile"])} do
      File.write!(Path.join(dir, @ready), source.label <> "\n")
      :ok
    else
      {step, {out, code}} -> {:error, "#{source.label}: mix #{step} exited #{code}: #{tail(out)}"}
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
