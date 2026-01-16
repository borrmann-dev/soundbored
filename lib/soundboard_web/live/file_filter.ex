defmodule SoundboardWeb.Live.FileFilter do
  @moduledoc """
  Filters and groups files based on the selected tags and search query.
  Tags are used for grouping (tagged matches vs other matches), not filtering.
  """

  def filter_files(files, query, selected_tags) do
    filtered = filter_by_search(files, query)
    group_by_tags(filtered, selected_tags)
  end

  # Returns a flat list for backward compatibility (used by random sound feature)
  # For random sound, tags should filter (not just sort) to ensure random picks from tagged sounds
  def filter_files_flat(files, query, selected_tags) do
    files
    |> filter_by_search(query)
    |> filter_by_tags_for_random(selected_tags)
  end

  # Filter by tags for random sound feature - tags should filter, not just sort
  defp filter_by_tags_for_random(files, []), do: files

  defp filter_by_tags_for_random(files, [tag]) do
    Enum.filter(files, fn file ->
      Enum.any?(file.tags || [], fn file_tag -> file_tag.id == tag.id end)
    end)
  end

  defp filter_by_tags_for_random(files, _tags), do: files

  # Normalize by removing all separators and converting to lowercase
  defp normalize(text) when is_binary(text) do
    text
    # Remove all whitespace and separators
    |> String.replace(~r/[\s_\-\.]+/, "")
    |> String.downcase()
  end

  defp normalize(_), do: ""

  defp filter_by_search(files, ""), do: files

  defp filter_by_search(files, query) do
    normalized_query = normalize(query)

    if normalized_query == "" do
      files
    else
      # Extract words from original query (before normalization removes separators)
      query_words = extract_words(query)
      Enum.filter(files, &matches_query?(&1, normalized_query, query_words))
    end
  end

  # Extract words from query by splitting on separators
  defp extract_words(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.split(~r/[\s_\-\.]+/, trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp extract_words(_), do: []

  defp matches_query?(file, normalized_query, query_words) do
    # Check filename, tags, and keywords with the same simple logic
    matches?(file.filename, normalized_query, query_words) ||
      Enum.any?(file.tags || [], &matches?(&1.name, normalized_query, query_words)) ||
      Enum.any?(file.keywords || [], &matches?(&1.keyword, normalized_query, query_words))
  end

  # Versatile matching: full query substring OR all words appear OR fuzzy match
  defp matches?(text, normalized_query, query_words) do
    normalized_text = normalize(text)

    String.contains?(normalized_text, normalized_query) ||
      all_words_present?(normalized_text, query_words) ||
      fuzzy_match?(normalized_text, normalized_query)
  end

  # Check if all query words appear in text (in any order)
  defp all_words_present?(_text, []), do: false
  defp all_words_present?(text, words), do: Enum.all?(words, &String.contains?(text, &1))

  # Fuzzy match: all query characters appear in order (allows gaps)
  # Example: "fun" matches "funny", "test" matches "testing"
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

  # Group files into tagged matches and other matches
  defp group_by_tags(files, []) do
    %{tagged: files, other: []}
  end

  defp group_by_tags(files, [tag]) do
    {tagged, other} =
      Enum.split_with(files, fn file ->
        Enum.any?(file.tags || [], fn file_tag -> file_tag.id == tag.id end)
      end)

    %{tagged: tagged, other: other}
  end

  defp group_by_tags(files, _tags), do: %{tagged: files, other: []}
end
