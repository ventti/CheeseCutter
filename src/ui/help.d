/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

ContextHelp data type backing the F12 per-context help pages.
*/

module ui.help;

import std.string : format;
import com.util;

struct ContextHelp {
	string title;
	string[] text;
}

ContextHelp HELPMAIN = ContextHelp("Main help", 
["
Escape (x2).....Quit program
Alt-Return......Toggle fullscreen
F9..............Open the Load song dialog
F10.............Open the Save song dialog
F11.............Open the About dialog
Ctrl-F11........Quick save song (doesn't ask a filename)
Ctrl-F12........Save screenshot

`+dPlayback\n
F1..............Play from playback mark
Shift-F1........Play / resume from mark with tracking
F2..............Play from the start
Shift-F2........Play / resume from the start with tracking
F3..............Play from cursor position
F4..............Stop playback
F8..............Fast forward (w/ Shift = Fast forward more)
Scroll Lock.....Start/stop tracking (works only when playing)
Ctrl-F5.........Start/stop tracking (works only when playing)
Ctrl-1,2,3......Toggle voices on/off
Ctrl-F9.........Cycle playback visualization
Ctrl-F2.........Toggle interpolation
Ctrl-F3.........Toggle SID type (6581/8580)
Ctrl-F8.........Select next SID filter preset
Ctrl-Shift-F8...Select previous SID filter preset

`+dSong variables\n
Ctrl-Keypad - +.........Decrease/increase default song speed
[ ] (AltGr-8 / AltGr-9).Decrease/increase default song speed
Alt-Keypad - +..........Decrease/increase multispeed framecall counter 
{ } (AltGr-7 / AltGr-0).Decrease/increase multispeed framecall counter
Alt-T...................Edit title / author / release info
Ctrl-Alt-C..............Clear all sequences (asks for confirmation)
Ctrl-Alt-O..............Optimize song (clear unused sequences & data)
", "
`+dMoving between tables\n
Tab.....................Move cursor between subwindows
Ctrl-Tab................Move cursor between main windows
                        (sequencer, instrument table, subtables)
Alt-V...................Jump to Sequencer
Alt-I...................Jump to Instrument table
Alt-W...................Jump to Wave table
Alt-P...................Jump to Pulse table
Alt-F...................Jump to Filter table
Alt-M...................Jump to Cmd table
Alt-D...................Jump to Chord table
Alt-1, 2, 3.............Jump to voice 1, 2 or 3
Alt-4-9 can also move between tables:
Alt-4 = Ins, Alt-5 = Wave, Alt-6 = Pulse, Alt-7 = Filter,
Alt-8 = Cmd, Alt-9 = Chord

`+dInstrument table functions\n
Ctrl-L..................Load current instrument from disk
Ctrl-S..................Save current instrument to disk
Ctrl-D..................Delete current instrument
Ctrl-C..................Copy instrument to clipboard
Ctrl-V..................Paste instrument from clipboard

`+dPlayer reference\n
Check out the bundled CheeseCutter-EXTended user guide.

`+dAbout:
CheeseCutter-EXTended 0.1.0, based on CheeseCutter 2.9

"]);

ContextHelp HELPSEQUENCER = ContextHelp("Sequencer help",
["`+1Press F12 again to see the global help.

`+dGeneral

Alt-1,2,3...............Jump to voice 1, 2 or 3
Tab.....................Move cursor to the next voice

Keypad / *..............Decrease/increase base octave value
Ctrl-Keypad - +.........Decrease/increase default song speed
[ ] (AltGr-8 / AltGr-9).Decrease/increase default song speed
Keypad - +..............Decrease/increase active instrument number
Keypad 1-9..............Set cursor step value (used when entering notes)
Alt-Left/Right..........Activate previous/next subtune

F5......................Enter to the track column
Shift-F5................Display tracks alongside the sequences
F6......................Enter to the note column
F7......................Display tracks only ('overview mode')

Home/End................Move cursor to SEQ start/end OR screen top/bottom
Shift-Home/End..........Move cursor to song start/end
Backspace...............Set playback start mark (the blue bar) to current position
Ctrl-Home/Ctrl-H........Jump to playback mark position (also realigns the voices)

Ctrl-Z..................Undo
Ctrl-R..................Redo
Alt-C...................Ask for a SEQ number and copy contents over current SEQ
Alt-A...................Ask for a SEQ number and insert contents to cursor pos
(Shift-)Insert/Delete...Insert/delete a row (Shift=w/ sequence expand/shrink)
Ctrl-Insert/Delete......Expand/shrink the sequence
Shift-Enter.............Quick expand sequence (expands by highlight value * 4)
Ctrl-Q/A................Transpose semitone up/down
","Ctrl-W/S................Transpose octave up/down
Ctrl-M/N................Increase/decrease row highlight value
Ctrl-0(zero)............Reset highlighting to current row
Ctrl-E..................Show/hide row counters for sequences
Ctrl-T..................Toggle notes relative to current transpose
Keypad 0................Play notes for all voices in current row
Ctrl-P..................Split current sequence into two from cursor pos.
                        `+dUse with caution.


`+dIn the note column (F6)

 2 3   5 6 7   9 0
Q W E R T Y U I O P.....Enter notes (base octave+1)
 S D   G H J
Z X C V B N M...........Enter notes (base octave)

1.......................Enter a gate off (===)
A or !..................Enter a gate on (+++)
Space or '.'............Clear
Space...................Insert previously entered instrument/command value
                        (in instrument/command column only)
- +.....................Decrease/increase base octave
';'.....................Toggle insert instrument value automatically-mode
','.....................Change the note in current row to a tie note
Enter...................Grab the instrument value in the current row

`+dIn the track column (F5)

Up/Down.................Previous/next track in active voice
PageUp/PageDown.........Previous/next track in active voice
Ctrl-F..................Find next unused sequence starting from current value
< >.....................Select previous/next sequence
Ctrl-Q/A................Transpose all tracks up/down from cursor down
Hex digits..............Edit transpose/sequence value
", "`+dIn the track column (F5) (cont.)

Insert/Return...........Insert a track at cursor
Delete/Backspace........Delete track at cursor
Ctrl-Enter..............Insert a track to end of voice and move cursor there
Ctrl-Insert/Delete......Insert/delete track to end of voice and move cursor there
Ctrl-Shift-Insert/Del...Insert/delete a track for all voices
Ctrl-C or Alt-Z.........Ask for a number and copy tracks into clipboard
Ctrl-V..................Ask to paste copied tracks as insert or overwrite
Ctrl-I/O................Paste copied tracks as insert/overwrite
Alt-B...................Paste copied tracks as insert
Ctrl-Alt-1..............Swap voice's track with voice 1's tracks from crsr down
Ctrl-Alt-2..............Swap voice's track with voice 2's tracks from crsr down
Ctrl-Alt-3..............Swap voice's track with voice 3's tracks from crsr down
"]);


// Five pages (SPACE / F12-again cycles). Each MUST fit the help window (~34 lines
// before the render clamp); an over-long single page overflows the screen and its
// tail is silently dropped (and long enough would crash Screen.cprint) -- so keep
// each page comfortably short and add a page rather than growing one past the fold.
ContextHelp HELPSOUNDEDITOR = ContextHelp("Sound Editor help",
["`+1Press F12 again to see the global help.  SPACE for more.

`+dSound Editor (Ctrl-E toggles it from the classic editor)

A live view of the selected instrument: stacked, time-aligned graph
bands (output, ADSR, freq/arp, pulse, filter+resonance, wave control
bits) on one note-on axis, plus a parameter column and a raw table
strip. Play a note to see the playhead sweep across. The envelope +
scalar bytes are editable here (byte-identical to the classic table).

`+dJamming notes

 2 3   5 6 7   9 0
Q W E R T Y U I O P.....Notes, base octave + 1
 S D   G H J
Z X C V B N M...........Notes, base octave

Ctrl-Shift-PgDn/PgUp...Lower / raise the base octave
Keypad / *..............Legacy aliases

`+dNavigation

Ctrl-PgUp/PgDn..........Previous / next instrument
Keypad -/+..............Legacy aliases
Up / Down...............Move the parameter cursor
Ctrl-E..................Exit back to the classic editor",

"`+1Press F12 again to see the global help.  SPACE for more.

`+dEditing the sound (writes the same bytes as the classic table)

Left / Right............Edit the selected parameter (- / +)
  Attack/Decay/Sustain/Release.....nibble 0-F
  Restart..........................cycle Hard / Soft / 3 Frames
  Arpeggio speed...................nibble 0-F
  HR wave / HR SR..................byte 00-FF
Drag ADSR handles.......Set A/D/S/R by dragging the curve markers
						(A/R: left-right, D: both, S: up-down)
                        (drag the decay dot up/down for sustain; zoom
                        out to reach the release dot past the note)
Pulse/Filter blocks use direct manipulation (the touched block becomes
                        selected automatically):
  Its START dot (up/down)....Set the step's start level (pw / cutoff)
  Its END dot (up/down)......Tilt the ramp (takes priority over edge)
    Drag beyond band.........Add/remove full value-range windings
    Shift-drag END...........Set full signed speed range directly
  Any point on right edge....Resize duration (cursor becomes <->)
  Drag inside its box........Set pulse level / filter cutoff
  (edges + dots go YELLOW when grabbable. Shared programmes copy
   automatically; enable Linked edits to change every linked sound.)
  Keyjam edits re-render from reSID on mouse-up; Fit stays unchanged.
Shift-click a 2nd step..Select a RANGE; drag one shared join dot to
                        adjust only its two adjacent selected blocks
Drag empty Pulse/Filter...Create and edit the programme in one gesture
Ctrl-Shift-E..............Toggle visible Linked edits mode
Ctrl-Shift-J / Insert...Create a row after the selected row
Ctrl-Shift-D / Delete...Remove the selected row
Drag the loop grip......Move the loop-back point (top strip of the band)",

"`+1Press F12 again to see the global help.  SPACE for more.

`+dWave programme graph

Drag a pitch row up/down...Change its note/arpeggio value; relative and
                          absolute row encoding stays intact
Drag a delay row left/right..Change delay 1-F; the edge follows the pointer
Target and END rows........Protected from pitch/delay dragging
Click a Wave bit lane......Toggle that producing row's SID control bit
Drag across a bit lane.....Paint the same state without repeated toggles
                            (unrepresentable W2 controls stay unchanged with a cue)
Click trailing +...........Append a normal row before END/LOOP; its top cell
                            stays separate from the terminal triangle
                            (invalid programmes use Sound > New sound)
Top > triangle (left edge)..Loop start; drag to a legal authored row
Top < triangle (right edge).END/loop end; drag to set or retarget the loop
                            (the triangle owns only the band's top cell)

Shared Wave edits copy automatically; visible Linked edits mode is the only
way to change every linked sound. Crossed rows paint as one undo step;
reSID refreshes once on release, never during the drag.
Fit includes authored Wave timing even after a shorter keyjam recording.",

"`+1Press F12 again to see the global help.  SPACE for more.

`+dPulse / Filter program controls

Click Stop..............Make the selected program stop instead of loop
Click Type..............Toggle selected Filter row: sweep / config
Click Carry.............Toggle explicit start / inherit running value
Drag the Filter res line..Set resonance (0-F) for that filter block;
                        later blocks become constant CONFIG segments
Click Filter LP/BP/HP...Toggle each mode bit (yellow on, gray off)
Click Filter Route......Cycle voice 1/2/3/external-input routing mask
Ctrl-Shift-5 / 6........Nudge selected step START down / up
Ctrl-Shift-7 / 8........Nudge selected step END down / up
Ctrl-Shift-9 / 0........Nudge selected step duration down / up
Ctrl-Z / Ctrl-Y.........Undo / redo the edit",

"`+1Press F12 again to see the global help.

(Pointer rows -- Waveform / Wave / Pulse / Filter ptr -- are
 display-only; the sweeps are edited by dragging their bands.)

`+dView / zoom (mouse-first; the graphs zoom + pan)

Drag on the plot........Mark a tick-snapped selection
Dim vertical grid.......One track step: (speed+1) x multiplier ticks
- / + / Fit / Selection...Zoom out / in / whole note / selection
Scrollbar...............Drag the thumb to pan; click the track to page
Shift-Left / Right......Pan the view (~1/4 window)
Ctrl-Shift-A / G........Fit whole note / Zoom to selection
Home / End..............Legacy aliases
Backspace...............Clear the selection

`+dButton shortcuts (also shown when hovering)

Ctrl-Shift-O / I........Zoom out / in
Ctrl-Shift-A / G........Fit / Selection
Ctrl-Shift-J / D........Add / delete selected programme row
Ctrl-Shift-S / Ctrl-T...Stop programme / toggle Filter row type
Ctrl-I / Ctrl-Shift-N...Toggle Carry / create New private sound
Shift-PgUp / PgDn.......Previous / next wave row
Ctrl-Shift-1 / 2........Edit wave byte 1 / 2; Ctrl-L = set Loop
Ctrl-Shift-3 / 4........Resonance down / up
Ctrl-Shift-L/B/H/R......Toggle LP/BP/HP / cycle route

`+dPlayback

F1 / F2 / F3............Play from mark / start / cursor  (Shift = follow)
F4......................Stop playback"]);

ContextHelp genPlayerContextHelp(string title, char*[] descriptions) {
	string text;
	text = "`+1Press F12 again to see the global help.\n\n`+d" ~ title ~ "\n";
	foreach(idx, char* line; descriptions) {
		text ~= format("\n`0fByte %d: %s", idx + 1, petscii2D(line));
	}
	text ~= "\n\nPress Alt-H to turn the byte descriptions off.";
	ContextHelp ctx = ContextHelp(title, [text]);
	return ctx;
}
