defmodule Sfnt.Table do
  @moduledoc """
  The sfnt container: the table directory every OpenType and TrueType font
  starts with, and the checksum rules for writing one back out.

  A font file is a header, a directory of `{tag, checksum, offset, length}`
  records, and the table data itself. Everything else — glyph outlines, metrics,
  layout — lives inside those tables. This module knows the envelope and nothing
  about what is in it.
  """

  @typedoc "Tables keyed by their four-character tag, e.g. `\"CFF \"`, `\"head\"`."
  @type tables :: %{String.t() => binary()}

  @doc """
  Splits a font binary into its flavour tag and its tables.

  The flavour is `"OTTO"` for CFF outlines, or `<<0, 1, 0, 0>>` / `"true"` for
  TrueType ones — which decides whether glyphs live in `CFF ` or `glyf`.
  """
  @spec parse(binary()) :: {:ok, binary(), tables()} | {:error, term()}
  # These are sfnt-shaped enough to match the general clause, so they have to be
  # rejected before it.
  def parse(<<"ttcf", _::binary>>), do: {:error, :font_collection_unsupported}
  def parse(<<"wOFF", _::binary>>), do: {:error, :woff_unsupported}
  def parse(<<"wOF2", _::binary>>), do: {:error, :woff_unsupported}

  def parse(<<flavour::binary-4, num_tables::16, _search::48, rest::binary>> = font) do
    with {:ok, records} <- records(rest, num_tables, []) do
      tables =
        Map.new(records, fn {tag, offset, length} ->
          {tag, binary_part(font, offset, min(length, byte_size(font) - offset))}
        end)

      {:ok, flavour, tables}
    end
  end

  def parse(_), do: {:error, :not_a_font}

  defp records(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp records(<<tag::binary-4, _checksum::32, offset::32, length::32, rest::binary>>, n, acc) do
    records(rest, n - 1, [{tag, offset, length} | acc])
  end

  defp records(_, _, _), do: {:error, :truncated_table_directory}

  @doc """
  Writes tables back out as a font binary.

  Handles the parts that are easy to get subtly wrong: the binary-search hints
  in the header, four-byte alignment and padding, per-table checksums, and
  `head.checkSumAdjustment` — which is a checksum of the finished file and so
  has to be patched in after everything else is laid out.
  """
  @spec build(binary(), tables()) :: binary()
  def build(flavour, tables) do
    # The spec requires directory entries sorted by tag.
    sorted = Enum.sort_by(tables, fn {tag, _} -> tag end)
    count = length(sorted)
    directory_size = 12 + count * 16

    {records, data, _} =
      Enum.reduce(sorted, {[], [], directory_size}, fn {tag, body}, {recs, blobs, offset} ->
        padded = pad4(body)

        {[{tag, checksum(padded), offset, byte_size(body)} | recs], [padded | blobs],
         offset + byte_size(padded)}
      end)

    font =
      IO.iodata_to_binary([
        header(flavour, count),
        Enum.map(Enum.reverse(records), fn {tag, sum, offset, length} ->
          <<tag::binary-4, sum::32, offset::32, length::32>>
        end),
        Enum.reverse(blobs_of(data))
      ])

    patch_checksum_adjustment(font, Enum.reverse(records))
  end

  defp blobs_of(data), do: data

  # The header carries a binary-search acceleration triple that no modern
  # consumer relies on, but validators check, so compute it properly.
  defp header(flavour, count) do
    entry_selector = if count == 0, do: 0, else: floor(:math.log2(count))
    search_range = trunc(:math.pow(2, entry_selector)) * 16
    range_shift = count * 16 - search_range

    <<flavour::binary-4, count::16, search_range::16, entry_selector::16, range_shift::16>>
  end

  @doc """
  The sfnt checksum: the sum of a table's contents read as big-endian `uint32`,
  truncated to 32 bits.
  """
  @spec checksum(binary()) :: non_neg_integer()
  def checksum(data) do
    data
    |> pad4()
    |> sum_words(0)
  end

  defp sum_words(<<word::32, rest::binary>>, acc),
    do: sum_words(rest, Bitwise.band(acc + word, 0xFFFFFFFF))

  defp sum_words(<<>>, acc), do: acc

  @doc "Pads a binary to a four-byte boundary with zeros, as the spec requires."
  @spec pad4(binary()) :: binary()
  def pad4(data) do
    case rem(byte_size(data), 4) do
      0 -> data
      n -> data <> :binary.copy(<<0>>, 4 - n)
    end
  end

  # head.checkSumAdjustment must make the whole file sum to 0xB1B0AFBA. It has
  # to be zero while that sum is taken, so this writes zero, sums, then patches.
  defp patch_checksum_adjustment(font, records) do
    case Enum.find(records, fn {tag, _, _, _} -> tag == "head" end) do
      nil ->
        font

      {_tag, _sum, offset, _len} ->
        field = offset + 8
        zeroed = binary_part(font, 0, field) <> <<0::32>> <> after_field(font, field)
        adjustment = Bitwise.band(0xB1B0AFBA - checksum(zeroed), 0xFFFFFFFF)

        binary_part(zeroed, 0, field) <> <<adjustment::32>> <> after_field(zeroed, field)
    end
  end

  defp after_field(font, field) do
    binary_part(font, field + 4, byte_size(font) - field - 4)
  end
end
