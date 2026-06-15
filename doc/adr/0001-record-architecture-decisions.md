# 0001 — Record architecture decisions

**Status:** Accepted

## Context

New contributors and new AI sessions repeatedly pay an "orientation tax",
re-deriving the same rationale ("but *why* is it done this way?"). The generated
structure map (`doc/ARCHITECTURE.md`) answers *where things live* and *what
depends on what*, but it can't carry the *why*: the constraints, the rejected
alternatives, the gotchas. Free-form design docs accumulated in the repo root
(`player_v5.md`, `INSTRUMENT_ANALYSIS.md`, `doc/ADSR_VISUALIZATION_*.md`, …) but
have no convention, no index, and drift.

## Decision

Keep lightweight, append-only Architecture Decision Records under `doc/adr/`,
one file per decision, using the Nygard template (Status / Context / Decision /
Consequences). ADRs are immutable once accepted — a changed decision is captured
by a *new* ADR that supersedes the old one, never by editing history.

## Consequences

- The "why" gets a stable, greppable home that pairs with the generated map.
- Near-zero maintenance: nothing to keep "in sync" — only history to append.
- Existing ad-hoc design docs can be folded in or linked from an ADR over time;
  not required up front.
