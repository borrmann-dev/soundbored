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

  # Normalize query by removing extra whitespace and converting to lowercase
  defp normalize_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.downcase()
  end

  defp normalize_query(_), do: ""

  # Normalize text for fuzzy matching by removing extra whitespace
  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.downcase()
  end

  defp normalize_text(_), do: ""

  defp filter_by_search(files, ""), do: files

  defp filter_by_search(files, query) do
    normalized_query = normalize_query(query)

    if normalized_query == "" do
      files
    else
      Enum.filter(files, &matches_query?(&1, normalized_query))
    end
  end

  defp matches_query?(file, normalized_query) do
    filename_normalized = normalize_text(file.filename)
    filename_matches = String.contains?(filename_normalized, normalized_query)

    tag_matches =
      Enum.any?(file.tags || [], fn tag ->
        tag_normalized = normalize_text(tag.name)
        String.contains?(tag_normalized, normalized_query)
      end)

    keyword_matches =
      Enum.any?(file.keywords || [], fn kw ->
        keyword_normalized = normalize_text(kw.keyword)
        String.contains?(keyword_normalized, normalized_query)
      end)

    filename_matches || tag_matches || keyword_matches
  end

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
