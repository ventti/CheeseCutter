# 0002 — Live song-image memory layout

**Status:** Accepted

## Context

CheeseCutter edits a SID tune by running the *real* C64 player code against a
full 64K RAM image. `Song.data` / `memspace` (`src/ct/base.d`) **is** that 64K;
songs are saved/loaded as a complete image, and the in-process 6510 emulator
(`src/com/cpu.d`, driven from `src/audio/callback.d`) executes against it. The
layout therefore can't be chosen for editor convenience — it must match what the
player binary and the C64 hardware expect.

## Decision

Treat the song as a verbatim 64K memory image with fixed, hardware-dictated
addresses rather than an abstract model serialized at export time:

- `player.bin` loads at **$0e00** (header at $dfe), ~$0e00–$f83d contiguous.
- Public entry jump table at **$1000** (init=$1000, play=$1003, mplay=$1006) —
  these are hardcoded in `audio/callback.d` and `audio/player.d`.
- Data tables sit at fixed offsets read from the **$0fa0** table into
  `song.offsets[]` (indexed by the `Offsets` enum); many live *under ROM*
  (Inst=$b100, CMD1=$b300, FILTTAB=$b400, PULSTAB=$b500, …).
- Export and remote playback ship the live image starting at `ULTIMATE_IMG_LO`
  = **$0e00** verbatim (`src/ct/build.d`), so addresses match between the editor
  emulation, exported PRGs and real hardware.

## Consequences

- Editor emulation, exported `.prg`/`.sid`, and remote playback all share one
  address space — what you hear in the editor is what plays on a C64.
- Running on real hardware requires ROM banked **out** ($01=$35, IO mapped for
  SID at $d400) and IRQ via the **$fffe** hardware vector (no KERNAL); data under
  ROM is only reachable in that bank configuration. See ADR 0005.
- The layout is effectively frozen: moving an address means touching the player
  binary, the emulator call sites and the export path together.
