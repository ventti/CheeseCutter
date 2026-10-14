# Generic SID reconstruction prototype

Requires Python 3.10+ and libsidplayfp 3.x with its SIDLite builder.
This is a generic converter for supported PSIDs and players. Named songs below
are evaluation examples only. Conversion and comparison must never branch on
their names, paths, hashes, tune-specific addresses, or hand-picked instruments.
Format-level recognition (such as native CC recovery) and generic observations
(such as paired frequency loads) are allowed; inference must fall back safely.
Build the helpers once:

```sh
make -f Makefile.mac ct2util
python3 tools/build_sid_renderer.py
```

The renderer build uses `pkg-config --cflags --libs libsidplayfp`. For a library
extracted or built into a local prefix, use
`python3 tools/build_sid_renderer.py --prefix /path/to/libsidplayfp/prefix`;
this links its static library. Build wall-clock duration is printed.
This worktree's renderer was built against libsidplayfp 3.1.1 extracted into
`/private/tmp/cheesecutter-sidplayfp/libsidplayfp/3.1.1`; nothing was installed globally.

Run from the repository root with the `sid2ct` package:

```sh
python3 -m sid2ct --help
python3 -m sid2ct convert song.sid -o song.ct
python3 -m sid2ct compare song.sid -o comparison
python3 -m sid2ct compare song.sid song.ct -o comparison-existing --sid 8580
python3 -m sid2ct score original.wav reconstructed.wav
```

`convert` produces an editable CT and compares the entire detected song, including
mixed audio, each SID voice, and 5-second windows. It saves WAVs and reports beside
the CT in `<name>.comparison/`. Both `convert` and `compare` default to the duration
through the first proven play-routine loop. `--seconds` selects an explicit finite
capture instead; `--audio-seconds` deliberately limits conversion validation.
`--skip-diagnostics` retains mixed-WAV validation only. `score` reports JSON metrics
for existing mono PCM16 WAVs.

Loop detection hashes all 64 KiB of emulated memory after each play call, including
stack, zero page and self-modified code. Identical player state proves recurrence
within this deterministic CPU trace; a repeated musical phrase alone does not.
The default search limit is 600 seconds (`convert --max-seconds`). If no recurrence
is found, automatic duration fails rather than silently truncating the song. An
explicit `--seconds` capture is available for unsupported/non-looping players.
This is a conservative boundary: irrelevant counters can delay detection beyond
the audible loop. It does not prove SID oscillator/envelope/filter state recurrence
or equivalence on hardware. CIA-timed PSIDs use the recorded latch after every play call, so variable
tempo is integrated before resampling. VBI-timed PSIDs ignore CIA latch writes.
This assumes one interrupt interval per play call; intra-call timer control and
IRQ-driven players are outside this tracer model.

Generated static and native songs split patterns at the intro/loop boundary and
restart the loop section rather than replaying the intro. Boundaries are rounded
to the selected row grid; the report records timing errors. Native CC recovery
keeps the source's original orderlists. External raw traces require explicit
`--seconds`, because they contain no player-state loop evidence.

Use `<subcommand> --help` for its options. Existing comparison directories are
refused; `convert --force` can replace its explicitly named outputs.

Package responsibilities: `sid2ct.convert` handles conversion, `sid2ct.native`
builds editable programs, `sid2ct.audio` scores WAVs, `sid2ct.loops` detects recurrence and timing,
and `sid2ct.compare` runs A/B
diagnostics. The former four standalone Python tools are replaced by this package;
the C++ renderer and its build helper remain in `tools/`.

Further conversion examples:

```sh
python3 -m sid2ct convert song.sid -o output/song.ct --seconds 30
python3 -m sid2ct convert song.sid -o output/song.ct --seconds 30 --multiplier 2
python3 -m sid2ct convert song.sid -o output/song.ct --seconds 30 --auto-row-frames
```

Source timing is inferred from the CIA latch after initialization/play calls, or
PAL VBI when no CIA latch is programmed. `--multiplier N` explicitly overrides
it as `50*N` source calls/sec (range 1..16). Noninteger CIA rates are resampled to
the nearest supported CC multiplier at the physical PAL cadence (about 50.125 Hz)
to avoid cumulative timing drift; this may
lose changes shorter than a destination sound tick. This remains an approximation,
not recovery of intra-call SID writes.

Recognized CheeseCutter players use `sid2ct` to recover native structure and all
subtunes. Other players are traced. By default, WAV validation compares the
original static GTS5 bridge with a native CC mapper that fits observed sound
programmes, then keeps the better score. No GoatTracker executable or siddump
dependency is required.
The resulting `.ct` is editable and can be exported using `ct2util sid`.

The `.json` report records event counts, collisions, timing changes, instrument
merges, audio comparison metrics, and the CC conversion's warnings. Output/report/
WAV overwrite requires `--force`. All conversion and validation happen in temporary
files before outputs are written. Use `--skip-audio` for the original trace-only
workflow when libsidplayfp is unavailable.

Useful options:

- `--subtune 2`: choose the source subtune for generic reconstruction.
- `--row-frames 3`: finer output row grid; default 6 PAL frames. Range 3..127.
- `--force-trace`: compare inference with a known CheeseCutter source.
- `--trace source.trace`: infer from raw `ct2util sidtrace` output (25 hexadecimal
  register bytes per call); the selected multiplier defines the trace's timebase.
- `--tool /path/to/ct2util`: select a built utility.
- `--audio-seconds 30`: compare up to 30 seconds; default the entire detected/captured song.
- `--auto-row-frames`: compare grids 3, 4, 5, 6, 8 and 12 plus the explicit grid,
  then select the highest-scoring successful reconstruction.
- `--sid-model 8580`: force the model for both WAVs; default follows the source header.
- `--renderer /path/to/sid_render`: select the rendering helper.
- `--skip-audio`: omit WAVs and validation; incompatible with automatic grid search.
- `--sound-programs auto`: compare static and dynamic sound mappings (default).
  `static` selects the original GTS5 bridge; `dynamic` selects native sound-program
  inference. With audio skipped, `auto` uses the dynamic mapper.
- `--pitch-programs auto`: compare the original six-frame attack mapping with
  complete per-note pitch/control trajectories. The full mapping compresses
  redundant terminal holds to share instruments, preserves later arpeggios and
  held-gate note changes, and remains bounded by native table capacity. Both
  mappings are scored over the entire captured song; without audio, use full.
  `attack` preserves the original mapping, `compact` adds terminal-hold sharing
  to that mapping, and `full` also preserves later pitch changes. Auto tests all
  three to retain the best whole-song score. Sub-semitone slides/vibrato still
  require approximation to the tuning table.
- `--coupled-programs auto`: analyze physical SYNC/RING dependencies and compare
  the retained legacy mapper with preserved source-oscillator programs when
  effects are present. `preserve` keeps full pitch/control trajectories on both
  participating voices, including waveform-off/gate-off sources, follows
  upstream sync chains, preserves TEST and zero frequency, and compares coupled
  contours when instruments must be approximated. A reserved silent fallback
  prevents table exhaustion from making a hidden oscillator audible. `legacy`
  keeps the earlier behavior. With audio skipped, auto uses preserve for traces
  with dependencies. Oscillator phase, sub-semitone ratios, startup writes and
  table/row limits still prevent exact reconstruction.
- `--modulation-programs auto`: compare the retained legacy pulse mapper with a
  compact mapper (default). Compact programs drop final flat holds, preserve
  pulse low bits, reset discontinuities rather than clipping their slopes, and
  avoid the `$FF` keep-current preset sentinel. `legacy` and `compact` force one
  mapper; without audio, auto uses compact. Filter fitting is unchanged. Both
  candidates still use bounded programs, so complex or long pulse evolution can
  remain incomplete. Auto retains the better whole-capture mix score; individual
  voices/windows can still regress and must be checked in the diagnostics.
- `--sound-rate auto`: compare native programs at 50 Hz and the input play-call
  rate (default). `base` forces 50 Hz; `source` preserves source-rate sound ticks.
  Sequence rows always advance at 50 Hz. With audio skipped, `auto` uses source rate.
- `--tuning auto`: compare default tuning with a corroborated indexed source
  table, when available. `default` forces CC tuning; `source` requires recovery.
  Existing anchored DMC4 tuning remains the default for that recognized format.
  With audio skipped, recovered tuning is used without WAV selection.

## WAV validation

### Generic A/B diagnostics

The same command accepts any supported source SID, converting it automatically,
or compares against an existing CT (or SID). No song-specific comparison script
is required:

```sh
python3 -m sid2ct compare input.sid -o output/ab
python3 -m sid2ct compare input.sid reconstructed.ct -o output/ab-existing
python3 -m sid2ct compare input.sid -o output/ab-8580 --sid 8580
python3 -m sid2ct compare input.sid reconstructed.ct -o output/ab-6581 --sid 6581
```

The default SID model follows the source header's explicit 6581/8580 preference;
unspecified/either falls back to 6581. An override applies to both paths, including
automatic conversion's candidate selection. `--sid-model` is an alias for `--sid`.
Duration defaults to the detected source loop, diagnostic windows to 5 s (`--seconds` and
`--window-seconds`). The source subtune uses `--subtune`; an existing candidate
uses `--candidate-subtune` (default 1). Automatic native recovery follows the
converter's selected output subtune, including multi-subtune CC recovery.

With SID-only input, comparison converts the song and exports the generated CT
back to SID before rendering it. Conversion options include `--row-frames`,
`--auto-row-frames`, and `--selection-seconds` (default the whole song). Selection
remains a full-mix heuristic; voice/window diagnostics do not change the chosen
conversion.

Compare multiple versions without reconverting:

```sh
python3 -m sid2ct compare input.sid \
  --candidate baseline=baseline.ct --candidate refined=refined.ct -o output/versions
```

The new output directory contains the CT/SID exports, mixed WAVs, three solo WAVs
per version, all-muted reference WAVs, background-subtracted voice WAVs, and
`report.json`. Existing directories are refused to preserve baselines. Reports
compare the mix and each physical SID voice over the full duration and every
window, with RMS, envelope/spectral similarity, PCM error, timing, and worst windows.
Detected SYNC/RING sections also add physical voice-pair renders and
`coupled_pairs` diagnostics. `cross_channel_effects` identifies source/destination
voices, active intervals, hidden source activity and frequency changes. Pair
windows list intersecting coupling intervals and the worst active window.
Source audio muting keeps its oscillator running (covered by a ring-source
renderer regression); solo scores therefore include the actual cross-channel
input. Pair windows can contain uncoupled audio, shared filtering and a third
voice in a sync chain. They are diagnostic views, not isolated oscillator stems.

Silent or very short windows are inconclusive. Voice matching is by physical
channel number; it does not infer rearranged musical roles.

All voices/windows use the full mix's alignment to expose relative timing errors;
independent per-voice alignment is also reported as a secondary diagnostic.
SIDLite muting retains synthesis/filter interactions, so solo renders are not
additive stems. An all-muted render is subtracted to remove shared DC/background
from the primary voice comparisons; raw solo comparisons are retained too.
Subtraction clipping is counted. Shared nonlinear filtering, sync/ring coupling,
and backend-dependent sample muting limit attribution. This compares audio
observations, not the original instrument source.

### Mixed WAV selection

The source SID and re-exported CC SID are rendered through the **same libsidplayfp
instance configuration**, each in a fresh process: SIDLite backend, forced PAL,
the same SID model, 16 kHz mono PCM16, filters enabled and power-on delay zero.
No normalization is applied. libsidplayfp uses the SID's actual interrupt/timer
setup, so this comparison is independent of the reconstruction CPU tracer. It
can expose a wrong manually supplied source multiplier.

Outputs include `song.source.wav` and `song.reconstructed.wav` for listening.
The JSON records the renderer version/settings, tested duration, selected subtune,
RMS levels, overlap, alignment, normalized PCM error, envelope similarity and
spectral similarity. Alignment searches up to 250 ms on a 10 ms grid. The
approximate score combines time-varying logarithmic frequency-band shapes with
amplitude-envelope similarity and penalizes cropped overlap. It is **a candidate
ranking heuristic**, not a perceptual quality percentage or proof of equivalence.

`exact_match` requires equal-length, sample-identical, non-silent PCM. Two silent
recordings, or a near-silent/very short recording, are `inconclusive`. Other results
are `different`, including scores close to one. An exact match only establishes
agreement for the selected renderer settings, subtune and tested interval. Startup
write timing and oscillator phase can prevent PCM equality even when register
snapshots match. SIDLite is the available libsidplayfp backend here; results do
not establish equivalence across other SID engines or real hardware.

Automatic grid search renders the source once and each grid/sound-program/rate/tuning
candidate once, retains the winning `.ct` and WAV, and reports every candidate/
error. Static candidates remain in the search, so native mapping cannot lower
the best score on the selected interval. It does not infer the source multiplier
or song length.
A short comparison interval can select a grid that is worse later in the song.
Fixed-grid runs also report the rate/tuning search in `sound_program_search`.

Upstream API references: [libsidplayfp](https://github.com/libsidplayfp/libsidplayfp)
and its [3.x playback example](https://libsidplayfp.github.io/libsidplayfp/html/demo_8cpp-example.html).

## What it estimates

Gate rises mark attacks; gate falls mark releases. Stable pitch changes lasting
three PAL frames can introduce another note while the gate remains on. Pitch
uses PAL oscillator tuning, with a 35-cent tolerance for these held-note changes.

Static instruments cluster waveform/control bits, ADSR and pulse width after a
short onset window. Pitch is excluded from the key so transposed notes can reuse
an instrument. Pulse width is rounded to 16 SID units. Once 47 instruments are
allocated, additional timbres reuse a nearest estimate and are counted in the
report. Waveforms and pulse presets become native CC programs through the
existing GTS5 mapper. Fixed 64-row chunks deduplicate by exact content.

### Native sound-program fitting

The dynamic mapper detects raw gate rises, including TEST+GATE ($09) onsets,
then fits wave/pitch attack trajectories and explicit gate release into native
CC instrument programmes. Short gates can therefore survive even when note-on
and gate-off would fall on the same pattern row. Waveform runs use CC delay rows;
the attack mapper retains six PAL frames of pitch at the selected sound rate;
the full mapper retains the complete observed note segment. Sub-semitone modulation remains simplified. The attack mapper uses the most
common stable non-noise pitch; full mapping uses the lowest stable tonal pitch
to keep descending arpeggios transposable.

Pulse and filter trajectories are fitted as bounded piecewise-linear sweeps.
Pulse presets retain 16-SID-unit precision, cutoff presets keep the high eight
bits, and native filter mode/resonance/routing bits are preserved. Programs still
have timing/model limits and can be omitted when tables fill. Frequently used
sound variants allocate first; remaining variants reuse an envelope/control
estimate. Reports include wave/pulse/filter row counts and approximation counts.
Filter fitting preserves the high cutoff byte without extra rounding and accounts
for the preset-only first tick of each row. Discontinuities reset cutoff rather
than becoming clipped sweeps. Cutoff byte $FF is approximated as $FE because $FF
is the player's "keep current cutoff" sentinel.

A narrow DMC4-compatible code anchor detects its tempo work cell and paired
frequency-table loads, then recovers the 96-note tuning table. The source is the
[DMC format reference](https://github.com/anarkiwi/pydmcsid/blob/main/docs/format.md)
and its [player transcription](https://github.com/anarkiwi/pydmcsid/blob/main/src/pydmcsid/player.py).
No pydmcsid runtime dependency or copied player code is required. This recovers
**tuning**, not original DMC patterns or instruments; other DMC versions fall back
to generic estimation. The optimized CC exporter now preserves a song's custom
frequency table so editor playback and re-export share its tuning. Custom-tuned
exports may not match the existing native SID importer's fixed frequency anchor.

Other players can supply a source tuning candidate through repeated paired
absolute-indexed loads referencing 96-byte low/high halves. Recovery requires an
ascending chromatic table, at least six distinct matching tonal pitches, and exact
matches for at least half the observed gated tonal samples. Multiple qualifying
tables are rejected. This does not identify the player or recover source structure.
WAV selection retains default tuning because recovered tuning can score worse
under approximate sound mapping (as it does for Unsound Minds tune 1).

## Timing and fidelity

CC's extra multispeed ticks evolve sounds; sequence rows advance on the base
50 Hz timeline. Static output uses **CC multiplier 1**; native output compares
multiplier 1 with the source multiplier. Source call times are divided by the
source multiplier for sequence placement in both cases. Events round to the nearest output
row, clamped to the finite capture. When multiple events land on one voice/row,
the later one wins. Minimum row duration is three PAL frames. This loses rapid
pattern articulations; source-rate programs can preserve faster within-note changes.

This is an audible, editable transcription prototype, not faithful reconstruction
of arbitrary timbres. The static mapper omits sound evolution; the dynamic mapper
approximates attack/gate and pulse/filter programmes. Vibrato, later slides,
arpeggio intent, volume automation, and intra-call writes remain incomplete.
Legacy mapping retains sync/ring bits without reconstructing hidden source
oscillators. Preserved coupling also reconstructs observed source activity and
control/pitch trajectories, within tuning and capacity limits; it cannot recover
cycle-exact oscillator phase or intra-call register-write timing.
Noise/drum pitch and legato articulation can be misidentified. A finite capture
loops from its start; original loops and pattern boundaries are not inferred.

Input is limited to single-chip, PAL-compatible PSID v2-v4 with callable init/play
routines. RSID, IRQ-only, NTSC-only, BASIC/PlaySID-specific and multi-SID inputs
are rejected. The existing CPU emulator lacks full-machine timing, ROM and broad
illegal-opcode support. Each utility invocation has a 60-second timeout. Pattern
and orderlist capacity failures ask for a shorter capture or coarser grid.

## Validation

### Unsound Minds refinement (30-second captures)

Both inputs use `--multiplier 2`, PAL/6581. Refined runs use
`--sound-programs dynamic --auto-row-frames --audio-seconds 30 --seconds 30`.
Both select row duration 5 and output multiplier 2; tune 1 keeps default tuning,
while tune 2 selects the corroborated indexed table.

| Tune | Previous improved, 30 s | Refined, 30 s | Previous, first 10 s | Refined, first 10 s |
| --- | ---: | ---: | ---: | ---: |
| 1 | 0.794152 | 0.798245 | 0.778609 | 0.739809 |
| 2 | 0.891521 | 0.930158 | 0.874377 | 0.910282 |

Tune 1 has a small overall ranking gain and an opening regression; its volume
envelope remains too loud. Tune 2 improves on both 0–10 s and 10–30 s. Scores are
heuristics, not fidelity percentages. Selection uses all 30 seconds, so slices
are diagnostics rather than held-out validation. Baselines are retained.
Search/conversion wall times: 48.772 s and 48.166 s; existing binaries were reused.
Artifacts, the JSON comparison, and reproducible `compare_unsound_minds.py` are in
`/private/tmp/cheesecutter-sid-import-samples`. Refined outputs are named
`Unsound_Minds_{1,2}-refined.ct` and `.reconstructed.wav` (30 seconds).

The generic A/B command was also run with the preserved improved and refined CTs.
Background-subtracted, full-mix-aligned voice scores over 30 s:

| Example | Voice 1, previous → refined | Voice 2, previous → refined | Voice 3, previous → refined |
| --- | --- | --- | --- |
| Tune 1 | 0.711440 → 0.699711 | 0.767290 → 0.837765 | 0.826008 → 0.850425 |
| Tune 2 | 0.859414 → 0.941949 | 0.875155 → 0.934373 | 0.827253 → 0.922937 |

Tune 1's voice 1 is the strongest pain point: inferred RMS is 1665 versus source
827, envelope similarity is 0.356, and its worst 5 s window is 15–20 s (0.606).
This points toward gate/envelope/sustain modeling; the measurements alone do not
prove which register behavior causes it. Its independent envelope alignment hits
the -250 ms search boundary, which should not be treated as a reliable true offset.
Tune 2 improves across all three voices; voice 3's opening 0–5 s window remains
the weakest active voice window (0.846). Its voice 1 is silent in the first 10 s,
so those voice windows are correctly inconclusive, not rated as perfect matches.
Reports and raw/background-subtracted WAVs are in the artifacts directory's
`voice-diagnostics-1` and `voice-diagnostics-2` folders. No subtraction clipping
occurred. Original mixed WAV scores were reproduced unchanged.

### Regression checks

```sh
python3 -m unittest tests.test_sid_reconstruct tests.test_sid_audio_compare tests.test_sid_native_reconstruct tests.test_sid_voice_compare -v
python3 -m unittest tests.test_sid_import.SidRoundTrip -v
```

Tests cover independent PAL pitch values, equivalent timebases at different
multipliers, event collisions, malformed input and an independent unknown-player
PSID. That PSID is traced, reconstructed, exported through the CC player, and
traced again to verify the expected C4 oscillator frequency. Audio tests cover exact PCM, shifted audio, pitch changes, truncated recordings,
silence, deterministic libsidplayfp rendering, native recovery similarity, and
end-to-end WAV-based row selection. Native tests also check actual re-exported
SID registers for short gates, pulse sweeps, filter routing/cutoff, and custom
tuning. The existing SID round-trip suite guards ordinary exports. Renderer
integration tests skip if it is not built. These tests do not establish audio equivalence for arbitrary songs.

## Whole-song example: Meanwhile the Planet

This is an evaluation example, not a player-specific conversion path:

```sh
python3 -m sid2ct convert ../shallowsid/hvsc/MUSICIANS/T/TBB/Meanwhile_the_Planet.sid --force -o meanwhile.ct
```

Automatic CIA timing is about 207.990 calls/sec, resampled to CC's physical
PAL 4x cadence (about 200.498 calls/sec). Full-memory recurrence proves an intro
ending at 147.719 s and a first loop ending at 324.958 s. The generated restart
is 147.712 s and its loop end 324.990 s after row quantization. Both mixed WAVs
contain 5,199,330 samples at 16 kHz; verification covers all 65 five-second
windows (the last is partial), including all three SID voices.

On this entire interval, the previous CT scores 0.633482 and the new native 4x
candidate 0.681484. Voice scores are 0.674546 / 0.520997 / 0.694414; voice 2 at
75–80 s remains a major pain point (score 0.068658). These are ranking metrics,
not fidelity percentages. All five conversion candidates exported successfully.
Detailed evaluation artifacts are under `/private/tmp/cheesecutter-sid-import-samples/`
and the CT's sibling `meanwhile.comparison/` directory.

Full-song evaluation artifacts for the current integrity changes are in
`/private/tmp/sid-integrity-after/`. The original Meanwhile baseline is in
`/private/tmp/sid-integrity-before/`. No conversion logic uses evaluation song names.

Audio scoring uses all available CPU cores by default (`--workers N`
on convert/compare, or `SID2CT_WORKERS=N`). FFT blocks preserve window order and
are numerically identical to serial analysis; `--workers 1` disables parallelism.
Full pitch programmes choose the lowest stable tonal pitch as their reference,
so descending/transposed arpeggios share relative trajectories rather than
allocating instruments by absolute pitch. Exact waveform suffixes share native
table storage without changing their playback.

When instrument capacity is exhausted, the full mapper compares ADSR nibble
differences, waveform-control trajectories, pulse duty and filter routing/mode/
cutoff. The attack and compact candidates retain the original fallback so full
model changes are selected only when their whole-song audio score wins. Reports
include observed variant counts, exact waveform sharing and approximated attack
counts; the number of inferred variants is not a recovered source instrument count.
On a 100-second source excerpt, four workers computed identical spectral features
in 0.809 seconds versus 2.702 seconds serial (3.34x); this benchmarks FFT analysis,
not the complete conversion including rendering. Voice renders run concurrently
with isolated SID player processes.

## Integrity evaluation (2026-10-08)

| Song | Tested interval | Mixed ranking score |
| --- | ---: | ---: |
| Meanwhile the Planet | Full detected loop, 324.958 s | 0.681484 baseline → 0.702944 |
| Viidakko | Full detected loop, 306.457 s | 0.568396 baseline → 0.687050 |
| Orivesi | Full detected loop, 235.593 s | 0.636222 |
| Panimo | Explicit 60 s sample | 0.900886 |
| 0 N 0 | Explicit 60 s sample | 0.691681 |

Meanwhile physical voice scores are 0.677178 / 0.564626 / 0.704942.
Approximated attacks fell from 2752 in the earlier full-trajectory mapper to
1291, but 47 native instruments are still exhausted and this is not exact source
instrument recovery. The final four-worker conversion and full voice/window
validation took 249.643 seconds; the original baseline took 410.566 seconds.
These timings include different candidate counts and concurrent evaluations.
Scores rank candidates; they are not fidelity percentages.

Panimo and 0 N 0 have no proven full-state loop within the supported 600-second
search. Their sample scores cannot establish whole-song equivalence or duration.
Evaluation reports/WAVs are linked in `/private/tmp/sid-integrity-evaluation.json`.
The primary full-song output is the worktree's `meanwhile.ct` and
`meanwhile.comparison/report.json`; other full-song/sample artifacts are in
`/private/tmp/sid-integrity-complete/` and `/private/tmp/sid-integrity-parallel/`.

85 converter, native playback, parallel FFT, SID round-trip and GoatTracker
import tests pass. Three separate editor SID menu/shortcut tests fail because
the expected import menu/picker is absent; those UI files were not changed here.
Build times: ct2util 2.05 s; ccdriver 28.39 s.


### Compact pulse refinement (2026-10-08)

The new generic pulse candidate removes redundant terminal holds, resets abrupt
width changes, preserves low pulse bits and avoids the `$FF` preset sentinel.
Exported-register regression: a source jump from 576 to 2048 previously played
831; compact mapping plays 2048 and the subsequent 2080/2112 ticks exactly.
The legacy mapper remains in automatic audio selection.

| Input | Duration / scope | Previous mix | Compact/search mix | Retained mix |
| --- | --- | ---: | ---: | ---: |
| Meanwhile the Planet | 324.958 s, detected full song | 0.702944 | 0.702658 | 0.702944 |
| Viidakko | 306.457 s, detected full song | 0.687050 | 0.686980 | 0.687050 |
| Orivesi | 235.593 s, detected full song | 0.636222 | 0.636222 | 0.636222 |
| Panimo | explicit 60 s sample | 0.900886 | 0.904752 | 0.904752 |
| 0 N 0 | explicit 60 s sample | 0.691681 | 0.691681 | 0.691681 |
| DRAX / Regrets | 51.492 s, detected full song | 0.776459 | 0.794161 | 0.794161 |
| Laxity / Crosswords | 369.300 s, detected full song | 0.803302 | 0.803302 (legacy wins) | 0.803302 |

All renders use the existing SIDLite/PAL, source-header SID model, 16 kHz PCM16
settings and unchanged scoring. Orivesi, 0 N 0 and Crosswords retain byte-identical
CTs. The unrelated-song baselines were regenerated from a pre-edit code snapshot.

Panimo voice scores: 0.937895/0.434420/0.825331 becomes
0.945578/0.434633/0.824513. Its voice 3 window at 40–45 s regresses
0.827941 → 0.814864. Regrets voices: 0.846525/0.712538/0.492796 becomes
0.874353/0.728257/0.491082; voice 3 at 45–50 s regresses
0.229415 → 0.189578. These gains do not establish across-the-board improvement.
Main-song compact diagnostics also include every physical voice and 5 s window;
their slightly lower mix scores keep them out of the retained result.

The main capacity problem remains: Meanwhile still has 539 variants, 47
instruments and 1291 approximated attacks. Viidakko compact has 320 variants
(previously 321), 291 approximated attacks (292), and 61 pulse rows (64),
but still exhausts 47 instruments. The weak second voices, sub-semitone
pitch/modulation, shared-filter evolution and counter-resistant loop detection
remain unresolved. Compact pulse programs retain the existing capture horizon
and at most five table rows.

Artifacts: `/private/tmp/sid-refinement-20261008/evaluation.json` contains scores,
voice/window deltas, durations, paths and limitations. `selected/` holds the
retained CTs; the song directories contain CT/WAV/JSON diagnostics and register
traces. Conversion/search wall times: Meanwhile 101.298 s; Viidakko 85.423 s;
Orivesi 72.505 s; Panimo 26.469 s; 0 N 0 13.252 s; Regrets 12.036 s;
Crosswords 58.528 s. Jobs overlapped, so these are not isolated benchmarks.
Timed ct2util build check: 0.067 s (already up to date).

92 relevant converter, SID round-trip and GoatTracker tests pass, including four
new exported-register tests. Four pre-existing editor checks were excluded after
reproducing failures: the three SID menu/picker/shortcut checks and the GoatTracker
menu/picker check. No editor UI files were changed.


### Sync/ring dependency handling (2026-10-08)

Physical topology and effective ring flags follow the upstream reSID
[SID constructor](https://github.com/libsidplayfp/resid/blob/master/sid.cc) and
[control-register implementation](https://github.com/libsidplayfp/resid/blob/master/wave.cc).
Frequency/control trajectories must not be discarded because a source envelope
has no gate or because its waveform is disabled. Release tails also keep a
coupled destination relevant after its gate falls. Ring is identified only for
triangle-containing waveforms without saw selection; a ring bit on pulse-only
or saw-containing waveforms is not counted as effective ring modulation.

Meanwhile's physical voice 2 depends on voice 1: 53,532 resampled source ticks
use sync/ring, including 26,104 ticks with source gate off and 14,259 with source
waveform off. Viidakko's voice 1 uses voice 3 for sync; its weak voice 2 has no
observed direct sync/ring dependency. Those weaknesses cannot both be attributed
to the same effect.

The preserve candidate retains participating oscillator trajectories through
waveform/gate-off segments and avoids CC's implicit one/two-unit per-voice
frequency offset with an explicit native zero-offset command. Instrument
fallback compares coupled pitch/control contours, and a silent fallback retains
waveform-off sources when their full programs exceed the wave table. Existing
static/legacy candidates remain available to audio selection.

Regression coverage includes every physical source/destination pairing, hidden
source pitch changes after the attack window, TEST transitions, frequency zero,
upstream sync chains, waveform-dependent ring detection, coupled contour
fallback, silent behavior at table exhaustion, renderer muting, and pair/window
reports. The implementation does not claim exact oscillator phase, modulation
frequency ratios, intra-call writes or hardware equivalence.

Artifacts and measured evaluations are under `/private/tmp/sid-coupling-20261008/`.
Early candidates and diagnostic reports remain for comparison; `evaluation.json`
records the final measured candidates and explicitly separates discarded trials.


### Optional staged helpers

Default conversion retains the existing allocation, event extraction and fixed
pattern chunks. Opt in with `--instrument-allocation trajectory` or `budget`,
`--pattern-mining`, `--change-points`, and `--joint-modeling`. Joint modeling
requires `--coupled-programs preserve` and trajectory/budget allocation.

Trajectory allocation selects existing weighted medoids, separates hidden
oscillators from sounding instruments and uses trajectory-aware fallback.
Budget allocation admits complete programs within 47 instruments, 256 wave
rows and 64 pulse/filter records including sentinels. Longer waves pack first
so exact suffix sharing matches the selector's accounting. Mandatory medoids
that exceed capacity reject the experiment; legacy remains available.

Change points currently provide advisory diagnostics without adding ADSR
attacks. Joint modeling weights representatives at time-local dependency
onsets; it does not fit phase. Pattern mining validates exact expansion, keeps
physical voices and individual intro/loop restart indices, and retains fixed
chunks if factoring increases dictionary size or exceeds native limits.

Bounded audio experiments are separate from the existing automatic search:

```sh
python3 -m sid2ct search song.sid -o experiments \
  --sound-programs dynamic --sound-rate source --tuning default \
  --pitch-programs full --modulation-programs compact --coupled-programs preserve
```

Search preserves `before.ct`, each completed helper CT/WAV/report and
`search.json`. It tests at most five named helper experiments, with caller caps
`--candidate-cap` (default 12) and `--search-seconds` (default 600). Time is
checked between operations; one in-flight operation can exceed the ceiling.
Identical CTs reuse candidate mixed renders with matching source/render settings.
Unless diagnostics are skipped or time is exhausted, before and up to three
unique experiments receive mix/physical voice/pair/register/window diagnostics.
The best scored experiment is copied to `selected.ct`; before wins ties. This
is a provisional mix ranking and can regress voices or windows. Every completed
alternative remains for review; combinations wait for regression criteria. `--seconds` means finite sample
validation; omit it for detected loop duration. Tests establish helper and
export invariants, not improved audio quality on arbitrary songs.

### Optional Optuna parameter search

Install the optional dependency in your Python environment:

```sh
python3 -m pip install -r tools/requirements-sid-search.txt
python3 -m sid2ct search song.sid -o experiments-optuna --optimizer optuna
python3 -m sid2ct search song.sid -o experiments-random --optimizer random
```

Both modes try up to 40 settings combinations besides `before.ct`, within the
same default 600-second budget. Use `--candidate-cap`, `--search-seconds` and
`--seed` to compare runs under equal budgets. Optuna uses TPE; random uses
Optuna's random sampler. The first ten TPE trials use random suggestions.
Normal conversion and the default `--optimizer helpers` require no Optuna.

These modes vary row length, sound update rate, available tuning, pitch method,
pulse method, instrument allocation and linked-voice allocation weighting.
Dynamic sounds and preserved oscillator dependencies remain enabled. Source
tuning is tried only when the baseline finds a supported frequency table.
Change-point reporting and exact pattern reuse are excluded from audio tuning.
Recovered native CheeseCutter songs skip parameter trials; `--force-trace`
allows experiments with reconstruction instead.

Captured registers and source audio are reused across trials. Repeated settings
reuse completed results; identical CTs reuse mixed renders. Failed conversions
are saved as failed trials. Each run saves trial history in `trials.sqlite3`,
conversion artifacts, and final settings, durations and decisions in
`search.json`. `--force` starts a new study and replaces named outputs while
retaining older study history; it does not resume the previous study.

The three best unique mixed-audio candidates receive voice, pair and section
checks against the baseline over the entire captured duration, even when
`--audio-seconds` shortens trial scoring. A candidate must improve the full
mix and lose no score on any comparable voice, pair or section. Use
`--regression-tolerance` to explicitly allow a score loss (default zero).
Missing checks, `--skip-diagnostics`, or exhausted time retain `before.ct` as
`selected.ct`. All other completed candidates remain available for review.
Silence with an inconclusive baseline score cannot be ranked.

Omit `--seconds` for detected song duration. Supplying it checks only that
finite capture. Trial scoring is a heuristic and can miss later improvements;
only shortlisted candidates receive full checks. Time is checked between
operations, so a running conversion or comparison can exceed the budget.
No early pruning is used: short-section quality does not reliably predict
the rest of a song. Existing pitch, phase and native-table limits still apply.

## Corpus, bench and semantic_if (tooling)

Use these to measure converter changes. They are not part of conversion.

Preconditions: HVSC checkout (`HVSC_ROOT`, default `../shallowsid/_hvsc-source`), built `ct2util`
and `tools/sid_render`. Optional packages: `uv venv .venv && uv pip install -p .venv/bin/python -r tools/requirements-sid-search.txt`.

- `python3 -m sid2ct corpus build` writes `tools/sid_corpus.toml`: the 7 evaluation songs plus up to 6
  songs for each of Agemixer, PRI, Deetsay, Flex, Shogoon, Dane, Blues Muz, DRAX and Jammer.
  Composers are found by the PSID author field, not by folder. Only single-SID, PAL-compatible PSIDs
  that the converter accepts are used. STIL entries that mention digi/samples are left out
  (`--llm` asks the local model to confirm). Seed 1, 70/30 dev/heldout split per composer.
- `python3 -m sid2ct bench --split dev|heldout|all --label NAME` converts each song in parallel
  (`--workers`, default half the cores; `--seconds 60` or `--full`; `--only GLOB`) into
  `~/.cache/sid2ct/bench/<label>/<song>/` (log in `convert.log`) and records mix/voice scores,
  wall time and git SHA in `~/.cache/sid2ct/bench.sqlite3`. It prints a table and the delta against the
  last run labelled `baseline` (`--compare LABEL`). Each song has a 15 minute limit.
- `tools/semantic_if.py` has `semantic_if(question, text)` (`yes`/`no`/`unknown`) and `semantic_choice`.
  It calls the local ollama model `clef-flash:9b` (`/v1/systemone`), caches answers in
  `~/.cache/sid2ct/llm.sqlite3`, and returns `unknown` if ollama is not running.
