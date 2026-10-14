# sid2ct: SID to CheeseCutter converter

`sid2ct` turns a SID file into an editable CheeseCutter song (`.ct`). It runs
the SID player in an emulator, records the SID registers, fits sounds and
patterns to them, and scores the result against the original audio.

- Input: single-chip, PAL-compatible PSID v2-v4 files with callable init and play routines.
- Output: an approximation that you can edit. It is not an exact copy.
- Run commands from the repository root with `python3 -m sid2ct`.
- Design decisions: `doc/adr/0016` to `doc/adr/0018`.

Conversion never branches on song names, paths, hashes, tune-specific addresses
or hand-picked instruments. Recognising a format (native CheeseCutter songs,
known editor players) is allowed. Inference falls back to the generic path when
recognition fails.

## Setup

Needs Python 3.10+. Audio needs libsidplayfp 3.x (the SIDLite builder).

```sh
make -f Makefile.mac ct2util
python3 tools/build_sid_renderer.py
```

- The renderer build uses `pkg-config --cflags --libs libsidplayfp`.
- For a library in a local prefix: `python3 tools/build_sid_renderer.py --prefix /path/to/prefix`. This links its static library.
- `--cxx CXX` picks the C++ compiler for the renderer.
- Optional: `python3 -m pip install -r tools/requirements-sid-search.txt` (numpy, Optuna, OR-Tools). scikit-learn enables surrogate pruning.
- Without a package, its feature is skipped. Plain `python3` still converts. Without numpy only effect mode `off` and allocation `legacy` exist.
- `--skip-audio` needs no libsidplayfp (trace-only). The helpers are `ct2util` and `tools/sid_render`. Use `--tool` and `--renderer` for other paths.

## Quick start

```sh
python3 -m sid2ct convert song.sid -o song.ct
python3 -m sid2ct convert song.sid -o song.ct --seconds 30
python3 -m sid2ct compare song.sid -o comparison
python3 -m sid2ct compare song.sid song.ct -o comparison-existing --sid 8580
python3 -m sid2ct score original.wav reconstructed.wav
python3 -m sid2ct search song.sid -o experiments
```

- `convert` writes `song.ct`, a `song.json` report and a `song.comparison/` folder. Nothing is overwritten without `--force`, and outputs are written only at the end.
- `compare` refuses an existing folder, so baselines are kept.

## How the converter works

### Capture and loop detection

- The CPU tracer runs init, then one play call per interrupt. It records the SID registers after each call.
- Loop detection hashes all 64 KiB of emulated memory after each play call. This includes the stack, zero page and self-modified code.
- A repeated state proves recurrence in this deterministic trace. A repeated melody alone does not.
- If no loop is found within `--max-seconds` (default 600), automatic duration fails. It does not truncate silently. Use `--seconds` for a fixed capture.
- Loop detection is conservative. Unused counters can delay detection past the audible loop.
- It does not prove that SID oscillator, envelope or filter state repeats, or that hardware sounds the same.

### Timing

- CIA-timed PSIDs: the converter uses the CIA latch after every play call, so variable tempo is handled before resampling.
- VBI-timed PSIDs: CIA latch writes are ignored. PAL VBI is assumed.
- Each play call is assumed to be one interrupt interval. Timers changed inside a call, and IRQ-driven players, are not modelled.
- `--multiplier N` sets the source rate to 50 x N calls per second (N = 1..16).
- Non-integer CIA rates are resampled to the nearest CheeseCutter multiplier at the PAL cadence (about 50.125 Hz). This avoids drift and may lose changes shorter than one sound tick.
- Events are rounded to the row grid. Minimum row length is three PAL frames.

### Player recognition

- Recognised CheeseCutter players: native structure is recovered, including all subtunes. Recognition uses code anchors (see `doc/adr/0012`).
- Editor players (GoatTracker, DMC, JCH NewPlayer): their song data is read as structure hints only. The register trace stays the source of truth (see `doc/adr/0018`).
- DMC: the tuning table is recovered from paired frequency loads. Other DMC versions fall back to generic estimation.
- Other players: traced and fitted generically.

### Sound estimation

- Gate rises mark attacks. Gate falls mark releases. Pitch changes that last three PAL frames count as new notes.
- Pitch uses PAL oscillator tuning, with a 35-cent tolerance for held-note changes.
- Static instruments group waveform and control bits, ADSR and pulse width. Pitch is not part of the key, so transposed notes share an instrument.
- Pulse width is rounded to 16 SID units.
- CheeseCutter allows 47 instruments. Later timbres reuse the nearest estimate and are counted in the report.
- Dynamic sound programs fit pulse and filter sweeps as piecewise-linear ramps. Cutoff byte $FF is written as $FE, because $FF means "keep current" in the player.
- Effects (`--effect-programs on`) map slides, vibrato, detune and arpeggios to command rows. Portamento is not mapped.
- Sync and ring are kept as coupled voices. Source oscillators are preserved when they affect another voice.

## Pipeline

Each stage is timed in `effort.stage_seconds` in the report.

1. **capture**: trace and loop detection. Reused from memory when the same song was seen before.
2. **candidates**: the static bridge, plus the base settings crossed with effects and allocation. Also one compact-programme candidate at the base sound rate with greedy allocation (the search does not always reach it). Built and scored in parallel. The first dynamic candidate always finishes, so an output exists. An effects-on candidate builds two filter variants (per instrument or global). Both are rendered and the better v2 wins (`effects.filter_selection` says `audio`).
3. **search**: an Optuna study (TPE, seeded with `--seed`) over row grid, sound rate, tuning, pitch, modulation, coupled programs, effect tolerance and solver weights. Trials run in batches of 8. Each trial is first scored by `regdist` through the CT player, with no audio. A surrogate model may skip the audio render of a trial. Without a trusted model, a trial whose distance is 50% above the best candidate is pruned.
4. **selection**: the best v2 among candidates whose v1 is within `--v1-tolerance` (0.01) of the best v1 any candidate reached. Ties go to the earlier candidate.
5. **polish**: local single-entry edits to the chosen CT (see below).
6. **diagnostics**: voice and window comparison of the chosen CT. If the budget ends first, they are skipped and a warning is written.

### Surrogate pruning

- A gradient boosting model predicts v2 and v1 from `regdist` and option values, before audio. It is trained on the memory database (`surrogate.pkl`).
- A trial is pruned when its predicted v2 plus a margin is below the best, or its predicted v1 is clearly below the guard.
- Used only when cross-validated R2 for v2 is at least 0.10 and there are 150 trials from 5 songs. The report (`effort.pruning`) shows the fit.

### Polish

- Single-entry edits: ADSR nibbles, pulse and filter rows, slide, vibrato, offset, wave transposition, waveform bits and delay.
- Edits that leave the register trace unchanged are skipped. Edits whose `regdist` is over 2% worse are dropped. The rest are rendered and scored in batches of 8.
- The largest strict v2 gain within the v1 tolerance is accepted. Default: 2 passes of 160 edits. `--high-effort`: 6 passes of 2000.

### Instrument allocation

- `legacy`: most-used sounds first (the greedy budget).
- `trajectory`: groups similar sound changes and uses trajectory-aware fallback.
- `budget`: fits complete programs within 47 instruments, 256 wave rows and 64 pulse and filter rows.
- `solve`: an OR-Tools CP-SAT model (`sid2ct/solve.py`). It picks at most 47 instruments and assigns each sound to one of them. It minimises audible register distortion within the table limits. It falls back to `budget` if it finds no solution.
- The solver uses 2 threads per candidate and stops on deterministic time, so the output does not depend on `--workers`.
- Default `auto` builds `legacy` and `solve` and keeps the one with the better audio score.
- Solver limits: 47 instruments, 254 wave rows (with exact suffix sharing), and 63 pulse and filter rows each.
- The loudness and envelope weights are tuned guesses. The cost is register distance, so it can prefer a loud wrong sound over a quiet right one.

## Effort, time, workers and memory

- `--effort default` is about 10 minutes for a full detected loop (300 s or longer). Shorter captures get a proportional share, at least half.
- `--high-effort` (or `--effort high`) is about 60 minutes.
- `--time-budget SECONDS` sets the total time. It overrides the effort level.
- `--max-trials N` caps the search. `0` skips it.
- One budget covers all stages and is checked inside the inner loops. When it ends, the best finished candidate is written.
- `--solve-time-limit` is per solve (20 s; 60 s with high effort), never more than 15% of the remaining budget.
- `--workers N` (default: all cores) sets the cores for one conversion. Up to `min(8, N // 2)` candidates run at once. Output does not depend on `N`, except when the time budget stops a run early.
- `bench` runs `--workers` conversions in parallel. Each gets `cores // workers` workers.
- `search` takes `--effort` and `--high-effort` for its default `--search-seconds` (600 s or 3600 s). Its trials run one at a time.
- Memory: `~/.cache/sid2ct/memory.sqlite3`, or `$SID2CT_CACHE/memory.sqlite3`.
  - Per song: the trace (reused on the next run) and the best parameters.
  - Per player family: the best parameters of past songs are tried first (own best, then the top 3 by v2).
  - Every trial is recorded with its `regdist` values.
- `--no-memory` reads and writes nothing. A fixed seed then gives the same result with or without the database.
- Renders are cached in `~/.cache/sid2ct/renders/`. The cache key includes the SID content, renderer binary, playback settings and voice mask. Delete the folder to clear it.

## Audio validation

### Scores

- `score_v2` (default): log-mel spectra at three window sizes, envelope and onset agreement, pitch-class agreement. `score_v1`: the older envelope and spectral score.
- Both use the same alignment (up to 250 ms, 10 ms grid). Scores rank candidates. They are not fidelity percentages.
- `exact_match`: equal length, sample-identical, non-silent PCM. Silent or very short recordings are `inconclusive`.

### Mixed WAV

- Source and re-exported SID are rendered in fresh processes: SIDLite, forced PAL, same SID model, 16 kHz mono PCM16, no normalisation.
- Outputs: `song.source.wav` and `song.reconstructed.wav`. `--sid` sets the model for both (default: the source header, else 6581).

### Voice and window diagnostics

- Each physical SID voice and each 5 s window (`--window-seconds`) is compared over the full duration.
- Voices are matched by physical channel number. Solo renders are not additive stems (filter interactions remain), so an all-muted render is subtracted.
- Sync and ring sections add voice-pair renders (`coupled_pairs`). Silent or very short windows are inconclusive.
- `compare --candidate LABEL=FILE` compares several versions without reconverting. The output folder holds CT and SID exports, mixed and solo WAVs, and `report.json`.

## Options

Every flag below is listed in the help of its command. `convert` and `search` take the same flags unless noted. Defaults are in brackets.

### Input, output and source

- `sid`: source SID file (positional).
- `-o`, `--output`: convert writes a `.ct` file. Search and compare write a folder.
- `--force`: replace existing outputs. Search replaces files in its folder. Compare never replaces (it refuses an existing folder).
- `--subtune N`: song number in the SID file [1].
- `--seconds N`: seconds to convert or compare [first player-state loop, or the search limit].
- `--max-seconds N`: longest search for a repeating state [600].
- `--multiplier N`: source update rate = 50 x N, 1 to 16 [detected].
- `--trace FILE`: read a `ct2util sidtrace` file (25 hex register bytes per call). Needs `--seconds`, because it has no loop evidence.
- `--force-trace`: rebuild from observed sounds, even when a native CheeseCutter song can be recovered.
- `--tool PATH`: the `ct2util` program.
- `--renderer PATH`: the SID audio renderer.
- `--sid {6581,8580}`, `--sid-model {6581,8580}`: SID chip model for both recordings [from the source header].

### Rows and timing

- `--row-frames N`: pattern row length in PAL frames, 3 to 127 [search: 6 first, then 3, 4, 5, 8 and 12. Compare: 6].
- `--auto-row-frames`: try rows of 3, 4, 5, 6, 8 and 12 frames plus the given length, and keep the best audio. Not supported by `search`.
- `--sound-rate {auto,base,source}`: `base` updates sounds at 50 Hz. `source` keeps the original rate. `auto` tries both (`convert`). `search` defaults to `source`.

### Audio and validation

- `--skip-audio` (convert only): no rendering or WAVs. Not compatible with an automatic grid search.
- `--audio-seconds N`: seconds of converted audio to compare [all].
- `--window-seconds N`: length of each comparison section [5].
- `--skip-diagnostics`: compare only the mix. Skips voices and sections.
- `--score {v1,v2}`: score for choosing candidates [v2].
- `--v1-tolerance X`: allowed v1 loss from the best v1 of any candidate [0.01].
- `--workers N`: CPU cores [all]. For compare, the cores used for audio analysis.
- `--selection-seconds N` (compare only): seconds of audio used to choose a conversion [whole comparison].
- `--candidate LABEL=FILE` (compare only): version to compare. Repeat for several versions.
- `--candidate-subtune N` (compare only): song number in the converted files [1].

### Effort, search and memory

- `--effort {default,high}`, `--high-effort`: time budget [default about 10 min; high about 60 min].
- `--time-budget SECONDS`: total wall time. Overrides `--effort`.
- `--seed N`: random seed of the parameter search [0].
- `--max-trials N`: most candidates after the first stage [as many as the budget allows; 0 skips the search].
- `--no-polish`: skip the local polish.
- `--no-memory`: read and write nothing in the memory database. No warm start.
- `--solve-time-limit SECONDS`: solver time per allocation [20; 60 with high effort].

### Sound programmes

- `--sound-programs {auto,static,dynamic}`: fixed sounds, dynamic sounds, or both [auto]. `search` requires `dynamic`.
- `--tuning {auto,default,source}`: CheeseCutter tuning, recovered source tuning, or both [auto]. `search` uses `default` or `source`.
- `--pitch-programs {auto,attack,compact,full}`: keep early pitch changes only (`attack`), remove redundant holds (`compact`), or keep later changes too (`full`) [auto; `full` without audio]. `search` uses `full`.
- `--modulation-programs {auto,legacy,compact}`: pulse-width mapper [auto; compact without audio].
- `--coupled-programs {auto,legacy,preserve}`: `preserve` keeps oscillator changes that affect another voice through sync or ring [auto]. `search` requires `preserve`.
- `--effect-programs {auto,off,on}`: map effects to command rows [auto]. `on` needs numpy. `search` default is `off`.
- `--instrument-allocation {auto,legacy,trajectory,budget,solve}`: see [Instrument allocation](#instrument-allocation) [auto]. `search` leaves this to its own trials.
- `--structure-hints {auto,off}`: read GoatTracker, DMC or JCH song data for the solver [auto]. `auto` adds a slower memory trace.
- `--layout {compact,chunks}`: `compact` reuses repeated and transposed blocks, and falls back to `chunks` if it cannot be verified. `chunks` uses fixed 64-row blocks [compact].
- `--change-points`: report where pitch, gate or control values change. Playback does not change [off].
- `--pattern-mining`: reuse repeated pattern rows, keeping every row and the loop position [off].
- `--joint-modeling`: give extra priority to instruments in voices that affect each other. Needs `--coupled-programs preserve` and a non-legacy allocation [off].

### Search only

- `--candidate-cap N`: most new versions besides `before` [12 for `helpers`, 40 for `optuna` and `random`].
- `--search-seconds S`: time limit [600; 3600 with `--high-effort`].
- `--optimizer {helpers,optuna,random}`: `helpers` runs five fixed experiments. `optuna` learns promising settings. `random` samples the same space [helpers].
- `--regression-tolerance X`: allowed score loss in each voice, pair or section [0].

### Bench

`python3 -m sid2ct bench`:

- `--split {dev,heldout,all}`: corpus split [dev].
- `--workers N`: songs in parallel [half the cores].
- `--effort {default,high}`, `--no-memory`: passed to each conversion.
- `--seconds N`: explicit capture length [60]. `--full`: convert the detected loop instead.
- `--label NAME`: name of this run. `--compare LABEL`: earlier run to compare with [baseline].
- `--only GLOB`: only songs whose name or path matches, for example `"*Viidakko*"`.
- `--hvsc PATH`: HVSC root [`$HVSC_ROOT` or `../shallowsid/_hvsc-source`].
- `--corpus PATH`: corpus manifest [`tools/sid_corpus.toml`].
- `--timeout S`: limit per song [900; raise it with `--effort high`].
- `--effect-programs`, `--instrument-allocation`, `--structure-hints`, `--solve-time-limit`: passed to each conversion.

### Score, corpus, players and tools

- `score --max-lag-ms N`: largest timing shift to try [250].
- `score --alignment-ms N`: shift the converted audio by N ms before comparing.
- `corpus build --hvsc PATH`, `-o`/`--output PATH` [`tools/sid_corpus.toml`], `--per-composer N` [6], `--llm`.
- `players census --split {all,dev,heldout}`, `--llm`.
- `build_sid_renderer.py --prefix PATH`, `--cxx CXX`.
- `ct2util sidtrace --mem-reads FILE`: also writes per-call data reads and SID writes. `sid2ct/memtrace.py` reads them to find streams, row timing and sequence starts.

## Known limits

- Input must be single-chip, PAL-compatible PSID v2 to v4 with callable init and play. RSID, IRQ-only, NTSC-only, BASIC or PlaySID-specific, and multi-SID inputs are rejected.
- The CPU emulator has no full-machine timing, no ROM and partial illegal-opcode support. Each utility call has a 60 s timeout.
- Sound is approximated. Vibrato, later slides, arpeggio intent, volume automation and writes inside a play call are incomplete.
- Oscillator phase, sub-semitone ratios and intra-call writes are not reproduced. Noise and drum pitch, and legato, can be misidentified.
- A finite capture loops from its start. Original loops and pattern boundaries are not inferred.
- Pattern and orderlist limits can fail. The error asks for a shorter capture or a coarser grid.
- Instruments run out (47 limit). Extra sounds become approximations.
- Panimo and 0 N 0 have no full-state loop within the 600 s search. Their sample scores do not prove the duration or full-song equivalence.
- Sync and ring coupling is approximated. Shared filter evolution and muting interactions limit attribution.
- Scores do not prove equivalence on other SID engines or on real hardware.

## Last bench means

`python3 -m sid2ct bench`, 60 s captures, default effort, `--no-memory` on heldout, 2026-10-15.
Means over songs that also have a row in the first recorded run (label `baseline`). Ranking scores only.

| Split | Songs | v1 baseline | v1 now | v2 baseline | v2 now | Mean wall |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dev | 34 | 0.7523 | 0.8085 | 0.5816 | 0.6465 | 286 s |
| heldout | 18 | 0.7754 | 0.8251 | 0.5968 | 0.6567 | 278 s |

Run `bench` again for new numbers; it prints the change against the last baseline.

## Corpus, bench and local model helpers

These measure the converter. Conversion does not use them.

- Needs an HVSC checkout (`HVSC_ROOT`, default `../shallowsid/_hvsc-source`), built `ct2util` and `tools/sid_render`.
- `python3 -m sid2ct corpus build` writes `tools/sid_corpus.toml`. It has the 7 evaluation songs plus up to 6 songs for each of nine composers. Composers are found by the PSID author field. Only single-SID, PAL-compatible PSIDs are used. STIL entries that mention digi or samples are left out. Seed 1, 70/30 dev and heldout split per composer.
- `python3 -m sid2ct bench` writes results to `~/.cache/sid2ct/bench/<label>/` and `~/.cache/sid2ct/bench.sqlite3`. It records scores, wall time and the git SHA. It prints the change against the last run labelled `baseline`. Each song has a 15 minute limit.
- `tools/semantic_if.py` asks the local ollama model `clef-flash:9b` yes or no questions (cached in `~/.cache/sid2ct/llm.sqlite3`). It returns `unknown` if ollama is not running. The `--llm` flags use it.

## Tests

```sh
python3 -m unittest tests.test_sid_reconstruct tests.test_sid_audio_compare tests.test_sid_native_reconstruct tests.test_sid_voice_compare -v
python3 -m unittest tests.test_sid_import.SidRoundTrip -v
```

- Cover timing, malformed input, audio scoring, native recovery and exported registers. Renderer tests skip when the renderer is not built.
- They do not prove audio equivalence for arbitrary songs.

Package map: `sid2ct.convert` (conversion), `sid2ct.native` (CheeseCutter programs), `sid2ct.flow` (stages), `sid2ct.portfolio` (parallel candidates), `sid2ct.regdist` (register distance), `sid2ct.solve` (CP-SAT), `sid2ct.polish`, `sid2ct.surrogate`, `sid2ct.audio` (WAV scores), `sid2ct.loops` (recurrence and timing), `sid2ct.compare` (A/B diagnostics), `sid2ct.players` (player recognition and hints). The C++ renderer and its build helper stay in `tools/`.
