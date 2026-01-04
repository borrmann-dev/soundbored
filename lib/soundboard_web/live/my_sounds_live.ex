defmodule SoundboardWeb.MySoundsLive do
  use SoundboardWeb, :live_view
  use SoundboardWeb.Live.PresenceLive
  alias SoundboardWeb.Components.Soundboard.{DeleteModal, EditModal}
  import EditModal
  import DeleteModal
  import SoundboardWeb.Components.Soundboard.TagComponents, only: [tag_filter_button: 1]
  alias Soundboard.{Favorites, Repo, Sound, Volume}
  alias SoundboardWeb.Live.{FileFilter, TagHandler}
  import TagHandler, only: [all_tags: 1, tag_selected?: 2]
  import FileFilter, only: [filter_files: 3]
  import Ecto.Query
  require Logger

  @pubsub_topic "soundboard"

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Soundboard.PubSub, @pubsub_topic)
    end

    socket =
      socket
      |> mount_presence(session)
      |> assign(:current_path, "/my-sounds")
      |> assign(:current_user, get_user_from_session(session))
      |> assign(:search_query, "")
      |> assign(:selected_tags, [])
      |> assign(:show_modal, false)
      |> assign(:current_sound, nil)
      |> assign(:tag_input, "")
      |> assign(:tag_suggestions, [])
      |> assign(:show_delete_confirm, false)

    if socket.assigns[:current_user] do
      user = socket.assigns.current_user
      favorites = Favorites.list_favorites(user.id)

      # Get only sounds uploaded by the current user
      my_sounds =
        Sound.with_tags()
        |> Repo.all()
        |> Repo.preload([:user, user_sound_settings: [:user]])
        |> Enum.filter(&(&1.user_id == user.id))
        |> Enum.sort_by(&String.downcase(&1.filename))

      {:ok, assign(socket, favorites: favorites, my_sounds: my_sounds)}
    else
      {:ok, assign(socket, favorites: [], my_sounds: [])}
    end
  end

  # Get filtered sounds based on search query and selected tags (public for template access)
  def filtered_sounds(assigns) do
    assigns.my_sounds
    |> filter_files(assigns.search_query, assigns.selected_tags)
  end

  @impl true
  def handle_event("play", %{"name" => filename}, socket) do
    username =
      if socket.assigns.current_user,
        do: socket.assigns.current_user.username,
        else: "Anonymous"

    SoundboardWeb.AudioPlayer.play_sound(filename, username)
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, query)}
  end

  @impl true
  def handle_event("toggle_tag_filter", %{"tag" => tag_name}, socket) do
    tag = Enum.find(all_tags(socket.assigns.my_sounds), &(&1.name == tag_name))
    current_tag = List.first(socket.assigns.selected_tags)
    selected_tags = if current_tag && current_tag.id == tag.id, do: [], else: [tag]

    {:noreply,
     socket
     |> assign(:selected_tags, selected_tags)
     |> assign(:search_query, "")}
  end

  @impl true
  def handle_event("toggle_favorite", %{"sound-id" => sound_id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "You must be logged in to favorite sounds")}

      user ->
        case Favorites.toggle_favorite(user.id, sound_id) do
          {:ok, _favorite} ->
            favorites = Favorites.list_favorites(user.id)

            {:noreply,
             socket
             |> assign(:favorites, favorites)
             |> put_flash(:info, "Favorites updated!")}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  # Edit modal handlers
  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    sound = Sound.get_sound!(id)
    {:noreply, assign(socket, current_sound: sound, show_modal: true)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:current_sound, nil)
     |> assign(:tag_input, "")
     |> assign(:tag_suggestions, [])}
  end

  @impl true
  def handle_event("close_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:current_sound, nil)
     |> assign(:tag_input, "")
     |> assign(:tag_suggestions, [])}
  end

  @impl true
  def handle_event("close_modal_key", %{"key" => "Escape"}, socket) do
    if socket.assigns.show_modal do
      {:noreply,
       socket
       |> assign(:show_modal, false)
       |> assign(:current_sound, nil)
       |> assign(:tag_input, "")
       |> assign(:tag_suggestions, [])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate_sound", %{"_target" => ["filename"]} = params, socket) do
    filename = (params["filename"] || "") <> ".mp3"
    sound_id = params["sound_id"]

    existing_sound =
      Sound
      |> where([s], s.filename == ^filename and s.id != ^sound_id)
      |> Repo.one()

    if existing_sound do
      {:noreply, put_flash(socket, :error, "A sound with that name already exists")}
    else
      {:noreply, clear_flash(socket)}
    end
  end

  @impl true
  def handle_event("validate_sound", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_sound", params, socket) do
    sound = socket.assigns.current_sound
    user_id = socket.assigns.current_user.id

    case update_sound(sound, user_id, params) do
      {:ok, _updated_sound} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sound updated successfully")
         |> assign(:show_modal, false)
         |> assign(:current_sound, nil)
         |> reload_sounds()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update sound")}
    end
  end

  @impl true
  def handle_event("add_tag", %{"key" => "Enter", "value" => value}, socket) when value != "" do
    sound = socket.assigns.current_sound

    case TagHandler.add_tag(socket, value, sound.tags) do
      {:ok, updated_socket} ->
        {:noreply,
         updated_socket
         |> assign(:tag_input, "")
         |> assign(:tag_suggestions, [])
         |> reload_sounds()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("add_tag", %{"value" => value}, socket) do
    suggestions = TagHandler.search_tags(value)
    {:noreply, socket |> assign(:tag_input, value) |> assign(:tag_suggestions, suggestions)}
  end

  @impl true
  def handle_event("tag_input", %{"value" => value}, socket) do
    suggestions = TagHandler.search_tags(value)
    {:noreply, socket |> assign(:tag_input, value) |> assign(:tag_suggestions, suggestions)}
  end

  @impl true
  def handle_event("remove_tag", %{"tag" => tag_name}, socket) do
    sound = socket.assigns.current_sound
    tags = Enum.reject(sound.tags, &(&1.name == tag_name))

    case TagHandler.update_sound_tags(sound, tags) do
      {:ok, updated_sound} ->
        {:noreply, socket |> assign(:current_sound, updated_sound) |> reload_sounds()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to remove tag")}
    end
  end

  @impl true
  def handle_event("select_tag", %{"tag" => tag_name}, socket) do
    tag = Enum.find(TagHandler.search_tags(""), &(&1.name == tag_name))
    sound = socket.assigns.current_sound

    if tag do
      case TagHandler.update_sound_tags(sound, [tag | sound.tags]) do
        {:ok, updated_sound} ->
          {:noreply,
           socket
           |> assign(:current_sound, updated_sound)
           |> assign(:tag_input, "")
           |> assign(:tag_suggestions, [])
           |> reload_sounds()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to add tag")}
      end
    else
      {:noreply, put_flash(socket, :error, "Tag not found")}
    end
  end

  @impl true
  def handle_event("show_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :show_delete_confirm, true)}
  end

  @impl true
  def handle_event("hide_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :show_delete_confirm, false)}
  end

  @impl true
  def handle_event("delete_sound", _params, socket) do
    sound = socket.assigns.current_sound

    case Repo.delete(sound) do
      {:ok, _} ->
        SoundboardWeb.AudioPlayer.invalidate_cache(sound.filename)

        if sound.source_type == "local" do
          uploads_dir = Application.get_env(:soundboard, :uploads_dir, "priv/static/uploads")
          sound_path = Path.join(uploads_dir, sound.filename)
          _ = File.rm(sound_path)
        end

        {:noreply,
         socket
         |> assign(:show_modal, false)
         |> assign(:show_delete_confirm, false)
         |> assign(:current_sound, nil)
         |> reload_sounds()
         |> put_flash(:info, "Sound deleted successfully")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete sound")
         |> assign(:show_delete_confirm, false)}
    end
  end

  @impl true
  def handle_event("update_volume", %{"volume" => volume, "target" => "edit"}, socket) do
    case socket.assigns.current_sound do
      nil ->
        {:noreply, socket}

      sound ->
        default_percent = Volume.decimal_to_percent(sound.volume)

        updated_sound =
          Map.put(sound, :volume, Volume.percent_to_decimal(volume, default_percent))

        {:noreply, assign(socket, :current_sound, updated_sound)}
    end
  end

  @impl true
  def handle_event("update_volume", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:sound_played, %{filename: filename, played_by: username}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "#{username} played #{filename}")
     |> clear_flash_after_timeout()}
  end

  @impl true
  def handle_info({:sound_played, filename}, socket) when is_binary(filename) do
    username =
      if socket.assigns.current_user,
        do: socket.assigns.current_user.username,
        else: "Anonymous"

    {:noreply,
     socket
     |> put_flash(:info, "#{username} played #{filename}")
     |> clear_flash_after_timeout()}
  end

  @impl true
  def handle_info({:error, message}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, message)
     |> clear_flash_after_timeout()}
  end

  @impl true
  def handle_info({:files_updated}, socket) do
    if socket.assigns[:current_user] do
      user = socket.assigns.current_user
      favorites = Favorites.list_favorites(user.id)

      my_sounds =
        Sound.with_tags()
        |> Repo.all()
        |> Repo.preload([:user, user_sound_settings: [:user]])
        |> Enum.filter(&(&1.user_id == user.id))
        |> Enum.sort_by(&String.downcase(&1.filename))

      {:noreply, assign(socket, favorites: favorites, my_sounds: my_sounds)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  @impl true
  def handle_info({:stats_updated}, socket) do
    {:noreply, socket}
  end

  defp clear_flash_after_timeout(socket) do
    Process.send_after(self(), :clear_flash, 3000)
    socket
  end

  defp reload_sounds(socket) do
    if socket.assigns[:current_user] do
      user = socket.assigns.current_user
      favorites = Favorites.list_favorites(user.id)

      my_sounds =
        Sound.with_tags()
        |> Repo.all()
        |> Repo.preload([:user, user_sound_settings: [:user]])
        |> Enum.filter(&(&1.user_id == user.id))
        |> Enum.sort_by(&String.downcase(&1.filename))

      assign(socket, favorites: favorites, my_sounds: my_sounds)
    else
      socket
    end
  end

  defp update_sound(sound, user_id, params) do
    Repo.transaction(fn ->
      db_sound =
        Repo.get!(Sound, sound.id)
        |> Repo.preload(:user_sound_settings)

      uploads_dir = Application.get_env(:soundboard, :uploads_dir, "priv/static/uploads")
      old_path = Path.join(uploads_dir, db_sound.filename)
      new_filename = params["filename"] <> Path.extname(db_sound.filename)
      new_path = Path.join(uploads_dir, new_filename)

      sound_params = %{
        filename: new_filename,
        source_type: params["source_type"] || db_sound.source_type,
        url: params["url"],
        volume:
          params["volume"]
          |> Volume.percent_to_decimal(Volume.decimal_to_percent(db_sound.volume))
      }

      case Sound.changeset(db_sound, sound_params) |> Repo.update() do
        {:ok, updated_sound} ->
          update_user_settings(db_sound, user_id, params)
          SoundboardWeb.AudioPlayer.invalidate_cache(db_sound.filename)
          SoundboardWeb.AudioPlayer.invalidate_cache(updated_sound.filename)
          maybe_rename_file(db_sound, old_path, new_path, new_filename)
          Phoenix.PubSub.broadcast(Soundboard.PubSub, "soundboard", {:files_updated})
          updated_sound

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp maybe_rename_file(sound, old_path, new_path, new_filename) do
    if sound.source_type == "local" && sound.filename != new_filename && File.exists?(old_path) do
      File.rename(old_path, new_path)
    end
  end

  defp update_user_settings(sound, user_id, params) do
    user_setting =
      Enum.find(sound.user_sound_settings, &(&1.user_id == user_id)) ||
        %Soundboard.UserSoundSetting{sound_id: sound.id, user_id: user_id}

    setting_params = %{
      user_id: user_id,
      sound_id: sound.id,
      is_join_sound: params["is_join_sound"] == "true",
      is_leave_sound: params["is_leave_sound"] == "true"
    }

    user_setting
    |> Soundboard.UserSoundSetting.changeset(setting_params)
    |> Repo.insert_or_update()
  end
end
