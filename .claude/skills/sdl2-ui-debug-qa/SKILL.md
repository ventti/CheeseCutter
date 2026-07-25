---
name: sdl2-ui-debug-qa
description: Generic, engine-agnostic strategy for automated debugging and QA of interactive SDL2 UIs — headless/offscreen rendering, deterministic input injection and replay, screenshot/visual-diff regression, state-assertion hooks, crash/hang detection with sanitizers, and CI wiring. Use whenever building or debugging an SDL2-based UI/game and wanting automated testing, regression detection, crash repro, fuzzing, or CI integration — even for a bare "how do I test my SDL2 app" or a bug that's hard to reproduce. In this repo, `ccdriver` (the run-cheesecutter skill) is the reference implementation of layers 1–3.
---

# SDL2 UI Automated Debugging & QA

A layered, engine-agnostic strategy. Each layer is independent — adopt
incrementally, don't build all of it at once.

## The five layers

### 1. Headless execution (foundation)
Run the app without a real display so CI/agents can drive it.
- `SDL_VIDEODRIVER=dummy` (or `offscreen` if you need a real GL/Vulkan context +
  readback) before `SDL_Init`.
- Linux CI fallback: `xvfb-run` if `dummy` isn't enough (e.g. native GL driver quirks).
- Verify: app must reach a stable "frame N rendered" state without a real
  window — this is the prerequisite for everything below.

### 2. Deterministic input injection & replay
Decouple "what drives input" from the app logic.
- Wrap `SDL_PollEvent` behind a thin source: real device → normal path; test
  mode → replay from a recorded/scripted event list via `SDL_PushEvent`.
- Record real sessions once (serialize the `SDL_Event` stream + timestamps) to
  build a corpus of repro cases and regression scripts.
- Use a **fixed timestep + seeded RNG** so replays are bit-reproducible, not
  just "close enough."

### 3. Observable state (the part people skip)
Visual diffing alone is brittle. Expose UI state so tests assert on *meaning*,
not pixels:
- A debug/introspection hook (stdin command, local socket, or in-process
  function) that dumps: focused widget, hit-test result at (x,y), current
  screen/state-machine node, dirty-rect list.
- This is what turns "the button didn't work" into "focus never left widget
  X" — actionable, not just a red diff.

### 4. Visual regression (screenshot diffing)
- Capture via `SDL_RenderReadPixels` (or swap-chain readback for GPU backends)
  at defined checkpoints (scene loaded, dialog open, animation settled).
- Diff against baseline PNGs with a tolerance threshold (pixel delta % or
  perceptual hash) — exact-match diffing breaks on font hinting/AA/GPU driver
  differences across CI runners.
- Store failing diffs as CI artifacts (actual / expected / delta image) — don't
  just report pass/fail.

### 5. Crash & hang detection
- Build a sanitizer variant (ASan+UBSan at minimum; TSan if multi-threaded
  event/render loops) and run the replay corpus through it in CI — this catches
  memory bugs the visual layer never will.
- Watchdog timeout per test case (an SDL event loop can hang silently on a
  modal/blocking call) — kill and flag as hang, not timeout-as-pass.
- On crash/hang, dump the last N injected events + last captured state snapshot
  for repro.

## Fuzzing (optional, high-value once 1–3 exist)
Once headless + input injection + state hooks exist, monkey-testing is nearly
free: generate semi-random event sequences (biased toward valid widget bounds,
not pure noise) and run under sanitizers looking for crashes/asserts/hangs, not
visual correctness.

## CI wiring
- Headless + sanitizer + replay-corpus job on every PR; visual regression as a
  separate (slower, flakier) job with generous tolerance and artifact upload on
  failure.
- Keep the replay corpus in-repo and append to it every time a real bug is fixed
  (regression test = the repro script that found it).

## Practical note for MCP/agent-driven debugging
To let an agent (e.g. Claude Code) drive this interactively rather than just in
CI, expose layers 1–3 as a small local tool server (stdin/socket protocol:
`inject_event`, `capture_screenshot`, `get_widget_state`, `advance_frame N`) —
same pattern as an MCP trace-analysis server: keep responses aggregate/
structured, not raw framebuffers, to avoid context blowout.

## How this maps to CheeseCutter (`ccdriver`)

This repo implements layers 1–3 heavily; layers 4–5 are open. Reuse the harness
rather than rebuilding. See the **run-cheesecutter** skill for the authoritative
build/run reference; the driver source is `.claude/skills/run-cheesecutter/driver.d`.

- **Layer 1 (headless) — done.** The editor renders under
  `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy`; SDL software-renders to a
  readable framebuffer, so `shot:`/`screendump` yield real PNGs.
- **Layer 2 (input injection & replay) — done, two ways.** `./ccdriver` takes an
  ordered `cmd:value` argv sequence (`load:`, `key:`, `keyup:`, `click:`,
  `shiftclick:`, `ff:N`, `jamrender:`, `shot:`, …) for one-shot scripts. It also
  has a persistent **`serve`** mode: a stdin command stream delimited by
  `checkpoint:<marker>` acknowledgements. `tests/ccdriver_session.py`
  (`CCDriverSession`) wraps that into a stateful, deterministic replay session.
  `./ccdriver -h` is the authoritative command list.
- **Layer 3 (observable state) — the strongest fit.** There is a large
  introspection surface far beyond a single `state` dump: `soundstate`,
  `sounddump`, `insbytes`, `regstate`, `cellstate`, `controlstate`,
  `shortcutstate`, `undostate`, `capturestate`, `wave*state`/`wavepreview`,
  `seqdump`/`insdump`/`recdump`, plus raw reSID envelope **oracles**. The
  `tests/test_sound_editor_*.py` pytest corpus deliberately asserts on this
  *meaning* (IDs tie to `doc/SOUND_EDITOR_REQUIREMENTS_AUDIT.md`), not on pixels
  — exactly this layer's thesis.
- **Layer 4 (visual regression) — done, tolerance-based.**
  `tests/visual_regression.py` captures a `shot:` at named checkpoints and
  compares it to a committed `tests/baselines/<name>.png` with a *perceptual
  tolerance* (a small fraction of pixels may differ by a small amount), never an
  exact golden diff — honoring the repo's own "text is the durable oracle" stance
  and this skill's anti-pattern warning. `CCUTTER_UPDATE_BASELINES=1` regenerates
  baselines; on mismatch the actual + a red diff mask land in `tests/_artifacts/`
  for CI upload. Checkpoints live in `tests/test_visual_regression.py`.
- **Layer 5 (crash/hang detection) — ASan builds clean; run as a manual smoke.**
  `make -f Makefile.mac sanitize-asan` builds an AddressSanitizer ccdriver;
  `sanitize-smoke` then drives one broad editor session through it
  (`tests/asan_smoke.py`). It found **zero memory errors**. Hard-won specifics,
  all encoded in the target:
  - Instrument only the **D** objects (the UI under active development); leave
    the reSID **C++** DSP uninstrumented — its per-sample loop under ASan is
    minutes-slow and finds nothing the D side doesn't.
  - Link via the **LLVM-version-matched Homebrew clang** (llvm@20), not Apple
    clang, so the D objects' compiler-rt ASan runtime resolves (`__asan_version_
    mismatch_check_*` are incompatible across clang flavors).
  - Never instrument the C acme objects — the host `mkplayer` tool hangs.
  - **The overhead is severe here (~80x): a ~1s headless session takes ~90s
    under ASan** (D GC / software-framebuffer hot paths × ASan shadow memory).
    So re-running the full ~115-test corpus is impractical (hours). The value is
    memory safety — covered by one broad smoke — not re-verifying the numerics
    the release-binary layer-1-3 corpus already checks. Hence the CI `sanitize`
    job is **manual (`workflow_dispatch`) only, never gating a PR**; for a deeper
    look, run a specific repro through the instrumented `./ccdriver` and just
    wait it out.

## Realizing the MCP/agent pattern here
The "expose layers 1–3 as a small local tool server" note above is **already
built**: `serve` + the `checkpoint:` stdin protocol *is* that server, and
`CCDriverSession` is a ready client. An MCP wrapper would just shell out to it.

## CI wiring status here
`.github/workflows/build.yml` runs, on every PR: the three platform **builds**
and a **`test`** job (macOS: `make -f Makefile.mac test-sound-editor` — layers
1-4, uploads `tests/_artifacts` on failure). The **`sanitize`** job (layer 5,
`make sanitize-smoke`) is **manual only** (`workflow_dispatch`) because of the
ASan overhead above — trigger it from the Actions tab. Locally, `mise run test`
runs the same functional corpus.

## Anti-patterns to flag
- Exact-pixel screenshot diffing with zero tolerance (guaranteed CI flakiness
  across GPU/driver versions).
- Testing only via visual diff with no state introspection — undiagnosable
  failures.
- Real-time-dependent tests (sleep-based waits) instead of a fixed timestep —
  nondeterministic replays.
