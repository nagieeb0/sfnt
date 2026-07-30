defmodule Sfnt.CFF do
  @moduledoc """
  Compact Font Format: enough of it to replace glyph outlines and write the
  table back.

  CFF is the outline format inside an OpenType (`OTTO`) font, and it is where
  almost all of a font's bytes are — 63% of the brand face this was written for.
  Subsetting it is what makes a font small enough to embed in every PDF.

  ## Why rewriting CFF is fiddly

  The Top DICT holds *absolute* offsets to the charset, CharStrings and Private
  DICT. Change the size of any of them and every offset moves — but DICT
  integers are variable-width, so writing a bigger offset can make the Top DICT
  itself bigger, which moves the offsets again. The usual fix, used here, is to
  encode every offset in the fixed five-byte form (`29` + `int32`). The Top DICT
  then has a size that does not depend on its contents, and the layout resolves
  in a single pass.
  """

  alias Sfnt.Charstring

  # DICT operators this module needs to understand.
  @charset 15
  @encoding 16
  @charstrings 17
  @private 18
  @subrs 19
  @ros 1230
  @fdarray 1236
  @fdselect 1237

  # Top DICT operators whose operands are string ids, not numbers.
  @sid_ops [0, 1, 2, 3, 4, 1200, 1221, 1222]

  # SIDs below this are the CFF standard strings, which live in the spec rather
  # than in the font's String INDEX.
  @n_std_strings 391

  # A charstring that draws nothing. Unused glyphs become this rather than
  # disappearing, so glyph ids keep their meaning — see `Sfnt.subset/3`.
  @endchar <<14>>

  @doc """
  Replaces the outlines of every glyph outside `keep` with an empty charstring.

  Glyph ids are preserved. That matters more than the extra bytes it costs: a
  PDF written with Identity-H addresses glyphs by id, so renumbering them would
  invalidate every text object already written against the original font.

  Returns `{:error, :cid_keyed_unsupported}` for CID-keyed CFFs, which carry an
  FDArray/FDSelect pair this does not rewrite yet.
  """
  @spec subset(binary(), MapSet.t(non_neg_integer()), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def subset(cff, keep, opts \\ []) do
    with {:ok, font} <- parse(cff) do
      if Map.has_key?(font.top, @ros) or Map.has_key?(font.top, @fdarray) or
           Map.has_key?(font.top, @fdselect) do
        {:error, :cid_keyed_unsupported}
      else
        {:ok, rebuild(font, keep, Keyword.get(opts, :renumber, false))}
      end
    end
  end

  @doc """
  Number of glyphs in the CFF, taken from its CharStrings INDEX.
  """
  @spec glyph_count(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def glyph_count(cff) do
    with {:ok, font} <- parse(cff), do: {:ok, length(font.charstrings)}
  end

  # ── Parsing ───────────────────────────────────────────────────────────────

  defp parse(<<_major, _minor, hdr_size, _off_size, _::binary>> = cff) when hdr_size >= 4 do
    with {:ok, names, p} <- index(cff, hdr_size),
         {:ok, [top_dict], p} <- index(cff, p),
         {:ok, strings, p} <- index(cff, p),
         {:ok, gsubrs, _p} <- index(cff, p),
         top = dict(top_dict),
         {:ok, cs_offset} <- fetch_offset(top, @charstrings),
         {:ok, charstrings, _} <- index(cff, cs_offset) do
      {:ok,
       %{
         raw: cff,
         header: binary_part(cff, 0, hdr_size),
         names: names,
         top: top,
         strings: strings,
         gsubrs: gsubrs,
         charstrings: charstrings
       }}
    end
  end

  defp parse(_), do: {:error, :malformed_cff}

  defp fetch_offset(top, op) do
    case Map.get(top, op) do
      [offset] when is_integer(offset) -> {:ok, offset}
      _ -> {:error, {:missing_dict_operator, op}}
    end
  end

  # A CFF INDEX: count, then one more offset than there are items, then the
  # data those offsets carve up. Offsets are 1-based from just before the data.
  defp index(bin, pos) do
    case bin do
      <<_::binary-size(^pos), 0::16, _::binary>> ->
        {:ok, [], pos + 2}

      <<_::binary-size(^pos), count::16, off_size, _::binary>> when off_size in 1..4 ->
        bits = off_size * 8
        table = pos + 3
        offsets = for i <- 0..count, do: uint(bin, table + i * off_size, off_size)
        _ = bits
        data = table + (count + 1) * off_size - 1

        items =
          for i <- 0..(count - 1) do
            start = data + Enum.at(offsets, i)
            binary_part(bin, start, Enum.at(offsets, i + 1) - Enum.at(offsets, i))
          end

        {:ok, items, data + Enum.at(offsets, count)}

      _ ->
        {:error, :malformed_index}
    end
  end

  defp uint(bin, pos, size), do: :binary.decode_unsigned(binary_part(bin, pos, size))

  # A DICT is operands followed by an operator, repeatedly. Operators below 22
  # are one byte, except 12 which introduces a two-byte escape.
  defp dict(bin), do: dict(bin, [], %{})

  defp dict(<<>>, _stack, acc), do: acc

  defp dict(<<12, op, rest::binary>>, stack, acc),
    do: dict(rest, [], Map.put(acc, 1200 + op, Enum.reverse(stack)))

  defp dict(<<op, rest::binary>>, stack, acc) when op <= 21,
    do: dict(rest, [], Map.put(acc, op, Enum.reverse(stack)))

  defp dict(<<28, v::signed-16, rest::binary>>, stack, acc), do: dict(rest, [v | stack], acc)
  defp dict(<<29, v::signed-32, rest::binary>>, stack, acc), do: dict(rest, [v | stack], acc)

  # Real numbers are nibble-encoded and terminated by an 0xf nibble. Nothing
  # here does arithmetic on them, so they are carried through verbatim.
  defp dict(<<30, rest::binary>>, stack, acc) do
    {raw, rest} = real(rest, <<30>>)
    dict(rest, [{:real, raw} | stack], acc)
  end

  defp dict(<<b0, rest::binary>>, stack, acc) when b0 in 32..246,
    do: dict(rest, [b0 - 139 | stack], acc)

  defp dict(<<b0, b1, rest::binary>>, stack, acc) when b0 in 247..250,
    do: dict(rest, [(b0 - 247) * 256 + b1 + 108 | stack], acc)

  defp dict(<<b0, b1, rest::binary>>, stack, acc) when b0 in 251..254,
    do: dict(rest, [-(b0 - 251) * 256 - b1 - 108 | stack], acc)

  defp dict(<<_, rest::binary>>, stack, acc), do: dict(rest, stack, acc)

  defp real(<<byte, rest::binary>>, acc) do
    acc = acc <> <<byte>>

    if Bitwise.band(byte, 0x0F) == 0x0F or Bitwise.bsr(byte, 4) == 0x0F do
      {acc, rest}
    else
      real(rest, acc)
    end
  end

  defp real(<<>>, acc), do: {acc, <<>>}

  # ── Rebuilding ────────────────────────────────────────────────────────────

  defp rebuild(font, keep, renumber?) do
    indexed = Enum.with_index(font.charstrings)

    # Only the surviving outlines get a say in which subroutines are reachable.
    kept_charstrings =
      indexed
      |> Enum.filter(fn {_cs, gid} -> MapSet.member?(keep, gid) end)
      |> Enum.map(&elem(&1, 0))

    charstrings =
      if renumber? do
        kept_charstrings
      else
        Enum.map(indexed, fn {cs, gid} -> if MapSet.member?(keep, gid), do: cs, else: @endchar end)
      end

    charstrings_index = encode_index(charstrings)
    {charset, strings, top_sids} = prune_strings(font, keep, renumber?)
    gsubrs = subset_gsubrs(font, kept_charstrings)
    font = %{font | strings: strings, gsubrs: gsubrs, top: Map.merge(font.top, top_sids)}
    {private, private_size} = copy_private(font, kept_charstrings)

    # Offsets are written five bytes wide, so the Top DICT's size is known
    # before its contents are — which is what makes a single-pass layout work.
    offset_ops = [@charset, @encoding, @charstrings, @private]

    fixed_top =
      font.top
      |> Map.take(Map.keys(font.top) -- offset_ops)
      |> encode_dict()

    top_size = byte_size(fixed_top) + placeholder_size(font.top, offset_ops)

    prefix_size =
      byte_size(font.header) + index_size(font.names) + index_size([<<0::size(top_size * 8)>>]) +
        index_size(font.strings) + index_size(font.gsubrs)

    charset_offset = prefix_size
    charstrings_offset = charset_offset + byte_size(charset)
    private_offset = charstrings_offset + byte_size(charstrings_index)

    top =
      font.top
      |> maybe_put(@charset, charset_offset, byte_size(charset) > 0)
      |> maybe_put(@encoding, 0, Map.has_key?(font.top, @encoding))
      |> Map.put(@charstrings, charstrings_offset)
      |> maybe_put_private(private_size, private_offset)
      |> encode_dict(offset_ops)

    # The fixed-width encoding must have predicted the real size exactly, or
    # every offset above is wrong. Fail loudly rather than emit a broken font.
    ^top_size = byte_size(top)

    IO.iodata_to_binary([
      font.header,
      encode_index(font.names),
      encode_index([top]),
      encode_index(font.strings),
      encode_index(font.gsubrs),
      charset,
      charstrings_index,
      private
    ])
  end

  defp maybe_put(top, _op, _value, false), do: top
  defp maybe_put(top, op, value, true), do: Map.put(top, op, value)

  defp maybe_put_private(top, nil, _offset), do: Map.delete(top, @private)
  defp maybe_put_private(top, size, offset), do: Map.put(top, @private, [size, offset])

  # The String INDEX holds every custom glyph name in the font — 736 of them
  # here, 10 KB, and by far the biggest thing left after the outlines. Names
  # belong to glyphs, so once most glyphs are empty most names are dead too.
  #
  # Dropped glyphs are pointed at SID 0 (`.notdef`), which is what they now
  # are, and the surviving custom strings are renumbered densely.
  defp prune_strings(font, keep, renumber?) do
    n = length(font.charstrings)

    case charset_sids(font, n) do
      nil ->
        # A predefined charset (offset 0/1/2) has no custom names to prune.
        {<<>>, font.strings, %{}}

      sids ->
        top_sid_ops = Map.take(font.top, @sid_ops) |> Enum.filter(&custom_sid?/1)

        used =
          sids
          |> Enum.with_index(1)
          |> Enum.filter(fn {_sid, gid} -> MapSet.member?(keep, gid) end)
          |> Enum.map(fn {sid, _gid} -> sid end)
          |> Enum.concat(Enum.flat_map(top_sid_ops, fn {_op, v} -> List.wrap(v) end))
          |> Enum.filter(&(&1 >= @n_std_strings))
          |> Enum.uniq()
          |> Enum.sort()

        remap = used |> Enum.with_index(@n_std_strings) |> Map.new()
        strings = Enum.map(used, &Enum.at(font.strings, &1 - @n_std_strings))

        charset =
          sids
          |> Enum.with_index(1)
          |> then(fn pairs ->
            if renumber?,
              do: Enum.filter(pairs, fn {_sid, gid} -> MapSet.member?(keep, gid) end),
              else: pairs
          end)
          |> Enum.map_join(fn {sid, gid} ->
            <<if(MapSet.member?(keep, gid), do: Map.get(remap, sid, sid), else: 0)::16>>
          end)

        rewritten =
          Map.new(top_sid_ops, fn {op, v} ->
            {op, Enum.map(List.wrap(v), &Map.get(remap, &1, &1))}
          end)

        {<<0>> <> charset, strings, rewritten}
    end
  end

  defp custom_sid?({_op, v}), do: Enum.any?(List.wrap(v), &(is_integer(&1) and &1 >= 0))

  # Charset formats: 0 is a flat SID array, 1 and 2 are runs of {first, nLeft}
  # with a one- or two-byte count. Offsets 0-2 name a predefined charset.
  defp charset_sids(font, n) do
    case Map.get(font.top, @charset) do
      [offset] when offset > 2 ->
        case :binary.at(font.raw, offset) do
          0 -> for i <- 1..(n - 1)//1, do: uint(font.raw, offset + 1 + (i - 1) * 2, 2)
          1 -> expand_ranges(font.raw, offset + 1, n - 1, 1, [])
          2 -> expand_ranges(font.raw, offset + 1, n - 1, 2, [])
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp expand_ranges(_cff, _pos, remaining, _width, acc) when remaining <= 0,
    do: acc |> Enum.reverse() |> List.flatten()

  defp expand_ranges(cff, pos, remaining, width, acc) do
    first = uint(cff, pos, 2)
    n_left = uint(cff, pos + 2, width)
    run = for i <- 0..min(n_left, remaining - 1)//1, do: first + i

    expand_ranges(cff, pos + 2 + width, remaining - (n_left + 1), width, [run | acc])
  end

  # The Private DICT is copied verbatim and its local Subrs INDEX kept
  # immediately after it, because the DICT's Subrs offset is relative — so
  # keeping the two adjacent keeps that offset correct without rewriting it.
  #
  # The subroutines themselves are subsetted the same way charstrings are:
  # unused entries become empty, so indices stay valid and no bias arithmetic
  # has to be redone.
  defp copy_private(font, kept_charstrings) do
    case Map.get(font.top, @private) do
      [size, offset] when is_integer(size) and is_integer(offset) ->
        private = binary_part(font.raw, offset, size)
        {private <> subset_local_subrs(font, private, offset, kept_charstrings), size}

      _ ->
        {<<>>, nil}
    end
  end

  defp subset_local_subrs(font, private, private_offset, kept_charstrings) do
    with [relative] when is_integer(relative) <- Map.get(dict(private), @subrs),
         {:ok, subrs, _stop} <- index(font.raw, private_offset + relative) do
      {used, _globals} = Charstring.used_subrs(kept_charstrings, subrs, font.gsubrs)

      subrs
      |> Enum.with_index()
      |> Enum.map(fn {subr, i} -> if MapSet.member?(used, i), do: subr, else: <<11>> end)
      |> encode_index()
    else
      _ -> <<>>
    end
  end

  # Global subroutines get the same treatment, but they sit in the CFF prefix
  # rather than after the Private DICT.
  defp subset_gsubrs(font, kept_charstrings) do
    case Map.get(font.top, @private) do
      [size, offset] when is_integer(size) and is_integer(offset) ->
        locals =
          with [relative] when is_integer(relative) <-
                 Map.get(dict(binary_part(font.raw, offset, size)), @subrs),
               {:ok, subrs, _} <- index(font.raw, offset + relative) do
            subrs
          else
            _ -> []
          end

        {_used, used_global} = Charstring.used_subrs(kept_charstrings, locals, font.gsubrs)
        blank_unused(font.gsubrs, used_global)

      _ ->
        {_used, used_global} = Charstring.used_subrs(kept_charstrings, [], font.gsubrs)
        blank_unused(font.gsubrs, used_global)
    end
  end

  # `return` (11) is the shortest valid subroutine body.
  defp blank_unused(subrs, used) do
    subrs
    |> Enum.with_index()
    |> Enum.map(fn {subr, i} -> if MapSet.member?(used, i), do: subr, else: <<11>> end)
  end

  # ── Encoding ──────────────────────────────────────────────────────────────

  defp encode_index([]), do: <<0::16>>

  defp encode_index(items) do
    lengths = Enum.map(items, &byte_size/1)
    total = Enum.sum(lengths)

    off_size =
      cond do
        total + 1 <= 0xFF -> 1
        total + 1 <= 0xFFFF -> 2
        total + 1 <= 0xFFFFFF -> 3
        true -> 4
      end

    offsets =
      lengths
      |> Enum.scan(1, &(&1 + &2))
      |> then(&[1 | &1])
      |> Enum.map(&<<&1::size(off_size * 8)>>)

    IO.iodata_to_binary([<<length(items)::16, off_size>>, offsets, items])
  end

  defp index_size([]), do: 2
  defp index_size(items), do: byte_size(encode_index(items))

  # Offsets go out as the five-byte form so their width never depends on their
  # value; everything else takes its natural shortest encoding.
  defp encode_dict(dict, wide \\ []) do
    dict
    |> Enum.sort_by(fn {op, _} -> op end)
    |> Enum.map_join(fn {op, operands} ->
      operands = List.wrap(operands)
      encoder = if op in wide, do: &wide_operand/1, else: &operand/1
      Enum.map_join(operands, encoder) <> operator(op)
    end)
  end

  defp placeholder_size(dict, ops) do
    ops
    |> Enum.filter(&Map.has_key?(dict, &1))
    |> Enum.map(fn
      @private -> 10 + byte_size(operator(@private))
      op -> 5 + byte_size(operator(op))
    end)
    |> Enum.sum()
  end

  defp operator(op) when op >= 1200, do: <<12, op - 1200>>
  defp operator(op), do: <<op>>

  defp wide_operand(v) when is_integer(v), do: <<29, v::signed-32>>
  defp wide_operand(other), do: operand(other)

  defp operand({:real, raw}), do: raw
  defp operand(v) when is_integer(v) and v >= -107 and v <= 107, do: <<v + 139>>

  defp operand(v) when is_integer(v) and v >= 108 and v <= 1131 do
    v = v - 108
    <<Bitwise.bsr(v, 8) + 247, Bitwise.band(v, 0xFF)>>
  end

  defp operand(v) when is_integer(v) and v <= -108 and v >= -1131 do
    v = -v - 108
    <<Bitwise.bsr(v, 8) + 251, Bitwise.band(v, 0xFF)>>
  end

  defp operand(v) when is_integer(v) and v >= -32768 and v <= 32767, do: <<28, v::signed-16>>
  defp operand(v) when is_integer(v), do: <<29, v::signed-32>>
end
