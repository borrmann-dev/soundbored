defmodule Soundboard.Favorites do
  @moduledoc """
  The Favorites module.
  """
  import Ecto.Query
  alias Soundboard.{Favorites.Favorite, Repo}

  def list_favorites(user_id) do
    Favorite
    |> where([f], f.user_id == ^user_id)
    |> select([f], f.sound_id)
    |> Repo.all()
  end

  def toggle_favorite(user_id, sound_id) do
    case Repo.get_by(Favorite, user_id: user_id, sound_id: sound_id) do
      nil -> add_favorite(user_id, sound_id)
      favorite -> Repo.delete(favorite)
    end
  end

  defp add_favorite(user_id, sound_id) do
    %Favorite{}
    |> Favorite.changeset(%{user_id: user_id, sound_id: sound_id})
    |> Repo.insert()
  end

  def favorite?(user_id, sound_id) do
    Repo.exists?(from f in Favorite, where: f.user_id == ^user_id and f.sound_id == ^sound_id)
  end
end
