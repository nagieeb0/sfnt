defmodule Sfnt do
  @moduledoc """
  Font subsetting in pure Elixir, for embedding fonts in PDFs.

  A PDF embeds the fonts it uses. Embed a whole face and a one-page invoice
  carries 150 KB of glyphs it will never draw. Subsetting takes the brand face
  this was written for from **158 KB to 7 KB** — smaller than the rest of the
  invoice.

      {:ok, small} = Sfnt.subset(font, used_glyph_ids)

  ## What it removes

  Three things, and the last two are the ones people forget:

    * **Unused outlines.** On a typical invoice that is 900 of 949 glyphs.
    * **Layout tables.** `GSUB`, `GPOS` and `GDEF` drive shaping — which has
      already happened by the time a PDF exists, since a PDF addresses glyphs
      by id. They were 31% of the file here.
    * **Unreachable subroutines.** CFF glyphs share outline fragments through
      subroutines. They were another 13 KB, and a glyph that is no longer drawn
      stops needing them.

  ## Two modes, and the choice matters

  By default glyph ids are **preserved**: unused glyphs are emptied rather than
  removed. A PDF written with Identity-H addresses glyphs by id, so renumbering
  behind an already-written content stream would render plausible but wrong
  letters. Keeping ids means subsetting can happen at any point in the pipeline,
  at the cost of the per-glyph overhead of the glyphs you dropped.

  With `renumber: true` the glyphs are packed down and you get back a
  `%{old_id => new_id}` map to rewrite your content stream with. That removes
  the overhead entirely — 21 KB against 7 KB on the same invoice — but you must
  apply the map.

  ## Supported

  TrueType (`glyf`/`loca`) and CFF outlines. Composite glyphs pull in their
  components automatically. CID-keyed CFF returns
  `{:error, :cid_keyed_unsupported}` rather than emitting a broken font;
  `renumber: true` is CFF-only for now.
  """

  alias Sfnt.{CFF, Glyf, Table}

  # Layout and hinting-adjacent tables that an embedded PDF font never reads.
  # Everything else is kept, so an unknown-but-required table is never dropped.
  @droppable ~w(GSUB GPOS GDEF GSUB JSTF BASE MATH DSIG FFTM LTSH VDMX hdmx gasp
                PCLT kern morx feat prop Silf Glat Gloc Sill vhea vmtx VORG)

  @typedoc "Glyph ids to keep, as returned by a shaping engine."
  @type glyphs :: MapSet.t(non_neg_integer()) | [non_neg_integer()]

  @doc """
  Subsets `font` to the glyphs in `keep`.

  Glyph 0 (`.notdef`) is always kept — a PDF viewer falls back to it, and a
  font without it is invalid.

  ## Options

    * `:drop_layout` — remove `GSUB`/`GPOS`/`GDEF` and friends. Default `true`;
      set to `false` when the subsetted font is for something other than a PDF,
      such as a web font that still needs to shape.
  """
  @spec subset(binary(), glyphs(), keyword()) ::
          {:ok, binary()}
          | {:ok, binary(), %{non_neg_integer() => non_neg_integer()}}
          | {:error, term()}
  def subset(font, keep, opts \\ []) when is_binary(font) do
    keep = keep |> MapSet.new() |> MapSet.put(0)
    renumber? = Keyword.get(opts, :renumber, false)

    with {:ok, flavour, tables} <- Table.parse(font),
         {:ok, tables} <- subset_outlines(tables, keep, renumber?) do
      tables =
        if Keyword.get(opts, :drop_layout, true),
          do: Map.drop(tables, @droppable),
          else: tables

      tables = Map.drop(tables, Keyword.get(opts, :drop, []))

      if renumber? do
        order = Enum.sort(keep)

        {:ok, Table.build(flavour, renumber_metrics(tables, order)),
         order |> Enum.with_index() |> Map.new()}
      else
        {:ok, Table.build(flavour, tables)}
      end
    end
  end

  # With renumbering, everything indexed by glyph id has to be rebuilt in the
  # new order: the horizontal metrics, and the glyph count they are read with.
  defp renumber_metrics(tables, order) do
    count = length(order)

    tables
    |> Map.update!("maxp", fn <<version::32, _old::16, rest::binary>> ->
      <<version::32, count::16, rest::binary>>
    end)
    |> then(fn t ->
      case {t["hmtx"], t["hhea"]} do
        {hmtx, <<head::binary-34, num_metrics::16>>} when is_binary(hmtx) ->
          t
          |> Map.put("hmtx", rebuild_hmtx(hmtx, num_metrics, order))
          |> Map.put("hhea", <<head::binary, count::16>>)

        _ ->
          t
      end
    end)
  end

  # hmtx is `numberOfHMetrics` advance/bearing pairs followed by bearings only,
  # so a glyph past that run reuses the last advance. Reading it back out per
  # glyph and re-emitting full pairs is simpler than preserving the compression,
  # and costs two bytes per glyph on a table that is now tiny.
  defp rebuild_hmtx(hmtx, num_metrics, order) do
    last = max(num_metrics - 1, 0)

    Enum.map_join(order, fn gid ->
      i = min(gid, last)

      case hmtx do
        <<_::binary-size(^i)-unit(32), advance::16, bearing::signed-16, _::binary>> ->
          <<advance::16, bearing::signed-16>>

        _ ->
          <<0::16, 0::16>>
      end
    end)
  end

  @doc """
  Splits a font into its tables, keyed by tag.

  Useful on its own for inspecting a font — `Sfnt.tables(font) |> Map.keys()`
  answers "what is actually in this file".
  """
  @spec tables(binary()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def tables(font) do
    with {:ok, _flavour, tables} <- Table.parse(font), do: {:ok, tables}
  end

  @doc """
  Number of glyphs in the font, from `maxp`.
  """
  @spec glyph_count(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def glyph_count(font) do
    with {:ok, _flavour, tables} <- Table.parse(font) do
      case tables["maxp"] do
        <<_version::32, count::16, _::binary>> -> {:ok, count}
        _ -> {:error, :missing_maxp}
      end
    end
  end

  # ── Outlines ──────────────────────────────────────────────────────────────

  defp subset_outlines(%{"CFF " => cff} = tables, keep, renumber?) do
    with {:ok, subsetted} <- CFF.subset(cff, keep, renumber: renumber?) do
      {:ok, Map.put(tables, "CFF ", subsetted)}
    end
  end

  # Renumbering TrueType would mean rewriting composite glyph references as
  # well as glyf/loca, and half-doing it would produce a font that loads and
  # draws the wrong letters. Refuse instead.
  defp subset_outlines(%{"glyf" => _} = _tables, _keep, true),
    do: {:error, :renumber_unsupported_for_truetype}

  defp subset_outlines(
         %{"glyf" => glyf, "loca" => loca, "head" => head} = tables,
         keep,
         false
       ) do
    with {:ok, num_glyphs} <- num_glyphs(tables),
         {:ok, format} <- loca_format(head),
         {:ok, new_glyf, new_loca, new_format} <-
           Glyf.subset(glyf, loca, keep, format, num_glyphs) do
      {:ok,
       tables
       |> Map.put("glyf", new_glyf)
       |> Map.put("loca", new_loca)
       |> Map.put("head", put_loca_format(head, new_format))}
    end
  end

  defp subset_outlines(_tables, _keep, _renumber?), do: {:error, :no_outlines}

  defp num_glyphs(%{"maxp" => <<_version::32, count::16, _::binary>>}), do: {:ok, count}
  defp num_glyphs(_), do: {:error, :missing_maxp}

  # head.indexToLocFormat lives at byte 50.
  defp loca_format(<<_::binary-50, format::signed-16, _::binary>>) when format in [0, 1],
    do: {:ok, format}

  defp loca_format(_), do: {:error, :bad_head}

  defp put_loca_format(<<head::binary-50, _::16, rest::binary>>, format),
    do: <<head::binary, format::16, rest::binary>>
end
