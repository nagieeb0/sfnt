defmodule Sfnt.Glyf do
  @moduledoc """
  TrueType outlines: the `glyf` table and the `loca` index that carves it up.

  Simpler than CFF — `loca` is just an array of offsets, so emptying a glyph
  means giving it a zero-length slice. The one trap is composite glyphs, which
  are built by referencing other glyph ids; drop a component and the glyph that
  uses it renders as a hole.
  """

  @doc """
  Rewrites `glyf` and `loca` so only glyphs in `keep` retain outlines.

  Returns the new tables plus the `indexToLocFormat` value `head` must be
  updated to, since dropping data can move the table under the 64 KB boundary
  where the short `loca` format becomes usable.
  """
  @spec subset(binary(), binary(), MapSet.t(non_neg_integer()), 0 | 1, non_neg_integer()) ::
          {:ok, binary(), binary(), 0 | 1} | {:error, term()}
  def subset(glyf, loca, keep, loca_format, num_glyphs) do
    with {:ok, offsets} <- offsets(loca, loca_format, num_glyphs) do
      keep = closure(glyf, offsets, keep)

      {blobs, total} =
        Enum.map_reduce(0..(num_glyphs - 1), 0, fn gid, acc ->
          data = if MapSet.member?(keep, gid), do: glyph_at(glyf, offsets, gid), else: <<>>
          # Glyph data must stay two-byte aligned for the short loca format.
          data = if rem(byte_size(data), 2) == 1, do: data <> <<0>>, else: data
          {data, acc + byte_size(data)}
        end)

      new_format = if total <= 0x1FFFE, do: 0, else: 1
      {:ok, IO.iodata_to_binary(blobs), encode_loca(blobs, new_format), new_format}
    end
  end

  @doc """
  Expands `keep` to include every glyph reachable from it through composite
  references.
  """
  @spec closure(binary(), [non_neg_integer()], MapSet.t()) :: MapSet.t()
  def closure(glyf, offsets, keep), do: closure(glyf, offsets, MapSet.to_list(keep), keep)

  defp closure(_glyf, _offsets, [], seen), do: seen

  defp closure(glyf, offsets, [gid | rest], seen) do
    components =
      glyf
      |> glyph_at(offsets, gid)
      |> components()
      |> Enum.reject(&MapSet.member?(seen, &1))

    closure(glyf, offsets, components ++ rest, Enum.into(components, seen))
  end

  # A negative contour count marks a composite glyph; what follows is a chain of
  # {flags, glyphIndex, args...} entries, continuing while MORE_COMPONENTS is set.
  defp components(<<n::signed-16, _bbox::binary-8, rest::binary>>) when n < 0,
    do: component_ids(rest, [])

  defp components(_), do: []

  defp component_ids(<<flags::16, index::16, rest::binary>>, acc) do
    arg_size = if Bitwise.band(flags, 0x0001) != 0, do: 4, else: 2

    scale_size =
      cond do
        Bitwise.band(flags, 0x0008) != 0 -> 2
        Bitwise.band(flags, 0x0040) != 0 -> 4
        Bitwise.band(flags, 0x0080) != 0 -> 8
        true -> 0
      end

    skip = arg_size + scale_size
    acc = [index | acc]

    case rest do
      <<_::binary-size(^skip), tail::binary>> when Bitwise.band(flags, 0x0020) != 0 ->
        component_ids(tail, acc)

      _ ->
        acc
    end
  end

  defp component_ids(_, acc), do: acc

  defp glyph_at(glyf, offsets, gid) do
    start = Enum.at(offsets, gid)
    stop = Enum.at(offsets, gid + 1)

    if is_integer(start) and is_integer(stop) and stop > start and stop <= byte_size(glyf) do
      binary_part(glyf, start, stop - start)
    else
      <<>>
    end
  end

  defp offsets(loca, 0, num_glyphs) do
    expected = (num_glyphs + 1) * 2

    if byte_size(loca) >= expected do
      {:ok, for(<<v::16 <- binary_part(loca, 0, expected)>>, do: v * 2)}
    else
      {:error, :loca_too_short}
    end
  end

  defp offsets(loca, 1, num_glyphs) do
    expected = (num_glyphs + 1) * 4

    if byte_size(loca) >= expected do
      {:ok, for(<<v::32 <- binary_part(loca, 0, expected)>>, do: v)}
    else
      {:error, :loca_too_short}
    end
  end

  defp offsets(_loca, format, _num_glyphs), do: {:error, {:bad_loca_format, format}}

  defp encode_loca(blobs, format) do
    running = Enum.scan(blobs, 0, fn blob, acc -> acc + byte_size(blob) end)

    [0 | running]
    |> Enum.map_join(fn offset ->
      case format do
        0 -> <<div(offset, 2)::16>>
        1 -> <<offset::32>>
      end
    end)
  end
end
