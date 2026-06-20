defmodule MobCiPaletteTest do
  use ExUnit.Case, async: true

  # Tier 0 ships no manifest — the contract is just "the module compiles
  # against mob". Grow this suite alongside your plugin's pure logic.
  test "the plugin module compiles" do
    assert Code.ensure_loaded?(MobCiPalette)
  end
end
