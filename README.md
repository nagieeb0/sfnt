# Sfnt

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Font subsetting in pure Elixir. No NIFs, no ports, no `fonttools`.

A PDF embeds the fonts it uses. Embed a whole face and a one-page invoice
carries 150 KB of glyphs it will never draw.

```elixir
{:ok, small} = Sfnt.subset(font, used_glyph_ids)
```

On the brand face this was written for — an Arabic + Latin OpenType family:

| | bytes |
| --- | ---: |
| original | 158,424 |
| subsetted, ids preserved | 21,728 |
| subsetted, renumbered | **6,956** |

That is **95.6%**, and the font is now smaller than the invoice around it.

## Installation

```elixir
def deps do
  [{:sfnt, github: "nagieeb0/sfnt"}]
end
```

## What it removes

Three things, and the last two are the ones people forget.

**Unused outlines.** On a typical invoice that is 900 of 949 glyphs.

**Layout tables.** `GSUB`, `GPOS` and `GDEF` drive shaping — which has already
happened by the time a PDF exists, because a PDF addresses glyphs by id, not by
character. They were 31% of this file and never read again.

> One trap worth stating plainly: this only holds if shaping happened *before*
> subsetting. Some PDF writers shape from the font you hand them, in which case
> dropping `GSUB` means Arabic stops joining and the glyph ids no longer match
> what you subsetted for. Pass `drop_layout: false` for those.

**Unreachable subroutines.** CFF glyphs share outline fragments through
subroutines, and a glyph that is no longer drawn stops needing them. Another
13 KB here. Finding them means walking Type 2 charstring bytecode, including the
`hintmask` operator whose length depends on how many stem hints have been
declared so far — miscount and every byte after it is misread.

## Two modes, and the choice matters

```elixir
# Glyph ids preserved: unused glyphs are emptied, not removed.
{:ok, small} = Sfnt.subset(font, glyph_ids)

# Renumbered: packed down, with a map to rewrite your content stream.
{:ok, smaller, %{old_id => new_id}} = Sfnt.subset(font, glyph_ids, renumber: true)
```

**Preserving ids is the default and it is the safe one.** A PDF written with
Identity-H addresses glyphs by id, so renumbering behind an already-written
content stream renders plausible but wrong letters — the kind of bug that ships.
Preserving ids means subsetting can happen at any point in the pipeline, at the
cost of the per-glyph overhead of the glyphs you dropped.

**Renumbering is three times smaller** and gives back the mapping, but you have
to apply it.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `:renumber` | `false` | Pack glyph ids down; returns `{:ok, font, map}`. CFF only. |
| `:drop_layout` | `true` | Remove `GSUB`/`GPOS`/`GDEF` and friends. Set `false` for a web font that still has to shape. |
| `:drop` | `[]` | Extra tables to remove by tag, e.g. `["cmap", "name"]` for a PDF-only font. |

## Also useful on its own

```elixir
Sfnt.tables(font)      #=> {:ok, %{"CFF " => <<...>>, "head" => <<...>>, ...}}
Sfnt.glyph_count(font) #=> {:ok, 949}
```

## Correctness

Rewriting a font fails quietly: a subtly wrong offset produces a file that loads
fine and draws the wrong letters. So the suite checks things that would actually
break rather than that the output is smaller —

- kept glyphs keep their **exact** outline bytes, compared against the original
- dropped glyphs really are empty
- advance widths follow the renumbering
- `head.checkSumAdjustment` makes the whole file sum to `0xB1B0AFBA`
- subsetting is idempotent
- composite glyphs pull in their components

Both outline formats are covered by their own fixture. Independently verified
against `fontTools`: across 111 subsetted glyphs, **zero outline differences**,
and the renumbered output beat `fontTools`' own subsetter on the same glyph set
(26,212 against 29,892).

```sh
mix test
```

## Supported

CFF (`OTTO`) and TrueType (`glyf`/`loca`).

Not supported, and reported rather than mangled: CID-keyed CFF
(`{:error, :cid_keyed_unsupported}`), WOFF/WOFF2 (decompress first), and font
collections. `renumber: true` is CFF-only for now — on TrueType it returns
`{:error, :renumber_unsupported_for_truetype}` rather than half-applying it,
because renumbering there also means rewriting composite glyph references.

`cmap` is not remapped when renumbering, so drop it (`drop: ["cmap"]`) for a
PDF-embedded font, where nothing reads it.

## License

MIT. Test fonts are SIL Open Font License — see `test/support/ATTRIBUTION.md`.
