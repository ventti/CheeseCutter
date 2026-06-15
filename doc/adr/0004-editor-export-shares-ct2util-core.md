# 0004 — Editor export reuses the ct2util core

**Status:** Accepted

## Context

`ct2util` is the standalone CLI that compiles/optimizes a `.ct`/`.ct2` song into
a runnable `.prg` or a PSID `.sid`. The editor grew the same need (export a
packed `.prg` and a PSID `.sid` directly from a session). Reimplementing the
pack/optimize/format logic in the UI would risk the CLI and the editor producing
different bytes from the same song.

## Decision

Keep the build/export logic in the `ct` package and have both front ends call
it. `src/ct/build.d` owns validation and the `ExportFormat` set
(`FullPrg`, `OptimizedPrg`, `Psid` — `ExportOptions`), with `ct.purge` providing
the optimize pass and `ct.dump` the serialization. `ct2util.d` and the editor
UI (`src/ui/*`, via `ct.build`) are thin callers over that shared core.

## Consequences

- The CLI and the editor produce identical output for identical input — one code
  path to test and optimize.
- Export formats are extended in one place (`ExportFormat` / `build.d`), not per
  front end.
- `ct.build` must stay UI-agnostic so the CLI keeps linking without SDL/editor
  modules.
