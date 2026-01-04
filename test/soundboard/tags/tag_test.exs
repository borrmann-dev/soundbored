defmodule Soundboard.Tags.TagTest do
  @moduledoc """
  Tests the Tag module.
  """
  use Soundboard.DataCase
  alias Soundboard.Accounts.User
  alias Soundboard.{Repo, Sound, Tag}

  import Ecto.Changeset

  describe "tag validation" do
    test "requires name" do
      changeset = Tag.changeset(%Tag{}, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "enforces unique names" do
      unique_name = "unique_tag_#{System.unique_integer([:positive])}"

      {:ok, _tag} =
        %Tag{name: unique_name}
        |> Tag.changeset(%{})
        |> unique_constraint(:name)
        |> Repo.insert()

      {:error, changeset} =
        %Tag{name: unique_name}
        |> Tag.changeset(%{})
        |> unique_constraint(:name)
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "tag management" do
    setup do
      user = insert_user()
      {:ok, sound} = insert_sound(user)
      {:ok, tag} = %Tag{name: "test_tag"} |> Tag.changeset(%{}) |> Repo.insert()
      %{sound: sound, tag: tag}
    end

    test "associates tags with sounds", %{sound: sound, tag: tag} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Insert directly into join table with timestamps
      Repo.query!(
        "INSERT INTO sound_tags (sound_id, tag_id, inserted_at, updated_at) VALUES (?, ?, ?, ?)",
        [sound.id, tag.id, now, now]
      )

      updated_sound = Repo.preload(sound, :tags)
      assert [%{name: "test_tag"}] = updated_sound.tags
    end
  end

  describe "tag search" do
    setup do
      suffix = System.unique_integer([:positive])
      {:ok, tag1} = Repo.insert(%Tag{name: "searchable_#{suffix}"})
      {:ok, tag2} = Repo.insert(%Tag{name: "searchable_extra_#{suffix}"})
      {:ok, _} = Repo.insert(%Tag{name: "other_#{suffix}"})
      %{tag1: tag1, tag2: tag2, suffix: suffix}
    end

    test "finds tags by partial name match", %{suffix: suffix} do
      results = Tag.search("searchable_#{suffix}") |> Repo.all()
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["searchable_#{suffix}", "searchable_extra_#{suffix}"]
    end

    test "search is case insensitive", %{suffix: suffix} do
      results = Tag.search("SEARCHABLE_#{suffix}") |> Repo.all()
      assert length(results) == 2
      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["searchable_#{suffix}", "searchable_extra_#{suffix}"]
    end
  end

  # Helper functions
  defp insert_user do
    {:ok, user} =
      %Soundboard.Accounts.User{}
      |> User.changeset(%{
        username: "test_user",
        discord_id: "123456",
        avatar: "test.jpg"
      })
      |> Repo.insert()

    user
  end

  defp insert_sound(user) do
    %Sound{}
    |> Sound.changeset(%{
      filename: "test_sound.mp3",
      source_type: "local",
      user_id: user.id
    })
    |> Repo.insert()
  end
end
