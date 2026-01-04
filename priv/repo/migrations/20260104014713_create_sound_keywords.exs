defmodule Soundboard.Repo.Migrations.CreateSoundKeywords do
  use Ecto.Migration

  def change do
    create table(:sound_keywords) do
      add :keyword, :string, null: false
      add :sound_id, references(:sounds, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:sound_keywords, [:sound_id])
    create index(:sound_keywords, [:keyword])
    create unique_index(:sound_keywords, [:sound_id, :keyword])
  end
end
