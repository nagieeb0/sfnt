# Changelog

## 0.1.0

First release.

- `Sfnt.subset/3` for CFF (`OTTO`) and TrueType (`glyf`/`loca`) outlines.
- Two modes: glyph ids preserved by default, or `renumber: true` for the
  smallest possible output plus an `%{old => new}` map.
- Drops layout tables (`GSUB`/`GPOS`/`GDEF`) and unreachable CFF subroutines,
  and prunes the CFF String INDEX.
- Composite TrueType glyphs pull in their components automatically.
- `Sfnt.tables/1` and `Sfnt.glyph_count/1` for inspecting a font.
