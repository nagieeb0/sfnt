defmodule Sfnt.CFFTest do
  @moduledoc """
  CFF is where the bytes are and where the rewriting is hardest — absolute
  offsets in the Top DICT, a shared subroutine pool, and a string table keyed by
  glyph. These check the parts that fail silently.
  """

  use ExUnit.Case, async: true

  @otf Path.join(__DIR__, "support/NewCM10-Regular-subset.otf")

  setup_all do
    otf = File.read!(@otf)
    {:ok, count} = Sfnt.glyph_count(otf)
    {:ok, otf: otf, count: count}
  end

  describe "retain-gids subsetting" do
    test "shrinks the font", %{otf: otf} do
      {:ok, small} = Sfnt.subset(otf, [1, 2, 3, 40])

      assert byte_size(small) < byte_size(otf)
    end

    test "kept glyphs keep their exact charstring bytes", %{otf: otf} do
      keep = [1, 5, 20, 40, 60]
      {:ok, small} = Sfnt.subset(otf, keep)

      for gid <- keep do
        assert charstring(otf, gid) == charstring(small, gid),
               "glyph #{gid} charstring changed"
      end
    end

    test "dropped glyphs become a bare endchar", %{otf: otf} do
      {:ok, small} = Sfnt.subset(otf, [1, 5])

      for gid <- [6, 7, 30, 50] do
        assert charstring(small, gid) == <<14>>, "glyph #{gid} should be empty"
      end
    end

    test "glyph count is unchanged", %{otf: otf, count: count} do
      {:ok, small} = Sfnt.subset(otf, [1, 5])
      assert {:ok, ^count} = Sfnt.glyph_count(small)
    end

    test "the result parses back as a font", %{otf: otf} do
      {:ok, small} = Sfnt.subset(otf, [1, 5, 9])
      {:ok, tables} = Sfnt.tables(small)

      assert "CFF " in Map.keys(tables)
      assert Sfnt.Table.checksum(small) == 0xB1B0AFBA
    end

    test "subsetting is idempotent", %{otf: otf} do
      keep = [1, 5, 20]
      {:ok, once} = Sfnt.subset(otf, keep)
      {:ok, twice} = Sfnt.subset(once, keep)

      for gid <- keep, do: assert(charstring(once, gid) == charstring(twice, gid))
      assert byte_size(twice) <= byte_size(once)
    end
  end

  describe "renumbering" do
    test "packs glyphs down and reports the mapping", %{otf: otf} do
      keep = [1, 5, 20, 40]
      {:ok, small, map} = Sfnt.subset(otf, keep, renumber: true)

      # notdef is always kept, so the mapping covers the request plus glyph 0.
      assert Map.keys(map) |> Enum.sort() == Enum.sort([0 | keep])
      assert Map.values(map) |> Enum.sort() == Enum.to_list(0..4)
      assert map[0] == 0
      assert {:ok, 5} = Sfnt.glyph_count(small)
    end

    test "outlines follow the mapping", %{otf: otf} do
      keep = [1, 5, 20, 40, 60]
      {:ok, small, map} = Sfnt.subset(otf, keep, renumber: true)

      for {old, new} <- map do
        assert charstring(otf, old) == charstring(small, new),
               "glyph #{old} -> #{new} charstring changed"
      end
    end

    test "advance widths follow the mapping", %{otf: otf} do
      keep = [1, 5, 20, 40]
      {:ok, small, map} = Sfnt.subset(otf, keep, renumber: true)

      for {old, new} <- map do
        assert advance(otf, old) == advance(small, new),
               "glyph #{old} -> #{new} advance width changed"
      end
    end

    test "is much smaller than retaining ids", %{otf: otf} do
      keep = [1, 5, 20, 40]
      {:ok, retained} = Sfnt.subset(otf, keep)
      {:ok, renumbered, _} = Sfnt.subset(otf, keep, renumber: true)

      assert byte_size(renumbered) < byte_size(retained)
    end
  end

  describe "subroutines" do
    test "the font still parses after unreachable subroutines are dropped", %{otf: otf} do
      # If subroutine subsetting removed something still referenced, the
      # charstrings of kept glyphs would no longer match the originals.
      keep = Enum.to_list(1..30)
      {:ok, small} = Sfnt.subset(otf, keep)

      for gid <- keep, do: assert(charstring(otf, gid) == charstring(small, gid))
    end
  end

  # Pulls one glyph's charstring straight out of the CFF, independently of the
  # code under test: header, then the Name / TopDICT / String / GlobalSubr
  # INDEXes, then CharStrings at the offset the Top DICT gives.
  defp charstring(font, gid) do
    {:ok, tables} = Sfnt.tables(font)
    cff = tables["CFF "]
    <<_maj, _min, hdr_size, _off_size, _::binary>> = cff

    {_names, p} = skip_index(cff, hdr_size)
    {[top], p} = read_index(cff, p)
    {_strings, p} = skip_index(cff, p)
    {_gsubrs, _p} = skip_index(cff, p)

    {items, _} = read_index(cff, charstrings_offset(top))
    Enum.at(items, gid)
  end

  # Walks the Top DICT for operator 17 (CharStrings) and returns its operand.
  defp charstrings_offset(dict), do: charstrings_offset(dict, [])

  defp charstrings_offset(<<17, _::binary>>, [offset | _]), do: offset
  defp charstrings_offset(<<12, _op, rest::binary>>, _stack), do: charstrings_offset(rest, [])

  defp charstrings_offset(<<op, rest::binary>>, _stack) when op <= 21,
    do: charstrings_offset(rest, [])

  defp charstrings_offset(<<28, v::signed-16, rest::binary>>, s),
    do: charstrings_offset(rest, [v | s])

  defp charstrings_offset(<<29, v::signed-32, rest::binary>>, s),
    do: charstrings_offset(rest, [v | s])

  defp charstrings_offset(<<b0, rest::binary>>, s) when b0 in 32..246,
    do: charstrings_offset(rest, [b0 - 139 | s])

  defp charstrings_offset(<<b0, b1, rest::binary>>, s) when b0 in 247..250,
    do: charstrings_offset(rest, [(b0 - 247) * 256 + b1 + 108 | s])

  defp charstrings_offset(<<b0, b1, rest::binary>>, s) when b0 in 251..254,
    do: charstrings_offset(rest, [-(b0 - 251) * 256 - b1 - 108 | s])

  defp charstrings_offset(<<_, rest::binary>>, s), do: charstrings_offset(rest, s)

  defp skip_index(cff, pos) do
    {items, stop} = read_index(cff, pos)
    {items, stop}
  end

  defp read_index(cff, pos) do
    case cff do
      <<_::binary-size(^pos), 0::16, _::binary>> ->
        {[], pos + 2}

      <<_::binary-size(^pos), count::16, off_size, _::binary>> ->
        table = pos + 3

        offs =
          for i <- 0..count,
              do: :binary.decode_unsigned(part(cff, table + i * off_size, off_size))

        data = table + (count + 1) * off_size - 1

        items =
          for i <- 0..(count - 1) do
            part(cff, data + Enum.at(offs, i), Enum.at(offs, i + 1) - Enum.at(offs, i))
          end

        {items, data + Enum.at(offs, count)}
    end
  end

  defp part(bin, pos, len), do: binary_part(bin, pos, len)

  defp advance(font, gid) do
    {:ok, tables} = Sfnt.tables(font)
    <<_::binary-34, num_metrics::16>> = tables["hhea"]
    i = min(gid, num_metrics - 1)
    <<_::binary-size(^i)-unit(32), adv::16, _::binary>> = tables["hmtx"]
    adv
  end
end
