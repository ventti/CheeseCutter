# Architecture Decision Records

This directory holds **ADRs** — short, append-only notes that capture *why* a
non-obvious design decision was made. The code shows *what* and *how*; an ADR
preserves the *why* (the alternatives, constraints and consequences) that code
can't show and that a `git log` archaeology dig would only partially recover.

## Conventions

- One file per decision: `NNNN-kebab-title.md`, numbered in order.
- Use the [Nygard template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):
  **Status**, **Context**, **Decision**, **Consequences**.
- **ADRs are append-only.** Once accepted, don't rewrite one — if a decision
  changes, add a *new* ADR that supersedes it and mark the old one
  `Superseded by NNNN`. This is what makes ADRs near-zero-maintenance: there is
  nothing to keep "in sync", only history to extend.
- Keep them short (a screen or less). Link to code with `src/...:line` and to
  the architecture map (`doc/ARCHITECTURE.md`) where useful.

## Why this exists

New contributors (and new AI sessions) re-derive the same rationale repeatedly.
A handful of ADRs answers the recurring "but *why* is it done this way?" once.
Pair them with `doc/ARCHITECTURE.md` (the generated structure map): the map says
where things live, the ADRs say why they're shaped that way.

## Index

| ADR | Title |
| --- | --- |
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions |
| [0002](0002-live-song-image-memory-layout.md) | Live song-image memory layout |
| [0003](0003-single-shortcut-registry.md) | Single shortcut registry as source of truth |
| [0004](0004-editor-export-shares-ct2util-core.md) | Editor export reuses the ct2util core |
| [0005](0005-remote-playback-backends.md) | Remote playback via a shared transport core |
| [0006](0006-instrument-color-tags.md) | Instrument color tags live in the description text |
| [0007](0007-about-splash-scroller.md) | About-splash scroller renders directly over the SDL renderer |
