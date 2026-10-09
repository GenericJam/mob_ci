defmodule MobCi.ExclusionsTest do
  # Parks a plugin through the application env, so not async.
  use ExUnit.Case, async: false

  alias MobCi.{DeviceCaps, Sets, Triggers, Versions}

  setup do
    [parked | _] = DeviceCaps.buildable(Versions.plugins())
    Application.put_env(:mob_ci, :exclusions, [{parked, "F99: parked for this test"}])
    on_exit(fn -> Application.delete_env(:mob_ci, :exclusions) end)
    %{parked: parked}
  end

  test "a parked plugin leaves the built pool; include_excluded: true (what --static plans with) keeps it",
       %{parked: parked} do
    refute parked in Sets.pool()
    assert Sets.pool(include_excluded: true) == DeviceCaps.buildable(Versions.plugins())
  end

  test "a parked plugin keeps its singleton cell: alone it doesn't collide", %{parked: parked} do
    assert Sets.resolve({:singleton, parked}, []) == {:ok, [parked]}
    assert Sets.parse("singleton:#{parked}") == {:ok, {:singleton, parked}}
    assert "singleton:#{parked}" in Sets.nightly()
    assert "singleton:#{parked}" in Triggers.sets_for_repos([parked])
  end
end
