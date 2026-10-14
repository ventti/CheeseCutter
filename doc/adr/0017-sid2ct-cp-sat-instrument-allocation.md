# 0017 - CP-SAT instrument allocation within stock CT 4.x limits

**Status:** Accepted
**Date:** 2026-10-15

## Context

A converted song must fit the limits of a stock CheeseCutter 4.x player: at
most 47 instruments, and fixed numbers of wave, pulse, filter and command
rows. Many observed sounds are more than 47. The greedy allocation
(`budget`) picks instruments one at a time and can waste the limit on quiet
or rarely heard sounds.

## Decision

- `--instrument-allocation solve` chooses at most 47 instruments and the
  table rows with an integer model in OR-Tools CP-SAT (`sid2ct/solve.py`).
  The model minimises the audibility-weighted distortion of each sound
  against the instrument that plays it. The cost comes from the exact CT
  player model and `regdist`, plus envelope and loudness terms.
- The legacy greedy allocation stays as a candidate and as the fallback when
  the solver gives no solution, errors, or is missing.
- The solver uses a fixed number of threads (`SOLVER_WORKERS`, 2) and stops on
  a deterministic time limit. Its result does not depend on `--workers` or on
  machine load. Wall time is only a backstop at the end of the budget.

## Consequences

- `ortools` is an optional dependency. Without it the solver is skipped and
  the greedy allocation is used. Plain `python3` still converts.
- The objective is distortion, not the number of exact variants. Some sounds
  can become approximations even when the total cost goes down. A small bias
  favours exact matches.
- The loudness weight is a tuned guess, because register distance can prefer
  a loud wrong sound over a quiet right one.
