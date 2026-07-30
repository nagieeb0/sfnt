defmodule SfntTest do
  @moduledoc """
  Binary surgery on fonts fails silently — a subtly wrong offset produces a
  file that loads fine and draws the wrong letters. So these check invariants
  that would actually break: that outlines survive byte-for-byte, that dropped
  glyphs really are gone, and that the result parses back.
  """

  use ExUnit.Case, async: true

  doctest Sfnt

  # Noto Naskh Arabic (SIL Open Font License) — TrueType outlines, and Arabic
  # brings composite glyphs and a large glyph count with it.
  @ttf Path.join(__DIR__, "support/NotoNaskhArabic-Regular.ttf")

  setup_all do
    ttf = File.read!(@ttf)
    {:ok, count} = Sfnt.glyph_count(ttf)
    {:ok, ttf: ttf, count: count}
  end

  describe "parse and rebuild" do
    test "a rebuilt font still parses and keeps every table", %{ttf: ttf} do
      {:ok, tables} = Sfnt.tables(ttf)
      {:ok, rebuilt} = Sfnt.subset(ttf, 0..(map_size(tables) + 500), drop_layout: false)

      {:ok, after_tables} = Sfnt.tables(rebuilt)
      assert Map.keys(after_tables) == Map.keys(tables)
    end

    test "rejects things that are not fonts" do
      assert {:error, :not_a_font} = Sfnt.subset("hello world", [1])
      assert {:error, :woff_unsupported} = Sfnt.subset("wOF2" <> <<0::256>>, [1])
      assert {:error, :font_collection_unsupported} = Sfnt.subset("ttcf" <> <<0::256>>, [1])
    end

    test "tables/1 reports what is in the file", %{ttf: ttf} do
      {:ok, tables} = Sfnt.tables(ttf)

      assert "glyf" in Map.keys(tables)
      assert "loca" in Map.keys(tables)
      assert "head" in Map.keys(tables)
    end
  end

  describe "subset/3 on TrueType outlines" do
    test "shrinks the font a lot", %{ttf: ttf} do
      {:ok, small} = Sfnt.subset(ttf, [3, 10, 40, 41, 42])

      assert byte_size(small) < div(byte_size(ttf), 3)
    end

    test "kept glyphs keep their exact outline bytes", %{ttf: ttf} do
      keep = [3, 10, 40, 100, 250]
      {:ok, small} = Sfnt.subset(ttf, keep)

      for gid <- keep do
        assert glyph_bytes(ttf, gid) == glyph_bytes(small, gid),
               "glyph #{gid} outline changed"
      end
    end

    test "dropped glyphs are emptied", %{ttf: ttf, count: count} do
      {:ok, small} = Sfnt.subset(ttf, [3, 10, 40])

      dropped = Enum.filter([11, 12, 50, 60, count - 1], &(glyph_bytes(ttf, &1) != <<>>))
      assert dropped != [], "test needs at least one non-empty glyph to drop"

      for gid <- dropped do
        assert glyph_bytes(small, gid) == <<>>, "glyph #{gid} should be empty"
      end
    end

    test "glyph ids and count are preserved", %{ttf: ttf, count: count} do
      {:ok, small} = Sfnt.subset(ttf, [3, 40])
      assert {:ok, ^count} = Sfnt.glyph_count(small)
    end

    test "layout tables go by default and stay on request", %{ttf: ttf} do
      {:ok, without} = Sfnt.subset(ttf, [3])
      {:ok, with_layout} = Sfnt.subset(ttf, [3], drop_layout: false)

      {:ok, a} = Sfnt.tables(without)
      {:ok, b} = Sfnt.tables(with_layout)

      refute "GSUB" in Map.keys(a)
      assert "GSUB" in Map.keys(b)
      assert byte_size(with_layout) > byte_size(without)
    end

    test "notdef survives even when not asked for", %{ttf: ttf} do
      {:ok, small} = Sfnt.subset(ttf, [40])
      assert glyph_bytes(ttf, 0) == glyph_bytes(small, 0)
    end

    test "an empty keep set still produces a usable font", %{ttf: ttf, count: count} do
      {:ok, small} = Sfnt.subset(ttf, [])

      assert {:ok, ^count} = Sfnt.glyph_count(small)
      assert byte_size(small) < byte_size(ttf)
    end

    test "renumbering is refused rather than half-applied", %{ttf: ttf} do
      # Renumbering TrueType would also mean rewriting composite glyph
      # references. Doing the metrics but not the outlines would produce a font
      # that loads and draws the wrong letters.
      assert {:error, :renumber_unsupported_for_truetype} =
               Sfnt.subset(ttf, [3, 40], renumber: true)
    end

    test "extra tables can be dropped by name", %{ttf: ttf} do
      {:ok, small} = Sfnt.subset(ttf, [3], drop: ["cmap", "name"])
      {:ok, tables} = Sfnt.tables(small)

      refute "cmap" in Map.keys(tables)
      refute "name" in Map.keys(tables)
    end
  end

  describe "composite glyphs" do
    test "components are pulled in automatically", %{ttf: ttf} do
      # Find a composite: a negative contour count in the first two bytes.
      composite =
        Enum.find(1..2000, fn gid ->
          case glyph_bytes(ttf, gid) do
            <<n::signed-16, _::binary>> -> n < 0
            _ -> false
          end
        end)

      assert composite, "expected the test font to contain a composite glyph"

      {:ok, small} = Sfnt.subset(ttf, [composite])

      <<_::signed-16, _bbox::binary-8, rest::binary>> = glyph_bytes(ttf, composite)
      <<_flags::16, component::16, _::binary>> = rest

      assert glyph_bytes(small, component) != <<>>,
             "component #{component} of composite #{composite} was dropped"
    end
  end

  describe "checksums" do
    test "head.checkSumAdjustment makes the whole file sum to the magic value", %{ttf: ttf} do
      {:ok, small} = Sfnt.subset(ttf, [3, 40])

      assert Sfnt.Table.checksum(small) == 0xB1B0AFBA
    end
  end

  # Reads a glyph's outline bytes straight out of glyf via loca, independently
  # of the code under test.
  defp glyph_bytes(font, gid) do
    {:ok, tables} = Sfnt.tables(font)
    <<_::binary-50, format::signed-16, _::binary>> = tables["head"]
    <<_::binary-4, count::16, _::binary>> = tables["maxp"]
    glyf = tables["glyf"]

    offsets =
      case format do
        0 -> for <<v::16 <- binary_part(tables["loca"], 0, (count + 1) * 2)>>, do: v * 2
        1 -> for <<v::32 <- binary_part(tables["loca"], 0, (count + 1) * 4)>>, do: v
      end

    start = Enum.at(offsets, gid)
    stop = Enum.at(offsets, gid + 1)

    if is_integer(start) and is_integer(stop) and stop > start,
      do: binary_part(glyf, start, stop - start),
      else: <<>>
  end
end
