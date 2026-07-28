# ADSR Track Visualization Specification

## Overview

The ADSR Track Visualization displays the envelope curve of each SID voice as background brightness in the track editor. This provides visual feedback about the amplitude envelope (Attack-Decay-Sustain-Release) of each voice during playback and editing.

## Activation Condition

- **Show only when**: `vismode == VisMode.Regs` (SID register visualization mode is active)
- This piggybacks on the existing Regs mode which already displays SID register values in the top-right corner

## Data Source

### Input Data
- **Primary source**: `audio.audio.sidreg` array (same data displayed in Regs mode)
- **Size**: 0x19 bytes (25 bytes, covering $D400-$D418)
- **Already available**: This array is populated in `audio_frame()` callback from `song.sidbuf[]`

### SID Register Mapping

For each voice N (where N = 0, 1, 2 for voices 1, 2, 3):

| Register | Offset | Description |
|----------|--------|-------------|
| Control | `sidreg[4 + N*7]` | Bit 0: Gate (1=voice on, 0=release cycle) |
| Attack/Decay | `sidreg[5 + N*7]` | Bits 4-7: Attack, Bits 0-3: Decay |
| Sustain/Release | `sidreg[6 + N*7]` | Bits 4-7: Sustain level, Bits 0-3: Release |

### Extracting ADSR Values

```d
for(int voice = 0; voice < 3; voice++) {
    int baseReg = voice * 7;
    ubyte controlReg = sidreg[baseReg + 0x04];
    ubyte attackDecay = sidreg[baseReg + 0x05];
    ubyte sustainRelease = sidreg[baseReg + 0x06];
    
    bool gateOn = (controlReg & 0x01) != 0;
    ubyte attack = (attackDecay >> 4) & 0x0F;   // 0-15
    ubyte decay = attackDecay & 0x0F;           // 0-15
    ubyte sustain = (sustainRelease >> 4) & 0x0F; // 0-15
    ubyte release = sustainRelease & 0x0F;      // 0-15
}
```

## ADSR Timing Constants

From `doc/sid_registers.txt` and SID chip specification:

### Attack Times (ms)
| Value | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|-------|---|---|---|---|---|---|---|---|---|---|----|----|----|----|----|-----|
| Time  | 2 | 8 | 16 | 24 | 38 | 56 | 68 | 80 | 100 | 250 | 500 | 800 | 1000 | 3000 | 5000 | 8000 |

### Decay/Release Times (ms)
| Value | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|-------|---|---|---|---|---|---|---|---|---|---|----|----|----|----|----|-----|
| Time  | 6 | 24 | 48 | 72 | 114 | 168 | 204 | 240 | 300 | 750 | 1500 | 2400 | 3000 | 9000 | 15000 | 24000 |

### Sustain Level
- Range: 0-15 (corresponds to volume levels 0-15)
- This is the target level during the Sustain phase
- Value 15 = full amplitude, 0 = silent

## Timing Calculation

### Frame Rate
- **PAL**: 50.125 Hz (used by CheeseCutter)
- **NTSC**: 60 Hz (alternative, less common in this editor)
- **Frame duration**: ~19.95 ms per frame (PAL)

### Editor Speed Parameter
- **Location**: `song.playSpeed` (from `song.memspace[offsets[Offsets.PlaySpeed]]`)
- **Interpretation**: Frames per row = `playSpeed + 1`
  - If playSpeed = 5, then 6 frames per row
  - If playSpeed = 2, then 3 frames per row
- **Row duration**: `(playSpeed + 1) * (1000 / 50.125)` ms
  - Example: playSpeed=5 → 6 frames → ~119.7 ms per row

### Converting ADSR Times to Frames

```d
float msPerFrame = 1000.0 / 50.125;  // ~19.95 ms for PAL

int attackFrames = cast(int)(ATTACK_TIME_MS[attack] / msPerFrame);
int decayFrames = cast(int)(DECAY_RELEASE_TIME_MS[decay] / msPerFrame);
int releaseFrames = cast(int)(DECAY_RELEASE_TIME_MS[release] / msPerFrame);

// Convert to rows
int framesPerRow = song.playSpeed + 1;
float attackRows = attackFrames / cast(float)framesPerRow;
float decayRows = decayFrames / cast(float)framesPerRow;
float releaseRows = releaseFrames / cast(float)framesPerRow;
```

## Envelope State Machine

Each voice maintains an envelope state:

### States
1. **Silent**: Gate off, envelope at zero
2. **Attack**: Gate on, envelope rising from 0 to 1.0
3. **Decay**: Gate on, envelope falling from 1.0 to sustain level
4. **Sustain**: Gate on, envelope holding at sustain level
5. **Release**: Gate off, envelope falling from current level to 0

### State Transitions

```
             Gate On
Silent ───────────────> Attack
                           │
                           │ (reaches peak)
                           ▼
                         Decay
                           │
                           │ (reaches sustain level)
                           ▼
Gate Off              Sustain
   │                      │
   │                      │ Gate Off
   │                      ▼
   └─────────────────> Release
                           │
                           │ (reaches zero)
                           ▼
                        Silent
```

### Envelope Calculation Per Frame

For each audio frame (called from `audio_frame()` callback):

1. **Read current SID registers** for each voice
2. **Detect gate transitions** (compare with previous frame)
3. **Update envelope value** based on current state:
   - **Attack**: `envelope += (1.0 / attackFrames)`
   - **Decay**: `envelope -= ((1.0 - sustainLevel) / decayFrames)`
   - **Sustain**: `envelope = sustainLevel` (hold constant)
   - **Release**: `envelope -= (envelope / releaseFrames)`

4. **Clamp envelope**: `envelope = clamp(envelope, 0.0, 1.0)`

## Row Brightness Calculation

### Challenge
A single row spans multiple frames (determined by `playSpeed`). During this time, the envelope curve changes. We need to decide on a representative value for the entire row.

### Options (To Be Decided)

1. **Peak**: Maximum envelope value during the row
   - **Pros**: Shows the loudest moment, more visually striking
   - **Cons**: May exaggerate short transients

2. **Average**: Mean envelope value across all frames in the row
   - **Pros**: Smooth representation, reflects total energy
   - **Cons**: May obscure short loud peaks

3. **Median**: Middle value of envelope samples during the row
   - **Pros**: Robust to outliers
   - **Cons**: Computationally more complex

4. **End-of-row**: Envelope value at the last frame of the row
   - **Pros**: Simple, matches sequencer timing
   - **Cons**: May miss transients entirely

### Recommendation
**Start with Peak**, as it ensures visible feedback for all envelope activity. Can be adjusted later based on user experience.

### Implementation Strategy

```d
struct RowEnvelopeData {
    float peakEnvelope = 0.0f;
    int frameCount = 0;
}

// In audio callback, for each frame:
void updateRowEnvelope(int voice, int currentRow, float envelope) {
    auto data = &rowEnvelopeData[voice][currentRow];
    data.peakEnvelope = max(data.peakEnvelope, envelope);
    data.frameCount++;
}

// When row completes or when rendering:
float getRowBrightness(int voice, int row) {
    return rowEnvelopeData[voice][row].peakEnvelope;
}
```

## Visual Rendering

### Color Palette Mapping

- **Brightness range**: 0.0 to 1.0 (float)
- **Palette indices**: 16 to 31 (16-step gradient)
- **Mapping**: 
  ```d
  int step = cast(int)(brightness * 15.0f);
  step = clamp(step, 0, 15);
  int bgColor = 16 + (15 - step); // Invert: high brightness = low index
  ```
  - brightness=1.0 → step=15 → bgColor=16 (brightest)
  - brightness=0.5 → step=7 → bgColor=24 (medium)
  - brightness=0.0 → step=0 → bgColor=31 (darkest/black)

### Where to Apply

- **Location**: Track editor rows
- **Apply to**: Background color of all cells in the track column for that voice
- **Width**: Full voice column width (from `voices[i].area.x` to `voices[i].area.x + voices[i].area.width`)
- **Preserve**: Foreground colors (text) should remain unchanged

### Rendering Integration

Currently, visualization rendering happens in two places:
1. `seq.seqtable.SeqTable.renderVisualization()` - for sequence view
2. Similar method would be needed for other views

The rendering is called from `ui.ui.timerEvent()` AFTER `update()` to ensure colors aren't overwritten:

```d
// NOW apply visualization colors as the FINAL step
// This must happen AFTER update() to prevent colors from being overwritten
if(toplevel.followplay && toplevel.fplay) {
    toplevel.fplay.renderVisualization();
} else if(toplevel.sequencer) {
    toplevel.sequencer.renderVisualization();
}
```

## Implementation Architecture

### Module Structure

Current implementation in `src/audio/visualizer.d`:
- ✓ Already tracks envelope states per voice
- ✓ Already calculates brightness (0.0-1.0) per frame
- ✓ Has `updateSidRegisters()` called from audio callback
- ✓ Has `updateVisualizerFrame()` called each full frame
- ✓ Has persistent brightness storage per row

### Required Extensions

1. **Condition on VisMode.Regs**
   - In `renderVisualization()`, check if `ui.vismode == VisMode.Regs`
   - Only apply ADSR colors when this mode is active

2. **Row-to-Brightness Mapping**
   - Already implemented via `persistentBrightness` dictionary
   - Currently stores max brightness per `rowCounter`
   - This matches the "peak" strategy

3. **Per-Frame Accumulation**
   - ✓ Already done: `updatePersistentBrightness()` called from sequencer
   - Stores maximum brightness seen at each row position

4. **Color Application**
   - ✓ Already implemented in `seq.seqtable.renderVisualization()`
   - Maps brightness to palette 16-31
   - Applies to track columns

## Testing Checklist

### Verification Points

1. **Mode Activation**
   - [ ] ADSR visualization only appears when Regs mode is active
   - [ ] Visualization disappears when switching to other modes

2. **Timing Accuracy**
   - [ ] Fast attacks (value 0-4) show immediate brightness
   - [ ] Slow attacks (value 10-15) show gradual rise over multiple rows
   - [ ] Sustain level correctly reflects ADSR sustain parameter
   - [ ] Release fades appropriately when gate turns off

3. **Visual Quality**
   - [ ] Brightness gradient smooth (no sudden jumps)
   - [ ] Colors map correctly to palette 16-31
   - [ ] Foreground text remains readable
   - [ ] No color artifacts or flickering

4. **Performance**
   - [ ] No slowdown during playback
   - [ ] Responsive UI during visualization

5. **Edge Cases**
   - [ ] Very fast ADSR (all values 0-2)
   - [ ] Very slow ADSR (all values 12-15)
   - [ ] Gate off immediately after gate on
   - [ ] Multiple retriggering (staccato notes)
   - [ ] playSpeed changes mid-song

## Future Enhancements

### Possible Improvements

1. **Alternative Statistics**
   - Add option to switch between peak/average/median
   - UI toggle in settings or with keyboard shortcut

2. **Waveform Indication**
   - Different color hues for different waveforms (triangle/saw/pulse/noise)
   - Use separate gradient ranges

3. **Filter Visualization**
   - Overlay filter cutoff/resonance as secondary color component
   - Use palette ranges 32-47 for filter state

4. **Ring Mod / Sync Indicators**
   - Visual markers when special modes are active
   - Border color or text attribute changes

5. **Volume Register**
   - Factor in $D418 volume (bits 0-3) as multiplier
   - Would show global volume changes

## References

- `doc/sid_registers.txt` - SID register documentation
- `src/audio/visualizer.d` - Current envelope simulation implementation
- `src/ui/ui.d:864-880` - Regs mode display code
- `src/seq/seqtable.d:298-365` - Visualization rendering code
- `src/ct/base.d:1276-1289` - Song speed properties

---

**Document Version**: 1.0  
**Date**: 2025-10-26  
**Status**: Specification Complete, Ready for Implementation

