defmodule SoundboardWeb.MySoundsLive do
  use SoundboardWeb, :live_view
  use SoundboardWeb.Live.PresenceLive
  import SoundboardWeb.Components.Soundboard.TagComponents, only: [tag_filter_button: 1]
  alias Soundboard.{Favorites, Sound}
  alias SoundboardWeb.Live.{FileFilter, TagHandler}
  import TagHandler, only: [all_tags: 1, tag_selected?: 2]
  import FileFilter, only: [filter_files: 3]
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

    if socket.assigns[:current_user] do
      user = socket.assigns.current_user
      favorites = Favorites.list_favorites(user.id)

      # Get only sounds uploaded by the current user
      my_sounds =
        Sound.with_tags()
        |> Soundboard.Repo.all()
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
        |> Soundboard.Repo.all()
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
end
