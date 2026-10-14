# 0018 - sid2ct player extractors give structure hints only

**Status:** Accepted
**Date:** 2026-10-15

## Context

Some editor players (GoatTracker, DMC and JCH NewPlayer) store their song
data in a known layout. Reading that data would give note rows, patterns and
instrument numbers directly. But a wrong or partial reader could then produce
wrong sound. The register trace of the real SID is the only ground truth.

## Decision

- Known players are identified with SIDId signatures (`sid2ct/players/`).
  Each recognised player has an extractor that reads its song data into
  `StructureHints` (`sid2ct/players/hints.py`): rows, patterns, notes and
  orderlists.
- Hints never produce the final sound. The register trace stays the source of
  truth.
- Trace frames are used only to accept or reject a hint. They are not used to
  derive one.
- Conversion never branches on song names, file paths or hashes.
- Hints only guide the solver. For example, notes that share a source
  instrument prefer one CT instrument, as a soft penalty.

## Consequences

- A wrong extractor can only cost score. It cannot make the output sound
  wrong on its own.
- Each new player needs its own extractor and tests. An unknown player falls
  back to trace-only conversion.
- `--structure-hints auto` runs a slower memory trace (`sidtrace --mem-reads`)
  for recognised players. `off` skips it.
