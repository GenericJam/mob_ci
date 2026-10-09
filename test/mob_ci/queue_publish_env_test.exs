defmodule MobCi.QueuePublishEnvTest do
  # Not async: points PATH at a stub `mix` and sets the queue's variables in
  # this VM's environment, as a lane worker running inside a cell would.
  use ExUnit.Case, async: false

  alias MobCi.Queue

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_ci_publish_env_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    seen = Path.join(dir, "seen.env")

    File.write!(Path.join(dir, "mix"), """
    #!/usr/bin/env bash
    echo "trigger=${MOB_CI_TRIGGER-unset} job=${MOB_CI_JOB_ID-unset} args=$*" > #{seen}
    """)

    File.chmod!(Path.join(dir, "mix"), 0o755)
    saved = for k <- ~w(PATH MOB_CI_TRIGGER MOB_CI_JOB_ID), into: %{}, do: {k, System.get_env(k)}
    System.put_env(%{"PATH" => dir <> ":" <> saved["PATH"], "MOB_CI_TRIGGER" => "poll", "MOB_CI_JOB_ID" => "8"})

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      File.rm_rf!(dir)
    end)

    %{dir: dir, seen: seen}
  end

  test "the report runs without the queue's trigger and job id (a hook it starts isn't filed under the job)", %{dir: dir, seen: seen} do
    assert Queue.publish(%{id: 8, trigger: "poll"}, dir) == 0
    assert File.read!(seen) =~ ~r/^trigger=unset job=unset args=.*ci\.report/
    assert File.exists?(Path.join(dir, "job-8-report.log"))
  end
end
