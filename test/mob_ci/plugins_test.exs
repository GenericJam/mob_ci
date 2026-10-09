defmodule MobCi.PluginsTest do
  use ExUnit.Case, async: true

  alias MobCi.Plugins
  alias MobDev.Plugin.Validator

  describe "manifest loading" do
    test "every sample-set fixture loads (tier-0 → nil, others → map)" do
      assert Plugins.load_manifest(:mob_ci_palette) == nil, "tier-0 ships no manifest"

      for name <- [:mob_ci_haptic, :mob_ci_gauge, :mob_ci_notes, :mob_ci_pulse] do
        m = Plugins.load_manifest(name)
        assert is_map(m), "#{name} manifest should load"
        assert m.name == name
      end
    end
  end

  describe "real ecosystem plugins resolve from ~/code (realism gate)" do
    test "a fixture wins; a real plugin falls back to the sibling repo" do
      assert Plugins.fixture_dir(:mob_ci_haptic) == Path.expand("../../fixtures/mob_ci_haptic", __DIR__)
      assert Plugins.fixture_dir(:mob_camera) == Path.expand("~/code/mob_camera")
    end

    test "load_manifest reads a real plugin's manifest" do
      m = Plugins.load_manifest(:mob_camera)
      assert is_map(m) and m.name == :mob_camera
    end
  end

  describe "pure projections over the sample set" do
    test "nif modules come from the tier-1/native plugins" do
      assert :mob_ci_haptic_nif in Plugins.expected_nif_modules(Plugins.sample_set())
    end

    test "screen routes come from the tier-3 plugin" do
      routes = Plugins.expected_screens(Plugins.sample_set())
      assert "/mob_ci_notes/list" in routes
      assert "/mob_ci_notes/detail" in routes
    end

    test "components come from the tier-2 plugin" do
      assert :mob_ci_gauge in Plugins.expected_components(Plugins.sample_set())
    end

    test "supervised workers come from the tier-4 plugin" do
      assert MobCiPulse.Worker in Plugins.expected_supervised(Plugins.sample_set())
    end

    test "migration namespaces come from the tier-3 plugin" do
      assert "mob_ci_notes_" in Plugins.expected_migration_namespaces(Plugins.sample_set())
    end
  end

  describe "the sample set is internally consistent (real cross_validate)" do
    test "the milestone-1 sample set has no cross-plugin conflicts" do
      result = Validator.cross_validate(Plugins.activated(Plugins.sample_set()))
      assert result.errors == [], "sample set should compose cleanly: #{inspect(result.errors)}"
    end

    test "the clash pair is rejected on route, NIF, and component" do
      result = Validator.cross_validate(Plugins.activated([:mob_ci_clash_a, :mob_ci_clash_b]))
      blob = Enum.join(result.errors, "\n")
      assert result.errors != []
      assert blob =~ "/mob_ci_clash/home"
      assert blob =~ "mob_ci_clash_nif"
      assert blob =~ "mob_ci_clash_widget"
    end
  end
end
