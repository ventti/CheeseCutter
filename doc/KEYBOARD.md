# CheeseCutter keyboard reference

_Generated from the shortcut registry (com.shortcuts)._

## Global

### Application

| Shortcut | Action |
|---|---|
| `Ctrl-Q` | Quit program |

### Display

| Shortcut | Action |
|---|---|
|  | Display note names with flats (b) instead of sharps (#) |
| `Alt-Up` | Oscilloscope: zoom in on the recorded keyjam note (shorter window) |
| `Alt-Down` | Oscilloscope: zoom out toward the whole recorded keyjam note |
| `Ctrl-F12` | Save screenshot |
| `Ctrl-Cmd-F` | Toggle fullscreen |
| `Alt-H` | Toggle help texts |
| `Shift-F12` | Toggle the oscilloscope overlay (combined synthesized audio waveform, live during playback and keyjam) |
| `Ctrl-Shift-F` | Toggle the read-only filter track column |
| `Ctrl-E` | Toggle the visual Sound Editor (live instrument view with keyjam) |

### Edit

| Shortcut | Action |
|---|---|
| `Ctrl-R` / `Ctrl-Shift-Z` / `Ctrl-Y` | Redo |
| `Ctrl-Z` | Undo |

### File

| Shortcut | Action |
|---|---|
| `Ctrl-N` | Clear the song and start a new project |
| `Shift-F10` | Export song: Full player .prg / Optimized .prg / PSID (options dialog) |
| `Shift-F9` | Import a ProTracker module (.mod): pick the file, then choose channels and which effects to translate |
| `F9` / `Ctrl-O` | Open the Load song dialog |
| `F10` | Open the Save song dialog |
| `Ctrl-F10` / `Ctrl-S` | Quick save song (doesn't ask a filename) |
| `Ctrl-Shift-F10` | Render audio: .wav / .flac (duration, normalize, bit depth, rate) |

### Help

| Shortcut | Action |
|---|---|
| `F12` | Open context help |
| `Ctrl-P` | Open the command palette: search commands and songs by name or shortcut (also Esc, then type) |
| `F11` / `Alt-S` | Show the splash / about screen |

### Keyjam

| Shortcut | Action |
|---|---|
| `Ctrl-Space` / `Ctrl-K` | Toggle keyjam mode |

### Playback

| Shortcut | Action |
|---|---|
| `F8` | Fast forward |
| `Shift-F8` | Fast forward more |
| `Shift-F3` | Play / resume from cursor with tracking |
| `Shift-F1` | Play / resume from mark with tracking |
| `Shift-F2` | Play / resume from the start with tracking |
| `F3` | Play from cursor position (loops the selected block if one is active) |
| `F1` | Play from playback mark (loops the selected block if one is active) |
| `F2` | Play from the start (loops the selected block if one is active) |
| `ScrollLock` / `Ctrl-F5` | Start/stop tracking (works only when playing) |
| `F4` | Stop playback |

### Playback options

| Shortcut | Action |
|---|---|
| `Ctrl-F9` | Cycle playback visualization |
| `Alt-F12` | Dump current SID register frame |
| `Ctrl-F8` | Select next SID filter preset |
| `Ctrl-Shift-F8` | Select previous SID filter preset |
| `Ctrl-F3` | Toggle SID type (6581/8580) |
| `Ctrl-F2` | Toggle interpolation |

### Properties

| Shortcut | Action |
|---|---|
|  | Properties: playback backend, reSID SID model & filter preset, Ultimate IP/port, x64sc path, audio driver |

### Song management

| Shortcut | Action |
|---|---|
| `Alt-Keypad 0` / `Ctrl-Alt-C` | Clear all sequences |
| `Alt-Keypad .` / `Ctrl-Alt-O` | Optimize song (clear unused sequences & data) |

### Song variables

| Shortcut | Action |
|---|---|
| `Ctrl--` / `Ctrl-Keypad -` | Decrease default song speed |
| `Alt-Keypad -` | Decrease multispeed framecall counter |
| `Ctrl-+` / `Ctrl-Keypad +` | Increase default song speed |
| `Alt-Keypad +` | Increase multispeed framecall counter |

### Voice control

| Shortcut | Action |
|---|---|
| `Cmd-1` / `Ctrl-1` | Toggle voice 1 on/off |
| `Cmd-2` / `Ctrl-2` | Toggle voice 2 on/off |
| `Cmd-3` / `Ctrl-3` | Toggle voice 3 on/off |

### Window navigation

| Shortcut | Action |
|---|---|
| `Alt-T` | Edit title / author / release info |
| `F6` | Enter the sequencer note column (focuses the Sequencer) |
| `F5` | Enter the sequencer track column (focuses the Sequencer) |
| `Alt-9` / `Alt-D` | Jump to Chord table |
| `Alt-8` / `Alt-M` | Jump to Cmd table |
| `Alt-7` / `Alt-F` | Jump to Filter table |
| `Alt-4` / `Alt-I` | Jump to Instrument table |
| `Alt-6` / `Alt-P` | Jump to Pulse table |
| `Alt-V` | Jump to Sequencer |
| `Alt-5` / `Alt-W` | Jump to Wave table |
|  | Jump to the active instrument's wave-table row |
| `Alt-1` | Jump to voice 1 |
| `Alt-2` | Jump to voice 2 |
| `Alt-3` | Jump to voice 3 |
| `Ctrl-Tab` | Move cursor between main windows |
| `Ctrl-Shift-Tab` | Move cursor between main windows (reverse) |
| `Tab` | Move cursor between subwindows |
| `Shift-Tab` | Move cursor between subwindows (reverse) |
| `F7` | Toggle the sequencer tracklist overview (focuses the Sequencer) |

## Sequencer (all columns)

### Display

| Shortcut | Action |
|---|---|
| `Alt-,` | Decrease row highlight value |
| `Alt-.` | Increase row highlight value |
| `Alt-0` | Reset highlighting to current row |
| `Alt-E` | Show/hide row counters for sequences |
| `Alt-T` | Toggle notes relative to current transpose |

### Navigation

| Shortcut | Action |
|---|---|
| `Ctrl-L` | Center the cursor on screen |
| `Ctrl-Home` / `Ctrl-H` | Jump to playback mark (realigns the voices) |
| `Shift-End` | Move cursor to song end |
| `Shift-Home` | Move cursor to song start |
| `Ctrl-Backspace` | Set loop (wrap) mark to current position |
| `Backspace` | Set playback start mark to current position |

### Selection

| Shortcut | Action |
|---|---|
| `Ctrl-D` | Clear the block selection |
| `Ctrl-C` | Copy the selected block to the clipboard |
| `Ctrl-X` | Cut the selected block (blank rows, keep length) |
| `Ctrl-Shift-B` | Mark block selection end at the cursor |
| `Ctrl-B` | Mark block selection start at the cursor |
| `Ctrl-Shift-V` | Merge the block into empty rows only from the cursor |
| `Ctrl-Shift-N` | Paste the block as new track(s)/sequence(s) at the cursor |
| `Ctrl-V` | Paste the block over rows from the cursor (overflow dropped) |

### Sequence operations

| Shortcut | Action |
|---|---|
| `Alt-Right` | Activate next subtune |
| `Alt-Left` | Activate previous subtune |
| `Alt-C` | Ask for a sequence number and copy contents over current sequence |
| `Alt-N` | Ask for a sequence number and insert contents to cursor pos |

## Sequencer: note column (F6)

### Note

| Shortcut | Action |
|---|---|
| `,` | Change the note in current row to a tie note |
| `<` | Decrease base octave |
| `Return` | Grab the current row's instrument as the active instrument |
| `>` | Increase base octave |
| `;` | Toggle automatic instrument value insert |
| `Alt-S` | Transpose octave down |
| `Alt-W` | Transpose octave up |
| `Alt-A` | Transpose semitone down |
| `Alt-Q` | Transpose semitone up |

### Note column

| Shortcut | Action |
|---|---|
| `Alt-Return` / `Insert` | Insert a row without expanding the sequence |

### Sequence

| Shortcut | Action |
|---|---|
| `Shift-Delete` | Delete a row (with sequence shrink) |
| `Ctrl-Return` / `Ctrl-Insert` | Expand the sequence |
| `Alt-Shift-Return` / `Shift-Insert` | Insert a row (with sequence expand) |
| `End` | Move cursor to sequence end (or screen bottom) |
| `Home` | Move cursor to sequence start (or screen top) |
| `Keypad 0` / `Ctrl-Shift-P` | Play notes for all voices in current row |
| `Shift-Return` | Quick expand sequence (by highlight value * 4) |
| `Ctrl-Delete` | Shrink the sequence |
| `Alt-P` | Split current sequence into two from cursor pos |

## Sequencer: track column (F5)

### Track column

| Shortcut | Action |
|---|---|
| `Ctrl-C` / `Alt-Z` | Ask for a number and copy tracks into clipboard |
| `Ctrl-Shift-Delete` | Delete a track for all voices |
| `Delete` | Delete track at cursor |
| `Ctrl-Delete` | Delete track to end of voice and move there |
| `Ctrl-F` | Find next unused sequence from current value |
| `Alt-Return` / `Insert` | Insert a track at cursor |
| `Ctrl-Shift-Return` / `Ctrl-Shift-Insert` | Insert a track for all voices |
| `Ctrl-Return` / `Ctrl-Insert` | Insert a track to end of voice and move there |
| `Ctrl-V` | Paste copied tracks (ask insert or overwrite) |
| `Ctrl-I` / `Alt-B` | Paste copied tracks as insert |
| `Ctrl-O` | Paste copied tracks as overwrite |
| `>` | Select next sequence |
| `<` | Select previous sequence |
| `Ctrl-Alt-1` | Swap voice's tracks with voice 1's from cursor down |
| `Ctrl-Alt-2` | Swap voice's tracks with voice 2's from cursor down |
| `Ctrl-Alt-3` | Swap voice's tracks with voice 3's from cursor down |
| `Alt-A` | Transpose tracks down from cursor down |
| `Alt-Q` | Transpose tracks up from cursor down |

## Instrument table

### Instrument table

| Shortcut | Action |
|---|---|
| `Ctrl-C` | Copy instrument to clipboard |
| `Ctrl-D` | Delete current instrument |
| `Ctrl-L` | Load current instrument from disk |
| `Ctrl-V` | Paste instrument from clipboard |
| `Ctrl-S` | Save current instrument to disk |

## Wave / pulse / filter tables

### Tables

| Shortcut | Action |
|---|---|
| `.` | Clear current wave row |
| `Delete` | Delete a row |
| `Alt-Return` / `Insert` | Insert a row |
| `Shift-Home` | Jump to first row |
| `Shift-End` | Jump to last used row |

## Sound Editor

### Sound

| Shortcut | Action |
|---|---|
| `Ctrl-Shift-N` | Create a new private sound |
| `Ctrl-Shift-1` | Edit selected wave byte 1 |
| `Ctrl-Shift-2` | Edit selected wave byte 2 |

### Sound Editor controls

| Shortcut | Action |
|---|---|
| `Ctrl-Shift-R` | Cycle Filter channel route |
| `Ctrl-Shift-3` | Decrease Filter resonance |
| `Ctrl-Shift-PageDown` / `Keypad /` | Decrease keyjam octave |
| `Ctrl-Shift-9` | Decrease selected sweep duration |
| `Ctrl-Shift-7` | Decrease selected sweep end value |
| `Ctrl-Shift-5` | Decrease selected sweep start value |
| `Ctrl-Shift-D` / `Delete` | Delete the selected programme row |
| `Ctrl-Shift-A` / `Home` | Fit the full sound |
| `Ctrl-Shift-4` | Increase Filter resonance |
| `Ctrl-Shift-PageUp` / `Keypad *` | Increase keyjam octave |
| `Ctrl-Shift-0` | Increase selected sweep duration |
| `Ctrl-Shift-8` | Increase selected sweep end value |
| `Ctrl-Shift-6` | Increase selected sweep start value |
| `Ctrl-Shift-J` / `Alt-Return` / `Insert` | Insert the selected programme row |
| `Ctrl-PageDown` / `Keypad +` | Select next instrument |
| `Ctrl-PageUp` / `Keypad -` | Select previous instrument |
| `Shift-PageDown` | Select the next wave row |
| `Shift-PageUp` | Select the previous wave row |
| `Ctrl-L` | Set the wave loop target |
| `Ctrl-Shift-S` | Stop the selected programme |
| `Ctrl-Shift-B` | Toggle Filter band-pass |
| `Ctrl-Shift-H` | Toggle Filter high-pass |
| `Ctrl-Shift-L` | Toggle Filter low-pass |
| `Ctrl-T` | Toggle Filter sweep/config row type |
| `Ctrl-Shift-E` | Toggle linked programme edits |
| `Ctrl-I` | Toggle selected sweep carry value |
| `Ctrl-Shift-I` | Zoom in |
| `Ctrl-Shift-O` | Zoom out |
| `Ctrl-Shift-G` / `End` | Zoom to the time selection |

## File dialogs

_Active inside the load / save / import / instrument file dialogs._

| Shortcut | Action |
|---|---|
| `Ctrl-D` / right-click | Toggle the highlighted directory as a favorite (favorites are listed at the top) |
| _type a name_ | Type-ahead: jump to the first matching entry |
| `Tab` / `Shift-Tab` | Switch between the file list, directory and filename fields |
| `Return` | Enter the highlighted directory / confirm the selection |
| `Esc` | Cancel the dialog |

## Platform notes

- macOS outside Sound Editor: legacy Cmd translation acts as Ctrl+Shift.
- macOS: Cmd+1/2/3 toggle voices; Ctrl+Shift+1..9 set sequencer step size. Cmd+4..9 retain keypad emulation.
- macOS outside Sound Editor: Cmd+Up / Cmd+Down act as Shift+Home / Shift+End.
- Sound Editor uses physical Ctrl/Shift primaries; global Cmd+1/2/3 toggle voices.
- macOS: Option+Return inserts; Shift+Option+Return inserts with sequence expansion.
- macOS: Ctrl+Return replaces Ctrl+Insert; Ctrl+Shift+Return replaces Ctrl+Shift+Insert in tracks.
- macOS: Ctrl+Cmd+F toggles fullscreen; Shift+Return still quick-expands sequences.
- macOS: F11 may be intercepted by the system (Show Desktop).

