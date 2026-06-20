defmodule MobCiNotes.Migrations.CreateItems do
  # Rename this file with a real timestamp before publishing (the leading
  # integer is the Ecto version). mob_dev namespaces the copied filename by
  # the plugin's repo_namespace so it can't collide with other plugins'.
  use Ecto.Migration

  def change do
    create table(:mob_ci_notes_items) do
      add(:name, :string, null: false)
    end
  end
end
