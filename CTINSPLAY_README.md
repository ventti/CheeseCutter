# CheeseCutter Instrument Player (ctinsplay)

A standalone command-line tool to play and render CheeseCutter `.cti` instrument files using the ReSID SID emulation engine.

## Overview

This tool allows you to:
- Play CheeseCutter instrument patches from the command line
- Test instrument sounds at different notes/pitches
- Render instruments to ProTracker-compatible 8SVX sample files
- Experiment with different SID models (6581/8580) and clock modes (PAL/NTSC)

## Building

### Prerequisites

- C++ compiler with C++11 support (g++ or clang++)
- SDL2 development libraries
- Existing CheeseCutter source tree (uses ReSID from the main project)

On macOS (using Homebrew):
```bash
brew install sdl2
```

On Ubuntu/Debian:
```bash
sudo apt-get install libsdl2-dev
```

### Compile

```bash
make -f Makefile.ctinsplay
```

This will create the `ctinsplay` executable.

## Usage

### Basic Playback

Play an instrument file at default settings (C-3, 2 seconds):
```bash
./ctinsplay myinstrument.cti
```

### Specify Note and Duration

```bash
./ctinsplay bass.cti -n 24 -d 3000
```

This plays the bass instrument at note 24 (C-2) for 3 seconds.

### Render to ProTracker Sample

```bash
./ctinsplay lead.cti -n 48 -o lead_sample.8svx -r 16574
```

This renders the lead instrument at note 48 (C-4) to an 8SVX file at 16574 Hz (standard Amiga sample rate).

### Command-Line Options

```
  -n, --note <value>       Note value (0-95, default: 36 = C-3)
                           0 = C-1, 12 = C-2, 24 = C-3, 36 = C-4, etc.
  
  -d, --duration <ms>      Duration in milliseconds (default: 2000)
  
  -r, --samplerate <hz>    Sample rate (default: 48000)
                           Common rates: 16574 (Amiga), 22050, 44100, 48000
  
  -o, --output <file>      Output to ProTracker sample file (.8svx)
                           If not specified, plays through speakers
  
  -m, --model <6581|8580>  SID model (default: 6581)
                           6581: Original MOS 6581 (C64)
                           8580: Newer MOS 8580 (C64C)
  
  -c, --clock <pal|ntsc>   Clock mode (default: pal)
                           pal:  985248 Hz (50.125 FPS)
                           ntsc: 1022727 Hz (60 FPS)
  
  -h, --help               Show help message
```

## Note Values

The tool uses a numeric note system where:

- 0-11: Octave 1 (C-1 to B-1)
- 12-23: Octave 2 (C-2 to B-2)
- 24-35: Octave 3 (C-3 to B-3)
- 36-47: Octave 4 (C-4 to B-4)
- 48-59: Octave 5 (C-5 to B-5)
- etc. up to 95

Each octave spans 12 semitones following standard chromatic scale.

## CheeseCutter Instrument Format (.cti)

The `.cti` format is a CSV-like format using backtick (`) as delimiter:

```
playerid`name`def`wave1`wave2`pulse`filter
```

Where:
- **playerid**: Player version (e.g., "cc4.07")
- **name**: Instrument name string
- **def**: 8 bytes of instrument definition in hex
  - Byte 0: Attack/Decay (ADSR)
  - Byte 1: Sustain/Release (ADSR)
  - Byte 2: Restart type / arpeggio speed
  - Byte 3: Hard restart waveform
  - Byte 4: Filter table pointer
  - Byte 5: Pulse table pointer
  - Byte 6: Hard restart SR envelope
  - Byte 7: Wave table pointer
- **wave1**: Wave table data (hex string)
- **wave2**: Wave table data 2 (hex string)
- **pulse**: Pulse table data (hex string, optional)
- **filter**: Filter table data (hex string, optional)

## Implementation Details

### SID Emulation

The tool uses the ReSID engine (same as CheeseCutter) to emulate the Commodore 64 SID chip. It supports:

- Accurate frequency generation using PAL/NTSC frequency tables
- ADSR envelope simulation
- Wave table interpretation (waveform changes, transpose, loops)
- Pulse width modulation
- Both 6581 and 8580 filter models

### Wave Table Interpretation

The wave table player implements:
- Waveform changes (triangle, sawtooth, pulse, noise)
- Transpose values (relative and absolute)
- Wave delay timing
- Loop commands (0x7E = loop to previous, 0x7F = loop to specified position)

### Pulse Table Interpretation

The pulse table player implements:
- Pulse width sweeps (increase/decrease)
- Duration-based modulation
- Initial pulse values
- Loop/chain to next pulse program

### Audio Rendering

The tool renders audio in two modes:

1. **Real-time playback** (default): Uses SDL2 audio to play through system speakers
2. **File output** (-o flag): Renders to IFF 8SVX format (ProTracker compatible)

## ProTracker Sample Output

When using the `-o` option, the tool creates an IFF 8SVX file which can be imported into:

- ProTracker (Amiga)
- OpenMPT
- MilkyTracker  
- Renoise
- Other trackers supporting 8SVX format

The output is 8-bit mono audio. For best quality in samplers, use:
- 16574 Hz for authentic Amiga sound
- 22050 Hz or higher for modern usage

## Examples

### Create a Bass Sample

```bash
./ctinsplay bass.cti -n 24 -d 2000 -o bass_c2.8svx -r 16574
```

### Test Lead at Different Pitches

```bash
./ctinsplay lead.cti -n 36  # C-4
./ctinsplay lead.cti -n 48  # C-5
./ctinsplay lead.cti -n 60  # C-6
```

### Compare SID Models

```bash
./ctinsplay pad.cti -n 48 -m 6581  # Warm, filtered sound
./ctinsplay pad.cti -n 48 -m 8580  # Brighter, cleaner sound
```

## Troubleshooting

### "Cannot open file"
Make sure the `.cti` file exists and has the correct format. Create instrument files using CheeseCutter's Ctrl+S function in the instrument editor.

### "Failed to open audio device"
SDL2 audio initialization failed. Check that:
- Your audio system is working
- SDL2 is properly installed
- No other application is blocking audio access

### Distorted Output
Try adjusting:
- Sample rate (use lower rates for cleaner output)
- Duration (some instruments need time to develop)
- SID model (6581 vs 8580 have different filter characteristics)

## Integration with CheeseCutter Workflow

1. Create instruments in CheeseCutter
2. Save individual instruments as `.cti` files (Ctrl+S in instrument editor)
3. Use `ctinsplay` to:
   - Preview instruments outside the full editor
   - Render sample libraries for other trackers
   - Test instruments at various pitches
   - Create sample packs from your SID instruments

## Technical Notes

### Frequency Table

The tool uses the standard C64 SID frequency table for PAL systems, covering 96 notes (8 octaves). Frequencies are calculated for the PAL clock rate (985248 Hz) and adjusted for NTSC when specified.

### Frame Timing

Audio updates happen at the refresh rate:
- PAL: 50.125 Hz
- NTSC: 60 Hz

Wave table and pulse table updates are synchronized to these frame rates, matching CheeseCutter's behavior.

### Cycle Accuracy

The ReSID engine provides cycle-accurate emulation of the SID chip, ensuring faithful reproduction of:
- Combined waveforms
- Filter characteristics  
- Phase accumulation
- ADSR envelope timing

## License

This tool uses:
- ReSID library (GPL) - SID emulation
- SDL2 (zlib license) - Audio output
- CheeseCutter instrument format (GPL)

The tool itself is released under the same GPL license as CheeseCutter.

## Credits

- ReSID engine: Dag Lem
- CheeseCutter: Abaddon
- ctinsplay tool: Created for CheeseCutter project

## See Also

- [CheeseCutter main documentation](README.md)
- [Keyboard shortcuts](doc/KEYBOARD.md)
- [ReSID homepage](http://www.zimmers.net/anonftp/pub/cbm/crossplatform/emulators/resid/)

