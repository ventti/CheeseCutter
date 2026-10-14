# 0016 - sid2ct fits with register distance; audio score selects

**Status:** Accepted
**Date:** 2026-10-15

## Context

`sid2ct convert` builds many candidate songs and must pick one. Rendering
audio for every candidate and every search trial is slow. Register traces
(the SID register values per frame) are cheap to get and to compare. Their
score does not always match what the ear hears. For example, the filter
variant choice can look better by register distance and sound worse.

## Decision

- Inside the search, each trial is scored by `sid2ct/regdist.py`. It is a
  perceptually weighted distance between two register traces. The converted
  song is replayed through the real CT player model (`ctplayer`) to get its
  trace. No audio is rendered for this step.
- A surrogate model may skip the audio render of a trial that is clearly
  worse. Without a trusted model, a fixed rule prunes trials.
- The final choice is made by audio score v2. A candidate is only eligible if
  its v1 score is within `--v1-tolerance` (0.01) of the best v1 any candidate
  reached. This keeps v2 gains from hiding a large v1 loss.
- The filter variant (per-instrument or global filter) is an exception. Its
  choice in the first stage is judged by rendering both and keeping the better
  v2, because register distance can disagree with the ear there.

## Consequences

- The inner loop is fast, so more trials fit in the time budget.
- `regdist` and audio can disagree. A low register distance does not prove a
  good sound. Only audio selection decides the output.
- Changing the weights in `regdist.py` changes which trials are pruned, so
  bench results should be compared with the same settings.
