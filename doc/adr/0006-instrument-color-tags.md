# 0006 — Instrument color tags live in the description text

**Status:** Accepted

## Context

Users wanted to color-code instruments so a given sound stands out in the
instruments list and the track view. The song file format (and its `.ct`
on-disk serialization) is fixed; adding a new per-instrument field would be a
format/version change and would need new UI to edit it. Each instrument already
carries a free-form 32-char description (`Song.insLabels`, `src/ct/base.d`) with
an existing editor (Return/Tab in the instrument table) and existing
persistence.

## Decision

Encode the color preference as a `$` tag inside the existing description string
rather than adding a data field:

- `$X` (one hex digit `0`–`F`) → instrument-number **foreground** = palette
  index X; background unchanged.
- `$XY` (two hex digits) → foreground X **and** background Y.

`Song.instrumentColor(int ins)` parses the label on demand (returns
`InstrumentColor{fg,bg}`, `-1` = unset): first valid `$`+hex(+hex) wins; a `$`
not followed by a hex digit is skipped so it stays usable as text. The hex digit
maps directly to the 16-entry C64 palette (`PALETTE` in `src/com/fb.d`), the same
mapping the framebuffer's backtick color codes already use.

Two render sites consume it, coloring only the instrument-**number** cell(s):
- instruments list — `InsValueTable.update` (`src/ui/tables.d`);
- track view — `SeqVoice.update` (`src/seq/seqtable.d`).

Precedence falls out of draw order (no extra state): base text → user tag color
→ active-instrument override → selection tint → cursor overlay (which inverts
the cell). The user color therefore only **replaces the default gray**; cursor,
highlight and active-instrument colors always win. The tag is parsed live each
frame, so edits take effect immediately and need no extra wiring.

## Consequences

- Zero file-format change; works with existing songs, the existing description
  editor, and existing save/load. The tag is plain text, so it round-trips and
  is visible/editable.
- The description field is now overloaded: a literal `$` followed by a hex digit
  in a name becomes a color directive. Mitigated by "first valid tag wins" and
  ignoring `$` + non-hex; documented in the guide (Player Tables) and README.
- Background tint is scoped to the number cell only (in the track view the
  note/command columns belong to no single instrument). On the single
  track-value row the playback/wrap bars tint only where the background is still
  `0`, so a user background on those two cells suppresses the bar there —
  cosmetic and rare, accepted.
