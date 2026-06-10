# CheeseCutter keyboard reference

_Generated from the shortcut registry (com.shortcuts)._

## Global

### Application

| Shortcut | Action |
|---|---|
| `F12` | Open context help |
| `Esc` | Quit program (press twice) |
| `Ctrl-F12` | Save screenshot |
| `F11` | Show the splash / about screen |
| `Alt-Return` | Toggle fullscreen |

### Display

| Shortcut | Action |
|---|---|
| `Alt-H` | Toggle help texts |

### Edit

| Shortcut | Action |
|---|---|
| `Ctrl-R` | Redo |
| `Ctrl-Z` | Undo |

### File

| Shortcut | Action |
|---|---|
| `F9` | Open the Load song dialog |
| `F10` | Open the Save song dialog |
| `Ctrl-F10` | Quick save song (doesn't ask a filename) |
| `Shift-F10` | Save current subtune as a playable .prg |

### Keyjam

| Shortcut | Action |
|---|---|
| `Ctrl-Space` | Toggle keyjam mode |

### Playback

| Shortcut | Action |
|---|---|
| `F8` | Fast forward |
| `Shift-F8` | Fast forward more |
| `Shift-F1` | Play / resume from mark with tracking |
| `Shift-F2` | Play / resume from the start with tracking |
| `F3` | Play from cursor position |
| `F1` | Play from playback mark |
| `F2` | Play from the start |
| `Ctrl-F5` / `ScrollLock` | Start/stop tracking (works only when playing) |
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

### Song management

| Shortcut | Action |
|---|---|
| `Alt-Keypad 0` / `Ctrl-Alt-C` | Clear sequences (press twice to activate) |
| `Alt-Keypad .` / `Ctrl-Alt-O` | Optimize (clear unused sequences & data) |

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
| `Ctrl-1` | Toggle voice 1 on/off |
| `Ctrl-2` | Toggle voice 2 on/off |
| `Ctrl-3` | Toggle voice 3 on/off |

### Window navigation

| Shortcut | Action |
|---|---|
| `Alt-T` | Edit title / author / release info |
| `Alt-9` / `Alt-D` | Jump to Chord table |
| `Alt-8` / `Alt-M` | Jump to Cmd table |
| `Alt-7` / `Alt-F` | Jump to Filter table |
| `Alt-4` / `Alt-I` | Jump to Instrument table |
| `Alt-6` / `Alt-P` | Jump to Pulse table |
| `Alt-V` | Jump to Sequencer |
| `Alt-5` / `Alt-W` | Jump to Wave table |
| `Alt-1` | Jump to voice 1 |
| `Alt-2` | Jump to voice 2 |
| `Alt-3` | Jump to voice 3 |
| `Ctrl-Tab` | Move cursor between main windows |
| `Ctrl-Shift-Tab` | Move cursor between main windows (reverse) |
| `Tab` | Move cursor between subwindows |
| `Shift-Tab` | Move cursor between subwindows (reverse) |

## Sequencer (all columns)

### Display

| Shortcut | Action |
|---|---|
| `Ctrl-N` | Decrease row highlight value |
| `Ctrl-M` | Increase row highlight value |
| `Ctrl-0` | Reset highlighting to current row |
| `Ctrl-E` | Show/hide row counters for sequences |
| `Ctrl-T` | Toggle notes relative to current transpose |

### Navigation

| Shortcut | Action |
|---|---|
| `Ctrl-L` | Center the cursor on screen |
| `Ctrl-H` / `Ctrl-Home` | Jump to playback mark (realigns the voices) |
| `Shift-End` | Move cursor to song end |
| `Shift-Home` | Move cursor to song start |
| `Ctrl-Backspace` | Set loop (wrap) mark to current position |
| `Backspace` | Set playback start mark to current position |

### Sequence operations

| Shortcut | Action |
|---|---|
| `Alt-Right` | Activate next subtune |
| `Alt-Left` | Activate previous subtune |
| `Alt-C` | Ask for a SEQ number and copy contents over current SEQ |
| `Alt-A` | Ask for a SEQ number and insert contents to cursor pos |
| `Ctrl--` / `Ctrl-Keypad -` | Decrease sequencer height |
| `F6` | Enter the note column |
| `F5` | Enter the track column / toggle tracklist display |
| `Ctrl-=` / `Ctrl-Keypad +` | Increase sequencer height |
| `F7` | Toggle tracklist overview mode |

## Sequencer: note column (F6)

### Note column

| Shortcut | Action |
|---|---|
| `,` | Change the note in current row to a tie note |
| `<` | Decrease base octave |
| `Shift-Delete` | Delete a row (with sequence shrink) |
| `Ctrl-Insert` | Expand the sequence |
| `Return` | Grab the instrument value in the current row |
| `>` | Increase base octave |
| `Shift-Insert` | Insert a row (with sequence expand) |
| `End` | Move cursor to SEQ end (or screen bottom) |
| `Home` | Move cursor to SEQ start (or screen top) |
| `Ctrl-Shift-P` / `Keypad 0` | Play notes for all voices in current row |
| `Shift-Return` | Quick expand sequence (by highlight value * 4) |
| `Ctrl-Delete` | Shrink the sequence |
| `Ctrl-P` | Split current sequence into two from cursor pos |
| `;` | Toggle automatic instrument value insert |
| `Ctrl-S` | Transpose octave down |
| `Ctrl-W` | Transpose octave up |
| `Ctrl-A` | Transpose semitone down |
| `Ctrl-Q` | Transpose semitone up |

## Sequencer: track column (F5)

### Track column

| Shortcut | Action |
|---|---|
| `Alt-Z` / `Ctrl-C` | Ask for a number and copy tracks into clipboard |
| `Ctrl-Shift-Delete` | Delete a track for all voices |
| `Delete` | Delete track at cursor |
| `Ctrl-Delete` | Delete track to end of voice and move there |
| `Ctrl-F` | Find next unused sequence from current value |
| `Insert` | Insert a track at cursor |
| `Ctrl-Shift-Insert` | Insert a track for all voices |
| `Ctrl-Insert` | Insert a track to end of voice and move there |
| `Ctrl-V` | Paste copied tracks (ask insert or overwrite) |
| `Alt-B` / `Ctrl-I` | Paste copied tracks as insert |
| `Ctrl-O` | Paste copied tracks as overwrite |
| `>` | Select next sequence |
| `<` | Select previous sequence |
| `Ctrl-Alt-1` | Swap voice's tracks with voice 1's from cursor down |
| `Ctrl-Alt-2` | Swap voice's tracks with voice 2's from cursor down |
| `Ctrl-Alt-3` | Swap voice's tracks with voice 3's from cursor down |
| `Ctrl-A` | Transpose tracks down from cursor down |
| `Ctrl-Q` | Transpose tracks up from cursor down |

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
| `Insert` | Insert a row |
| `G` | Jump to current instrument's wave |
| `Shift-Home` | Jump to first row |
| `Shift-End` | Jump to last used row |

## Platform notes

- macOS: the Cmd key acts as Ctrl+Shift for any shortcut.
- macOS: Cmd+1..9 act as the numeric keypad 1..9.
- macOS: Cmd+Up / Cmd+Down act as Shift+Home / Shift+End.
- macOS: F11 may be intercepted by the system (Show Desktop).

