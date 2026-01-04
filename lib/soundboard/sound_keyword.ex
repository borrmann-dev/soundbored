defmodule Soundboard.SoundKeyword do
  @moduledoc """
  Schema for sound keywords - alternative search terms for sounds.
  Unlike tags (categories), keywords are used purely for search matching.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "sound_keywords" do
    field :keyword, :string
    belongs_to :sound, Soundboard.Sound

    timestamps()
  end

  def changeset(sound_keyword, attrs) do
    sound_keyword
    |> cast(attrs, [:keyword, :sound_id])
    |> validate_required([:keyword, :sound_id])
    |> validate_length(:keyword, min: 1, max: 100)
    |> unique_constraint([:sound_id, :keyword])
    |> foreign_key_constraint(:sound_id)
  end
end
