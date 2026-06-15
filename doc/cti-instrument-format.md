# CheeseCutter `.cti` instrument file format

A `.cti` file holds a single CheeseCutter instrument: its envelope, the wave
table, and (optionally) pulse and filter programs. The editor writes one with
**Ctrl+S** in the instrument editor and loads one with Ctrl+L. The in-memory
model these fields map onto lives in `src/ct/base.d` (`Ins` and the wave / pulse
/ filter tables).

## File structure

One line of backtick-delimited (`` ` ``) fields:

```
playerid`name`def`wave1`wave2`pulse`filter
```

| Field      | Contents |
|------------|----------|
| `playerid` | Player version that wrote the file, e.g. `cc4.07`. |
| `name`     | Instrument name (up to 31 chars). |
| `def`      | Instrument definition: 16 hex chars = 8 bytes (see below). |
| `wave1`    | Wave-table column 1 (transpose/tuning), hex byte string. |
| `wave2`    | Wave-table column 2 (waveform/control), hex byte string. |
| `pulse`    | Pulse-modulation program, hex byte string (may be empty). |
| `filter`   | Filter-modulation program, hex byte string (may be empty). |

`wave1` and `wave2` are equal-length and read as paired rows
`(wave1[i], wave2[i])`. Pulse and filter are 4-byte entries (below).

## Definition bytes (`def`)

| Byte | Purpose | Description |
|------|---------|-------------|
| 0 | Attack / Decay | Hi nibble: attack (0–F), lo nibble: decay (0–F). |
| 1 | Sustain / Release | Hi nibble: sustain (0–F), lo nibble: release (0–F). |
| 2 | Restart / arp | `$00` = 3-frame restart, `$40` = soft, `$80` = hard; `$0x` = arp delay. |
| 3 | Hard-restart waveform | Waveform used during hard restart. |
| 4 | Filter pointer | Index into the filter table (`$00`–`$3F`). |
| 5 | Pulse pointer | Index into the pulse table (`$00`–`$3F`). |
| 6 | Hard-restart SR | Sustain/Release used during hard restart. |
| 7 | Wave pointer | Index into the wave table. |

## Wave table

Paired rows `(wave1[i], wave2[i])`, stepped once per frame.

**`wave1` — transpose / tuning**

| Value | Meaning |
|-------|---------|
| `$00`–`$5F` | Relative transpose (0–95 semitones up). |
| `$80`–`$DF` | Absolute frequency (`$80` = note 0). |
| `$7E` | Loop to the previous row. |
| `$7F` | Loop to the row given in `wave2`. |

**`wave2` — waveform / control**

| Value | Meaning |
|-------|---------|
| `$00` | No operation. |
| `$01`–`$0F` | Override the wave delay for this row. |
| `$10`–`$DF` | SID waveform value (written directly to `$D404` + voice). |
| `$E0`–`$EF` | SID waveform `$00`–`$0F`. |
| (when `wave1` = `$7F`) | Loop-target row pointer. |

## Pulse table

4-byte entries:

| Offset | Purpose |
|--------|---------|
| 0 | Duration and direction (`$00`–`$7F` add, `$80`–`$FF` subtract). |
| 1 | Add value per frame. |
| 2 | Initial pulse value (nibbles reversed: `$48` = `$8400`). |
| 3 | Next-entry pointer (`$00`–`$3F`), or `$7F` = stop. |

## Filter table

4-byte entries (same shape as pulse):

| Offset | Purpose |
|--------|---------|
| 0 | Duration (`$00`–`$7F`) or filter type (`$90`–`$F0`). |
| 1 | Add value, or resonance/channel mask. |
| 2 | Initial cutoff value, or `$FF` = skip. |
| 3 | Next-entry pointer (`$00`–`$3F`), or `$7F` = stop. |

## Example

A wave-only bass with no pulse or filter program:

```
cc4.07`Simple Bass`4948000008010C11`114F4F4F11111111117F00`0000000000000000007E00```
```

- `cc4.07` — playerid
- `Simple Bass` — name
- `4948000008010C11` — `def` (A=4 D=9, S=4 R=8, 3-frame restart, …)
- `114F4F4F11111111117F00` — `wave1` column (ends `7F` = loop)
- `0000000000000000007E00` — `wave2` column
- the trailing empty fields — no pulse and no filter program

## Reference

The tables above store values that are written, per frame, to the SID. The maps
below help when reading raw bytes.

### SID voice registers (offset per voice)

| Offset (V1/V2/V3) | Register | Description |
|-------------------|----------|-------------|
| `$00`/`$07`/`$0E` | FREQLO | Frequency, low byte. |
| `$01`/`$08`/`$0F` | FREQHI | Frequency, high byte. |
| `$02`/`$09`/`$10` | PWLO | Pulse width, low byte. |
| `$03`/`$0A`/`$11` | PWHI | Pulse width, high 4 bits. |
| `$04`/`$0B`/`$12` | CONTROL | Waveform + gate. |
| `$05`/`$0C`/`$13` | ATTACK_DECAY | Attack / decay. |
| `$06`/`$0D`/`$14` | SUSTAIN_RELEASE | Sustain / release. |

### Control register (waveform) bits

```
Bit 0: Gate (1 = on)      Bit 4: Triangle
Bit 1: Sync               Bit 5: Sawtooth
Bit 2: Ring modulation    Bit 6: Pulse
Bit 3: Test               Bit 7: Noise
```

Common values: `$11` triangle+gate, `$21` sawtooth+gate, `$41` pulse+gate,
`$81` noise+gate.

### ADSR timing

Attack times (ms): `0:2 1:8 2:16 3:24 4:38 5:56 6:68 7:80 8:100 9:250 A:500
B:800 C:1000 D:3000 E:5000 F:8000`

Decay / release times (ms): `0:6 1:24 2:48 3:72 4:114 5:168 6:204 7:240 8:300
9:750 A:1500 B:2400 C:3000 D:9000 E:15000 F:24000`

### Frame rate

Tables advance one row per video frame: **50.125 Hz** on PAL (985248 Hz clock,
19656 cycles/frame), **60 Hz** on NTSC (1022727 Hz clock, 17046 cycles/frame).
