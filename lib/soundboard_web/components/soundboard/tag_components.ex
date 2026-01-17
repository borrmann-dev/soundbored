defmodule SoundboardWeb.Components.Soundboard.TagComponents do
  @moduledoc """
  Shared tag UI helpers for the soundboard modals.
  """
  use Phoenix.Component
  alias SoundboardWeb.Live.TagHandler

  attr :tags, :list, default: []
  attr :remove_event, :string, required: true
  attr :tag_key, :atom, default: :name
  attr :wrapper_class, :string, default: "mt-2 flex flex-wrap gap-2"

  def tag_badge_list(assigns) do
    assigns = assign_new(assigns, :tag_key, fn -> :name end)

    ~H"""
    <div class={@wrapper_class}>
      <%= for tag <- @tags do %>
        <% tag_name = tag_value(tag, @tag_key) %>
        <span class="inline-flex items-center gap-1 rounded-full bg-blue-50 dark:bg-blue-900 px-2 py-1 text-xs font-semibold text-blue-600 dark:text-blue-300">
          {tag_name}
          <button
            type="button"
            phx-click={@remove_event}
            phx-value-tag={tag_name}
            class="text-blue-600 dark:text-blue-300 hover:text-blue-500 dark:hover:text-blue-200"
          >
            <svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
              <path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z" />
            </svg>
          </button>
        </span>
      <% end %>
    </div>
    """
  end

  attr :tag_input, :string, default: ""
  attr :tag_suggestions, :list, default: []
  attr :select_event, :string, required: true
  attr :tag_key, :atom, default: :name

  attr :wrapper_class, :string,
    default:
      "absolute z-10 mt-1 w-full bg-white dark:bg-gray-700 shadow-lg max-h-60 rounded-md py-1 text-base overflow-auto focus:outline-none sm:text-sm"

  attr :suggestion_class, :string,
    default:
      "w-full text-left px-4 py-2 text-sm hover:bg-blue-50 dark:hover:bg-blue-900 dark:text-gray-100"

  def tag_suggestions_dropdown(assigns) do
    assigns = assign_new(assigns, :tag_input, fn -> "" end)

    ~H"""
    <%= if String.trim(@tag_input || "") != "" and @tag_suggestions != [] do %>
      <div class={@wrapper_class}>
        <%= for tag <- @tag_suggestions do %>
          <% tag_name = tag_value(tag, @tag_key) %>
          <% {before_part, match_part, after_part} = split_for_highlight(tag_name, @tag_input) %>
          <button
            type="button"
            phx-click={@select_event}
            phx-value-tag={tag_name}
            class={@suggestion_class}
          >
            <%= if match_part != "" do %>
              <%= before_part %><mark class="bg-yellow-200 dark:bg-yellow-800 font-semibold"><%= match_part %></mark><%= after_part %>
            <% else %>
              <%= tag_name %>
            <% end %>
          </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :tag, :any, required: true
  attr :selected_tags, :list, required: true
  attr :uploaded_files, :list, required: true
  attr :tag_key, :atom, default: :name
  attr :click_event, :string, default: "toggle_tag_filter"
  attr :class, :any, default: []
  attr :search_query, :string, default: ""

  def tag_filter_button(assigns) do
    assigns = assign_new(assigns, :tag_key, fn -> :name end)
    assigns = assign_new(assigns, :search_query, fn -> "" end)

    tag_name = tag_value(assigns.tag, assigns.tag_key)
    matches_search = tag_matches_query?(tag_name, assigns.search_query)
    is_selected = TagHandler.tag_selected?(assigns.tag, assigns.selected_tags)

    base_classes = "inline-flex items-center gap-1 rounded-full px-3 py-1 text-sm font-medium"

    button_classes =
      cond do
        is_selected ->
          [base_classes, "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300"]

        matches_search ->
          [
            base_classes,
            "bg-gray-200 text-gray-800 hover:bg-gray-300 dark:bg-gray-700 dark:text-gray-200 dark:hover:bg-gray-600"
          ]

        true ->
          [
            base_classes,
            "bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-400 dark:hover:bg-gray-700"
          ]
      end

    assigns = assign(assigns, :button_classes, button_classes)
    assigns = assign(assigns, :tag_name, tag_name)

    ~H"""
    <button
      phx-click={@click_event}
      phx-value-tag={@tag_name}
      class={@button_classes}
    >
      {@tag_name}
      <span class="text-xs">({TagHandler.count_sounds_with_tag(@uploaded_files, @tag)})</span>
    </button>
    """
  end

  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Type a tag and press Enter..."
  attr :input_id, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""
  attr :onkeydown, :string, default: nil
  attr :autocomplete, :string, default: nil
  attr :rest, :global

  def tag_input_field(assigns) do
    assigns = assign_new(assigns, :value, fn -> "" end)

    base_class =
      "block w-full rounded-md border-gray-300 dark:border-gray-600 shadow-sm focus:border-blue-500 " <>
        "focus:ring-blue-500 sm:text-sm dark:bg-gray-700 dark:text-gray-100 dark:placeholder-gray-400"

    assigns = assign(assigns, :base_class, base_class)

    ~H"""
    <input
      type="text"
      value={@value}
      placeholder={@placeholder}
      id={@input_id}
      disabled={@disabled}
      class={[@base_class, @class]}
      onkeydown={@onkeydown}
      autocomplete={@autocomplete}
      {@rest}
    />
    """
  end

  defp tag_value(tag, tag_key) when is_atom(tag_key) do
    case tag do
      %{^tag_key => value} -> value
      %{} -> Map.get(tag, :name) || tag
      _ -> tag
    end
  end

  defp tag_value(tag, _tag_key), do: tag

  defp split_for_highlight(text, query) when is_binary(text) and is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {text, "", ""}
    else
      # Case-insensitive search
      text_lower = String.downcase(text)
      query_lower = String.downcase(query)

      case String.split(text_lower, query_lower, parts: 2) do
        [before_lower, after_lower] ->
          # Find the actual position in the original text (case-sensitive)
          before_length = String.length(before_lower)
          match_length = String.length(query)
          match_start = before_length

          before_part = String.slice(text, 0, before_length)
          match_part = String.slice(text, match_start, match_length)
          after_part = String.slice(text, match_start + match_length, String.length(text))

          {before_part, match_part, after_part}

        _ ->
          # No match found, return original text with no highlight
          {text, "", ""}
      end
    end
  end

  defp split_for_highlight(text, _query), do: {text, "", ""}

  # Check if a tag matches the search query using the same fuzzy matching logic as FileFilter
  defp tag_matches_query?(_tag_name, ""), do: false
  defp tag_matches_query?(_tag_name, query) when is_nil(query), do: false

  defp tag_matches_query?(tag_name, query) when is_binary(tag_name) and is_binary(query) do
    normalized_query = normalize_text(query)
    normalized_tag = normalize_text(tag_name)

    if normalized_query == "" do
      false
    else
      query_words = extract_words(query)
      matches?(normalized_tag, normalized_query, query_words)
    end
  end

  defp tag_matches_query?(_tag_name, _query), do: false

  # Normalize by removing all separators and converting to lowercase
  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/[\s_\-\.]+/, "")
    |> String.downcase()
  end

  defp normalize_text(_), do: ""

  # Extract words from query by splitting on separators
  defp extract_words(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.split(~r/[\s_\-\.]+/, trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp extract_words(_), do: []

  # Versatile matching: full query substring OR all words appear OR fuzzy match
  defp matches?(text, normalized_query, query_words) do
    String.contains?(text, normalized_query) ||
      all_words_present?(text, query_words) ||
      fuzzy_match?(text, normalized_query)
  end

  # Check if all query words appear in text (in any order)
  defp all_words_present?(_text, []), do: false
  defp all_words_present?(text, words), do: Enum.all?(words, &String.contains?(text, &1))

  # Fuzzy match: all query characters appear in order (allows gaps)
  defp fuzzy_match?(text, query) when byte_size(query) < 2, do: String.contains?(text, query)

  defp fuzzy_match?(text, query) do
    text_chars = String.graphemes(text)
    query_chars = String.graphemes(query)
    chars_in_order?(text_chars, query_chars)
  end

  # Check if all query chars appear in order in text (allowing gaps)
  defp chars_in_order?(_text, []), do: true
  defp chars_in_order?([], _query), do: false

  defp chars_in_order?([t | text_rest], [q | query_rest]) when t == q,
    do: chars_in_order?(text_rest, query_rest)

  defp chars_in_order?([_t | text_rest], query), do: chars_in_order?(text_rest, query)
end
