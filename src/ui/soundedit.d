/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Visual Sound Editor screen: a live, keyjam-driven view of the selected instrument laid out as a left parameter column, a stack of time-aligned graph bands sharing one zoomable/pannable tick-based X axis (pixel-perfect output waveform, ADSR envelope, a piano-roll pitch band (relative arp + absolute notes on one note axis), pulse, a filter band coloured per frame by filter type with a resonance-over-time overlay, and a stacked SID control-bit-lane wave view) with a restart pre-roll, a note-trigger divider, a single vertical playhead, a tick-snapped drag selection, a subtle zoom-control row, a raw-hex table strip along the bottom, and a context F12 help page.

This is the full-screen alternative sound-editing mode toggled from the classic
editor (Ctrl-E). It runs keyjam (notes play) but uses the *normal* background,
not the dark-blue keyjam tint. The layout (design doc §7, §9 v4) stacks every
time-varying graph on ONE shared horizontal axis = frames since note-on
(~19.95 ms PAL ticks). The X span AUTO-FITS the note's full duration (§12):
visFrames is computed once per draw as the max of the ADSR-derived length (SID ms
tables) and the actual recorded extent, so short sounds zoom in and long releases
zoom out to fit; every band maps frame->pixel through the single viewport.xForFrame(): a pixel-perfect
output waveform (per-horizontal-pixel min/max of the live mix while playing, or
the per-note capture for a held keyjam note), the ADSR envelope (SID ms tables
converted to frames, sampled per frame with a nominal gate so A/D/S/R all show),
the pulse / filter table programs (simulated read-only from the ct.base byte
tables the C64 player interprets each frame), and a wave band drawn as 8 stacked
SID control-bit lanes (Noise/Pulse/Saw/Triangle/Test/Ring/Sync/Gate). The axis
reserves a small pre-roll at the left for the hard/soft/3-frame restart phase,
with a note-trigger divider at frame 0. All bands share the same left edge and
pixel width so a single full-height vertical playhead, placed at the current
frame-since-trigger of the sounding voice, crosses them all in lockstep. Left of the graphs a parameter column lists the instrument's editable
fields with a movable cursor; the bottom strip shows the
raw hex of the instrument's 8 bytes plus the wave/pulse/filter rows it points
into.

P4a (§19.5) adds the FIRST editing: the per-instrument SCALAR bytes — Attack /
Decay / Sustain / Release nibbles (AD col0, SR col1), the Restart type (col2 bits
6-7) + arpeggio-speed nibble (col2 low nibble), and the HR wave (col3) / HR SR
(col6) bytes — are editable BOTH numerically in the left column (Up/Down select a
row, Left/Right decrement/increment; Shift-Left/Right pans instead) AND by dragging
the A/D/S/R handles on the ADSR curve, each reflecting the other instantly (both
read the same song.instrumentTable byte, so one write updates both views). Edits go
through com.session's undo stack (Undoable: one step per keypress / per drag
gesture; global Ctrl-Z/Y) and re-trigger a held keyjam note so the new envelope is
audible immediately. This is BYTE-IDENTICAL to editing the same bytes in the classic
Instruments table. The pointer rows (Waveform / Wave / Pulse / Filter ptr) stay
DISPLAY-ONLY — the wave/pulse/filter PROGRAMS are edited via their graphs in P4b/c.
*/

module ui.soundedit;

import std.conv : to;
import std.string : format, stripRight, leftJustify;
import std.algorithm : max, min;
import std.math : lround, log2, floor, ceil, abs;
import derelict.sdl2.sdl;
import com.fb : FONT_X, FONT_Y, keyjamBackground, mousePixelY, traceMouseDrag;
import com.session : screen, video, state, song, mainui, insertUndo, UndoValue, Undoable;
import com.shortcuts : Ctx, formatShortcuts;
import com.palette : idx, Role, BaseColor;
import ct.base : Song, NOTES;
static import ct.purge;
import ui.window;
import ui.input;
import ui.button : Button;
import ui.dialogs : QueryDialog;
import ui.ui : UI;
import ui.menubar : MenuBar;
import ui.palette : CommandPalette;
import ui.help;
static import audio.player;
static import audio.audio;
static import audio.visualizer;

extern(C) int sid_render_envelope_preview(ubyte attackDecay, ubyte sustainRelease,
	int gateTicks, int multiplier, int restartTicks, ubyte* outTrace, int ticks) nothrow;

int soundEditorStepTicks(int effectiveSpeed, int multiplier) pure nothrow @safe {
	if(effectiveSpeed < 2) effectiveSpeed = 2;
	if(multiplier < 1) multiplier = 1;
	return (effectiveSpeed + 1) * multiplier;
}

int soundEditorDurationTicks(int value, bool rows, int effectiveSpeed, int multiplier)
		pure nothrow @safe {
	if(value < 1) value = 1;
	return rows ? value * soundEditorStepTicks(effectiveSpeed, multiplier) : value;
}

// R40/R41 compile-time contracts. The implementation immediately below is deliberately
// small and pure so the UI, headless usage driver and table-drag code share one definition
// of Rows versus Ticks.
static assert(soundEditorStepTicks(4, 2) == 10);
static assert(soundEditorDurationTicks(4, true, 4, 2) == 40);
static assert(soundEditorDurationTicks(4, false, 4, 2) == 4);

// §16.2 REAL-TIME shared axis. The recorded bands (recAmp/recFreq/..), the Output
// captureBuf and the playhead (recLen) are all indexed per PLAYER TICK, and the
// player runs `multiplier` ticks per PAL screen frame. So the true duration of ONE
// axis index (one tick) is the screen-frame period divided by the multiplier. The
// old code hardcoded the SCREEN-frame period as if one index == one screen frame,
// which is only true at multiplier==1; at multiplier==2 (e.g. vent-arkijuusto.ct)
// the ADSR ms->frames conversion, the restart geometry and the "~X s" label ran at
// 2x the recorded bands' scale (the label read ~2x too long). Deriving tickMs from
// the live multiplier each draw keeps EVERY band on the same real-time axis at any
// multiplier: t = tickIndex * tickMs (recorded/sim/playhead), t = sampleIndex/freq
// (Output), and the ADSR ms tables / restart / label are already real time.
private enum float SCREEN_FRAME_MS = 19.95f;   // PAL screen-frame period (ms)
// Nominal held-gate duration (ms) used to slope the drawn ADSR sustain->release
// knee on the sim/idle path. Real time, so it maps to the right number of ticks at
// any multiplier (was a fixed 46-tick count = ~918 ms only correct at multiplier 1).
private enum float NOMINAL_GATE_MS = 918.0f;
// §12.1: the post-trigger X span is no longer a fixed constant -- it AUTO-FITS the
// note's full duration each frame (see SoundEditor.computeVisFrames). These are the
// sane clamp bounds: a floor so a tiny sound isn't absurdly zoomed in, and a ceiling
// so a pathological length still renders (long sounds get <1px/frame = zoomed out).
private enum int MIN_VIS = 24;
private enum int MAX_VIS = 1600;
// §17.3 The viewport can zoom/scroll out PAST the fitted note (visFrames) so the
// release-tail dot is reachable even for a long release. MAX_CONTENT bounds that
// extended right edge (enough to hold a full nibble-F release at 2x multispeed).
private enum int MAX_CONTENT = 3200;
// §12.1: envelope-amplitude threshold for "the note is still audible" when reading
// the recorded extent (below this counts as silence / note ended).
private enum float AMP_EPS = 0.02f;
// §9.2: pre-roll region reserved at the LEFT of the shared axis for the hard/soft
// restart phase that runs in the frames BEFORE the note triggers (frames
// -RESTART_FRAMES .. 0). Frame 0 = the note-trigger divider. Every band maps
// frame->pixel through viewport.xForFrame(), which folds this offset in, so a single
// vertical probe hits the same frame index in every band.
private enum int RESTART_FRAMES = 10;
// §17.1 minimum viewport span (ticks). Zooming in can't narrow the view below this
// so the axis never collapses to (near) zero width.
private enum int MIN_VIEW_SPAN = 4;

// SID ADSR timing (ms) per 4-bit nibble value 0..15 -- the real, non-linear MOS
// tables (mirrors audio.visualizer / doc/ADSR_VISUALIZATION_SPEC.md, duplicated
// here because the visualizer's copies are private). Used to slope the drawn
// envelope so it matches what you hear.
private immutable float[16] ATTACK_TIME_MS = [
	2.0, 8.0, 16.0, 24.0, 38.0, 56.0, 68.0, 80.0,
	100.0, 250.0, 500.0, 800.0, 1000.0, 3000.0, 5000.0, 8000.0
];
private immutable float[16] DECAY_RELEASE_TIME_MS = [
	6.0, 24.0, 48.0, 72.0, 114.0, 168.0, 204.0, 240.0,
	300.0, 750.0, 1500.0, 2400.0, 3000.0, 9000.0, 15000.0, 24000.0
];

private float clamp01(float v) {
	if(v < 0) return 0;
	if(v > 1) return 1;
	return v;
}

// A simulated sweep-table program: the per-frame value staircase (pulse 0..4095
// or filter cutoff 0..2047), the source table row for each frame (for playhead
// mapping), and where/whether the program loops or stops.
private struct SweepSim {
	int[] val;          // per-frame value
	int[] rowOf;        // table row each frame came from
	// §10.1/§10.2 filter-only per-frame state (empty for pulse sims): the filter
	// mode bits (b0 & 0x70), resonance (0..15) and routing (b1 & 0x0F) that were in
	// effect each frame, carried forward from the last CONFIG row across sweeps.
	int[] modeOf;
	int[] resOf;
	int[] routeOf;
	// §20 P4b-3: the filter CONFIG row (last b0&0x80 row at/before this frame) that
	// governs the mode/res/routing on this frame, or -1 if none yet. This is the row
	// whose b0/b1 the resonance-drag / mode-cycle edits.
	int[] cfgRowOf;
	int loopFrame = -1; // frame index the looped section starts at (-1 = none)
	int loopPeriod = 0; // §11.3 length in frames of one loop cycle (for loop-line spacing)
	bool stops;         // program halts ($7F) rather than loops
}

// A wave/arp program row as drawn in the lane.
private struct WaveCell {
	int row;
	int ctrl;       // wave2: SID control byte / delay override / unchanged
	int transpose;  // wave1: relative transpose or absolute note
}

private struct WaveSim {
	WaveCell[] cells;
	int loopIndex = -1;    // cell index carrying the loop/jump marker (-1 = none)
	int loopTargetRow = -1; // $7F jump target row; -2 = $7E loop-to-previous
}

// §9.3 wave program flattened to ONE effective SID control byte per FRAME (the
// waveform/gate/ring/sync/test bits actually applied that frame, carrying forward
// across delay/unchanged rows), plus the frame the program loops back to.
private struct WaveFrameSim {
	int[] ctrlOf;       // effective control byte at each frame
	int[] rowOf;        // wave-table row producing each frame
	// §10.3 pitch program per frame from the wave-table transpose/arp column (wave1):
	// transOf = the semitone value (relative offset, or the absolute note number when
	// absOf is true); absOf = true when wave1 was an absolute tuning byte ($80+).
	int[] transOf;
	bool[] absOf;
	int loopFrame = -1; // frame index the looped section starts at (-1 = none)
	int loopPeriod = 0; // §11.3 length in frames of one loop cycle (for loop-line spacing)
}

/// Full-screen visual Sound Editor (see module doc). v2 layout: left parameter
/// column + stacked frame-aligned graph bands with one shared playhead + raw
/// table-data strip. All read-only.
// Stable, read-only state exposed for the headless usage tests.  Keep this
// semantic (ticks/selection/source), rather than exposing rendering internals,
// so tests describe what a user sees and can do.
struct SoundEditorDebugState {
	int tickMillis1000;
	int trackStepTicks;
	int visibleFrames;
	int prerollTicks;
	double viewStartTick, viewEndTick;
	bool userZoomed, hasSelection, usesRecording;
	int selectionStart, selectionEnd;
	int cursorDirection;
	int previewInstrument, previewNote;
	bool durationRows;
	int durationValue, gateHoldTicks, keyjamChannel;
}

struct SoundEditorControlDebug {
	string actionId;
	int x0, x1, row;
	bool enabled;
}

struct SoundEditorWaveAddDebug {
	bool visible, enabled;
	int frame, x, y, close;
	string reason;
}

struct SoundEditorWaveLoopDebug {
	bool looped, stopped, startVisible, endVisible;
	int startFrame, endFrame;
	int startLeft, startRight, endLeft, endRight, top, bottom;
}

struct SoundEditorSweepLoopDebug {
	bool looped, stopped, startVisible, endVisible;
	int startLeft, startRight, endLeft, endRight, top, bottom;
}

// Frequency-band pitch mapping probe: everything needed to check that a dragged block
// tracks the cursor 1:1. `drawnY` is where drawAuthoredPitchStaircase puts the row's
// current value; `mouseY` is the pixel the drag read. If they differ by more than one
// value step, the block is not following the mouse.
struct SoundEditorPitchProbe {
	int bandTop, bandBottom, bandHeight;
	int plotLeft, plotRight;   // band's X pixel range; a press outside starts no drag
	int scale, latchedScale;
	int row, value, pitch;
	int drawnY, mouseY, valueAtMouseY;
	int stepPixels1000;   // pixels per one semitone, x1000 (integer transport)
	bool dragging, clampedByScale;
}

class SoundEditor : Window, Undoable {
	// All colours go through the semantic palette (com.palette): UI chrome via Role.*
	// (idx), graph colours via named BaseColor.* — no magic indices anywhere.
	private @property int COL_TITLE() { return idx(Role.cursor); }
	private @property int COL_LABEL() { return idx(Role.text); }
	private @property int COL_VALUE() { return idx(Role.soundeditValue); }
	private @property int COL_HEAD()  { return idx(Role.cursor); }
	private @property int COL_CTRL()  { return idx(Role.text); }
	private @property int COL_SCROLL_TRACK() { return idx(Role.soundeditScrollTrack); }
	private @property int COL_SCROLL_THUMB() { return idx(Role.soundeditScrollThumb); }
	private @property int COL_SEL_WASH() { return idx(Role.soundeditSelection); }
	private @property int COL_SEL_EDGE() { return idx(Role.soundeditSelEdge); }
	private @property int COL_DIM()      { return idx(Role.soundeditDim); }
	private @property int COL_DIMFILL()  { return idx(Role.soundeditDim); }
	private enum int COL_SEP      = BaseColor.darkgray;
	private enum int COL_AXIS     = BaseColor.darkgray;
	private enum int COL_CURVE    = BaseColor.lightgreen;
	private enum int COL_TRACE    = BaseColor.lightgreen;
	private enum int COL_LOOP     = BaseColor.orange;
	private enum int COL_LOOPLINE = BaseColor.gray;
	private enum int COL_TRACKSTEP = BaseColor.darkgray;
	private enum int COL_PULSE_FILL = BaseColor.blue;
	private enum int COL_PULSE_LINE = BaseColor.lightblue;
	private enum int COL_FILT_LINE  = BaseColor.lightred;
	private enum int COL_TRIGGER  = BaseColor.red;
	private enum int COL_STEPSEL  = BaseColor.white;   // §20 P4b-2 selected-step outline
	private enum int COL_RESTART  = BaseColor.cyan;
	private enum int COL_RSTFILL  = BaseColor.brown;
	private enum int COL_RSTCURVE = BaseColor.lightred;
	private enum int COL_RES      = BaseColor.yellow;
	private enum int COL_FREQ_REL = BaseColor.lightgreen;
	private enum int COL_FREQ_ABS = BaseColor.cyan;
	private enum int GLYPH_BLOCK  = 197;
	private enum int GLYPH_DOTS   = 6 * 32 + 16;   // font glyph 208 — sparse dots (scroll track)

	// §21 P4c step-box edges + endpoint handles: a subtle idle colour, and YELLOW when the
	// pointer hovers a grabbable edge/handle or a drag is active (the affordance the user
	// asked for). BOX_HIT_PX/END_HIT_PX are the grab radii (device px).
	private enum int COL_BOX_IDLE = BaseColor.gray;
	private enum int COL_BOX_HOT  = BaseColor.yellow;
	private enum int BOX_HIT_PX   = 5;   // horizontal grab zone around a box edge
	private enum int DUR_HIT_PX   = FONT_X; // one text cell: mouse coordinates are cell-granular
	private enum int END_HIT_PX   = 6;   // radius around a value endpoint handle
	// §21 P4c loop lines usually sit ON a step boundary (a loop-back target = a step
	// start), so the loop marker and a box edge share the same X. Split them by Y: the
	// loop grip owns the TOP cell-ROW of the band, the resize edges everything below it.
	// (Mouse input is cell-granular — 14px — so a sub-row strip would be unhittable.)

	// §10.1 filter cutoff fill/line colour per active mode (b0 & 0x70), C64 palette
	// indices in the standard order. -1 = no mode (filter off -> empty band).
	private static int filterModeColor(int mode) {
		switch(mode & 0x70) {
			case 0x10: return BaseColor.red;        // LP
			case 0x20: return BaseColor.green;      // BP
			case 0x40: return BaseColor.lightblue;  // HP
			case 0x30: return BaseColor.orange;     // LP+BP
			case 0x60: return BaseColor.cyan;       // BP+HP
			case 0x50: return BaseColor.purple;     // LP+HP
			case 0x70: return BaseColor.gray;       // LP+HP+BP
			default:   return -1;  // none      -> filter off
		}
	}
	private static string filterModeName(int mode) {
		string s;
		if(mode & 0x10) s ~= "LP";
		if(mode & 0x20) s ~= "BP";
		if(mode & 0x40) s ~= "HP";
		return s.length ? s : "off";
	}
	// R58 uses one absolute cutoff axis. LP/BP/HP are response silhouettes around
	// that same value, never separate value lanes.
	struct FilterRegions {
		int mode, cutoff, top, bottom, y;
		bool lp, bp, hp;
		int lpTop, lpBottom, bpTop, bpBottom, hpTop, hpBottom;
	}
	private int filterCutoffY(ref Geo g, int cutoff) {
		int top, bottom; bandBox(g, 4, top, bottom);
		int span = max(1, bottom - top - 1);
		return bottom - 1 - cast(int)lround(
			cast(double)clampInt(cutoff, 0, 2047) * span / 2047.0);
	}
	// Inverse of filterCutoffY at an exact band pixel row. A live drag passes the real
	// mouse pixel (see dragPixelY): the band is only ~5 character rows tall, so a cell
	// centre reaches barely 5 of the 2048 cutoff values.
	private int filterCutoffValueAtPixel(ref Geo g, int py, bool clampValue = true) {
		int top, bottom; bandBox(g, 4, top, bottom);
		int span = max(1, bottom - top - 1);
		int value = cast(int)lround(cast(double)(bottom - 1 - py) * 2047 / span);
		return clampValue ? clampInt(value, 0, 2047) : value;
	}
	private int filterCutoffValue(ref Geo g, int cellY, bool clampValue = true) {
		return filterCutoffValueAtPixel(g, cellY * FONT_Y + FONT_Y / 2, clampValue);
	}
	private FilterRegions filterRegions(ref Geo g, int mode, int cutoff) {
		FilterRegions r;
		r.mode = mode & 0x70; r.cutoff = clampInt(cutoff, 0, 2047);
		bandBox(g, 4, r.top, r.bottom);
		r.y = filterCutoffY(g, r.cutoff);
		r.lp = !!(r.mode & 0x10); r.bp = !!(r.mode & 0x20); r.hp = !!(r.mode & 0x40);
		r.lpTop = r.y; r.lpBottom = r.bottom - 1;
		int half = (r.bottom - r.top) / 6;
		r.bpTop = max(r.top, r.y - half);
		r.bpBottom = min(r.bottom - 1, r.y + half);
		r.hpTop = r.top; r.hpBottom = r.y;
		return r;
	}

	// §9.3 Wave band = 8 stacked SID control-bit lanes. Indexed by BIT NUMBER 0..7
	// (b0 Gate .. b7 Noise); the lanes are stacked b7 at the TOP down to b0 at the
	// bottom. Distinct palette colour + 3-char label per bit.
	private static immutable int[8]    BITLANE_COL = [
		BaseColor.lightgreen, BaseColor.lightblue, BaseColor.orange, BaseColor.purple,
		BaseColor.cyan, BaseColor.green, BaseColor.yellow, BaseColor.lightgray];
	private static immutable string[8] BITLANE_LBL = ["Gate","Sync","Ring","Test","Tri","Saw","Pulse","Noise"];

	// Left parameter column: fixed set of rows, cursor moved with Up/Down. The
	// scalar/envelope rows are EDITABLE (P4a) with Left/Right; the pointer rows
	// (Waveform/Wave/Pulse/Filter ptr) stay display-only — programs are edited via the
	// graphs in P4b/c, never by hand-poking a pointer. Row indices are named so the
	// editable/write-back switch and the ADSR-curve mapping never use magic numbers.
	private enum int ROW_ATTACK = 0, ROW_DECAY = 1, ROW_SUSTAIN = 2, ROW_RELEASE = 3,
		ROW_WAVEFORM = 4, ROW_WAVEPTR = 5, ROW_PULSEPTR = 6, ROW_FILTPTR = 7,
		ROW_RESTART = 8, ROW_GATE = 9, ROW_HRWAVE = 10, ROW_HRSR = 11,
		ROW_JAMCHANNEL = 12, ROW_GATEHOLD = 13, ROW_DURATIONUNIT = 14;
	private enum int PARAM_ROWS = 15;
	private int paramCursor;
	// R40/R41/R50: one explicit duration unit controls how sweep edges snap and how
	// the fixed keyjam gate value is interpreted. Rows follow live speed/multiplier;
	// Ticks are raw player calls. Defaulting to the legacy 50-tick authored preview
	// preserves existing songs/gestures; the master flow explicitly selects 4 Rows.
	private bool durationRows = false;
	private int durationValue = 50;
	private int keyjamChannel = 0;

	// §19 P4a ADSR-curve drag: which handle (ADSR_*) the user grabbed on the ADSR band,
	// and whether a handle drag is in progress. One insertUndo is taken at press
	// (clickedAt), the byte(s) are rewritten each draggedTo tick (curve + column redraw
	// from the bytes automatically), and the held note is re-triggered once at release.
	private enum int ADSR_ATTACK = 0, ADSR_DECAY = 1, ADSR_SUSTAIN = 2, ADSR_RELEASE = 3;
	private enum int ADSR_HIT_PX = 9;      // handle grab radius (device pixels; ~one cell)

	// A drag "gesture" state machine. The ten mouse drags are mutually exclusive, so at
	// most one is in progress at a time; activeGesture holds it (null = none). The base
	// folds the shared boilerplate: the ONE undo snapshot on first motion (gated by
	// `moved`), the per-tick update, and the re-trigger-if-moved teardown at release.
	// Nested + non-static so update()/onFirstMotion() reach outer SoundEditor members
	// (snapshotInstruments, adsrDragUpdate, retriggerIfSounding) directly.
	private abstract class DragGesture {
		bool moved;                              // replaces each Xmoved: a byte was written this gesture
		abstract bool onFirstMotion();           // snapshot/ownership; false = abort the drag
		abstract void update(ref Geo g, int x, int y);
		void end() {}                            // extra teardown (default none)
		bool retriggersOnMove() { return true; } // re-trigger the held note on release if moved
		// Copy-on-write fork remaps SweepTable row indices; each sweep gesture overrides
		// this to remap its OWN folded row field(s) via remapForkedSweepRow. No-op default.
		void remapRows() {}
	}
	private DragGesture activeGesture;           // null = no drag in progress

	private final class AdsrDrag : DragGesture {
		int handle;
		this(int h) { handle = h; }
		override bool onFirstMotion() { snapshotInstruments(); return true; }
		override void update(ref Geo g, int x, int y) { adsrDragUpdate(g, x, y, handle); }
	}

	// Silent pre-keyjam ADSR truth. The selected reSID backend renders this isolated
	// trace; the cache changes only when its authored inputs change after a completed
	// gesture. During a drag the previous trace remains visible and no render occurs.
	private ubyte[] silentEnvPreview;
	private int silentEnvGeneration = 0;
	private int silentEnvIns = -1, silentEnvAd = -1, silentEnvSr = -1;
	private int silentEnvGate = -1, silentEnvMult = -1, silentEnvBackend = -1;
	private int silentEnvNote = -1;

	// §20 P4b-1 pulse/filter program LEVEL drag: a vertical grab inside the Pulse
	// (band 3) or Filter (band 4) plot region rewrites the SweepTable row active at
	// the grabbed frame — its init byte b2 (pulse width 0..4095 nibble-swapped, or
	// filter cutoff 0..2047 >> 3) — so the sweep starts at the dragged level. table
	// 0 = pulse, 1 = filter; row = the SweepTable row being edited (from the sim's
	// rowOf[frame]); moved gates the ONE undo snapshot per gesture (first drag tick).
	private final class SweepLevelDrag : DragGesture {
		int table, row;
		this(int t, int r) { table = t; row = r; }
		override bool onFirstMotion() { return beginSweepDragMutation(table, clampedIns()); }
		override void update(ref Geo g, int x, int y) { sweepLevelDragUpdate(g, y, table, row); }
		override void remapRows() { row = remapForkedSweepRow(row); }
	}
	// Shared ownership is resolved non-modally on the first mutation: copy-on-write by
	// default, or in-place only while the visible Linked edits mode is active.
	// Copy-on-write is the safe default. Linked editing is explicit and scoped to the
	// active sound; replacing one of its programmes or changing instrument resets it.
	private int linkedEditKind = -1;   // 0 Pulse, 1 Filter, 2 Wave
	private int linkedEditStart = -1;
	private int[0x40] lastSweepForkMap;

	// §20 P4b-2 SELECTED STEP: a plain CLICK (press+release, no motion) inside the Pulse
	// (0) or Filter (1) band selects the SweepTable row active at that frame; a bright
	// outline is drawn on that step's frame span. Ins/Del then insert/delete a row via the
	// ct.purge row-ops. selectedSweepTable = -1 means no step selected; selecting in one
	// band clears the other; switching instrument clears it (the row index is table-local).
	private int selectedSweepTable = -1;
	private int selectedSweepRow = -1;
	// §21 P4c(v3) MULTI-block selection: left-click sets the anchor (selectedSweepRow) and
	// this extent to the same row; Shift-left-click sets the extent to another block, so the
	// consecutive program steps between anchor and extent are all selected. A drag on a
	// multi-selection sets the shared JOIN(s) between those blocks to one value (each join:
	// left block's END + right block's START meet at the dragged level).
	private int selectedSweepRowEnd = -1;
	// §20 P4b-2 LOOP-MARKER drag: grabbing the subtle loop line (or, for a stopping
	// program, its end marker) drags the program's loop-BACK point. sweepLoopCloseRow =
	// the row whose b3 jump we rewrite (the loop-closing / terminal row); dragging sets it
	// to the SweepTable row active at the dragged frame (converting a $7f stop into a loop
	// if needed). moved gates the ONE undo snapshot per gesture (first drag tick).
	private final class SweepLoopDrag : DragGesture {
		int table, closeRow;
		this(int t, int cr) { table = t; closeRow = cr; }
		override bool onFirstMotion() { return beginSweepDragMutation(table, clampedIns()); }
		override void update(ref Geo g, int x, int y) { sweepLoopDragUpdate(g, x, table, closeRow); }
		override void remapRows() { closeRow = remapForkedSweepRow(closeRow); }
	}

	// §20 P4b-3 filter RESONANCE drag: a vertical grab on the resonance overlay line in
	// the Filter band (band 4) rewrites the b1 HIGH nibble (res 0..15, low nibble =
	// routing preserved) of the CONFIG row governing the grabbed frame. Distinct from the
	// P4b-1 cutoff-level drag (hit-tested BEFORE it). row = the config row whose b1 we
	// edit; moved gates the ONE undo snapshot per gesture (first drag tick).
	private final class SweepResDrag : DragGesture {
		int row, targetRow;
		this(int r, int t) { row = r; targetRow = t; }
		override bool onFirstMotion() {
			int ins = clampedIns();
			if(!beginSweepDragMutation(1, ins)) return false;
			// A later block may materialize a CONFIG row, which shifts global table refs.
			row = ensureResConfigForTarget(ins, targetRow, row);
			return true;
		}
		override void update(ref Geo g, int x, int y) { sweepResDragUpdate(g, y, row); }
		override void remapRows() {
			row = remapForkedSweepRow(row);
			targetRow = remapForkedSweepRow(targetRow);
		}
	}

	// §21 P4c step-BOX handles (ADSR-style, for the Pulse/Filter bands). A step is drawn
	// as a box spanning its frame window; its EDGES resize the duration and its VALUE
	// ENDPOINTS shape the ramp. Edges/handles light YELLOW on hover / while active.
	//  - DURATION drag (a box left/right edge): rewrites a row's b0 duration (low 7 bits).
	//    The RIGHT edge resizes THIS step; the LEFT edge resizes the PREVIOUS step (their
	//    shared boundary). row = the row whose b0 we edit; anchorF = the FIXED frame the
	//    resized step starts at, so width = draggedFrame - anchor.
	//    viewStart/viewEnd/viewLocked: Auto-Fit normally follows changing programme
	//    length. During one resize gesture that would move the axis between mouse-motion
	//    events and amplify/slow the next delta. Keep the press-time axis fixed until
	//    release so the edge follows the mouse.
	//    targetExit/legalExit/clipped: preserve the authored (unwrapped) endpoint while a
	//    pulse duration changes. If the shorter duration would require an illegal slope,
	//    remember both values so mouse-up can explain the deterministic clamp instead of
	//    silently changing the graph shape.
	private final class SweepDurDrag : DragGesture {
		int table, row, anchorF;
		double viewStart, viewEnd;
		bool viewLocked;
		bool unitClipped;
		int targetExit, legalExit;
		bool clipped;
		this(int t, int r, int f0) {
			table = t; row = r; anchorF = f0;
			viewStart = viewport.startTick; viewEnd = viewport.endTick;
			viewLocked = true;
			unitClipped = false;
			int scale = t == 0 ? 1 : 2;
			targetExit = sweepStepEnterVal(t, r)
				+ sweepSignedSlope(t, r) * scale * sweepRampApplications(t, r);
			legalExit = targetExit;
			clipped = false;
		}
		override bool onFirstMotion() { return beginSweepDragMutation(table, clampedIns()); }
		override void update(ref Geo g, int x, int y) { sweepDurDragUpdate(g, x, this); }
		override void remapRows() { row = remapForkedSweepRow(row); }
		override void end() {
			viewLocked = false;
			if(moved && unitClipped) {
				UI.statusline.display("Row duration limited to the table maximum of 128 ticks.");
			} else if(moved && clipped && (table == 0 || table == 1)) {
				auto k = sweepKind(table);
				UI.statusline.display(format(
					"%s endpoint limited: requested $%03X; legal $%03X.",
					k.name, targetExit & k.mask, legalExit & k.mask));
			}
		}
	}
	//  - ENDPOINT drag (a value handle at the step's start/end): START translates the
	//    segment (init b2); END tilts it (slope b1 + direction). isEnd picks which.
	//    winding = authored unwrapped exit minus visible wrapped exit.
	private final class SweepEndDrag : DragGesture {
		int table, row;
		bool isEnd;
		int winding;
		this(int t, int r, bool e, int w) { table = t; row = r; isEnd = e; winding = w; }
		override bool onFirstMotion() { return beginSweepDragMutation(table, clampedIns()); }
		override void update(ref Geo g, int x, int y) { sweepEndDragUpdate(g, y, table, row, isEnd, winding); }
		override void remapRows() { row = remapForkedSweepRow(row); }
	}
	//  - JOIN drag (only when both adjacent blocks are selected): edits the one clicked
	//    shared boundary (left END + right START), never unrelated joins in the range.
	private final class SweepJoinDrag : DragGesture {
		int leftRow, rightRow;
		this(int l, int r) { leftRow = l; rightRow = r; }
		override bool onFirstMotion() { return beginSweepDragMutation(selectedSweepTable, clampedIns()); }
		override void update(ref Geo g, int x, int y) { sweepJoinDragUpdate(g, y, leftRow, rightRow); }
		override void remapRows() {
			leftRow = remapForkedSweepRow(leftRow);
			rightRow = remapForkedSweepRow(rightRow);
		}
	}
	// §20 P4b-3 the filter mode chip cycles through the LP/BP/HP combos (§10.1) writing the
	// first config row's b0 mode bits (0x70). This is the requested cycle order.
	// Wave control-bit editing is deliberately immediate: clicking a lane cell toggles
	// that bit in the row producing the clicked frame. Unlike pulse/filter handles there
	// is no separate selection gesture.
	private static int decodeWaveControl(int raw, int carried) {
		if(raw < 0x10) return carried;       // unchanged / delay override
		if(raw >= 0xe0 && raw <= 0xef) return raw & 0x0f;
		return raw;
	}
	private static ubyte encodeWaveControl(int ctrl) {
		ctrl &= 0xff;
		return cast(ubyte)(ctrl < 0x10 ? (0xe0 | ctrl) : ctrl);
	}
	private static bool representableWaveControl(int ctrl, out ubyte encoded) {
		ctrl &= 0xff;
		// $E0..$EF are the encoded-low form, while $F0..$FF are reserved.  A
		// direct effective value in either range therefore has no lossless W2 byte.
		if(ctrl >= 0xe0) { encoded = 0; return false; }
		encoded = encodeWaveControl(ctrl);
		return true;
	}

	// §11.2 the voice whose real recording feeds the bands this frame (-1 = none),
	// and whether that voice actually has a recording (else the bands fall back to
	// the dimmed table simulation). Recomputed at the top of update().
	private int viewVoice = -1;
	private bool useRec = false;
	// Keep Fit stable across an edit-triggered reSID re-render. Cleared only by a new
	// user-struck keyjam note, not by the internal preview render.
	private int lockedKeyjamFit = 0;
	private int seenKeyjamTrigger = 0;

	// §14.1 mouse-hover probe: the last cell the pointer hovered (screen char-cells),
	// and whether we have a hover position to consider. update() maps it to a frame
	// on the fresh geometry, draws a white vertical probe line + a numeric readout of
	// the register values at that frame, and skips the probe when the cursor is
	// outside the plot region (so leaving the plot clears it).
	private int hoverCellX = -1, hoverCellY = -1;
	private bool hovering = false;
	// Native Alt-H hover help owns the global status line. Keep the semantic target,
	// not the pointer coordinates, so stationary motion never extends its timeout.
	private string hoveredControlAction;
	private static SDL_Cursor* sizeWeCursor;
	private static SDL_Cursor* sizeNsCursor;
	private static SDL_Cursor* sizeAllCursor;
	private enum int CURSOR_NORMAL = 0, CURSOR_HORIZONTAL = 1,
		CURSOR_VERTICAL = 2, CURSOR_BOTH = 3;
	private int editCursor = CURSOR_NORMAL;

	SoundEditorDebugState debugState() {
		return SoundEditorDebugState(
			cast(int)lround(tickMs * 1000.0), trackStepTicks(), visFrames,
			prerollTicks, viewport.startTick, viewport.endTick, viewport.userZoomed,
			hasSelection, useRec, selStartTick, selEndTick, editCursor,
			inputKeyjam.previewInstrument(), inputKeyjam.previewNote(),
			durationRows, durationValue, configuredGateTicks(), keyjamChannel + 1);
	}

	// Read-only probe of the pitch mapping for the selected wave row (see the struct).
	SoundEditorPitchProbe pitchProbe() {
		Geo g = layout();
		SoundEditorPitchProbe p;
		bandBox(g, 2, p.bandTop, p.bandBottom);
		p.bandHeight = p.bandBottom - p.bandTop;
		p.plotLeft = g.plotX0px;
		p.plotRight = g.plotX0px + g.plotWpx;
		int ins = clampedIns();
		p.latchedScale = waveGraphScale;
		p.scale = freqBandScale(ins);
		p.dragging = waveGraphDragging;
		p.row = waveGraphDragging ? waveGraphRow : selectedWaveRow;
		if(p.row >= 0 && p.row < 256) {
			p.value = song.waveTable[p.row];
			p.pitch = (p.value >= 0x80 && p.value <= 0xdf) ? p.value & 0x7f : p.value;
		} else p.value = p.pitch = -1;
		p.drawnY = p.pitch >= 0 ? yForPitch(p.bandTop, p.bandBottom, p.scale, p.pitch) : -1;
		p.mouseY = mousePixelY;
		p.valueAtMouseY = pitchForY(p.bandTop, p.bandBottom, p.scale, p.mouseY);
		p.stepPixels1000 = p.scale > 0 ? p.bandHeight * 1000 / p.scale : 0;
		p.clampedByScale = p.pitch > p.scale;
		return p;
	}

	final bool commandEnabled(string actionId) {
		int ins = clampedIns();
		bool waveSelected = selectedWaveNormal(ins);
		bool sweepSelected = selectedSweepTable >= 0 && selectedSweepRow >= 1;
		bool filterSelected = selectedSweepTable == 1 && selectedSweepRow >= 1;
		bool configSelected = filterSelected
			&& (song.filterTable[selectedSweepRow * 4] & 0x80) != 0;
		switch(actionId) {
			case "se_zoom_out": case "se_zoom_in": case "se_fit": return true;
			case "se_selection": return hasSelection;
			case "se_add": return (sweepSelected && !sweepTableFull(selectedSweepTable))
				|| waveSelected;
			case "se_delete": return sweepSelected || waveSelected;
			case "se_stop": return sweepSelected;
			case "se_type": return filterSelected;
			case "se_carry": return sweepSelected && !configSelected;
			case "se_new": return song.tWave.seekTableEnd() + 7 <= 256
				&& song.tPulse.seekTableEnd() <= 0x3e
				&& song.tFilter.seekTableEnd() + 1 <= 0x3e;
			case "se_wave_prev": return waveSelected
				&& selectedWaveRow > song.instrumentTable[ins + 7 * 48];
			case "se_wave_next": return waveSelected && selectedWaveRow + 1 <
				waveCloseRow(song.instrumentTable[ins + 7 * 48]);
			case "se_wave_1": case "se_wave_2": case "se_wave_loop": return waveSelected;
			case "se_res_down": case "se_res_up": return configSelected;
			case "se_lp": case "se_bp": case "se_hp": case "se_route":
				return filterControlConfigRow(ins) >= 0;
			case "se_start_down": case "se_start_up": case "se_end_down":
			case "se_end_up": case "se_duration_down": case "se_duration_up":
				return sweepSelected;
			case "se_linked": return true;
			case "se_octave_down": case "se_octave_up":
			case "se_instrument_prev": case "se_instrument_next": return true;
			default: return false;
		}
	}

	private int selectedOwnershipKind(int ins) {
		if(selectedSweepTable >= 0 && selectedSweepRow >= 1) return selectedSweepTable;
		if(selectedWaveNormal(ins)) return 2;
		return -1;
	}
	private int ownershipStart(int kind, int ins) {
		if(kind == 0) return song.instrumentTable[ins + 5 * 48];
		if(kind == 1) return song.instrumentTable[ins + 4 * 48];
		if(kind == 2) return song.instrumentTable[ins + 7 * 48];
		return -1;
	}
	private bool linkedEditActive(int kind, int ins) {
		return kind >= 0 && linkedEditKind == 3 && linkedEditStart == ins;
	}
	private void toggleLinkedEdits() {
		int ins = clampedIns();
		if(linkedEditKind == 3 && linkedEditStart == ins)
			linkedEditKind = linkedEditStart = -1;
		else {
			linkedEditKind = 3;
			linkedEditStart = ins;
		}
		UI.statusline.display(linkedEditKind == 3 && linkedEditStart == ins
			? "Linked edits active: all sounds using this programme will change."
			: "Copy-on-write edits active.");
	}
	final string debugOwnershipMode() {
		int ins = clampedIns();
		return linkedEditKind == 3 && linkedEditStart == ins ? "linked" : "fork";
	}

	final SoundEditorControlDebug[] debugControls() {
		Geo g = layout();
		SoundEditorControlDebug[] result;
		auto controls = zoomButtons(g);
		// Enum values are stable action identities, not layout order. Report the
		// controls in their visible left-to-right order so this semantic oracle
		// verifies the same logical grouping a user sees.
		bool[18] emitted;
		foreach(_; 0 .. 18) {
			int next = -1;
			foreach(i, ref button; controls)
				if(!emitted[i] && button.x0 >= 0
						&& (next < 0 || button.x0 < controls[next].x0))
					next = cast(int)i;
			if(next < 0) break;
			emitted[next] = true;
			result ~= SoundEditorControlDebug(controlActionId(next),
				controls[next].x0, controls[next].x1, controls[next].row,
				controls[next].enabled);
		}
		if(filterModeChipVisible(g)) {
			auto modes = filterModeButtons(clampedIns(), g);
			static immutable string[3] ids = ["se_lp", "se_bp", "se_hp"];
			foreach(i, ref button; modes)
				result ~= SoundEditorControlDebug(ids[i], button.x0, button.x1,
					button.row, button.enabled);
		}
		if(filterRouteChipVisible(g)) {
			auto route = filterRouteButton(clampedIns(), g);
			result ~= SoundEditorControlDebug("se_route", route.x0, route.x1, route.row,
				route.enabled);
		}
		return result;
	}

	final SoundEditorWaveAddDebug debugWaveAdd() {
		Geo g = layout();
		return waveAddTarget(clampedIns(), g);
	}

	final SoundEditorWaveLoopDebug debugWaveLoopGeometry() {
		Geo g = layout();
		return waveLoopGeometry(clampedIns(), g);
	}

	final SoundEditorSweepLoopDebug debugSweepLoopGeometry(int table) {
		SoundEditorSweepLoopDebug result;
		if(table < 0 || table > 1) return result;
		Geo g = layout();
		int ins = clampedIns();
		auto k = sweepKind(table);
		int start = song.instrumentTable[ins + k.insCol * 48];
		SweepSim sim = sweepSim(k, start);
		auto shape = sweepLoopGeometry(table, g, sim);
		result.looped = shape.looped; result.stopped = shape.stopped;
		result.startVisible = shape.startVisible; result.endVisible = shape.endVisible;
		result.startLeft = shape.startLeft; result.startRight = shape.startRight;
		result.endLeft = shape.endLeft; result.endRight = shape.endRight;
		result.top = shape.top; result.bottom = shape.bottom;
		return result;
	}

	struct EnvelopePreviewDebug {
		int generation;
		int note;
		const(ubyte)[] envelope;
	}

	// Headless read-only oracle for the same production trace drawAdsrBand consumes.
	final EnvelopePreviewDebug debugEnvelopePreview(int ticks) {
		if(ticks < 1) ticks = 1;
		if(ticks > MAX_CONTENT) ticks = MAX_CONTENT;
		ensureSilentEnvelopePreview(ticks);
		int n = min(ticks, cast(int)silentEnvPreview.length);
		return EnvelopePreviewDebug(silentEnvGeneration, silentEnvNote,
			silentEnvPreview[0 .. n]);
	}

	struct FilterStepDebug {
		int row, mode, frame0, frame1, x0, x1, cutoff0, cutoff1, y0, y1, handles;
	}
	final FilterRegions debugFilterShape(int mode, int cutoff) {
		Geo g = layout();
		return filterRegions(g, mode, cutoff);
	}
	// Read-only oracle for the exact one-axis step geometry. Coordinates are UI cells
	// so usage tests feed the single production handle back through hover/drag.
	final FilterStepDebug[] debugFilterShapes() {
		FilterStepDebug[] result;
		int ins = clampedIns();
		SweepSim s = simFilter(song.instrumentTable[ins + 4 * 48]);
		Geo g = layout();
		bool[0x40] seen;
		foreach(index, row; s.rowOf) {
			if(row < 1 || row >= 0x40 || seen[row]
					|| (song.filterTable[row * 4] & 0x80)) continue;
			seen[row] = true;
			int a = cast(int)index, b = a + 1;
			while(b < s.rowOf.length && s.rowOf[b] == row) ++b;
			int mode = a < s.modeOf.length ? s.modeOf[a] & 0x70 : 0;
			int ys = filterCutoffY(g, s.val[a]);
			int ye = filterCutoffY(g, s.val[b - 1]);
			result ~= FilterStepDebug(row, mode, a, b,
				viewport.xForFrame(g, a) / FONT_X, viewport.xForFrame(g, b) / FONT_X,
				s.val[a], s.val[b - 1], ys / FONT_Y, ye / FONT_Y, 1);
		}
		return result;
	}

	// §12 dynamic X window, computed ONCE per draw at the top of update() and threaded
	// through xForFrame + every band so they all share the exact same zoom. visFrames
	// = the auto-fitted post-trigger span (frames); totalFrames = pre-roll + visFrames.
	private int visFrames = MIN_VIS;
	// §17.3 right edge the viewport may zoom/scroll out to (>= visFrames): far enough
	// that the release-tail dot is always reachable past the fitted note.
	private int contentMaxFrames = MIN_VIS;
	private int totalFrames = RESTART_FRAMES + MIN_VIS;
	// §17/left-edge fix: the restart pre-roll is only as wide as the ACTUAL restart
	// phase for this instrument (restartFramesFor(ins), ~2-3 ticks) — NOT a fixed
	// RESTART_FRAMES=10. So the note data begins right at the plot's left edge with
	// just a thin restart strip before the trigger, instead of ~19% of the width.
	// Recomputed per draw in update() (where ins is known) and used as the axis lower
	// bound everywhere (fit / clamp / total / ADSR restart wash / scrollbar).
	private int prerollTicks = 2;

	// §16.2 real-time axis, refreshed at the top of update() from the live player
	// multiplier: tickMs = the real duration of one axis index (one player tick).
	// Every ms<->tick conversion (ADSR ms tables, the scale label, the probe readout)
	// goes through tickMs so all bands + label agree at any multiplier.
	// §19: nominalGateFrames is the ADSR-estimate sustain hold, in axis units = 50
	// "frames" as shown on the scale label. It drives the estimate curve, the drag
	// handles, the hover Env% helper, and the idle window-fit — one constant keeps
	// them all consistent at 50.
	private float tickMs = SCREEN_FRAME_MS;
	private int nominalGateFrames = 50;

	// §17.1 "where are we looking on the timeline": the zoomable/pannable VIEWPORT
	// over the shared tick axis. [startTick, endTick] (a sub-window of the whole
	// note) maps across plotWpx instead of always the whole note, so zoom = narrow
	// the window, pan = slide it, and every band/playhead/marker/loop-line/probe
	// follows for free (they all go through viewport.xForFrame / tickForPixel).
	// Default = FIT = the whole note incl. the restart pre-roll
	// ([-prerollTicks, visFrames]); viewport.userZoomed keeps a user's zoom across
	// instrument/recording changes until they hit Fit. Ticks are floats so
	// repeated ×2/×0.5 zoom steps + panning stay smooth; the axis clamps to
	// [-prerollTicks, contentMaxFrames] with a MIN_VIEW_SPAN floor.
	//
	// This is a self-contained value: every method that needs the axis bounds
	// (prerollTicks/visFrames/contentMaxFrames) or the pixel geometry (Geo) takes
	// them as parameters rather than reaching back into SoundEditor, so the whole
	// timeline-window concept lives in one place. It is deliberately a mutable
	// struct kept as ONE field below (`viewport`) -- every mutation must go through
	// that field directly (e.g. `viewport.zoomBy(...)`); never copy it into a
	// local and mutate the copy, or the change is silently lost.
	private struct Viewport {
		double startTick = -RESTART_FRAMES;
		double endTick = MIN_VIS;
		bool userZoomed = false;
		// Integer visible-frame bounds derived from the ticks each draw (see
		// refresh()), so band loops only emit the frames actually on screen (no
		// off-view pile-up at the clamped plot edges). frameLo = floor(startTick),
		// frameHi = ceil(endTick)+1.
		int frameLo = 0, frameHi = MIN_VIS;

		// §9.1/§12.2/§17.1 THE one true tick->pixel map every band shares. Frame/
		// tick f may be negative (pre-roll/restart); f=0 is the note-trigger
		// divider. The returned pixel is CLAMPED to the plot box so a partially-
		// off-view edge frame lands exactly at the plot edge; band loops
		// additionally skip fully-off-view frames (see visRange) so nothing piles up.
		int xForFrame(ref Geo g, double f) {
			double span = endTick - startTick;
			if(span < 1e-6) span = 1e-6;
			double p = (f - startTick) / span;   // 0..1 across the plot width
			if(p < 0) p = 0;
			if(p > 1) p = 1;
			return g.plotX0px + cast(int)lround(p * g.plotWpx);
		}

		// §17.1 inverse of xForFrame: the (fractional) tick at absolute pixel
		// column px.
		double tickForPixel(ref Geo g, int px) {
			double span = endTick - startTick;
			return startTick + cast(double)(px - g.plotX0px) * span / g.plotWpx;
		}

		// §17.1 True when tick/frame f falls within the current viewport (so a
		// single vertical marker at f should be drawn; off-view markers are
		// skipped rather than clamped to a plot edge, which would misplace them).
		bool frameInView(double f) {
			return f >= startTick - 1e-6 && f <= endTick + 1e-6;
		}

		// §17.1 Visible integer-frame range for a band loop of length n: only the
		// frames whose cell intersects the viewport (plus a one-frame margin each
		// side so a partially-visible edge cell still draws). Clamped to [0, n).
		void visRange(int n, out int lo, out int hi) {
			lo = frameLo; hi = frameHi;
			if(lo < 0) lo = 0;
			if(hi > n) hi = n;
			if(hi < lo) hi = lo;
		}

		// §17.1 Reset the viewport to FIT (the whole note incl. the restart
		// pre-roll) -- the v12 default, and what [Fit]/Home restore. Called
		// whenever !userZoomed so the axis keeps auto-fitting as the
		// instrument/recording changes.
		void fit(int prerollTicks, int visFrames) {
			startTick = -prerollTicks;
			endTick = visFrames;
		}

		// §17.1/§17.3 Clamp the (user) viewport within [-prerollTicks,
		// contentMaxFrames] and enforce the MIN_VIEW_SPAN floor, keeping the view
		// centre where possible.
		void clamp(int prerollTicks, int contentMaxFrames) {
			double lo = -prerollTicks;
			double hi = contentMaxFrames;   // §17.3 allow zoom/scroll past the note to the release tail
			double full = hi - lo;
			if(full <= MIN_VIEW_SPAN) { startTick = lo; endTick = hi; return; }
			double span = endTick - startTick;
			if(span < MIN_VIEW_SPAN) span = MIN_VIEW_SPAN;
			if(span > full) span = full;
			double centre = (startTick + endTick) / 2.0;
			startTick = centre - span / 2.0;
			endTick = centre + span / 2.0;
			if(startTick < lo) { endTick += lo - startTick; startTick = lo; }
			if(endTick > hi)   { startTick -= endTick - hi; endTick = hi; }
			if(startTick < lo) startTick = lo;
		}

		// §17.3 Zoom the viewport about its centre by `factor` (>1 = zoom out,
		// <1 = in), clamped. Marks the view as user-zoomed so it survives
		// instrument changes until Fit.
		void zoomBy(double factor, int prerollTicks, int contentMaxFrames) {
			double centre = (startTick + endTick) / 2.0;
			double span = (endTick - startTick) * factor;
			if(span < MIN_VIEW_SPAN) span = MIN_VIEW_SPAN;
			startTick = centre - span / 2.0;
			endTick = centre + span / 2.0;
			userZoomed = true;
			clamp(prerollTicks, contentMaxFrames);
		}

		// §17.3 Pan the viewport by `dticks` (keeping its span), clamped.
		void panBy(double dticks, int prerollTicks, int contentMaxFrames) {
			startTick += dticks;
			endTick += dticks;
			userZoomed = true;
			clamp(prerollTicks, contentMaxFrames);
		}

		// §17.3 Zoom the viewport to [selStart, selEnd] (the current selection).
		// Caller is responsible for checking there IS a selection first.
		void zoomToSelection(int selStart, int selEnd, int prerollTicks, int contentMaxFrames) {
			startTick = selStart;
			endTick = selEnd;
			userZoomed = true;
			clamp(prerollTicks, contentMaxFrames);
		}

		// Recompute the integer visible-frame bounds (frameLo/frameHi) from the
		// current ticks. Called once per draw after the ticks settle for the frame.
		void refreshFrameBounds() {
			frameLo = cast(int)floor(startTick);
			frameHi = cast(int)ceil(endTick) + 1;
		}
	}
	private Viewport viewport;

	// §17.2 tick-snapped SELECTION [selStartTick, selEndTick] (ordered, snapped to the
	// integer tick grid = the native per-tick rate). hasSelection when a drag produced
	// a range; a plain click (no drag) or Backspace clears it. Stored in tick units so
	// it stays put under zoom/pan (drawn through xForFrame).
	private bool hasSelection = false;
	private int selStartTick = 0, selEndTick = 0;
	// Transient left-drag state (button held): anchor tick + whether motion occurred.
	private bool selecting = false;
	private bool dragMoved = false;
	private int dragAnchorTick = 0;
	// A left-press that landed on a zoom-control button (so the paired release neither
	// finalises nor clears a selection).
	private bool clickWasButton = false;
	// §17.3 zoom-control button feedback: which button the pointer hovers (-1 = none,
	// updated by hoverAt) and which one is currently held down (-1 = none, set on
	// press, fired on release over the same button). Drive the Button widget's hover/
	// pressed styles so the user sees what the click will do.
	private int hoveredBtn = -1;
	private int pressedBtn = -1;
	// True while a held button (pressedBtn) still has the pointer over it — drag off
	// and the pressed style drops (the release then cancels instead of firing).
	private bool pressedOver = false;
	// Filter-gutter buttons use the same arm-on-press / fire-on-release contract as
	// the graph controls.  The semantic action id keeps layout, hover and release
	// hit-testing independent of the currently rendered label.
	private string pressedFilterAction = "";
	private bool pressedFilterOver = false;
	// Wave-program row selected by the graph control strip. This is an absolute
	// wavetable row, matching $7F loop targets and the raw-table presentation.
	private int selectedWaveRow = -1;
	private bool waveGraphDragging = false;
	private bool waveGraphMoved = false;
	private bool waveGraphAuthorizing = false;
	private int waveGraphRow = -1;
	private int waveGraphField = 0; // 0 pitch (vertical), 1 delay (horizontal)
	private int waveGraphAnchorX = 0, waveGraphAnchorValue = 0;
	// The frequency band's vertical scale auto-fits to the program's largest value, so
	// editing a value would move the axis the value is measured against: the dragged block
	// runs away from the cursor and every other block jumps. Latch the scale at drag start
	// and keep drawing AND hit-testing against it until the gesture ends. -1 = not dragging.
	private int waveGraphScale = -1;
	private bool waveLoopDragging = false;
	private bool waveLoopAuthorizing = false;
	private bool waveLoopMoved = false;
	private int waveLoopCloseRow = -1;
	private int waveLoopIns = -1;
	// A control-lane drag is a paint gesture: its first cell chooses set/clear and every
	// later cell receives that same value. This makes backtracking idempotent and gives
	// the complete stroke one undo snapshot and one release-time preview refresh.
	private bool waveBitPainting = false;
	private bool waveBitChanged = false;
	private bool waveBitDesired = false;
	private int waveBitPaintIns = -1;
	private int waveBitLastRow = -1, waveBitLastBit = -1;

	// §17.4 horizontal-scrollbar drag state. A left-press ON the scrollbar row grabs
	// the thumb; while dragging, the viewport start follows the pointer so the thumb
	// stays under the grab point (span kept constant, clamped). scrollGrabOffset = the
	// tick (on the FULL/Fit axis) under the initial press minus viewport.startTick, so the
	// grab point on the thumb is preserved across the drag.
	private bool scrollDragging = false;
	private double scrollGrabOffset = 0;

	// The screen owns its own keyjam so note keys play while the panel is
	// focused and navigating (the classic editor's global inputKeyjam is
	// bypassed for this window by the Toplevel routing guard).
	private InputKeyjam inputKeyjam;

	this(Rectangle a) {
		super(a);
		expandedBand = -1;   // normal stacked view until a title is double-clicked
		// §10.3 one-glance band table: output, adsr, freq, pulse, filter (weighted
		// 1,1,0.9,0.9,0.9), then the fixed-height wave band. Drives layout() heights
		// and update()'s per-band draw loop.
		bands = [
			BandInfo(1.0f, 0,         (int ins, ref Geo g) { drawOutputBand(g); }),
			BandInfo(1.0f, 0,         &drawAdsrBand),
			BandInfo(0.9f, 0,         &drawFreqBand),
			BandInfo(0.9f, 0,         &drawPulseBand),
			BandInfo(0.9f, 0,         &drawFilterBand),
			BandInfo(0.0f, WAVE_ROWS, &drawWaveBand),   // fixed height; weight unused
		];
		inputKeyjam = new InputKeyjam();
		inputKeyjam.setKeyjamVoice(keyjamChannel);
		inputKeyjam.ensurePreviewBaseline(clampedIns());
		inputKeyjam.setFixedGateTicks(configuredGateTicks());
		seenKeyjamTrigger = audio.player.keyjamNoteTrigger;
	}

	// A newly opened Sound Editor always starts on the leftmost SID voice. The
	// choice remains editable for the duration of that editor session.
	void beginSession() {
		keyjamChannel = 0;
		selectedWaveRow = -1;
		linkedEditKind = linkedEditStart = -1;
		hoveredControlAction = "";
		// Re-fit the frequency axis for a fresh session (it is otherwise grow-only, so a
		// previous session's zoomed-out axis would persist). See freqScaleSticky.
		freqScaleSticky = freqScaleStickyIns = -1;
		syncKeyjamConfiguration();
	}

	// Read-only semantic timing oracle used by the ordered headless usage test.
	int[] debugWaveRows(int frames = 64) {
		WaveFrameSim s = simWaveFrames(song.instrumentTable[clampedIns() + 7 * 48],
			waveTimeForInstrument(clampedIns()));
		return s.rowOf[0 .. min(frames, cast(int)s.rowOf.length)].dup;
	}
	int[] debugWaveControls(int frames = 64) {
		WaveFrameSim s = simWaveFrames(song.instrumentTable[clampedIns() + 7 * 48],
			waveTimeForInstrument(clampedIns()));
		return s.ctrlOf[0 .. min(frames, cast(int)s.ctrlOf.length)].dup;
	}
	int[] debugWaveTranspose(int frames = 64) {
		WaveFrameSim s = simWaveFrames(song.instrumentTable[clampedIns() + 7 * 48],
			waveTimeForInstrument(clampedIns()));
		return s.transOf[0 .. min(frames, cast(int)s.transOf.length)].dup;
	}
	int[2] debugWaveLoop() {
		WaveFrameSim s = simWaveFrames(song.instrumentTable[clampedIns() + 7 * 48],
			waveTimeForInstrument(clampedIns()));
		return [s.loopFrame, s.loopPeriod];
	}

	override @property string contextId() { return Ctx.soundEditor; }

	// §10.4: F12 while the Sound Editor is active shows ITS own help page (not the
	// tracker's global help). The F12 help_dialog action opens
	// HelpDialog(area, activeWindow.contextHelp); pressing F12 again in that dialog
	// falls through to the global HELPMAIN because our title differs (dialogs.d:182).
	override ContextHelp contextHelp() { return ui.help.HELPSOUNDEDITOR; }

	// ---- shared geometry (recomputed each frame from `area`) ----
	private struct Geo {
		int paramX, paramW;     // left parameter column (cells)
		int sepX;               // vertical separator column (cells)
		int labelX;             // band label gutter start (cells)
		int plotX0px, plotWpx;  // shared pixel X origin + width for every band
		int stackTopPx, stackBotPx;
		int[7] bandTopPx;       // 6 bands + trailing bottom bound
		int rawTopRow;          // top border row of the raw-data strip (cells)
		int controlRow;         // §17.3 zoom-control button row (cells)
		int scrollRow;          // reserved for the future horizontal scrollbar (blank)
	}

	// The wave band stacks 8 SID control-bit lanes ONE per character row, so it gets
	// a FIXED height (a weight that merely rounds to ~8 rows is fragile) of WAVE_ROWS
	// character rows at the bottom of the stack; bands 0..4 share the rest by weight.
	private enum int WAVE_ROWS = 9;   // 8 lanes + 1 row of slack for the bandBox inset

	// §10.3 The six stacked bands, top -> bottom, in ONE ordered list: what exists, in
	// what order, and how tall. `weight` sizes the weighted bands (0..4); `fixedRows > 0`
	// marks a fixed-height band (only the wave band); `draw` points at the band's
	// existing draw*Band body. layout() and update() read this instead of open-coded
	// weight arrays / magic band indices. Built once in the constructor.
	private struct BandInfo {
		float weight;                             // relative height weight (weighted bands)
		int fixedRows;                            // >0 => fixed-height (wave); 0 => weighted
		void delegate(int ins, ref Geo g) draw;   // the existing draw*Band method
	}
	private BandInfo[6] bands;

	private struct SweepLoopGeometry {
		bool looped, stopped;
		bool startVisible, endVisible;
		int startLeft, startRight, endLeft, endRight;
		int top, bottom;
	}

	// A sweep "table" is an int: 0 = pulse, 1 = filter. The pulse/filter code paths
	// share almost all of their shape and differ only in these per-kind constants;
	// this resolves them ONCE instead of scattering `table == 0 ? ... : ...`
	// ternaries through every method.
	private struct SweepKind {
		bool isFilter;
		int insCol;    // instrumentTable column: pulse 5, filter 4
		int band;      // stack band index: pulse 3, filter 4
		int maxVal;    // pulse 4095, filter 2047
		int modulus;   // pulse 4096, filter 2048
		int scale;     // pulse 1, filter 2
		int mask;      // pulse 0xfff, filter 0x7ff
		int maxSlope;  // pulse 255, filter 127
		int minSlope;  // pulse -255, filter -128
		string name;   // "Pulse" / "Filter"
		// The live SweepTable data, mutable (same underlying array song.pulseTable/
		// filterTable already alias) so callers can read AND write through it exactly
		// as the old `table == 0 ? song.pulseTable : song.filterTable` ternary did.
		ubyte[] table() { return isFilter ? song.filterTable : song.pulseTable; }
		int seekTableEnd() {
			return isFilter ? song.tFilter.seekTableEnd() : song.tPulse.seekTableEnd();
		}
	}
	// `table` must be provably 0 or 1 here — sentinels like -1 are not valid input.
	private static SweepKind sweepKind(int table) {
		return table == 0
			? SweepKind(false, 5, 3, 4095, 4096, 1, 0xfff, 255, -255, "Pulse")
			: SweepKind(true,  4, 4, 2047, 2048, 2, 0x7ff, 127, -128, "Filter");
	}
	// simPulse/simFilter are instance methods (they read other instance state), so
	// this small dispatcher lives on the class rather than as a SweepKind method.
	private SweepSim sweepSim(SweepKind k, int startRow) {
		return k.isFilter ? simFilter(startRow) : simPulse(startRow);
	}

	// Memoized layout() result. layout() is a pure function of `area` (x/y/width/
	// height) plus compile-time constants FONT_X/FONT_Y — it touches no other
	// state. `area` is only ever assigned once, in the Window base-class
	// constructor, and never mutated afterwards, so comparing the four `area`
	// fields against the values used to build the cache is a safe, sufficient
	// invalidation check (equivalent to invalidating whenever `area` changes).
	private Geo cachedGeo;
	private Rectangle cachedGeoArea;
	private bool geoValid;
	// §22 band expansion: double-clicking a graph band's title maximises it (index into
	// `bands`, 0..4; -1 = normal stack). The others collapse to one-row title strips so
	// you can double-click another to switch or the expanded title to restore. Part of the
	// geo cache key so toggling it recomputes the layout.
	private int expandedBand = -1;
	private int cachedExpandedBand = -2;

	private Geo layout() {
		if(geoValid && cachedExpandedBand == expandedBand
				&& cachedGeoArea.x == area.x && cachedGeoArea.y == area.y
				&& cachedGeoArea.width == area.width && cachedGeoArea.height == area.height)
			return cachedGeo;
		Geo g;
		g.paramX = area.x + 2;
		g.paramW = 26;
		g.sepX   = g.paramX + g.paramW;
		g.labelX = g.sepX + 2;
		int labelW = 8;
		int plotX0c = g.labelX + labelW;
		int plotEndC = area.x + area.width - 2;
		int plotWc = plotEndC - plotX0c;
		if(plotWc < 8) plotWc = 8;
		g.plotX0px = plotX0c * FONT_X;
		g.plotWpx  = plotWc * FONT_X;

		int stackTopRow = area.y + 3;
		enum int RAW_H = 8;
		g.rawTopRow = area.y + area.height - RAW_H;
		// §17.3/§17.4 reserve two rows below the graph stack, above the raw-data strip:
		// a zoom-control button row and (just below it, blank for now) a row for the
		// future horizontal scrollbar. The band stack ends above them.
		g.scrollRow  = g.rawTopRow - 1;
		g.controlRow = g.scrollRow - 1;
		int stackBotRow = g.controlRow - 1;
		g.stackTopPx = stackTopRow * FONT_Y;
		g.stackBotPx = stackBotRow * FONT_Y;

		// Six bands (§10.3): output, adsr, frequency, pulse, filter, wave — sourced
		// from the `bands` metadata list (see its comment). The wave band's gutter
		// labels line up with its lane blocks, so it takes a FIXED height of
		// bands[5].fixedRows (WAVE_ROWS) character rows at the bottom of the stack,
		// and bands 0..4 share the remaining span by their weights.
		if(expandedBand >= 0 && expandedBand < 5) {
			// §22 one band maximised: every other band collapses to a one-row title strip
			// and the expanded band takes the rest of the stack. Order is preserved so the
			// strip titles stay double-clickable to switch or restore.
			int rowH = FONT_Y;
			int big = (g.stackBotPx - g.stackTopPx) - 5 * rowH;
			if(big < rowH) big = rowH;
			int y = g.stackTopPx;
			foreach(i; 0 .. 6) {
				g.bandTopPx[i] = y;
				y += (i == expandedBand) ? big : rowH;
			}
			g.bandTopPx[6] = g.stackBotPx;
		} else {
			int waveTopPx = g.stackBotPx - bands[5].fixedRows * FONT_Y;
			float[5] wgt;
			foreach(i; 0 .. 5) wgt[i] = bands[i].weight;
			float tot = 0; foreach(w; wgt) tot += w;
			float acc = 0;
			int span = waveTopPx - g.stackTopPx;
			g.bandTopPx[0] = g.stackTopPx;
			foreach(i; 0 .. 5) {
				acc += wgt[i];
				g.bandTopPx[i + 1] = g.stackTopPx + cast(int)lround(acc / tot * span);
			}
			g.bandTopPx[5] = waveTopPx;      // wave band: fixed WAVE_ROWS tall
			g.bandTopPx[6] = g.stackBotPx;
		}
		cachedGeo = g;
		cachedGeoArea = area;
		cachedExpandedBand = expandedBand;
		geoValid = true;
		return g;
	}

	// §12.1 Auto-fit the post-trigger X span to the note's full duration. Baseline =
	// the ADSR-derived duration from the SID ms tables (A+D+nominal-gate+R frames); if
	// a live recording of the viewed voice exists it overrides: the recorded end frame
	// wins once the note has fallen silent (release finished), else the growing record
	// head keeps the axis fitted while it is still sounding. Clamped to [MIN_VIS,MAX_VIS]
	// (long sounds zoom out to <1px/frame; that is the intended fit).
	private int computeVisFrames(int ins) {
		// ADSR-derived baseline (frames).
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		ubyte sr = song.instrumentTable[ins + 1 * 48];
		int attack  = (ad >> 4) & 0x0f, decay = ad & 0x0f, release = sr & 0x0f;
		int aF = cast(int)lround(ATTACK_TIME_MS[attack]         / tickMs);
		int dF = cast(int)lround(DECAY_RELEASE_TIME_MS[decay]   / tickMs);
		int rF = cast(int)lround(DECAY_RELEASE_TIME_MS[release] / tickMs);
		int vf = nominalGateFrames + rF;

		// §15.2(1) Recorded extent FITS the window when we have real audio — the axis
		// tracks the ACTUAL recording, NOT the (often huge) ADSR estimate. Do NOT max()
		// against `vf`: a slow AD=FF attack estimates ~20s while the real recording is
		// much shorter, and maxing would cram the waveform into the left edge,
		// time-misaligned with the other bands. The ADSR estimate is the basis ONLY for
		// the idle/sim preview (no recording).
		if(useRec) {
			int rl = audio.visualizer.getRecordingLength(viewVoice);
			int ampEnd = audio.visualizer.getRecordedAmpEnd(viewVoice, AMP_EPS);
			if(ampEnd > 0 && ampEnd < rl)
				vf = ampEnd;            // note ENDED: fit to the actual last-sounding frame
			else
				vf = rl;                // still sounding: fit to the growing record head
		}
		// A vivid recording owns only the sampled trace, not the editor geometry. Keep
		// every authored pulse/filter boundary reachable after keyjam too; otherwise a
		// short release can truncate a longer program and make its later boxes vanish.
		// This deliberately does not max against the nominal ADSR estimate above.
		int pe = pulseProgramExtent(song.instrumentTable[ins + 5 * 48]);
		if(pe > vf) vf = pe;
		int fe = filterProgramExtent(song.instrumentTable[ins + 4 * 48]);
		if(fe > vf) vf = fe;
		int we = waveProgramExtent(song.instrumentTable[ins + 7 * 48], waveTimeForInstrument(ins));
		if(we > vf) vf = we;

		if(vf < MIN_VIS) vf = MIN_VIS;
		if(vf > MAX_VIS) vf = MAX_VIS;
		return vf;
	}

	private int pulseProgramExtent(int startRow) {
		if(startRow <= 0 || startRow >= 0x40) return 0;
		bool[0x40] visited;
		int row = startRow, extent = 0;
		while(row >= 1 && row < 0x40 && !visited[row]) {
			visited[row] = true;
			extent += (song.pulseTable[row * 4] & 0x7f) + 1;
			int jump = song.pulseTable[row * 4 + 3];
			if(jump == 0) row++;
			else if(jump <= 0x3f) row = jump;
			else break;
		}
		return extent;
	}

	private int filterProgramExtent(int startRow) {
		if(startRow <= 0 || startRow >= 0x40) return 0;
		bool[0x40] visited;
		int row = startRow, extent = 0;
		while(row >= 1 && row < 0x40 && !visited[row]) {
			visited[row] = true;
			ubyte b0 = song.filterTable[row * 4];
			extent += (b0 & 0x80) ? 1 : (b0 & 0x7f) + 1;
			int jump = song.filterTable[row * 4 + 3];
			if(jump == 0) row++;
			else if(jump <= 0x3f) row = jump;
			else break;
		}
		return extent;
	}

	private int waveProgramExtent(int startRow, int waveTime) {
		int close = waveCloseRow(startRow);
		if(close < startRow) return 0;
		WaveFrameSim s = simWaveFrames(startRow, waveTime, MAX_VIS);
		if(s.loopFrame < 0) return 0;
		if(song.waveTable[close] == 0x7f)
			return s.loopFrame + max(1, s.loopPeriod);
		// $7E emits no value. Its visual terminal cadence is the simulator period or
		// the programme's longest explicit row-delay cadence, whichever is authored
		// longer. This derives Wave A's four-tick tail from its $04 delay while a fresh
		// one-row speed-0 programme remains exactly one tick; there is no fixed tail.
		int terminalPeriod = s.loopPeriod;
		foreach(row; startRow .. close) {
			int delay = song.waveTable[row + 256];
			if(delay >= 1 && delay <= 0x0f && delay > terminalPeriod)
				terminalPeriod = delay;
		}
		return s.loopFrame + max(1, terminalPeriod);
	}

	// §17.3 Right-hand extent the viewport may zoom/scroll out to. Independent of the
	// fitted note (visFrames): it always spans up to where a FULL (nibble-F) release
	// would end, so the release-tail dot is reachable past the sound even when the
	// note recording/estimate is short. Attack+decay come from this instrument; the
	// release term uses the max nibble so any release length can be dialled in.
	private int computeContentMax(int ins) {
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		int attack = (ad >> 4) & 0x0f, decay = ad & 0x0f;
		int aF = cast(int)lround(ATTACK_TIME_MS[attack]       / tickMs);
		int dF = cast(int)lround(DECAY_RELEASE_TIME_MS[decay]  / tickMs);
		int rFmax = cast(int)lround(DECAY_RELEASE_TIME_MS[15]  / tickMs);
		int cm = nominalGateFrames + rFmax;
		if(cm < visFrames) cm = visFrames;   // never narrower than the fitted note
		if(cm > MAX_CONTENT) cm = MAX_CONTENT;
		return cm;
	}

	// §13.4 The actual restart-phase length in frames for this instrument's col2
	// restart type: $80 hard ~= 2, $40 soft ~= 2, else ($00) the 3-frame restart ~= 3.
	// Used to place the restart marker at frame -restartFramesFor(ins) (inside the
	// fixed RESTART_FRAMES pre-roll), so the trigger<->restart interval is visible.
	private int restartFramesFor(int ins) {
		ubyte rst = song.instrumentTable[ins + 2 * 48];
		if((rst & 0xc0) == 0x80) return 2;   // hard restart
		if((rst & 0xc0) == 0x40) return 2;   // soft restart
		return 3;                            // $00 3-frame restart
	}

	// §13.1(b) The full TEXT backdrop of the Sound Editor: frame, title row (with the
	// instrument NN + name, §13.3), Octave, param column, band text-labels, zoom scale
	// label, the param/graph separator, and the raw-data strip. Emits NO overlay (ol*)
	// pixels. Graph bands + axes + playhead are layered on top afterwards; foreground
	// menus/dialogs mask only their own rectangles in com.fb.
	private void drawTextChrome(int ins, ref Geo g) {
		drawFrame(area);

		// drawFrame clears the interior to char 0x00. That glyph is NOT blank in this
		// font — it only looks invisible because it's drawn black-on-black (fg 0). When
		// a pop-up's drop-shadow later tints these plot cells via setColor(fg=11), the
		// char-0 glyph shows up as an opaque gray hatch (the classic editor has real
		// text there, so its shadow just dims the text). Fill our interior with SPACE
		// (a truly blank glyph) so a shadow over the empty plot area is invisible, as it
		// is over empty cells in the classic editor. Labels/params/bands are drawn after.
		foreach(yy; area.y + 1 .. area.y + area.height - 1)
			screen.data[area.x + 1 + yy * screen.width .. area.x + area.width - 1 + yy * screen.width] = 0x20;

		// §13.3 instrument NN + name now live in the wide title row (the old separate
		// "Instrument NN Name" line could run off-screen for a long name). Truncate a
		// long name to whatever fits between the fixed prefix and the "(F12 help)" tail.
		string name = stripRight(to!string(song.insLabels[ins][]));
		string prefix = format(" Sound Editor  -  %02X ", ins);
		string suffix = "   (F12 help) ";
		int avail = area.width - 3 - cast(int)prefix.length - cast(int)suffix.length;
		if(avail < 0) avail = 0;
		if(cast(int)name.length > avail) name = name[0 .. avail];
		screen.cprint(area.x + 2, area.y, COL_TITLE, 0, prefix ~ name ~ suffix);

		// Session audition state stays visible: selected SID voice, fixed gate duration,
		// active unit and its resolved tick count. This is state, not a hidden preference.
		screen.cprint(area.x + 2, area.y + 1, COL_LABEL, 0, "Octave");
		screen.cprint(area.x + 9, area.y + 1, COL_VALUE, 0, format("%d", state.octave));
		string hold = durationRows
			? format("%d Rows = %d Ticks", durationValue, configuredGateTicks())
			: format("%d Ticks", durationValue);
		screen.cprint(area.x + 13, area.y + 1, COL_LABEL, 0, "Keyjam Ch");
		screen.cprint(area.x + 23, area.y + 1, COL_VALUE, 0, format("%d", keyjamChannel + 1));
		screen.cprint(area.x + 27, area.y + 1, COL_LABEL, 0, "Gate high");
		screen.cprint(area.x + 37, area.y + 1, COL_VALUE, 0, hold);

		// §12.2/§16.2 unobtrusive scale label so the current zoom is legible. Seconds
		// use the REAL tick duration, so the same note reads the SAME seconds at any
		// multiplier (visFrames doubles at mult=2, tickMs halves -> product constant).
		float secs = visFrames * tickMs / 1000.0f;
		screen.cprint(g.labelX, area.y + 2, COL_LABEL, 0,
					  format("scale 0-%d Ticks (~%.1fs)", visFrames, secs));

		// Vertical separator between the param column and the graph stack.
		for(int y = area.y + 2; y <= g.rawTopRow - 1; y++)
			screen.setChar(g.sepX, y, 0x0500 | 216);

		drawParamColumn(ins, g);

		// Band TEXT labels (the pixel axis lines are drawn with the bands themselves).
		drawBandLabelText(g, 0, "Output");
		drawBandLabelText(g, 1, "ADSR");
		drawBandLabelText(g, 2, "Pitch");
		drawBandLabelText(g, 3, "Pulse");
		drawBandLabelText(g, 4, "Filter");
		// band 5 (wave) is self-labelled by its 8 bit-lane gutter labels — except when
		// another band is expanded and wave is a one-row strip, where it gets a title.
		if(expandedBand >= 0) drawBandLabelText(g, 5, "Wave");

		drawRawData(ins, g);
	}

	override void update() {
		// v2: keep note routing but never the blue keyjam tint on this screen.
		keyjamBackground = false;
		if(mainui !is null && (mainui.dialogActive
				|| (mainui.menubar !is null && mainui.menubar.active)
				|| (mainui.palette !is null && mainui.palette.active)))
			setEditCursor(CURSOR_NORMAL);
		// We drive our own overlay each frame; make sure no stale single-slot scope
		// trace lingers underneath the bands.
		video.clearScopeTrace();

		int ins = clampedIns();
		inputKeyjam.ensurePreviewBaseline(ins);
		inputKeyjam.setKeyjamVoice(keyjamChannel);
		inputKeyjam.setFixedGateTicks(configuredGateTicks());
		if(audio.player.keyjamNoteTrigger != seenKeyjamTrigger) {
			seenKeyjamTrigger = audio.player.keyjamNoteTrigger;
			lockedKeyjamFit = 0; // a genuinely new played note establishes a new scale
		}

		// §16.2 refresh the real-time axis unit from the live multiplier BEFORE any
		// ms<->tick conversion (computeVisFrames, ADSR sim, scale label, probe) so
		// they all share one axis at the current multiplier.
		int mult = audio.audio.multiplier;
		if(mult < 1) mult = 1;
		tickMs = SCREEN_FRAME_MS / mult;
		// The estimate and silent reSID render use the same configured gate-high duration
		// as an audible keyjam, so the authored ADSR curve and audition share one timeline.
		nominalGateFrames = configuredGateTicks();

		Geo g = layout();

		// §11.2: pick the voice whose ACTUAL recording drives the bands this frame —
		// a voice currently sounding this instrument, else one that has a recording of
		// it. When it has a recording the bands draw the real played audio; otherwise
		// they fall back to the dimmed table simulation as an idle preview.
		viewVoice = chooseVoice(ins);
		useRec = viewVoice >= 0 && audio.visualizer.voiceHasRecording(viewVoice);

		// §12.1 auto-fit the shared X window to the note's full duration, ONCE per draw,
		// then thread visFrames/totalFrames through xForFrame + every band so they all
		// share the exact same zoom (they'd misalign if recomputed per band).
		visFrames = lockedKeyjamFit > 0 ? lockedKeyjamFit : computeVisFrames(ins);
		contentMaxFrames = computeContentMax(ins);   // §17.3 zoom/scroll-out reaches the release tail
		prerollTicks = restartFramesFor(ins);   // thin restart strip -> graphs start at the left edge
		totalFrames = prerollTicks + visFrames;

		// §17.1 refresh the viewport over the (possibly changed) note extent: keep the
		// user's zoom until they hit Fit, else auto-fit to the whole note. Then derive
		// the integer visible-frame bounds every band loop clips to.
		auto durDrag = cast(SweepDurDrag)activeGesture;
		if(durDrag && durDrag.viewLocked) {
			viewport.startTick = durDrag.viewStart;
			viewport.endTick = durDrag.viewEnd;
		} else if(viewport.userZoomed) viewport.clamp(prerollTicks, contentMaxFrames);
		else viewport.fit(prerollTicks, visFrames);
		viewport.refreshFrameBounds();

		// Rebuild the overlay draw-list from scratch (all bands + the playhead).
		video.olClear();

		// Full text backdrop (frame, title row incl. instrument, param column, band
		// labels, scale label, separators, raw-data strip).
		drawTextChrome(ins, g);

		// §17.2 selection highlight FIRST (a subtle translucent-looking wash across the
		// whole stack), so the graph bands render on top of it and stay fully legible.
		drawSelectionFill(g);

		// Stacked, frame-aligned graph bands (top -> bottom); text labels are already
		// drawn by drawTextChrome, so here we draw only the pixel axis + band content.
		foreach(bi, ref band; bands) {
			// §22 in expand mode only the maximised band draws content; the rest are
			// one-row title strips (their titles are drawn by drawTextChrome).
			if(expandedBand >= 0 && cast(int)bi != expandedBand) continue;
			drawBandAxis(g, cast(int)bi);
			band.draw(ins, g);
			// Wave overlays paint across the FREQUENCY band (row references into the
			// wave table shown over the freq graph), so they draw right after band 2
			// (frequency) and before band 3 (pulse) — order preserved exactly.
			if(bi == 2) {
				drawSelectedWaveRow(ins, g);
				drawWaveAddTarget(ins, g);
				drawWaveLoopIndicators(ins, g);
			}
		}

		// Tracker-row grid sits above band fills but below the semantic markers
		// (restart, note trigger, selection and playhead), so those remain dominant.
		drawTrackStepGrid(g);

		// §13.4 restart marker: a vertical line at the START of the restart phase
		// (frame -restartFrames, the actual hard/soft/3-frame restart length for this
		// instrument's col2 type), in a colour DISTINCT from the red trigger divider
		// (frame 0) and the white playhead — so the short trigger<->restart interval
		// is visible. Drawn before the trigger so the (brighter) trigger wins on any
		// pixel overlap at extreme zoom.
		int restF = restartFramesFor(ins);
		if(viewport.frameInView(-restF))
			video.olVLine(viewport.xForFrame(g, -restF), g.stackTopPx, g.stackBotPx, COL_RESTART);

		// §9.2 note-trigger divider at frame 0 across ALL bands: everything left of it
		// is the restart pre-roll, everything right of it is the same frame index in
		// every band. (Skipped when frame 0 is panned out of the viewport.)
		if(viewport.frameInView(0))
			video.olVLine(viewport.xForFrame(g, 0), g.stackTopPx, g.stackBotPx, COL_TRIGGER);

		// §17.2 selection edges on top of the bands (bright, distinct from the wash).
		drawSelectionEdges(g);

		// §11.2 one full-height playhead = the recording's current record head. It
		// advances right as the recording grows during a live note and freezes at the
		// end once the note has finished. Only shown when a recording is driving the
		// bands (the idle sim preview has no record head).
		if(useRec) {
			int rh = audio.visualizer.getRecordingLength(viewVoice);
			if(rh > visFrames) rh = visFrames;
			if(viewport.frameInView(rh))
				video.olVLine(viewport.xForFrame(g, rh), g.stackTopPx, g.stackBotPx, COL_HEAD);
		}

		// §19 P4a draggable A/D/S/R handles on the ADSR curve (drawn on top of the band
		// so the grab targets are visible; the grabbed one lights up while dragging).
		if(bandVisible(1)) drawAdsrHandles(ins, g);

		// §17.3 subtle zoom-control button row + the current selection readout.
		drawZoomControls(g);

		// §17.4 horizontal scrollbar (row just below the control row): track = the whole
		// Fit range, thumb = the current viewport. Text cells, so it composites with the
		// rest of the chrome (drawTextChrome already wiped this row this frame).
		drawScrollbar(g);

		// §14.1 mouse-hover probe + numeric readout (only while the cursor is over the
		// plot region). Drawn last so the dashed white probe line sits on top.
		drawProbe(ins, g);
		// §21 P4c interactive step box (duration edges + ramp handles) on the hovered step,
		// drawn AFTER the probe so its YELLOW hot edge shows on top of the hover line.
		if(bandVisible(3) || bandVisible(4)) drawSweepStepBox(ins, g);
		// Authored LOOP/END triangles are the final graph chrome.  Their one-cell filled
		// silhouette must remain exact even when the closing step is selected.
		if(bandVisible(3) || bandVisible(4)) drawSweepLoopIndicatorsForInstrument(ins, g);
	}

	// §11.2 Choose the voice whose real SID recording should drive the bands for the
	// viewed instrument: prefer a voice CURRENTLY sounding it (live note), else any
	// voice whose last recording is of it (a finished note still shown frozen).
	// -1 when nothing has played this instrument (bands then show the dimmed sim).
	private int chooseVoice(int ins) {
		// §11.2b Keyjam audition (this screen's own note preview): the note is played
		// on ONE voice (audio.player.playNote / captureStart, others muted) with the
		// VIEWED instrument (state.activeInstrument), so that voice's recording IS the
		// viewed instrument's note. Bind to it directly via the capture voice+instrument
		// tracked at note-on, WITHOUT the player-memory instrument read — that read
		// derives the per-voice instrument from a SHTRANS-relative offset that is wrong
		// for OLD players (CC03.30 kalmankone: it returns instrument 0), which made the
		// getVoiceInstrument()==ins matches below fail and the bands fall back to the
		// ADSR-estimated table SIMULATION instead of the real recording. captureInstr
		// guards the stale case (instrument switched with +/- after playing, before
		// replaying). Only in keyjam mode: song playback (Status.Play) plays different
		// instruments per voice, where the player-memory match below is the right signal.
		if(audio.player.keyjamEnabled()) {
			int kv = audio.audio.captureVoice;
			if(kv >= 0 && kv < 3 && audio.audio.captureInstr == ins
			   && audio.visualizer.voiceHasRecording(kv)) return kv;
		}
		foreach(v; 0 .. 3)
			if(audio.visualizer.getVoiceInstrument(v) == ins
			   && audio.visualizer.getVoiceBrightness(v) > 0.01f) return v;
		foreach(v; 0 .. 3)
			if(audio.visualizer.getVoiceInstrument(v) == ins
			   && audio.visualizer.voiceHasRecording(v)) return v;
		return -1;
	}

	// §11.3 Draw SUBTLE dim vertical lines at every loop-boundary frame across a band
	// (loopFrame, +period, +2*period, ...). Distinct from the bright red trigger
	// divider and the white playhead. Used in BOTH the recording and sim paths (the
	// real audio repeats the looped section on the same period the sim computes).
	private enum int MIN_LOOP_PX = 6;   // keep loop lines subtle: never closer than this
	private void drawLoopLines(ref Geo g, int topPx, int botPx, int loopFrame, int period,
			int n) {
		// A period < 2 is a single-row "hold" (waveform sustained), not a repeating
		// section worth marking — skip it so it doesn't draw a line every frame.
		if(loopFrame < 0 || period < 2) return;
		int lastX = -1_000_000;
		for(int f = loopFrame; f < n && f < visFrames; f += period) {
			if(!viewport.frameInView(f)) continue;                          // §17.1 skip off-view
			int x = viewport.xForFrame(g, f);
			if(lastX > -1_000_000 && x - lastX < MIN_LOOP_PX) continue; // stay subtle, no comb
			video.olVLine(x, topPx, botPx, COL_LOOPLINE);
			lastX = x;
		}
	}

	private SweepLoopGeometry sweepLoopGeometry(int table, ref Geo g, ref SweepSim s) {
		SweepLoopGeometry result;
		int band = sweepKind(table).band;
		int topPx, botPx; bandBox(g, band, topPx, botPx);
		result.top = topPx;
		result.bottom = min(botPx, topPx + FONT_Y);
		result.looped = s.loopFrame >= 0 && s.loopPeriod >= 1;
		result.stopped = !result.looped && s.stops
			&& sweepProgramSteps(table, clampedIns()).length >= 2;
		if(result.looped) {
			int startFrame = s.loopFrame;
			int endFrame = s.loopFrame + s.loopPeriod;
			// xForFrame deliberately clamps to the viewport rails.  Gate the authored
			// frame first so an off-screen triangle can never appear or become hittable
			// at a rail merely because of that clamp.
			if(viewport.frameInView(startFrame)) {
				int startEdge = viewport.xForFrame(g, startFrame);
				result.startLeft = startEdge;
				result.startRight = startEdge + FONT_X;
				result.startVisible = result.startRight > g.plotX0px
					&& result.startLeft < g.plotX0px + g.plotWpx;
			}
			if(viewport.frameInView(endFrame)) {
				int endEdge = viewport.xForFrame(g, endFrame);
				result.endLeft = endEdge - FONT_X;
				result.endRight = endEdge;
				result.endVisible = result.endRight > g.plotX0px
					&& result.endLeft < g.plotX0px + g.plotWpx;
			}
		} else if(result.stopped) {
			int endFrame = min(cast(int)s.val.length, visFrames);
			if(viewport.frameInView(endFrame)) {
				int endEdge = viewport.xForFrame(g, endFrame);
				result.endLeft = endEdge - FONT_X;
				result.endRight = endEdge;
				result.endVisible = result.endRight > g.plotX0px
					&& result.endLeft < g.plotX0px + g.plotWpx;
			}
		}
		return result;
	}

	private void drawFilledInwardTriangle(int left, int right, int top, int bottom,
			bool pointsRight) {
		int width = right - left, height = bottom - top;
		if(width < 1 || height < 1) return;
		int maxDistance = max(1, (height - 1) / 2);
		foreach(dy; 0 .. height) {
			int distance = min(dy, height - 1 - dy);
			int reach = clampInt(cast(int)lround(
				cast(double)distance * (width - 1) / maxDistance), 0, width - 1);
			if(pointsRight) video.olHLine(left, left + reach, top + dy, COL_LOOP);
			else video.olHLine(right - 1 - reach, right - 1, top + dy, COL_LOOP);
		}
	}

	private SoundEditorWaveLoopDebug waveLoopGeometry(int ins, ref Geo g) {
		SoundEditorWaveLoopDebug result;
		result.startFrame = result.endFrame = -1;
		int topPx, botPx; bandBox(g, 2, topPx, botPx);
		// Mouse input arrives in character cells.  Keep the one-character marker and
		// its hit box on that same grid so every visible pixel has a reachable cell.
		result.top = ((topPx + FONT_Y - 1) / FONT_Y) * FONT_Y;
		result.bottom = result.top + FONT_Y;
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		if(close < start) return result;
		WaveFrameSim s = simWaveFrames(start, waveTimeForInstrument(ins), MAX_VIS);
		result.looped = song.waveTable[close] == 0x7f && s.loopFrame >= 0;
		result.stopped = song.waveTable[close] == 0x7e && s.loopFrame >= 0;
		if(!result.looped && !result.stopped) return result;
		result.endFrame = waveProgramExtent(start, waveTimeForInstrument(ins));
		if(result.looped) result.startFrame = s.loopFrame;
		if(result.looped && viewport.frameInView(result.startFrame)) {
			int edge = viewport.xForFrame(g, result.startFrame);
			result.startLeft = (edge / FONT_X) * FONT_X;
			result.startRight = result.startLeft + FONT_X;
			result.startVisible = result.startRight > g.plotX0px
				&& result.startLeft < g.plotX0px + g.plotWpx;
		}
		if(viewport.frameInView(result.endFrame)) {
			int edge = viewport.xForFrame(g, result.endFrame);
			result.endLeft = (max(0, edge - 1) / FONT_X) * FONT_X;
			result.endRight = result.endLeft + FONT_X;
			result.endVisible = result.endRight > g.plotX0px
				&& result.endLeft < g.plotX0px + g.plotWpx;
		}
		return result;
	}

	private void drawWaveLoopIndicators(int ins, ref Geo g) {
		auto shape = waveLoopGeometry(ins, g);
		if(shape.startVisible)
			drawFilledInwardTriangle(shape.startLeft, shape.startRight,
				shape.top, shape.bottom, true);
		if(shape.endVisible)
			drawFilledInwardTriangle(shape.endLeft, shape.endRight,
				shape.top, shape.bottom, false);
	}

	private int waveLoopHandleAt(int ins, ref Geo g, int cellX, int cellY) {
		auto shape = waveLoopGeometry(ins, g);
		int px = cellX * FONT_X + FONT_X / 2;
		int py = cellY * FONT_Y + FONT_Y / 2;
		if(py < shape.top || py >= shape.bottom) return -1;
		if(shape.startVisible && px >= shape.startLeft && px < shape.startRight) return 0;
		if(shape.endVisible && px >= shape.endLeft && px < shape.endRight) return 1;
		return -1;
	}

	private void drawSweepLoopIndicators(int table, ref Geo g, ref SweepSim s) {
		auto shape = sweepLoopGeometry(table, g, s);
		if(shape.startVisible)
			drawFilledInwardTriangle(shape.startLeft, shape.startRight,
				shape.top, shape.bottom, true);
		if(shape.endVisible)
			drawFilledInwardTriangle(shape.endLeft, shape.endRight,
				shape.top, shape.bottom, false);
	}

	private void drawSweepLoopIndicatorsForInstrument(int ins, ref Geo g) {
		int pp = song.instrumentTable[ins + 5 * 48];
		if(pp < 0x80) {
			SweepSim pulse = simPulse(pp);
			drawSweepLoopIndicators(0, g, pulse);
		}
		int fp = song.instrumentTable[ins + 4 * 48];
		SweepSim filter = simFilter(fp);
		drawSweepLoopIndicators(1, g, filter);
	}

	// The on-screen pixel span [xa, xb) frame `f` covers on the shared timeline.
	// xb is nudged to at least xa+1 so a span is never empty when adjacent
	// frames land on the same column (e.g. zoomed far out).
	private void frameXSpan(ref Geo g, int f, out int xa, out int xb) {
		xa = viewport.xForFrame(g, f);
		xb = viewport.xForFrame(g, f + 1);
		if(xb <= xa) xb = xa + 1;
	}

	// Draw a single-colour step graph ("staircase") over frame range [lo, hi):
	// one horizontal segment per frame at `yOf(f)`, plus a vertical riser to
	// the previous frame's segment whenever the level changed. Shared by any
	// per-frame level trace (filter resonance, pitch/transpose, ...).
	private void drawStaircase(ref Geo g, int lo, int hi, int delegate(int) yOf, int col) {
		int prevY = -1;
		foreach(f; lo .. hi) {
			int y = yOf(f);
			int xa, xb; frameXSpan(g, f, xa, xb);
			video.olHLine(xa, xb - 1, y, col);           // level segment
			if(prevY >= 0 && prevY != y)
				video.olVLine(xa, min(prevY, y), max(prevY, y), col); // riser
			prevY = y;
		}
	}

	// A per-frame value staircase (pulse width or filter cutoff) as an area fill +
	// top line on the shared frame axis. Fed from either the recording or the sim.
	private void drawValueBand(const(int)[] vals, int maxVal, int fillCol, int lineCol,
			int topPx, int botPx, ref Geo g) {
		int hh = botPx - topPx;
		if(hh <= 0 || maxVal <= 0) return;
		int n = min(cast(int)vals.length, visFrames);
		int lo, hi; viewport.visRange(n, lo, hi);       // §17.1 only emit on-screen frames
		foreach(f; lo .. hi) {
			int v = vals[f];
			if(v < 0) v = 0; if(v > maxVal) v = maxVal;
			int y = botPx - v * hh / maxVal;
			int xa, xb; frameXSpan(g, f, xa, xb);
			for(int x = xa; x < xb; x++) {
				video.olVLine(x, botPx, y, fillCol);
				video.olPoint(x, y, lineCol);
			}
		}
	}

	// ---- left parameter column (movable cursor; scalar/envelope rows editable P4a) ----

	private void drawParamColumn(int ins, ref Geo g) {
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		ubyte sr = song.instrumentTable[ins + 1 * 48];
		ubyte rst = song.instrumentTable[ins + 2 * 48];
		ubyte hrw = song.instrumentTable[ins + 3 * 48];
		ubyte fpt = song.instrumentTable[ins + 4 * 48];
		ubyte ppt = song.instrumentTable[ins + 5 * 48];
		ubyte hsr = song.instrumentTable[ins + 6 * 48];
		ubyte wpt = song.instrumentTable[ins + 7 * 48];
		int attack  = (ad >> 4) & 0x0f, decay   = ad & 0x0f;
		int sustain = (sr >> 4) & 0x0f, release = sr & 0x0f;

		// Waveform mnemonic from the first control byte the wave table sets.
		WaveSim w = simWave(wpt);
		int firstCtrl = 0;
		foreach(c; w.cells) if(c.ctrl >= 0x10) { firstCtrl = c.ctrl; break; }

		// §8.2 restart-condition byte (col 2): $80 hard / $40 soft / else 3-frame
		// restart; the low nibble is the ARPEGGIO SPEED.
		string rstStr = (rst & 0xc0) == 0x80 ? "Hard"
			: ((rst & 0xc0) == 0x40 ? "Soft" : "3 Frames");
		int arpSpeed = rst & 0x0f;

		// 6-char text bar for a 0..15 nibble.
		static string nibbleBar(int n) {
			int fill = n * 6 / 15;
			char[6] b = '.';
			foreach(k; 0 .. 6) if(k < fill) b[k] = '#';
			return cast(string)b.dup;
		}

		// Row order MUST match the ROW_* enum (Gate delay is its own row so Left/Right
		// edits it directly, keeping "Left/Right edits the selected value" consistent and
		// leaving Shift-Left/Right free to pan on every row).
		string[PARAM_ROWS] labels = [
			"Attack", "Decay", "Sustain", "Release", "Waveform", "Wave ptr",
			"Pulse ptr", "Filter ptr", "Restart", "Arpeggio speed", "HR wave", "HR SR",
			"Keyjam channel", "Gate hold", "Duration unit"
		];
		string[PARAM_ROWS] vals;
		vals[ROW_ATTACK]  = format("%X %s", attack,  nibbleBar(attack));
		vals[ROW_DECAY]   = format("%X %s", decay,   nibbleBar(decay));
		vals[ROW_SUSTAIN] = format("%X %s", sustain, nibbleBar(sustain));
		vals[ROW_RELEASE] = format("%X %s", release, nibbleBar(release));
		vals[ROW_WAVEFORM]= waveformName(firstCtrl);
		vals[ROW_WAVEPTR] = format("$%02X", wpt);
		vals[ROW_PULSEPTR]= ppt >= 0x80 ? format("fix $%03X", (ppt & 0x0f) << 8) : format("$%02X", ppt);
		vals[ROW_FILTPTR] = fpt == 0 ? "off" : format("$%02X", fpt);
		vals[ROW_RESTART] = rstStr;
		vals[ROW_GATE]    = format("%X %s", arpSpeed, nibbleBar(arpSpeed));
		vals[ROW_HRWAVE]  = format("$%02X", hrw);
		vals[ROW_HRSR]    = format("$%02X", hsr);
		vals[ROW_JAMCHANNEL] = format("Voice %d", keyjamChannel + 1);
		vals[ROW_GATEHOLD] = durationRows
			? format("%d R = %d T", durationValue, configuredGateTicks())
			: format("%d T", durationValue);
		vals[ROW_DURATIONUNIT] = durationRows ? "Rows" : "Ticks";

		int y0 = area.y + 3;
		immutable int valX = g.paramX + 16;   // wide enough for the "Arpeggio speed" label
		immutable int valMax = g.sepX - valX;   // chars available before separator
		screen.cprint(g.paramX, area.y + 2, COL_LABEL, 0, "Parameters");
		foreach(i; 0 .. PARAM_ROWS) {
			int y = y0 + i;
			bool sel = (i == paramCursor);
			int lc = sel ? COL_TITLE : COL_LABEL;
			int vc = sel ? COL_TITLE : COL_VALUE;
			// Cursor marker: ">" on the selected row. An EDITABLE selected row reads
			// "<>" (Left/Right change this value); pointer rows just show ">".
			string marker = sel ? (isEditableRow(i) ? "<" : " ") : " ";
			screen.cprint(g.paramX, y, lc, 0, marker);
			screen.cprint(g.paramX + 1, y, lc, 0, labels[i]);
			string v = vals[i];
			// A trailing ">" on an editable selected row balances the leading "<".
			if(sel && isEditableRow(i)) v = v ~ " >";
			if(v.length > valMax) v = v[0 .. valMax];
			screen.cprint(valX, y, vc, 0, v);
		}

		// One context-sensitive action hint below the parameter block. Modern synths expose
		// the current target and gesture before an edit; keep that predictability without
		// adding non-retro tooltips or another panel. Selection takes precedence over hover.
		int hintY = y0 + PARAM_ROWS;
		string hint = "L/R edit  Shift+L/R pan";
		int hintCol = COL_LABEL;
		if(selectedSweepTable >= 0 && selectedSweepRow >= 1) {
			auto selK = sweepKind(selectedSweepTable);
			string kind = selK.name;
			if(sweepMultiSelected())
				hint = format("%s $%02X-$%02X: drag joins", kind,
					selectedSweepRow, selectedSweepRowEnd);
			else {
				ubyte[] t = selK.table;
				if(selK.isFilter && (t[selectedSweepRow * 4] & 0x80)) {
					int cfgMode = t[selectedSweepRow * 4] & 0x70;
					int cfgRes = t[selectedSweepRow * 4 + 1] >> 4;
					int cfgMask = t[selectedSweepRow * 4 + 1] & 0x0f;
					hint = format("Filter $%02X CFG M%02X Res %X Rt %X",
						selectedSweepRow, cfgMode, cfgRes, cfgMask);
					hintCol = COL_TITLE;
					goto hintReady;
				}
				int ticks = (t[selectedSweepRow * 4] & 0x7f) + 1;
				int wraps = selectedSweepTable == 0
					? sweepStepWinding(0, selectedSweepRow) / 4096 : 0;
				string wrapCue = wraps ? format(" Wraps %+d", wraps) : "";
				// Put the exceptional/winding state before ordinary duration text so the
				// narrow retro parameter column can never clip away the important warning.
				if(durationRows) hint = format("%s $%02X:%s %d Ticks (%s Rows)", kind,
					selectedSweepRow, wrapCue, ticks,
					ticks % trackStepTicks() ? "partial" : format("%d", ticks / trackStepTicks()));
				else hint = format("%s $%02X:%s %d Ticks", kind,
					selectedSweepRow, wrapCue, ticks);
			}
			hintCol = COL_TITLE;
		} else if(hovering) {
			int waveRow;
			if(waveGraphRowAt(g, hoverCellX, hoverCellY, waveRow)) {
				int gesture = waveGestureForRow(waveRow);
				if(gesture == WAVE_GESTURE_PITCH)
					hint = format("Wave $%02X W1: drag up/down", waveRow);
				else if(gesture == WAVE_GESTURE_DELAY)
					hint = format("Wave $%02X W2: drag left/right", waveRow);
				else
					hint = format("Wave $%02X: reserved; exact W1/W2", waveRow);
				hintCol = gesture == WAVE_GESTURE_NONE ? COL_DIM : COL_VALUE;
			} else {
			int ht, hr;
			if(hoverSweepStep(g, ht, hr)) {
				hint = format("%s $%02X: drag edge / inside", sweepKind(ht).name, hr);
				hintCol = COL_VALUE;
			} else {
				int py = hoverCellY * FONT_Y + FONT_Y / 2;
				int px = hoverCellX * FONT_X + FONT_X / 2;
				if(px >= g.plotX0px && px < g.plotX0px + g.plotWpx) {
					if(py >= g.bandTopPx[1] && py < g.bandTopPx[2])
						hint = "ADSR: drag square handles";
					else if(py >= g.bandTopPx[5] && py < g.bandTopPx[6])
						hint = "Wave lane: click toggles bit";
					else if(py >= g.stackTopPx && py < g.stackBotPx)
						hint = "Plot: drag selects time range";
				}
			}
			}
		}
	hintReady:
		int hintMax = g.sepX - g.paramX - 1;
		if(cast(int)hint.length > hintMax) hint = hint[0 .. hintMax];
		screen.cprint(g.paramX, hintY, hintCol, 0, hint);
	}

	private static string waveformName(int ctrl) {
		if(ctrl == 0) return "(unchanged)";
		string s;
		if(ctrl & 0x10) s ~= "tri ";
		if(ctrl & 0x20) s ~= "saw ";
		if(ctrl & 0x40) s ~= "pul ";
		if(ctrl & 0x80) s ~= "noi ";
		if(s.length == 0) s = format("$%02X", ctrl);
		return stripRight(s);
	}

	// ---- §19 P4a: instrument-scalar editing (left column + ADSR drag) + undo ----

	// The current instrument, clamped to a valid index (shared by update / keypress /
	// the mouse handlers so they all edit the same instrument).
	private int clampedIns() {
		int ins = state.activeInstrument;
		if(ins < 0) ins = 0;
		if(ins > 47) ins = 47;
		return ins;
	}

	private static int clampInt(int v, int lo, int hi) {
		return v < lo ? lo : (v > hi ? hi : v);
	}

	// Which param rows carry an EDITABLE per-instrument scalar byte (P4a). The pointer
	// rows (Waveform / Wave / Pulse / Filter ptr) are display-only — programs are edited
	// via their graphs in P4b/c, never by hand-poking a pointer.
	private bool isEditableRow(int r) {
		switch(r) {
			case ROW_ATTACK, ROW_DECAY, ROW_SUSTAIN, ROW_RELEASE,
				 ROW_RESTART, ROW_GATE, ROW_HRWAVE, ROW_HRSR,
				 ROW_JAMCHANNEL, ROW_GATEHOLD, ROW_DURATIONUNIT:
				return true;
			default:
				return false;
		}
	}

	// ---- Undoable (com.session): one snapshot of the WHOLE instrument table per edit
	// gesture (per keypress, or once at ADSR drag start). Mirrors the classic HexTable
	// pattern (tableData = [data.dup]); global Ctrl-Z/Y dispatch to us for free once we
	// are on the stack. Byte-identical to a classic InsTable edit.
	private void snapshotInstruments() {
		UndoValue u;
		u.tableData = [song.instrumentTable.dup];
		insertUndo(this, u);
	}

	// §20.3 program edits touch a whole SweepTable (level drag) or shift pointers
	// across several tables (fork), so snapshot ALL tables in the classic
	// tableIterator order (wave, cmd, instr, chord, pulse, filter) exactly like the
	// classic HexTable's all-tables undo — a multi-table snapshot (length > 1) is what
	// undo() restores via the same iterator. withLabels adds insLabels for a fork.
	private void snapshotAllTables(bool withLabels) {
		UndoValue u;
		song.tableIterator((Song.Table t) { u.tableData ~= t.data.dup; });
		if(withLabels) {
			u.insLabels = song.insLabels;
			u.hasInsLabels = true;
		}
		insertUndo(this, u);
	}

	override void undo(UndoValue v) {
		// length == 1 = the P4a single instrument-table snapshot; length > 1 = a
		// program-edit all-tables snapshot restored in the tableIterator order it was
		// captured in (mirrors the classic HexTable all-tables undo).
		if(v.tableData.length == 1)
			song.instrumentTable[] = v.tableData[0];
		else if(v.tableData.length > 1) {
			int idx;
			song.tableIterator((Song.Table t) { t.data[0 .. $] = v.tableData[idx++][0 .. $]; });
		}
		if(v.hasInsLabels)
			song.insLabels[] = v.insLabels[];
	}

	override UndoValue createRedoState(UndoValue prev) {
		UndoValue r;
		if(prev.tableData.length <= 1)
			r.tableData = [song.instrumentTable.dup];
		else {
			song.tableIterator((Song.Table t) { r.tableData ~= t.data.dup; });
			r.insLabels = song.insLabels;
			r.hasInsLabels = true;
		}
		return r;
	}

	// Set one nibble of instrument byte col to an ABSOLUTE 0..15 value (preserving the
	// other nibble). The one true write path — same index expression the classic
	// InsValueTable uses (col*48 + ins), so the result is byte-identical.
	private void setNibbleAbs(int ins, int col, bool hi, int val) {
		val = clampInt(val, 0, 15);
		int idx = ins + col * 48;
		ubyte b = song.instrumentTable[idx];
		int h = (b >> 4) & 0x0f, l = b & 0x0f;
		if(hi) h = val; else l = val;
		song.instrumentTable[idx] = cast(ubyte)((h << 4) | l);
	}

	// Nudge a nibble by delta (Left/Right keyboard editing), clamped 0..15.
	private void bumpNibble(int ins, int col, bool hi, int delta) {
		ubyte b = song.instrumentTable[ins + col * 48];
		int cur = hi ? ((b >> 4) & 0x0f) : (b & 0x0f);
		setNibbleAbs(ins, col, hi, cur + delta);
	}

	// Nudge a whole byte (HR wave col3 / HR SR col6) by delta, clamped 0..255.
	private void bumpByte(int ins, int col, int delta) {
		int idx = ins + col * 48;
		song.instrumentTable[idx] = cast(ubyte)clampInt(song.instrumentTable[idx] + delta, 0, 255);
	}

	// Cycle the restart TYPE (col2 bits 6-7) hard->soft->3fr by delta, preserving bits
	// 0-5 (gate-on nibble + any low bits) so only the type field changes.
	private void cycleRestart(int ins, int delta) {
		int idx = ins + 2 * 48;
		ubyte b = song.instrumentTable[idx];
		static immutable int[3] order = [0x80, 0x40, 0x00]; // hard, soft, 3-frame
		int cur = 0;
		int tb = b & 0xc0;
		foreach(i, o; order) if(o == tb) { cur = cast(int)i; break; }
		int ni = ((cur + delta) % 3 + 3) % 3;
		song.instrumentTable[idx] = cast(ubyte)((b & 0x3f) | order[ni]);
	}

	// Apply a Left/Right delta to whatever the cursor row selects (no undo/re-trigger —
	// editSelected wraps this with the gesture snapshot + re-trigger).
	private void applyRowDelta(int ins, int row, int delta) {
		switch(row) {
			case ROW_ATTACK:  bumpNibble(ins, 0, true,  delta); break;
			case ROW_DECAY:   bumpNibble(ins, 0, false, delta); break;
			case ROW_SUSTAIN: bumpNibble(ins, 1, true,  delta); break;
			case ROW_RELEASE: bumpNibble(ins, 1, false, delta); break;
			case ROW_RESTART: cycleRestart(ins, delta); break;
			case ROW_GATE:    bumpNibble(ins, 2, false, delta); break;
			case ROW_HRWAVE:  bumpByte(ins, 3, delta); break;
			case ROW_HRSR:    bumpByte(ins, 6, delta); break;
			case ROW_JAMCHANNEL:
				keyjamChannel = clampInt(keyjamChannel + delta, 0, 2);
				syncKeyjamConfiguration();
				break;
			case ROW_GATEHOLD:
				durationValue = clampInt(durationValue + delta, 1, 128);
				syncKeyjamConfiguration();
				break;
			case ROW_DURATIONUNIT:
				changeDurationUnit(!durationRows);
				break;
			default: break;
		}
	}

	// One keyboard edit gesture: snapshot for undo, mutate, then make it audible.
	private void editSelected(int ins, int delta) {
		if(!isEditableRow(paramCursor)) return;
		bool songValue = paramCursor < ROW_JAMCHANNEL;
		if(songValue) snapshotInstruments();
		applyRowDelta(ins, paramCursor, delta);
		retriggerIfSounding();
	}

	// Re-render exactly once after an edit completes. During the gesture the previous
	// reSID capture remains visible, keeping both the slopes and fitted X axis stable.
	// A held note is retriggered normally; a released last keyjam note is rendered with
	// SDL output paused. Before the first played note, InputKeyjam supplies the explicit
	// C-4 baseline. Song playback remains protected from any preview injection.
	private void retriggerIfSounding() {
		if(audio.player.getPlaystatus() == audio.player.Status.Play) return;
		// Before the first user keyjam, a completed edit refreshes only the isolated
		// C-4 reSID envelope preview. It must not manufacture a keyjam recording.
		if(!inputKeyjam.hasPlayedPreviewNote()) {
			ensureSilentEnvelopePreview(max(visFrames,
				cast(int)silentEnvPreview.length));
			return;
		}
		// The initial C-4 baseline shapes the idle estimate, but does not manufacture a
		// recording merely because a scalar was edited. Once a user has keyjammed, the
		// durable last note is eligible for the silent real-SID mouse-up rerender.
		if(!inputKeyjam.noteHeld() && !inputKeyjam.hasPlayedPreviewNote()) return;
		int extent = visFrames;
		// Edits can lengthen a program while the prior keyjam fit is locked to a short
		// recording. Grow the silent rerender and the new lock before the next draw so
		// the just-created boundary remains visible and interactive.
		int pe = pulseProgramExtent(song.instrumentTable[clampedIns() + 5 * 48]);
		if(pe > extent) extent = pe;
		int fe = filterProgramExtent(song.instrumentTable[clampedIns() + 4 * 48]);
		if(fe > extent) extent = fe;
		int we = waveProgramExtent(song.instrumentTable[clampedIns() + 7 * 48],
			waveTimeForInstrument(clampedIns()));
		if(we > extent) extent = we;
		if(extent < MIN_VIS) extent = MIN_VIS;
		if(inputKeyjam.noteHeld()) {
			inputKeyjam.retrigger();
			audio.audio.renderKeyjamCapture(extent);
		} else if(inputKeyjam.previewMatchesInstrument(clampedIns())) {
			inputKeyjam.rerenderLastSilently(extent, min(nominalGateFrames, extent));
		} else return;
		lockedKeyjamFit = extent;
		seenKeyjamTrigger = audio.player.keyjamNoteTrigger;
	}

	private void ensureSilentEnvelopePreview(int requestedTicks) {
		if(requestedTicks < 1) requestedTicks = 1;
		if(requestedTicks > MAX_CONTENT) requestedTicks = MAX_CONTENT;
		inputKeyjam.ensurePreviewBaseline(clampedIns());
		int ins = clampedIns();
		int ad = song.instrumentTable[ins + 0 * 48];
		int sr = song.instrumentTable[ins + 1 * 48];
		int gate = configuredGateTicks();
		int mult = max(1, audio.audio.multiplier);
		int backend = audio.player.usefp;
		int note = inputKeyjam.previewNote();
		bool changed = ins != silentEnvIns || ad != silentEnvAd || sr != silentEnvSr
			|| gate != silentEnvGate || mult != silentEnvMult
			|| backend != silentEnvBackend || note != silentEnvNote;

		// A mouse move changes instrument bytes, but the audible/visible result commits
		// on release. Preserve the prior trace throughout the gesture.
		if(cast(AdsrDrag)activeGesture && silentEnvPreview.length) return;
		if(!changed && silentEnvPreview.length >= requestedTicks) return;

		int renderTicks = max(requestedTicks, cast(int)silentEnvPreview.length);
		if(renderTicks < MIN_VIS) renderTicks = MIN_VIS;
		silentEnvPreview.length = renderTicks;
		int rendered = sid_render_envelope_preview(cast(ubyte)ad, cast(ubyte)sr,
			gate, mult, restartFramesFor(ins) + 1, silentEnvPreview.ptr, renderTicks);
		if(rendered < 0) rendered = 0;
		if(rendered < renderTicks) silentEnvPreview.length = rendered;
		if(changed) silentEnvGeneration++;
		silentEnvIns = ins;
		silentEnvAd = ad;
		silentEnvSr = sr;
		silentEnvGate = gate;
		silentEnvMult = mult;
		silentEnvBackend = backend;
		silentEnvNote = note;
	}

	// Rows reachable from one instrument's wave pointer, including loop-marker rows.
	// Wave programs may jump between contiguous chunks, so follow $7f targets until a
	// $7e end marker or a previously visited row is reached.
	private bool[256] waveProgramRows(int startRow) {
		bool[256] rows;
		if(startRow <= 0 || startRow > 0xff) return rows;
		int row = startRow & 0xff;
		while(!rows[row]) {
			rows[row] = true;
			int w1 = song.waveTable[row];
			if(w1 == 0x7e) break;
			if(w1 == 0x7f) row = song.waveTable[row + 256];
			else row = (row + 1) & 0xff;
		}
		return rows;
	}

	private bool waveProgramShared(int ins) {
		bool[256] mine = waveProgramRows(song.instrumentTable[ins + 7 * 48]);
		foreach(j; 0 .. 48) {
			if(j == ins) continue;
			bool[256] other = waveProgramRows(song.instrumentTable[j + 7 * 48]);
			foreach(r; 0 .. 256) if(mine[r] && other[r]) return true;
		}
		return false;
	}

	private int waveTimeForInstrument(int ins) {
		return song.instrumentTable[ins + 2 * 48] & 0x0f;
	}

	// Closing $7E/$7F marker of the contiguous authored chunk. Markers are metadata:
	// they never become editable pitch/control rows themselves.
	private int waveCloseRow(int start) {
		if(start < 0 || start > 0xff) return -1;
		for(int row = start; row < 256; row++)
			if(song.waveTable[row] == 0x7e || song.waveTable[row] == 0x7f) return row;
		return -1;
	}

	private bool selectedWaveNormal(int ins) {
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		// A Pulse/Filter click is a fresh graph selection.  Keep the remembered Wave
		// row for later, but never let that stale row own contextual commands while a
		// sweep block is selected.
		return selectedSweepTable < 0 && close > start
			&& selectedWaveRow >= start && selectedWaveRow < close;
	}

	// Allocate a complete private sound in unused table space. Pulse and filter start as
	// canonical stopped programs, ready for their later graphical editing phases.
	private void createNewIsolatedSound() {
		int base = song.tWave.seekTableEnd();
		int pbase = song.tPulse.seekTableEnd(); if(pbase < 1) pbase = 1;
		int fbase = song.tFilter.seekTableEnd(); if(fbase < 1) fbase = 1;
		if(base < 0 || base + 7 > 256) {
			UI.statusline.display("Wave table needs seven free rows for a new sound.");
			return;
		}
		if(pbase > 0x3e || fbase + 1 > 0x3e) {
			UI.statusline.display("Pulse/filter table has no room for a new sound.");
			return;
		}
		int ins = clampedIns();
		snapshotAllTables(true);
		foreach(col; 0 .. 8) song.instrumentTable[ins + col * 48] = 0;
		song.instrumentTable[ins + 2 * 48] = 0x40; // soft restart, wave speed 0
		song.instrumentTable[ins + 3 * 48] = 0x80;
		song.instrumentTable[ins + 4 * 48] = cast(ubyte)fbase;
		song.instrumentTable[ins + 5 * 48] = cast(ubyte)pbase;
		song.instrumentTable[ins + 7 * 48] = cast(ubyte)base;
		linkedEditKind = linkedEditStart = -1;
		song.waveTable[base] = 0x00;
		song.waveTable[base + 256] = 0x00;
		song.waveTable[base + 1] = 0x7e;
		song.waveTable[base + 1 + 256] = 0x00;
		// P0: one neutral editable block, stopped.
		song.pulseTable[pbase * 4 .. pbase * 4 + 4] = [0x00, 0x00, 0x00, 0x7f];
		// F0: LP/voice-1 config + neutral inherited sweep, stopped.
		song.filterTable[fbase * 4 .. fbase * 4 + 4] = [0x90, 0x01, 0x00, 0x00];
		song.filterTable[(fbase + 1) * 4 .. (fbase + 1) * 4 + 4]
			= [0x00, 0x00, 0xff, 0x7f];
		song.insLabels[ins][] = ' ';
		immutable name = "New Sound";
		song.insLabels[ins][0 .. name.length] = name[];
		selectedWaveRow = base;
		clearSweepSelection();
		lockedKeyjamFit = 0;
		UI.statusline.display(format("New sound: Wave $%02X Pulse $%02X Filter $%02X.",
			base, pbase, fbase));
	}

	private void moveSelectedWave(int delta) {
		int ins = clampedIns();
		if(!selectedWaveNormal(ins)) return;
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		selectedWaveRow = clampInt(selectedWaveRow + delta, start, close - 1);
	}

	private void waveRowOp(bool insert) {
		int ins = clampedIns();
		if(!selectedWaveNormal(ins)) {
			UI.statusline.display("Select a wave row first.");
			return;
		}
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		if(insert && (song.tWave.seekTableEnd() >= 255 || close >= 255)) {
			UI.statusline.display("Wave table full - cannot insert row.");
			return;
		}
		if(!insert && close - start <= 1) {
			UI.statusline.display("A wave program must keep one value row.");
			return;
		}
		authorizeWaveMutation(ins, (int delta) {
			selectedWaveRow += delta;
			waveRowOpRaw(insert);
			retriggerIfSounding();
		});
	}

	private void waveRowOpRaw(bool insert) {
		int ins = clampedIns();
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		if(insert) {
			int pos = selectedWaveRow + 1;
			song.tWave.insertRow(song, pos);
			song.waveTable[pos] = 0;
			song.waveTable[pos + 256] = 0;
			selectedWaveRow = pos;
		} else {
			int pos = selectedWaveRow;
			bool deletedTarget = song.waveTable[close] == 0x7f
				&& song.waveTable[close + 256] == pos;
			song.tWave.deleteRow(song, pos);
			int newClose = close - 1;
			if(deletedTarget) {
				int replacement = pos < newClose ? pos : newClose - 1;
				if(replacement >= start)
					song.waveTable[newClose + 256] = cast(ubyte)replacement;
				else {
					song.waveTable[newClose] = 0x7e;
					song.waveTable[newClose + 256] = 0;
				}
			}
			selectedWaveRow = min(pos, newClose - 1);
		}
	}

	private void querySelectedWaveByte(int column) {
		int ins = clampedIns();
		if(!selectedWaveNormal(ins)) return;
		int row = selectedWaveRow;
		string prompt = column == 0 ? "Wave 1: $" : "Wave 2: $";
		mainui.activateDialog(new QueryDialog(prompt, (int value) {
			if(column == 0 && (value == 0x7e || value == 0x7f)) {
				UI.statusline.display("Use [Loop] for wave end/loop markers.");
				return;
			}
			authorizeWaveMutation(ins, (int delta) {
				int target = row + delta;
				song.waveTable[target + column * 256] = cast(ubyte)value;
				selectedWaveRow = target;
				retriggerIfSounding();
			});
		}, 0x100));
	}

	private void queryWaveLoopTarget() {
		int ins = clampedIns();
		if(!selectedWaveNormal(ins)) return;
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		mainui.activateDialog(new QueryDialog("Loop target: $", (int target) {
			if(target < start || target >= close) {
				UI.statusline.display("Loop target must be an authored wave row.");
				return;
			}
			authorizeWaveMutation(ins, (int delta) {
				int targetClose = close + delta;
				song.waveTable[targetClose] = 0x7f;
				song.waveTable[targetClose + 256] = cast(ubyte)(target + delta);
				selectedWaveRow += delta;
				retriggerIfSounding();
			});
		}, 0x100));
	}

	// Canonical append-and-relocate fork, matching Song.insertInstrument: getProgram()
	// returns all reachable chunks compacted together; relocate its $7f targets to the
	// append base and repoint only the active instrument.
	private bool forkWaveProgramRaw(int ins, out int delta) {
		delta = 0;
		int start = song.instrumentTable[ins + 7 * 48];
		if(!song.tWave.isValid(start)) {
			UI.statusline.display("Invalid wave program - cannot fork.");
			return false;
		}
		auto wp = song.tWave.getProgram(start);
		int base = max(song.tWave.seekTableEnd(), start + 24);
		if(base + wp.wave1.length > 256) {
			UI.statusline.display("Wave table full - cannot fork program.");
			return false;
		}
		ubyte[] w1 = wp.wave1.dup;
		ubyte[] w2 = wp.wave2.dup;
		// getProgram() compacts reachable chunks to a zero-based payload while
		// preserving the active pointer as wp.offset within that payload. Loop
		// targets therefore relocate by the append base, whereas callers holding
		// absolute rows remap by (new active pointer - old active pointer). These
		// are different coordinate systems when unused chunks precede the program.
		int newStart = base + wp.offset;
		delta = newStart - start;
		foreach(i; 0 .. w1.length)
			if(w1[i] == 0x7f) w2[i] = cast(ubyte)(w2[i] + base);
		song.tWave.wave1[base .. base + w1.length] = w1[];
		song.tWave.wave2[base .. base + w2.length] = w2[];
		song.instrumentTable[ins + 7 * 48] = cast(ubyte)newStart;
		return true;
	}

	alias WaveMutation = void delegate(int rowDelta);
	private void authorizeWaveMutation(int ins, WaveMutation mutation) {
		bool makePrivate = waveProgramShared(ins) && !linkedEditActive(2, ins);
		if(makePrivate) {
			int start = song.instrumentTable[ins + 7 * 48];
			if(!song.tWave.isValid(start)) {
				UI.statusline.display("Invalid wave program - cannot fork.");
				return;
			}
			auto wp = song.tWave.getProgram(start);
			int base = max(song.tWave.seekTableEnd(), start + 24);
			if(base + wp.wave1.length > 256) {
				UI.statusline.display("Wave table full - cannot fork program.");
				return;
			}
		}
		// One transaction contains both the automatic fork and the requested edit.
		snapshotAllTables(false);
		int delta = 0;
		if(makePrivate && !forkWaveProgramRaw(ins, delta)) return;
		mutation(delta);
	}

	private int waveRowAtFrame(int ins, int frame, out int effectiveCtrl) {
		WaveFrameSim s = simWaveFrames(song.instrumentTable[ins + 7 * 48],
			waveTimeForInstrument(ins));
		if(s.rowOf.length == 0) { effectiveCtrl = 0; return -1; }
		frame = clampInt(frame, 0, cast(int)s.rowOf.length - 1);
		effectiveCtrl = s.ctrlOf[frame];
		return s.rowOf[frame];
	}

	private enum int WAVE_GESTURE_NONE = 0, WAVE_GESTURE_PITCH = 1,
		WAVE_GESTURE_DELAY = 2, WAVE_GESTURE_TARGET = 3;
	private int waveGestureForRow(int row) {
		if(row < 0 || row >= 256) return WAVE_GESTURE_NONE;
		int raw1 = song.waveTable[row], raw2 = song.waveTable[row + 256];
		if(raw1 == 0x7f) return WAVE_GESTURE_TARGET;
		if(raw1 == 0x7e || !((raw1 >= 0x00 && raw1 <= 0x5f)
				|| (raw1 >= 0x80 && raw1 <= 0xdf))) return WAVE_GESTURE_NONE;
		if(raw2 >= 0x01 && raw2 <= 0x0f) return WAVE_GESTURE_DELAY;
		if(raw2 == 0x00 || (raw2 >= 0x10 && raw2 <= 0xef))
			return WAVE_GESTURE_PITCH;
		return WAVE_GESTURE_NONE;
	}

	private bool writeWaveBit(int row, int effectiveCtrl, int bit, bool on) {
		if(waveGestureForRow(row) != WAVE_GESTURE_PITCH) return false;
		int mask = 1 << bit;
		int ctrl = on ? effectiveCtrl | mask : effectiveCtrl & ~mask;
		int raw2 = song.waveTable[row + 256];
		ubyte encoded;
		if(!representableWaveControl(ctrl, encoded)) {
			UI.statusline.display("Wave control cannot be represented in W2; unchanged.");
			return false;
		}
		if(encoded == raw2) return false;
		song.waveTable[row + 256] = encoded;
		return true;
	}

	private bool canBeginWaveBitPaint(int ins, int frame, int bit) {
		int ctrl;
		int row = waveRowAtFrame(ins, frame, ctrl);
		if(waveGestureForRow(row) != WAVE_GESTURE_PITCH) return false;
		int desired = ctrl ^ (1 << bit);
		ubyte ignored;
		if(representableWaveControl(desired, ignored)) return true;
		UI.statusline.display("Wave control cannot be represented in W2; unchanged.");
		return false;
	}

	private void toggleWaveBitRaw(int ins, int frame, int bit) {
		int ctrl;
		int row = waveRowAtFrame(ins, frame, ctrl);
		if(waveGestureForRow(row) != WAVE_GESTURE_PITCH) return;
		writeWaveBit(row, ctrl, bit, !(ctrl & (1 << bit)));
	}

	private void beginWaveBitPaint(int ins, int frame, int bit) {
		int ctrl;
		int row = waveRowAtFrame(ins, frame, ctrl);
		if(waveGestureForRow(row) != WAVE_GESTURE_PITCH) return;
		waveBitPainting = true;
		waveBitChanged = false;
		waveBitDesired = !(ctrl & (1 << bit));
		waveBitPaintIns = ins;
		waveBitLastRow = row;
		waveBitLastBit = bit;
		waveBitChanged = writeWaveBit(row, ctrl, bit, waveBitDesired);
	}

	private void updateWaveBitPaint(ref Geo g, int x, int y) {
		if(!waveBitPainting) return;
		int frame, bit;
		if(!waveLaneAt(g, x, y, frame, bit)) return;
		int ctrl;
		int row = waveRowAtFrame(waveBitPaintIns, frame, ctrl);
		if(row == waveBitLastRow && bit == waveBitLastBit) return;
		waveBitLastRow = row;
		waveBitLastBit = bit;
		waveBitChanged = writeWaveBit(row, ctrl, bit, waveBitDesired) || waveBitChanged;
	}

	// ---- frequency band vertical mapping (§9.4) ----
	// SINGLE SOURCE OF TRUTH for value<->pixel on the frequency band. drawFreqBand and the
	// pitch drag MUST share it: when they disagreed (a fixed 0x5f hit-test against an
	// auto-fitted draw) a dragged block was written ~8x the value it was drawn at, so it
	// never followed the cursor. Change these two together or not at all.
	//
	// Semitones (transOf: relative offset, or absolute note number) map linearly onto the
	// band, bottom = 0. The scale auto-fits the program's largest value with a one-octave
	// floor so small arps stay legible; while a drag is live it is latched (waveGraphScale)
	// so the axis cannot move under the cursor mid-gesture.
	// The axis auto-fits to the program's peak, which would make it depend on the very
	// value being edited: lowering the peak re-fitted the axis the moment the drag ended,
	// so the block jumped away from the cursor (measured -16px at the minimum window,
	// -10px at ~90-row autoscale). Hold the fitted scale while the editor stays on one
	// instrument and only ever let it GROW, so no edit can move the axis under the user.
	// Re-fits when the instrument changes or a new session starts.
	private int freqScaleSticky = -1, freqScaleStickyIns = -1;

	private int freqBandScaleFrom(int ins, ref WaveFrameSim s) {
		if(waveGraphScale > 0) return waveGraphScale;   // latched for a whole drag
		int n = min(cast(int)s.transOf.length, visFrames);
		int fit = 12;   // one octave: keep small arps visible
		foreach(f; 0 .. n) if(s.transOf[f] > fit) fit = s.transOf[f];
		if(freqScaleStickyIns != ins) {
			freqScaleStickyIns = ins;
			freqScaleSticky = fit;
		}
		else if(fit > freqScaleSticky) freqScaleSticky = fit;   // grow only
		return freqScaleSticky;
	}

	// Same fit for callers that have no simulation at hand (the hit-test). The draw path
	// uses freqBandScaleFrom with the sim it already has rather than simulating twice.
	private int freqBandScale(int ins) {
		if(waveGraphScale > 0) return waveGraphScale;
		WaveFrameSim s = simWaveFrames(song.instrumentTable[ins + 7 * 48],
			waveTimeForInstrument(ins));
		return freqBandScaleFrom(ins, s);
	}

	private int yForPitch(int topPx, int botPx, int scale, int pitch) {
		int h = botPx - topPx; if(h < 1) h = 1;
		if(scale < 1) scale = 1;
		return botPx - clampInt(pitch, 0, scale) * h / scale;
	}

	private int pitchForY(int topPx, int botPx, int scale, int py) {
		int h = botPx - topPx; if(h < 1) h = 1;
		if(scale < 1) scale = 1;
		return clampInt(cast(int)lround(cast(double)(botPx - py) * scale / h), 0, 0x5f);
	}

	// Exact mouse pixel row for a vertical drag, given the character cell the UI dispatched.
	// Trusted only when it agrees with that cell: a synthetic click (ccdriver, tests) moves
	// no real mouse, so com.fb.mousePixelY would still hold a stale position from an earlier
	// motion. Disagreement means "no pixel for this event" -> fall back to the cell centre,
	// which is what the rest of the editor uses.
	private int dragPixelY(int cellY) {
		int px = mousePixelY;
		if(px >= 0 && px / FONT_Y == cellY) return px;
		return cellY * FONT_Y + FONT_Y / 2;
	}

	// Frequency graph hit maps through the same delay-aware row timeline the graph
	// draws. Clicking selects that authored row; dragging edits its meaningful axis:
	// pitch rows move vertically, delay rows ($01..$0F in wave2) resize horizontally.
	private bool waveGraphRowAt(ref Geo g, int x, int y, out int row) {
		row = -1;
		int px = x * FONT_X + FONT_X / 2;
		int py = y * FONT_Y + FONT_Y / 2;
		int topPx, botPx; bandBox(g, 2, topPx, botPx);
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx
				|| py < topPx || py >= botPx) return false;
		int frame = cast(int)lround(viewport.tickForPixel(g, px));
		if(frame < 0) return false;
		int ins = clampedIns();
		WaveFrameSim s = simWaveFrames(song.instrumentTable[ins + 7 * 48],
			waveTimeForInstrument(ins));
		if(frame >= cast(int)s.rowOf.length) return false;
		row = s.rowOf[frame];
		return row >= 0 && song.waveTable[row] != 0x7e && song.waveTable[row] != 0x7f;
	}

	private int waveGraphCursorAt(ref Geo g, int x, int y) {
		int row;
		if(!waveGraphRowAt(g, x, y, row)) return CURSOR_NORMAL;
		int gesture = waveGestureForRow(row);
		return gesture == WAVE_GESTURE_DELAY ? CURSOR_HORIZONTAL
			: gesture == WAVE_GESTURE_PITCH ? CURSOR_VERTICAL : CURSOR_NORMAL;
	}

	private void beginWaveGraphDrag(ref Geo g, int x, int y, int row) {
		int gesture = waveGestureForRow(row);
		if(gesture != WAVE_GESTURE_PITCH && gesture != WAVE_GESTURE_DELAY) return;
		selectedWaveRow = row;
		clearSweepSelection();
		waveGraphDragging = true;
		waveGraphMoved = false;
		waveGraphAuthorizing = false;
		waveGraphRow = row;
		int raw2 = song.waveTable[row + 256];
		waveGraphField = gesture == WAVE_GESTURE_DELAY ? 1 : 0;
		waveGraphAnchorX = x;
		waveGraphAnchorValue = waveGraphField ? raw2 : song.waveTable[row];
		// Latch the band's vertical scale for the gesture (see waveGraphScale). Must be read
		// BEFORE the first edit, while it still reflects what the user sees on screen. Clear
		// first so freqBandScale() recomputes instead of returning a previous gesture's latch.
		waveGraphScale = -1;
		if(waveGraphField == 0) waveGraphScale = freqBandScale(clampedIns());
		clickWasButton = true;
	}

	private void updateWaveGraphDrag(ref Geo g, int x, int y) {
		if(!waveGraphDragging || waveGraphRow < 0) return;
		if(!waveGraphMoved) {
			if(waveGraphAuthorizing) return;
			waveGraphAuthorizing = true;
			int ins = clampedIns();
			authorizeWaveMutation(ins, (int delta) {
				waveGraphAuthorizing = false;
				waveGraphRow += delta;
				selectedWaveRow += delta;
				waveGraphMoved = true;
				Geo committedGeometry = layout();
				updateWaveGraphDragRaw(committedGeometry, x, y);
			});
			return;
		}
		updateWaveGraphDragRaw(g, x, y);
	}

	private void updateWaveGraphDragRaw(ref Geo g, int x, int y) {
		if(waveGraphField == 1) {
			song.waveTable[waveGraphRow + 256] = cast(ubyte)clampInt(
				waveGraphAnchorValue + (x - waveGraphAnchorX), 1, 0x0f);
			return;
		}
		int topPx, botPx; bandBox(g, 2, topPx, botPx);
		// Sub-cell Y: the band is only ~5 character rows tall, so the cell-granular y the
		// UI dispatches would quantize the whole pitch range to 5 reachable values (~20 of
		// 96 units per step). Prefer the exact pixel the mouse is at; fall back to the cell
		// centre when it is unavailable (headless/driver-injected clicks set no pixel).
		int py = dragPixelY(y);
		int scale = freqBandScale(clampedIns());
		int pitch = pitchForY(topPx, botPx, scale, py);
		bool absolute = waveGraphAnchorValue >= 0x80 && waveGraphAnchorValue <= 0xdf;
		song.waveTable[waveGraphRow] = cast(ubyte)(absolute ? 0x80 | pitch : pitch);
		if(traceMouseDrag) {
			// drawnY is where the staircase will put this value; delta is how far the block
			// ends up from the cursor. Anything beyond half a step means it is not tracking.
			int drawnY = yForPitch(topPx, botPx, scale, pitch);
			import std.stdio : stderr;
			stderr.writefln("pitchdrag: cellY=%d mousePixelY=%d usedY=%d (fallback=%s) "
				~ "band=%d..%d scale=%d pitch=%d drawnY=%d delta=%+d stepPx=%.2f",
				y, mousePixelY, py, py != mousePixelY, topPx, botPx, scale, pitch,
				drawnY, drawnY - py, scale > 0 ? cast(double)(botPx - topPx) / scale : 0.0);
		}
	}

	private int waveRetargetRowAt(int ins, ref Geo g, int cellX) {
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		if(close <= start) return -1;
		WaveFrameSim s = simWaveFrames(start, waveTimeForInstrument(ins), MAX_VIS);
		int pointerFrame = cast(int)lround(viewport.tickForPixel(g, cellX * FONT_X + FONT_X / 2));
		// In range, the simulated row at the pointer owns the tick. Choosing a row by
		// nearest start instead makes the latter half of a long delay jump early.
		int authoredEnd = waveProgramExtent(start, waveTimeForInstrument(ins));
		if(pointerFrame >= 0 && pointerFrame < authoredEnd
				&& pointerFrame < cast(int)s.rowOf.length) {
			int owner = s.rowOf[pointerFrame];
			if(owner >= start && owner < close) return owner;
		}
		// Only an off-range pointer needs a nearest legal authored-row fallback.
		int bestRow = -1, bestDistance = int.max;
		bool[256] seen;
		foreach(frame, row; s.rowOf) {
			if(row < start || row >= close || seen[row]) continue;
			seen[row] = true;
			int distance = abs(cast(int)frame - pointerFrame);
			if(distance < bestDistance) { bestDistance = distance; bestRow = row; }
		}
		return bestRow;
	}

	private void beginWaveLoopDrag(int ins) {
		int start = song.instrumentTable[ins + 7 * 48];
		waveLoopDragging = true;
		waveLoopAuthorizing = false;
		waveLoopMoved = false;
		waveLoopIns = ins;
		waveLoopCloseRow = waveCloseRow(start);
		clickWasButton = true;
	}

	private void updateWaveLoopDrag(ref Geo g, int cellX) {
		if(!waveLoopDragging || waveLoopCloseRow < 0) return;
		if(!waveLoopMoved) {
			if(waveLoopAuthorizing) return;
			waveLoopAuthorizing = true;
			authorizeWaveMutation(waveLoopIns, (int delta) {
				waveLoopAuthorizing = false;
				waveLoopCloseRow += delta;
				if(selectedWaveRow >= 0) selectedWaveRow += delta;
				waveLoopMoved = true;
				Geo committedGeometry = layout();
				updateWaveLoopDragRaw(committedGeometry, cellX);
			});
			return;
		}
		updateWaveLoopDragRaw(g, cellX);
	}

	private void updateWaveLoopDragRaw(ref Geo g, int cellX) {
		int target = waveRetargetRowAt(waveLoopIns, g, cellX);
		if(target < 0) return;
		// §22 position decides the loop type: dropping the loop-back on the LAST authored
		// row (or dragging fully to the end) is "loop to previous" ($7E, a one-row sustain);
		// any earlier row is a $7F jump back to that row. One drag sets and moves both kinds.
		if(target >= waveLoopCloseRow - 1) {
			song.waveTable[waveLoopCloseRow] = 0x7e;
			song.waveTable[waveLoopCloseRow + 256] = 0;
		} else {
			song.waveTable[waveLoopCloseRow] = 0x7f;
			song.waveTable[waveLoopCloseRow + 256] = cast(ubyte)target;
		}
	}

	private SoundEditorWaveAddDebug waveAddTarget(int ins, ref Geo g) {
		SoundEditorWaveAddDebug a;
		a.frame = a.x = a.y = a.close = -1;
		a.reason = "invalid";
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		int topPx, botPx; bandBox(g, 2, topPx, botPx);
		if(close < start) return a;
		a.close = close;
		// Creation is authored-terminal chrome. Put `+` in the nearest free top-strip
		// cell immediately BEFORE the END/LOOP triangle. For a very short loop where
		// that cell is another triangle, search deterministically outward, left first;
		// every visible valid programme therefore keeps both targets reachable.
		a.frame = waveProgramExtent(start, waveTimeForInstrument(ins));
		auto loopShape = waveLoopGeometry(ins, g);
		int minCell = g.plotX0px / FONT_X;
		int maxCell = (g.plotX0px + g.plotWpx - 1) / FONT_X;
		int preferred = loopShape.endVisible ? loopShape.endLeft / FONT_X - 1
			: viewport.xForFrame(g, a.frame) / FONT_X;
		bool freeCell(int cell) {
			if(cell < minCell || cell > maxCell) return false;
			int left = cell * FONT_X, right = left + FONT_X;
			bool hitsStart = loopShape.startVisible
				&& right > loopShape.startLeft && left < loopShape.startRight;
			bool hitsEnd = loopShape.endVisible
				&& right > loopShape.endLeft && left < loopShape.endRight;
			return !hitsStart && !hitsEnd;
		}
		int plotCells = maxCell - minCell + 1;
		foreach(distance; 0 .. plotCells) {
			int leftCandidate = preferred - cast(int)distance;
			if(freeCell(leftCandidate)) { a.x = leftCandidate; break; }
			int rightCandidate = preferred + 1 + cast(int)distance;
			if(freeCell(rightCandidate)) { a.x = rightCandidate; break; }
		}
		// Creation is top-strip chrome like END/LOOP, leaving the frequency gesture
		// row below fully available for pitch and delay selection/dragging.
		a.y = (topPx + FONT_Y - 1) / FONT_Y;
		a.visible = viewport.frameInView(a.frame) && a.x >= minCell;
		a.enabled = song.tWave.seekTableEnd() < 255 && close < 255;
		a.reason = !a.enabled ? "full" : close == start ? "end-only" : "normal";
		return a;
	}

	private void drawWaveAddTarget(int ins, ref Geo g) {
		auto a = waveAddTarget(ins, g);
		if(!a.visible) return;
		screen.cprint(a.x, a.y, a.enabled ? COL_TITLE : COL_DIM, 0, "+");
	}

	private bool waveAddTargetAt(int ins, ref Geo g, int x, int y,
			out bool enabled) {
		auto a = waveAddTarget(ins, g);
		enabled = a.enabled;
		return a.visible && x == a.x && y == a.y;
	}

	private void appendWaveRowAtEnd(int ins) {
		int start = song.instrumentTable[ins + 7 * 48];
		int close = waveCloseRow(start);
		if(close < start) {
			UI.statusline.display("Invalid wave program - cannot append row.");
			return;
		}
		if(song.tWave.seekTableEnd() >= 255 || close >= 255) {
			UI.statusline.display("Wave table full - cannot append row.");
			return;
		}
		authorizeWaveMutation(ins, (int delta) {
			int targetClose = close + delta;
			song.tWave.insertRow(song, targetClose);
			song.waveTable[targetClose] = 0;
			song.waveTable[targetClose + 256] = 0;
			selectedWaveRow = targetClose;
			clearSweepSelection();
			retriggerIfSounding();
		});
	}

	private void drawSelectedWaveRow(int ins, ref Geo g) {
		if(!selectedWaveNormal(ins)) return;
		WaveFrameSim s = simWaveFrames(song.instrumentTable[ins + 7 * 48],
			waveTimeForInstrument(ins));
		int first = -1, last = -1;
		foreach(f, row; s.rowOf) {
			if(row == selectedWaveRow) { if(first < 0) first = cast(int)f; last = cast(int)f + 1; }
			else if(first >= 0) break;
		}
		if(first < 0) return;
		int topPx, botPx; bandBox(g, 2, topPx, botPx);
		int xa = viewport.xForFrame(g, first), xb = viewport.xForFrame(g, last);
		if(xb <= xa) xb = xa + 1;
		video.olRect(xa, topPx, xb - xa, botPx - topPx, COL_STEPSEL);
	}

	// Return the clicked wave frame + SID control bit. Lane geometry exactly mirrors
	// drawWaveBand (top lane Noise/b7, bottom lane Gate/b0).
	private bool waveLaneAt(ref Geo g, int x, int y, out int frame, out int bit) {
		frame = bit = -1;
		int px = x * FONT_X + FONT_X / 2;
		int py = y * FONT_Y + FONT_Y / 2;
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx) return false;
		int topPx, botPx; bandBox(g, 5, topPx, botPx);
		int topRow = (topPx + FONT_Y - 1) / FONT_Y;
		int lane = y - topRow;
		if(lane < 0 || lane >= 8 || py > botPx) return false;
		frame = cast(int)lround(viewport.tickForPixel(g, px));
		if(frame < 0) return false;
		bit = 7 - lane;
		return true;
	}

	// ---- ADSR-curve drag handles (§19.2/§19.3 graph gesture) ----

	// The 4 A/D/S/R handle centres (device pixels) for the CURRENT bytes, so the drawer
	// and the hit-test agree. Positions mirror drawAdsrBand's sim geometry: attack peak
	// (amp 1.0 at aF), decay->sustain knee (sustain level at aF+dF), a sustain-level grab
	// on the plateau, and the release tail (amp 0 at gateEnd+rF). inView[i] = drawable/
	// grabbable at the current zoom/pan.
	private void adsrHandlePositions(int ins, ref Geo g, out int[4] hx, out int[4] hy, out bool[4] inView) {
		int topPx, botPx; bandBox(g, 1, topPx, botPx);
		int h = botPx - topPx; if(h < 1) h = 1;
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		ubyte sr = song.instrumentTable[ins + 1 * 48];
		int attack = (ad >> 4) & 0x0f, decay = ad & 0x0f;
		int sustain = (sr >> 4) & 0x0f, release = sr & 0x0f;
		float sLvl = sustain / 15.0f;
		float aF = ATTACK_TIME_MS[attack]         / tickMs;
		float dF = DECAY_RELEASE_TIME_MS[decay]   / tickMs;
		float rF = DECAY_RELEASE_TIME_MS[release] / tickMs;
		if(rF < 0.5f) rF = 0.5f;
		float gateEnd = nominalGateFrames;
		float sustMid = (min(aF + dF, gateEnd) + gateEnd) / 2.0f;
		float[4] hf   = [aF, aF + dF, sustMid, gateEnd + rF];
		float[4] hlvl = [1.0f, sLvl, sLvl, 0.0f];
		foreach(i; 0 .. 4) {
			hx[i] = viewport.xForFrame(g, hf[i]);
			hy[i] = botPx - cast(int)lround(clamp01(hlvl[i]) * h);
			inView[i] = viewport.frameInView(hf[i]);
		}
	}

	// Draw a small square marker at each in-view A/D/S/R handle (the grabbed one lights
	// up red while dragging). Read-only sizing; positions come straight from the bytes.
	private void drawAdsrHandles(int ins, ref Geo g) {
		int[4] hx, hy; bool[4] inView;
		adsrHandlePositions(ins, g, hx, hy, inView);
		foreach(i; 0 .. 4) {
			if(!inView[i]) continue;
			auto ad = cast(AdsrDrag)activeGesture;
			int c = (ad && ad.handle == i) ? COL_TRIGGER : COL_HEAD;
			video.olFillRect(hx[i] - 2, hy[i] - 2, 5, 5, c);
		}
	}

	// The A/D/S/R handle (ADSR_*) nearest screen cell (x,y) within the grab radius, or -1.
	private int adsrHandleAt(ref Geo g, int cellx, int celly) {
		int[4] hx, hy; bool[4] inView;
		adsrHandlePositions(clampedIns(), g, hx, hy, inView);
		int px = cellx * FONT_X + FONT_X / 2;
		int py = celly * FONT_Y + FONT_Y / 2;
		int best = -1, bestd = ADSR_HIT_PX * ADSR_HIT_PX + 1;
		foreach(i; 0 .. 4) {
			if(!inView[i]) continue;
			int dx = px - hx[i], dy = py - hy[i];
			int d = dx * dx + dy * dy;
			if(d <= ADSR_HIT_PX * ADSR_HIT_PX && d < bestd) { bestd = d; best = i; }
		}
		return best;
	}

	// Nearest SID nibble 0..15 whose ms-table entry is closest to `ms`.
	private static int nearestMs(ref const float[16] tbl, double ms) {
		int best = 0; double bd = 1e18;
		foreach(i; 0 .. 16) {
			double d = tbl[i] - ms; if(d < 0) d = -d;
			if(d < bd) { bd = d; best = i; }
		}
		return best;
	}

	// Map the current ADSR-handle drag to the nearest SID nibble and write the byte
	// (curve + column redraw from the byte automatically). No undo/re-trigger here — the
	// gesture's snapshot was taken at press, the re-trigger fires once on release.
	private void adsrDragUpdate(ref Geo g, int cellx, int celly, int handle) {
		int ins = clampedIns();
		int px = cellx * FONT_X + FONT_X / 2;
		// Sustain is read off the exact mouse pixel: the ADSR band is ~5 character rows
		// tall, so a cell centre reached only ~6 of the 16 sustain levels, ~3 apart.
		// adsrHandlePositions draws the handle at the matching pixel.
		int py = dragPixelY(celly);
		double t = viewport.tickForPixel(g, px);
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		int attack = (ad >> 4) & 0x0f, decay = ad & 0x0f;
		float aF = ATTACK_TIME_MS[attack]       / tickMs;
		float dF = DECAY_RELEASE_TIME_MS[decay] / tickMs;
		switch(handle) {
			case ADSR_ATTACK: {
				double ms = t * tickMs; if(ms < 0) ms = 0;
				setNibbleAbs(ins, 0, true, nearestMs(ATTACK_TIME_MS, ms));
				break;
			}
			case ADSR_DECAY: {
				// The decay-end dot sits at (decay time, sustain level): X sets the decay
				// nibble, Y sets the SUSTAIN level — so dragging it up/down adjusts sustain.
				double ms = (t - aF) * tickMs; if(ms < 0) ms = 0;
				setNibbleAbs(ins, 0, false, nearestMs(DECAY_RELEASE_TIME_MS, ms));
				int topPx, botPx; bandBox(g, 1, topPx, botPx);
				int hh = botPx - topPx; if(hh < 1) hh = 1;
				double lvl = cast(double)(botPx - py) / hh;
				setNibbleAbs(ins, 1, true, clampInt(cast(int)lround(lvl * 15.0), 0, 15));
				break;
			}
			case ADSR_SUSTAIN: {
				int topPx, botPx; bandBox(g, 1, topPx, botPx);
				int h = botPx - topPx; if(h < 1) h = 1;
				double lvl = cast(double)(botPx - py) / h;
				setNibbleAbs(ins, 1, true, clampInt(cast(int)lround(lvl * 15.0), 0, 15));
				break;
			}
			case ADSR_RELEASE: {
				double ms = (t - nominalGateFrames) * tickMs; if(ms < 0) ms = 0;
				setNibbleAbs(ins, 1, false, nearestMs(DECAY_RELEASE_TIME_MS, ms));
				break;
			}
			default: break;
		}
	}

	// ---- §20 P4b-1 pulse/filter program LEVEL editing ----

	// The sweep band under a press: 0 = Pulse (band 3), 1 = Filter (band 4), -1 = none
	// or the instrument has no editable program in that band. Only a press inside the
	// band's plot pixel region counts (a "vertical grab" of the level). Hit-tested AFTER
	// the ADSR handles / scrollbar / zoom buttons, so those keep working.
	private int sweepBandAt(ref Geo g, int x, int y) {
		// Mouse input is character-cell granular. Test the cell CENTRE, matching every
		// handle/edge hit-test below, so the top and bottom cell of a band remain usable.
		int px = x * FONT_X + FONT_X / 2;
		int py = y * FONT_Y + FONT_Y / 2, pyTop = y * FONT_Y;
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx) return -1;
		int ins = clampedIns();
		if(py >= g.bandTopPx[3] && py < g.bandTopPx[4]) {
			int ptr = song.instrumentTable[ins + 5 * 48];
			if(ptr >= 1 && ptr <= 0x3f) return 0;    // pulse program (not fixed $80+/off)
		}
		// Preserve the established Filter cell ownership; Phase 3's full-height edge
		// correction is pulse-specific and must not move existing filter gestures.
		if(pyTop >= g.bandTopPx[4] && pyTop < g.bandTopPx[5]) {
			int ptr = song.instrumentTable[ins + 4 * 48];
			if(ptr >= 1 && ptr <= 0x3f) return 1;    // filter program (not off)
		}
		return -1;
	}

	// Pulse/Filter plot under a click even when no editable program exists. Used only
	// for immediate create/convert-on-first-drag; regular editing still goes through
	// sweepBandAt and therefore cannot accidentally treat a pointer as a row.
	private int emptySweepBandAt(ref Geo g, int x, int y) {
		int px = x * FONT_X, py = y * FONT_Y;
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx) return -1;
		int ins = clampedIns();
		if(py >= g.bandTopPx[3] && py < g.bandTopPx[4]) {
			int ptr = song.instrumentTable[ins + 5 * 48];
			if(ptr == 0 || ptr >= 0x40) return 0;
		}
		if(py >= g.bandTopPx[4] && py < g.bandTopPx[5]) {
			int ptr = song.instrumentTable[ins + 4 * 48];
			if(ptr <= 0 || ptr >= 0x40) return 1;
		}
		return -1;
	}

	private bool createSweepProgram(int table, int ins, int clickedValue) {
		auto k = sweepKind(table);
		int base = k.seekTableEnd();
		if(base < 1) base = 1; // row 0 is the player's inert/stop sentinel
		// Match the backend's instrument-import guard: keep row 63 as spare/sentinel.
		if(base > 0x3e) {
			UI.statusline.display(format("%s table full - cannot create program.", k.name));
			return false;
		}
		snapshotAllTables(true);
		if(table == 0) {
			int ptr = song.instrumentTable[ins + 5 * 48];
			// Converting a direct $80-$8f pulse keeps its audible fixed width. A truly
			// empty pointer uses the clicked graph level as the initial value.
			int initial = ptr >= 0x80 ? ((ptr & 0x0f) << 8) : clickedValue;
			song.pulseTable[base * 4 + 0] = 0;
			song.pulseTable[base * 4 + 1] = 0;
			song.pulseTable[base * 4 + 2] = encodeInitB2(0, initial);
			song.pulseTable[base * 4 + 3] = 0x7f;
			song.instrumentTable[ins + 5 * 48] = cast(ubyte)base;
		} else {
			int route = viewVoice >= 0 && viewVoice < 3 ? (1 << viewVoice) : 1;
			song.filterTable[base * 4 + 0] = 0x90; // config row, LP mode
			song.filterTable[base * 4 + 1] = cast(ubyte)route; // res 0, current voice routed
			song.filterTable[base * 4 + 2] = encodeInitB2(1, clickedValue);
			song.filterTable[base * 4 + 3] = 0x7f;
			song.instrumentTable[ins + 4 * 48] = cast(ubyte)base;
		}
		selectedWaveRow = -1;
		selectedSweepTable = table;
		selectedSweepRow = selectedSweepRowEnd = base;
		linkedEditKind = linkedEditStart = -1;
		return true;
	}

	// The SweepTable row producing the frame under the press x (via the sim's per-frame
	// rowOf), or -1 if the program is empty. This is the row whose init b2 the drag edits.
	private int sweepRowAtPress(int table, ref Geo g, int x) {
		int px = x * FONT_X + FONT_X / 2;
		int f = cast(int)lround(viewport.tickForPixel(g, px));
		if(f < 0) f = 0;
		int ins = clampedIns();
		auto k = sweepKind(table);
		SweepSim s = sweepSim(k, song.instrumentTable[ins + k.insCol * 48]);
		if(s.rowOf.length == 0) return -1;
		// A stopped program has genuine empty space after its final frame. Do not clamp
		// arbitrary clicks in that space onto the last row. But a one-frame filter CONFIG
		// block can be narrower than our cell-granular mouse input; keep one cell of hit
		// tolerance at the visible end so it can still be selected and [Add] can create
		// the first sweep row after it.
		if(f >= cast(int)s.rowOf.length) {
			int pressX = x * FONT_X + FONT_X / 2;
			int endX = viewport.xForFrame(g, cast(int)s.rowOf.length);
			if(s.rowOf.length > 0 && abs(pressX - endX) <= FONT_X * 2)
				return s.rowOf[$ - 1];
			return -1;
		}
		return s.rowOf[f];
	}

	// The set of SweepTable rows reachable from startRow via the b3 jump chain (the
	// program). Empty for a fixed/off pointer (<=0 or >=0x40). Same traversal simPulse/
	// simFilter use, so it matches exactly what plays.
	private bool[0x40] sweepProgramRows(int table, int startRow) {
		bool[0x40] rows;
		if(startRow <= 0 || startRow >= 0x40) return rows;
		const(ubyte)[] t = sweepKind(table).table;
		int row = startRow;
		while(row >= 0 && row < 0x40 && !rows[row]) {
			rows[row] = true;
			int b3 = t[row * 4 + 3];
			if(b3 == 0) row = (row + 1) & 0x3f;
			else if(b3 <= 0x3f) row = b3;
			else break;                    // $7f stop / illegal
		}
		return rows;
	}

	// True if this instrument's program shares ANY row with another instrument's program
	// in the same table (walk all 48 pointer bytes + their chains). §20.2 sharing check.
	private bool sweepProgramShared(int table, int ins) {
		int col = sweepKind(table).insCol;
		bool[0x40] mine = sweepProgramRows(table, song.instrumentTable[ins + col * 48]);
		bool any = false;
		foreach(r; mine) if(r) { any = true; break; }
		if(!any) return false;
		foreach(j; 0 .. 48) {
			if(j == ins) continue;
			bool[0x40] other = sweepProgramRows(table, song.instrumentTable[j + col * 48]);
			foreach(r; 0 .. 0x40) if(mine[r] && other[r]) return true;
		}
		return false;
	}

	// §20.2 fork: allocate a private copy of this instrument's program at seekTableEnd,
	// copy its rows, relocate their internal b3 jump targets to the new base, and repoint
	// ONLY this instrument. Snapshots ALL tables + insLabels for undo (pointer shifts).
	// Returns false (no mutation) if the sweep table can't fit the copy — never corrupts.
	private bool forkSweepProgram(int table, int ins) {
		auto k = sweepKind(table);
		int col = k.insCol;
		ubyte[] t = k.table;
		int startRow = song.instrumentTable[ins + col * 48];
		bool[0x40] mine = sweepProgramRows(table, startRow);
		int[] rows;
		foreach(r; 0 .. 0x40) if(mine[r]) rows ~= r;
		int count = cast(int)rows.length;
		if(count == 0) return false;
		int base = k.seekTableEnd();
		// Capacity: mirror insertInstrument's guard (data length 256 bytes - 4 => row 63).
		if(base + count > 0x3f) {
			UI.statusline.display(format("%s table full - cannot fork program.", k.name));
			return false;
		}
		snapshotAllTables(true);
		// old row -> new row. Ascending placement keeps b3==0 "fall through to next row"
		// adjacency (a b3==0 row's successor is the immediately-following row, which is
		// the next element of the ascending set), and remaps explicit jumps below.
		int[0x40] newRow; newRow[] = -1;
		foreach(i, r; rows) newRow[r] = base + cast(int)i;
		lastSweepForkMap = newRow;
		// Copy source rows into a buffer FIRST (source/dest may alias), relocate jumps.
		ubyte[] buf = new ubyte[count * 4];
		foreach(i, r; rows) buf[i * 4 .. i * 4 + 4] = t[r * 4 .. r * 4 + 4];
		foreach(i; 0 .. count) {
			ubyte b3 = buf[i * 4 + 3];
			if(b3 >= 1 && b3 <= 0x3f) buf[i * 4 + 3] = cast(ubyte)newRow[b3];
		}
		t[base * 4 .. base * 4 + count * 4] = buf[];
		song.instrumentTable[ins + col * 48] = cast(ubyte)newRow[startRow];
		// §20 P4b-2 keep the selection (anchor + multi-block extent) pointing at the SAME
		// steps in the private copy (their row indices moved with the fork).
		if(selectedSweepTable == table) {
			if(selectedSweepRow >= 0 && selectedSweepRow < 0x40 && newRow[selectedSweepRow] >= 0)
				selectedSweepRow = newRow[selectedSweepRow];
			if(selectedSweepRowEnd >= 0 && selectedSweepRowEnd < 0x40 && newRow[selectedSweepRowEnd] >= 0)
				selectedSweepRowEnd = newRow[selectedSweepRowEnd];
		}
		return true;
	}

	private int remapForkedSweepRow(int row) {
		return row >= 0 && row < 0x40 && lastSweepForkMap[row] >= 0
			? lastSweepForkMap[row] : row;
	}
	private bool beginSweepDragMutation(int table, int ins) {
		bool isShared = sweepProgramShared(table, ins);
		if(isShared && !linkedEditActive(table, ins)) {
			if(!forkSweepProgram(table, ins)) return false;
			// Selection is remapped by forkSweepProgram; remap the in-flight gesture's rows.
			if(activeGesture) activeGesture.remapRows();
			return true;
		}
		snapshotAllTables(false);
		return true;
	}
	private bool beginSweepDiscreteMutation(int table, int ins, bool withLabels = false) {
		if(sweepProgramShared(table, ins) && !linkedEditActive(table, ins))
			return forkSweepProgram(table, ins); // fork owns the one atomic snapshot
		snapshotAllTables(withLabels);
		return true;
	}

	// Map the current level drag's mouse Y to the target value and write the edited
	// row's init byte b2 (pulse width nibble-swapped 0..4095 step 16, or filter cutoff
	// 0..2047 >> 3). The band redraws live from the byte (WYSIWYG). No undo/re-trigger
	// here — the gesture snapshot is at the first drag tick, the re-trigger at release.
	private void sweepLevelDragUpdate(ref Geo g, int celly, int sweepTable, int sweepRow) {
		auto k = sweepKind(sweepTable);
		int band = k.band;
		int maxVal = k.maxVal;
		int topPx, botPx; bandBox(g, band, topPx, botPx);
		int h = botPx - topPx; if(h < 1) h = 1;
		// Exact mouse pixel, not the cell centre: these bands are ~5 character rows tall,
		// so cell granularity offered ~5 of 4096 pulse widths (~745 apart) or of 2048
		// cutoffs. drawValueBand/filterCutoffY place the drawn level at the same pixel,
		// so the level now lands under the cursor.
		int py = dragPixelY(celly);
		int v;
		if(sweepTable == 1 && sweepRow >= 1) {
			v = filterCutoffValueAtPixel(g, py);
		} else {
			v = cast(int)lround(cast(double)(botPx - py) * maxVal / h);
			v = clampInt(v, 0, maxVal);
		}
		if(sweepRow < 0 || sweepRow >= 0x40) return;
		if(sweepTable == 0) song.pulseTable[sweepRow * 4 + 2] = encodeInitB2(0, v);
		else song.filterTable[sweepRow * 4 + 2] = encodeInitB2(1, v);
	}

	// ---- §20 P4b-3 filter resonance + mode editing ----

	// First CONFIG row (b0 & 0x80) reachable in the filter program chain from startRow,
	// or -1 (fixed/off pointer, or a program with no config row). This is the "active
	// config row" the mode chip cycles. Same chain traversal simFilter uses.
	private int filterFirstConfigRow(int startRow) {
		if(startRow <= 0 || startRow >= 0x40) return -1;
		bool[0x40] visited;
		int row = startRow, guard = 0;
		while(row >= 0 && row < 0x40 && !visited[row] && guard++ < 0x80) {
			visited[row] = true;
			if(song.filterTable[row * 4] & 0x80) return row;
			int b3 = song.filterTable[row * 4 + 3];
			if(b3 == 0) row = (row + 1) & 0x3f;
			else if(b3 <= 0x3f) row = b3;
			else break;                          // $7f stop / illegal
		}
		return -1;
	}
	private int filterControlConfigRow(int ins) {
		if(selectedSweepTable == 1 && selectedSweepRow >= 1) {
			if(song.filterTable[selectedSweepRow * 4] & 0x80)
				return selectedSweepRow;
			// A SWEEP is the editable body of its logical CONFIG+SWEEP block. Make
			// the gutter mode/route controls follow that governing CONFIG, including
			// after deletion compacts a loop and its instantaneous CONFIG marker shares
			// the preceding boundary. Falling back to the first CONFIG made later blocks
			// appear selectable while their LP/BP/HP and route controls edited block 1.
			SweepSim s = simFilter(song.instrumentTable[ins + 4 * 48]);
			foreach(f, row; s.rowOf)
				if(row == selectedSweepRow && f < s.cfgRowOf.length
						&& s.cfgRowOf[f] >= 1)
					return s.cfgRowOf[f];
		}
		return filterFirstConfigRow(song.instrumentTable[ins + 4 * 48]);
	}

	// CONFIG rows are instantaneous and share their X with the preceding SWEEP edge.
	// Give their visible vertical marker a small cell-granular selection zone so users
	// can select CONFIG instead of always resizing the block on its left.
	private int filterConfigRowAtPress(ref Geo g, int x) {
		int ins = clampedIns();
		int ptr = song.instrumentTable[ins + 4 * 48];
		if(ptr < 1 || ptr > 0x3f) return -1;
		SweepSim s = simFilter(ptr);
		int px = x * FONT_X + FONT_X / 2;
		int best = -1, bestDist = DUR_HIT_PX + 1;
		bool[0x40] seen;
		foreach(f, row; s.rowOf) {
			if(row < 1 || row >= 0x40 || seen[row]
					|| !(song.filterTable[row * 4] & 0x80)) continue;
			seen[row] = true;
			int d = abs(px - viewport.xForFrame(g, cast(int)f));
			if(d <= DUR_HIT_PX && d < bestDist) { best = row; bestDist = d; }
		}
		return best;
	}

	// Hit-test the resonance overlay line in the Filter band at press (x,y screen cells).
	// The grab zone is a small band (RES_HIT_PX) around the DRAWN res line (which lives in
	// the filter band by construction) at a column the filter program actually emits — a
	// zone distinct from the cutoff-level drag area. Returns the CONFIG row governing the
	// pressed frame (whose b1 hi nibble the drag edits), or -1 (press not on the res line /
	// no config row governs this frame). Checked in clickedAt BEFORE the P4b-1 cutoff-level
	// drag (and before sweepBandAt, whose cell-top band split can't reach a top-edge res
	// line) so grabbing the resonance line always wins over a cutoff-level drag.
	private enum int RES_HIT_PX = 6;
	private int filterResHandleAt(ref Geo g, int x, int y, out int targetRow) {
		targetRow = -1;
		int px = x * FONT_X;
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx) return -1;
		int ins = clampedIns();
		int ptr = song.instrumentTable[ins + 4 * 48];
		if(ptr < 1 || ptr > 0x3f) return -1;
		SweepSim s = simFilter(ptr);
		if(s.resOf.length == 0) return -1;
		int fx = px + FONT_X / 2;
		int f = cast(int)lround(viewport.tickForPixel(g, fx));
		if(f < 0 || f >= cast(int)s.resOf.length) return -1;   // press x is off the drawn program
		int cfg = (f < cast(int)s.cfgRowOf.length) ? s.cfgRowOf[f] : -1;
		if(cfg < 0 || cfg > 0x3f) return -1;    // no config row here -> no res edit
		int res = s.resOf[f]; if(res < 0) res = 0; if(res > 15) res = 15;
		int topPx, botPx; bandBox(g, 4, topPx, botPx);
		int hh = botPx - topPx; if(hh < 1) hh = 1;
		int ry = botPx - res * hh / 15;
		int clickPy = y * FONT_Y + FONT_Y / 2;
		if(abs(clickPy - ry) <= RES_HIT_PX) {
			targetRow = f < cast(int)s.rowOf.length ? s.rowOf[f] : -1;
			return cfg;
		}
		return -1;
	}

	// Map the resonance drag's mouse Y to res 0..15 (across the filter band height, the
	// inverse of the drawer's ry = botPx - res*h/15) and write the CONFIG row's b1 HIGH
	// nibble, PRESERVING the low nibble (routing). No undo/re-trigger here — the gesture
	// snapshot is at the first drag tick, the re-trigger at release.
	private void sweepResDragUpdate(ref Geo g, int celly, int sweepResRow) {
		if(sweepResRow < 0 || sweepResRow >= 0x40) return;
		int topPx, botPx; bandBox(g, 4, topPx, botPx);
		int hh = botPx - topPx; if(hh < 1) hh = 1;
		int py = celly * FONT_Y + FONT_Y / 2;
		int v = cast(int)lround(cast(double)(botPx - py) * 15.0 / hh);
		v = clampInt(v, 0, 15);
		ubyte b1 = song.filterTable[sweepResRow * 4 + 1];
		song.filterTable[sweepResRow * 4 + 1] = cast(ubyte)((v << 4) | (b1 & 0x0f));
	}

	// Cell-granular graph height cannot represent all sixteen resonance nibbles. These
	// visible mouse controls provide exact +/-1 refinement for the selected CONFIG row,
	// preserving its route mask, mode, cutoff and jump.
	private void nudgeSelectedFilterRes(int delta) {
		int ins = clampedIns(), row = selectedSweepRow;
		if(selectedSweepTable != 1 || row < 1
				|| !(song.filterTable[row * 4] & 0x80)) return;
		if(!beginSweepDiscreteMutation(1, ins)) return;
		doNudgeSelectedFilterRes(delta);
	}
	private void doNudgeSelectedFilterRes(int delta) {
		int row = selectedSweepRow;
		if(selectedSweepTable != 1 || row < 1
				|| !(song.filterTable[row * 4] & 0x80)) return;
		ubyte b1 = song.filterTable[row * 4 + 1];
		int res = clampInt((b1 >> 4) + delta, 0, 15);
		if(res == (b1 >> 4)) return;
		song.filterTable[row * 4 + 1] = cast(ubyte)((res << 4) | (b1 & 0x0f));
		UI.statusline.display(format("Filter CONFIG $%02X: Res %X Mask %X.",
			row, res, b1 & 0x0f));
		retriggerIfSounding();
	}

	// Give a sweep block its own piecewise-constant resonance. If it is already directly
	// preceded by a CONFIG row, that row is its constant. Otherwise insert a carry-cutoff
	// CONFIG between the previous block and this one, preserving mode, routing and jumps.
	private int ensureResConfigForTarget(int ins, int targetRow, int governingCfg) {
		if(targetRow < 1 || targetRow >= 0x40) return governingCfg;
		if(song.filterTable[targetRow * 4] & 0x80) return targetRow;
		int[] steps = sweepProgramSteps(1, ins);
		int at = -1;
		foreach(i, r; steps) if(r == targetRow) { at = cast(int)i; break; }
		if(at < 0) return governingCfg;
		if(at > 0) {
			int prev = steps[at - 1];
			if(song.filterTable[prev * 4] & 0x80) return prev;
		}
		if(sweepTableFull(1)) {
			UI.statusline.display("Filter table full - cannot add a resonance segment.");
			return -1;
		}
		ubyte mode = governingCfg >= 1 ? song.filterTable[governingCfg * 4] & 0x70 : 0x10;
		ubyte rr = governingCfg >= 1 ? song.filterTable[governingCfg * 4 + 1] : 0;
		int nr;
		if(at > 0) {
			int prev = steps[at - 1];
			nr = prev + 1;
			ct.purge.filterInsertRow(song, nr);
			ubyte next = song.filterTable[prev * 4 + 3];
			song.filterTable[prev * 4 + 3] = 0;
			song.filterTable[nr * 4 + 3] = next;
		} else {
			nr = targetRow;
			ct.purge.filterInsertRow(song, nr);
			song.instrumentTable[ins + 4 * 48] = cast(ubyte)nr;
			song.filterTable[nr * 4 + 3] = 0;
		}
		if(selectedSweepTable == 1) {
			if(selectedSweepRow >= nr) ++selectedSweepRow;
			if(selectedSweepRowEnd >= nr) ++selectedSweepRowEnd;
		}
		song.filterTable[nr * 4] = cast(ubyte)(0x80 | mode);
		song.filterTable[nr * 4 + 1] = rr;
		song.filterTable[nr * 4 + 2] = 0xff; // keep the cutoff continuous
		return nr;
	}

	// Three independent mode-bit buttons in the filter gutter. They remain clickable
	// while off: dark-gray = bit clear, yellow = bit set. Labels intentionally have no
	// brackets so LP/BP/HP read as three compact hardware bits.
	private void filterModeChipCell(ref Geo g, out int cx, out int cy) {
		cx = g.labelX;
		cy = g.bandTopPx[4] / FONT_Y + 1;
	}
	private bool filterModeChipVisible(ref Geo g) {
		int cx, cy; filterModeChipCell(g, cx, cy);
		return cy + 2 < g.bandTopPx[5] / FONT_Y;
	}
	private Button[3] filterModeButtons(int ins, ref Geo g) {
		static immutable string[3] labels = ["LP", "BP", "HP"];
		static immutable int[3] bits = [0x10, 0x20, 0x40];
		static immutable string[3] actions = ["se_lp", "se_bp", "se_hp"];
		Button[3] b;
		int cx, cy; filterModeChipCell(g, cx, cy);
		int cfg = filterControlConfigRow(ins);
		int mode = cfg >= 0 ? song.filterTable[cfg * 4] & 0x70 : 0;
		foreach(i; 0 .. 3) {
			b[i].x0 = cx; b[i].x1 = cx + 4; b[i].row = cy + cast(int)i;
			b[i].label = " " ~ labels[i] ~ " ";
			b[i].enabled = cfg >= 0;
			b[i].active = (mode & bits[i]) != 0;
			b[i].hovered = hovering && b[i].contains(hoverCellX, hoverCellY);
			b[i].pressed = pressedFilterAction == actions[i] && pressedFilterOver;
			b[i].restingLabel = BaseColor.darkgray;
			b[i].activeLabel = BaseColor.yellow;
			b[i].activeBackground = BaseColor.black;
		}
		return b;
	}
	private int filterModeBitAt(int ins, ref Geo g, int x, int y) {
		if(!filterModeChipVisible(g)) return 0;
		auto b = filterModeButtons(ins, g);
		static immutable int[3] bits = [0x10, 0x20, 0x40];
		foreach(i; 0 .. 3) if(b[i].enabled && b[i].contains(x, y)) return bits[i];
		return 0;
	}
	private void filterRouteChipCell(ref Geo g, out int cx, out int cy) {
		cx = g.labelX;
		cy = g.bandTopPx[4] / FONT_Y + 4;
	}
	private bool filterRouteChipVisible(ref Geo g) {
		int cx, cy; filterRouteChipCell(g, cx, cy);
		// The route chip occupies the one-character separator row immediately below
		// the three filter-mode chips.  That boundary row is still Filter chrome; the
		// next graph begins below it.
		return cy <= g.bandTopPx[5] / FONT_Y;
	}
	private static string filterRouteName(int route) {
		string s;
		if(route & 1) s ~= "1";
		if(route & 2) s ~= "2";
		if(route & 4) s ~= "3";
		if(route & 8) s ~= "X"; // SID external input
		return s.length ? s : "-";
	}
	private Button filterRouteButton(int ins, ref Geo g) {
		int cx, cy; filterRouteChipCell(g, cx, cy);
		int cfg = filterControlConfigRow(ins);
		string name = cfg < 0 ? "n/a" : filterRouteName(song.filterTable[cfg * 4 + 1] & 0x0f);
		Button b;
		b.label = " Rt" ~ name.leftJustify(4) ~ " "; // fixed eight-cell padded target
		b.x0 = cx; b.x1 = cx + cast(int)b.label.length; b.row = cy;
		b.enabled = cfg >= 0;
		b.hovered = hovering && b.contains(hoverCellX, hoverCellY);
		b.pressed = pressedFilterAction == "se_route" && pressedFilterOver;
		b.restingLabel = cfg < 0 ? BaseColor.darkgray : COL_VALUE;
		return b;
	}
	private bool filterRouteChipAt(int ins, ref Geo g, int x, int y) {
		if(!filterRouteChipVisible(g)) return false;
		auto b = filterRouteButton(ins, g);
		return b.enabled && b.contains(x, y);
	}
	private string filterActionAt(int ins, ref Geo g, int x, int y) {
		if(filterModeChipVisible(g)) {
			auto b = filterModeButtons(ins, g);
			static immutable string[3] actions = ["se_lp", "se_bp", "se_hp"];
			foreach(i; 0 .. 3) if(b[i].enabled && b[i].contains(x, y)) return actions[i];
		}
		if(filterRouteChipAt(ins, g, x, y)) return "se_route";
		return "";
	}
	private void activateFilterAction(int ins, string action) {
		switch(action) {
			case "se_lp": toggleFilterModeBit(ins, 0x10); break;
			case "se_bp": toggleFilterModeBit(ins, 0x20); break;
			case "se_hp": toggleFilterModeBit(ins, 0x40); break;
			case "se_route": cycleFilterRoute(ins); break;
			default: break;
		}
	}
	private void drawFilterModeChip(int ins, ref Geo g) {
		if(!filterModeChipVisible(g)) return;
		auto b = filterModeButtons(ins, g);
		foreach(ref button; b) button.draw();
	}
	private void drawFilterRouteChip(int ins, ref Geo g) {
		if(!filterRouteChipVisible(g)) return;
		filterRouteButton(ins, g).draw();
	}

	private void toggleFilterModeBit(int ins, int bit) {
		if(filterControlConfigRow(ins) < 0) {
			UI.statusline.display("No filter config row - add a filter program to set mode.");
			return;
		}
		if(!beginSweepDiscreteMutation(1, ins)) return;
		doToggleFilterModeBit(ins, bit);
	}
	private void doToggleFilterModeBit(int ins, int bit) {
		int cfg = filterControlConfigRow(ins);
		if(cfg < 0) return;
		ubyte b0 = song.filterTable[cfg * 4];
		song.filterTable[cfg * 4] = cast(ubyte)(b0 ^ (bit & 0x70));
		retriggerIfSounding();
	}

	private void cycleFilterRoute(int ins) {
		if(filterControlConfigRow(ins) < 0) {
			UI.statusline.display("No filter config row - add a filter program to set routing.");
			return;
		}
		if(!beginSweepDiscreteMutation(1, ins)) return;
		doCycleFilterRoute(ins);
	}
	private void doCycleFilterRoute(int ins) {
		int cfg = filterControlConfigRow(ins);
		if(cfg < 0) return;
		ubyte b1 = song.filterTable[cfg * 4 + 1];
		song.filterTable[cfg * 4 + 1] = cast(ubyte)((b1 & 0xf0) | (((b1 & 0x0f) + 1) & 0x0f));
		retriggerIfSounding();
	}

	// ---- §20 P4b-2 add/delete step + loop-marker drag ----

	// The loop-CLOSING row of the program at startRow: the row whose b3 either stops
	// ($7f / illegal) or jumps back to an already-visited row. This is the row whose b3
	// the loop-marker drag rewrites. Same chain traversal simPulse/simFilter use. -1 if
	// the program is empty (fixed/off pointer).
	private int sweepCloseRow(int table, int startRow) {
		if(startRow <= 0 || startRow >= 0x40) return -1;
		const(ubyte)[] t = sweepKind(table).table;
		bool[0x40] visited;
		int row = startRow, guard = 0;
		while(row >= 0 && row < 0x40 && guard++ < 0x80) {
			visited[row] = true;
			int b3 = t[row * 4 + 3];
			int next;
			if(b3 == 0) next = (row + 1) & 0x3f;
			else if(b3 == 0x7f) return row;          // stop -> this row closes
			else if(b3 <= 0x3f) next = b3;
			else return row;                          // illegal terminal
			if(visited[next]) return row;             // loops back -> this row closes
			row = next;
		}
		return row;
	}

	// True if the SweepTable's last row (0x3f) already holds data, so inserting (which
	// shifts every row down one and drops the last) would lose it. Guards Ins so a full
	// table shows a status message instead of silently corrupting the program.
	private bool sweepTableFull(int table) {
		const(ubyte)[] t = sweepKind(table).table;
		int b = 0x3f * 4;
		return t[b] != 0 || t[b + 1] != 0 || t[b + 2] != 0 || t[b + 3] != 0;
	}

	// Hit-test the loop marker in the Pulse/Filter band at press (x,y screen cells).
	// Returns the loop-closing row if the press is within LOOP_HIT_PX of a drawn loop
	// line (loopFrame + k*period) or, for a stopping program, its subtle end marker;
	// else -1. Checked in clickedAt BEFORE the level-drag so grabbing the loop line
	// neither pans nor edits levels.
	private int sweepLoopHandleAt(int table, ref Geo g, int x, int y) {
		int cellLeft = x * FONT_X, cellRight = cellLeft + FONT_X;
		int cellTop = y * FONT_Y, cellBottom = cellTop + FONT_Y;
		if(cellRight <= g.plotX0px || cellLeft >= g.plotX0px + g.plotWpx) return -1;
		int ins = clampedIns();
		auto k = sweepKind(table);
		int startRow = song.instrumentTable[ins + k.insCol * 48];
		int closeRow = sweepCloseRow(table, startRow);
		if(closeRow < 0) return -1;
		SweepSim s = sweepSim(k, startRow);
		auto shape = sweepLoopGeometry(table, g, s);
		if(cellBottom <= shape.top || cellTop >= shape.bottom) return -1;
		bool hitsStart = shape.startVisible && cellRight > shape.startLeft
			&& cellLeft < shape.startRight;
		bool hitsEnd = shape.endVisible && cellRight > shape.endLeft
			&& cellLeft < shape.endRight;
		if(hitsStart || hitsEnd) return closeRow;
		return -1;
	}

	// Map the loop-marker drag's mouse X to a frame -> the SweepTable row active there,
	// and set the loop-closing row's b3 jump to that row (the new loop-start). Converts a
	// $7f stop into a loop. The band + loop line follow live from the byte (WYSIWYG). No
	// undo/re-trigger here — snapshot is at the first drag tick, re-trigger at release.
	private void sweepLoopDragUpdate(ref Geo g, int cellx, int table, int sweepLoopCloseRow) {
		if(sweepLoopCloseRow < 0 || sweepLoopCloseRow >= 0x40) return;
		int px = cellx * FONT_X + FONT_X / 2;
		int f = cast(int)lround(viewport.tickForPixel(g, px));
		if(f < 0) f = 0;
		int ins = clampedIns();
		auto k = sweepKind(table);
		int startRow = song.instrumentTable[ins + k.insCol * 48];
		SweepSim s = sweepSim(k, startRow);
		if(s.rowOf.length == 0) return;
		if(f >= cast(int)s.rowOf.length) f = cast(int)s.rowOf.length - 1;
		int target = s.rowOf[f];
		if(target < 0 || target > 0x3f) return;
		ubyte[] t = k.table;
		t[sweepLoopCloseRow * 4 + 3] = cast(ubyte)target;
	}

	// §20.1/§20.4 insert (after the selected row) or delete the selected sweep step via
	// the ct.purge row-ops (which shift the table AND fix every instrument pointer +
	// sequence command globally). Ownership resolves automatically before the row-op;
	// the fork and edit share one all-table undo snapshot.
	private void sweepRowOp(int table, bool insert) {
		int ins = clampedIns();
		if(selectedSweepRow < 0 || selectedSweepRow >= 0x40) return;
		if(insert && sweepTableFull(table)) {
			UI.statusline.display(format("%s table full - cannot insert step.",
				sweepKind(table).name));
			return;
		}
		if(!beginSweepDiscreteMutation(table, ins, true)) return;
		doSweepRowOp(table, insert);
	}

	// Resolve a canonical logical Filter block (CONFIG immediately followed in program
	// order by its SWEEP) from either constituent row.
	private bool filterLogicalBlockAt(int ins, int selected, out int cfg, out int sweep) {
		cfg = sweep = -1;
		int[] steps = sweepProgramSteps(1, ins);
		foreach(i, row; steps) {
			if(row != selected) continue;
			if(song.filterTable[row * 4] & 0x80) {
				if(i + 1 < steps.length && !(song.filterTable[steps[i + 1] * 4] & 0x80)) {
					cfg = row; sweep = steps[i + 1]; return true;
				}
			} else if(i > 0 && (song.filterTable[steps[i - 1] * 4] & 0x80)) {
				cfg = steps[i - 1]; sweep = row; return true;
			}
			return false;
		}
		return false;
	}

	// The actual row-op, once sharing is resolved. INSERT: a new row after the selected
	// one, seeded with the selected row's shape (b0/b1/b2) and taking over its jump role
	// (the selected row now falls through to it) so the program stays valid; selection ->
	// the new row. DELETE: remove the selected row; selection -> an adjacent program row.
	private void doSweepRowOp(int table, bool insert) {
		int sel = selectedSweepRow;
		if(sel < 0 || sel >= 0x40) return;
		auto k = sweepKind(table);
		ubyte[] t = k.table;
		if(insert) {
			int logicalCfg, logicalSweep;
			if(table == 1 && filterLogicalBlockAt(clampedIns(), sel,
					logicalCfg, logicalSweep)) {
				int nr = logicalSweep + 1;
				if(nr + 1 >= 0x40 || sweepTableFull(1)
						|| song.filterTable[0x3e * 4] != 0
						|| song.filterTable[0x3e * 4 + 1] != 0
						|| song.filterTable[0x3e * 4 + 2] != 0
						|| song.filterTable[0x3e * 4 + 3] != 0) {
					UI.statusline.display("Filter table needs two free rows for a logical block.");
					return;
				}
				ct.purge.filterInsertRow(song, nr);
				ct.purge.filterInsertRow(song, nr + 1);
				ubyte inheritedJump = t[logicalSweep * 4 + 3];
				ubyte cfg0 = t[logicalCfg * 4];
				ubyte cfg1 = t[logicalCfg * 4 + 1];
				t[nr * 4 .. nr * 4 + 4] = [cast(ubyte)(0x80 | (cfg0 & 0x70)),
					cfg1, 0xff, 0x00];
				t[(nr + 1) * 4 .. (nr + 1) * 4 + 4] = [0x00, 0x00, 0xff, inheritedJump];
				t[logicalSweep * 4 + 3] = 0;
				selectedSweepRow = selectedSweepRowEnd = nr; // CONFIG first: mode/res/route
				retriggerIfSounding();
				return;
			}
			int nr = sel + 1;
			ubyte b0 = t[sel * 4], b1 = t[sel * 4 + 1], b2 = t[sel * 4 + 2];
			if(table == 0) ct.purge.pulseInsertRow(song, nr);
			else ct.purge.filterInsertRow(song, nr);
			// Seed the new row with the selected step's shape; the new row inherits the
			// selected row's (possibly-adjusted) jump so the terminal/loop still resolves,
			// and the selected row now falls through (b3=0) into the new row.
			ubyte cur = t[sel * 4 + 3];
			// After a filter CONFIG row, the useful default is a neutral SWEEP row;
			// cloning the config made newly-created filters impossible to animate without
			// returning to hex. Other rows retain the established clone behavior.
			if(table == 1 && (b0 & 0x80)) { b0 = 0; b1 = 0; b2 = 0xff; }
			t[nr * 4 + 0] = b0; t[nr * 4 + 1] = b1; t[nr * 4 + 2] = b2; t[nr * 4 + 3] = cur;
			t[sel * 4 + 3] = 0;
			selectedSweepRow = nr;
			selectedSweepRowEnd = nr;
		} else {
			int logicalCfg, logicalSweep;
			if(table == 1 && filterLogicalBlockAt(clampedIns(), sel,
					logicalCfg, logicalSweep) && logicalSweep == logicalCfg + 1) {
				// A canonical filter block is one user object backed by CONFIG+SWEEP.
				// Delete both adjacent physical rows inside this one existing snapshot.
				int insBefore = clampedIns();
				int startBefore = song.instrumentTable[insBefore + 4 * 48];
				int closeBefore = sweepCloseRow(1, startBefore);
				int targetBefore = closeBefore >= 0 ? t[closeBefore * 4 + 3] : -1;
				bool loopBefore = targetBefore >= 1 && targetBefore <= 0x3f;
				bool deletesClose = closeBefore >= logicalCfg && closeBefore <= logicalSweep;
				bool deletesTarget = targetBefore >= logicalCfg && targetBefore <= logicalSweep;
				bool[48] restoreDeletedStart;
				bool[0x40] programBefore = sweepProgramRows(1, startBefore);
				int survivingRows;
				foreach(r; 1 .. 0x40)
					if(programBefore[r] && (r < logicalCfg || r > logicalSweep)) survivingRows++;
				if(survivingRows > 0)
					foreach(j; 0 .. 48) {
						int pointer = song.instrumentTable[j + 4 * 48];
						if(pointer == logicalCfg || pointer == logicalSweep)
							restoreDeletedStart[j] = true;
					}

				ct.purge.filterDeleteRow(song, logicalCfg);
				ct.purge.filterDeleteRow(song, logicalCfg);
				// purge's generic address shift maps a pointer AT the deleted first row
				// to row-1. When a successor logical block survives, it shifts into the
				// deleted gap, so every linked pointer must continue at that same row.
				foreach(j; 0 .. 48) if(restoreDeletedStart[j])
					song.instrumentTable[j + 4 * 48] = cast(ubyte)logicalCfg;

				int closeAfter = deletesClose ? logicalCfg - 1
					: (closeBefore > logicalSweep ? closeBefore - 2 : closeBefore);
				if(closeAfter >= 1 && closeAfter < 0x40) {
					if(deletesClose) {
						// Removing the complete closing loop cannot expand it onto an
						// unrelated block: the surviving predecessor explicitly stops.
						t[closeAfter * 4 + 3] = 0x7f;
					} else if(loopBefore) {
						int targetAfter;
						if(deletesTarget)
							targetAfter = logicalCfg; // successor shifted into the gap
						else
							targetAfter = targetBefore > logicalSweep
								? targetBefore - 2 : targetBefore;
						t[closeAfter * 4 + 3] = cast(ubyte)targetAfter;
					}
				}

				int ins = clampedIns();
				int startRow = song.instrumentTable[ins + 4 * 48];
				bool[0x40] rows = sweepProgramRows(1, startRow);
				int pick = -1;
				if(logicalCfg - 1 >= 1 && rows[logicalCfg - 1]) pick = logicalCfg - 1;
				else if(logicalCfg < 0x40 && rows[logicalCfg]) pick = logicalCfg;
				else foreach(r; 1 .. 0x40) if(rows[r]) { pick = r; break; }
				selectedSweepRow = selectedSweepRowEnd = pick;
				if(pick < 0) selectedSweepTable = -1;
				retriggerIfSounding();
				return;
			}
			// Capture loop meaning before the generic row deletion rebases absolute
			// addresses. Removing a target contracts to its successor; removing the sole
			// self-loop converts the preceding block to END, never to an expanded loop.
			int insBefore = clampedIns();
			int colBefore = k.insCol;
			int closeBefore = sweepCloseRow(table,
				song.instrumentTable[insBefore + colBefore * 48]);
			int targetBefore = closeBefore >= 0 ? t[closeBefore * 4 + 3] : -1;
			bool loopBefore = targetBefore >= 1 && targetBefore <= 0x3f;
			bool[48] restoreDeletedStart;
			bool[0x40] programBefore = sweepProgramRows(table,
				song.instrumentTable[insBefore + colBefore * 48]);
			int survivingRows;
			foreach(r; 1 .. 0x40) if(programBefore[r] && r != sel) survivingRows++;
			if(survivingRows > 0)
				foreach(j; 0 .. 48)
					if(song.instrumentTable[j + colBefore * 48] == sel)
						restoreDeletedStart[j] = true;
			if(table == 0) ct.purge.pulseDeleteRow(song, sel);
			else ct.purge.filterDeleteRow(song, sel);
			foreach(j; 0 .. 48) if(restoreDeletedStart[j])
				song.instrumentTable[j + colBefore * 48] = cast(ubyte)sel;
			if(loopBefore) {
				int closeAfter = closeBefore - 1;
				if(closeAfter >= 1 && closeAfter < 0x40) {
					if(sel == closeBefore && targetBefore == closeBefore) {
						t[closeAfter * 4 + 3] = 0x7f;
					} else {
						int targetAfter = targetBefore;
						if(targetBefore > sel) targetAfter--;
						else if(targetBefore == sel && sel < closeBefore) targetAfter = sel;
						t[closeAfter * 4 + 3] = cast(ubyte)targetAfter;
					}
				}
			}
			// Move the selection to an adjacent row still inside the (shifted) program.
			int ins = clampedIns();
			int startRow = song.instrumentTable[ins + k.insCol * 48];
			bool[0x40] rows = sweepProgramRows(table, startRow);
			int pick = -1;
			if(sel - 1 >= 0 && rows[sel - 1]) pick = sel - 1;
			else if(sel < 0x40 && rows[sel]) pick = sel;
			else foreach(r; 0 .. 0x40) if(rows[r]) { pick = r; break; }
			selectedSweepRow = pick;
			selectedSweepRowEnd = pick;
			if(pick < 0) selectedSweepTable = -1;   // program emptied -> no selection
		}
		retriggerIfSounding();
	}

	// Explicit graphical loop -> stop conversion. The inverse remains the loop-grip
	// drag, because creating a loop needs a visible target row rather than an arbitrary
	// pointer number.
	private void stopSelectedSweepProgram() {
		int table = selectedSweepTable;
		if(table < 0) return;
		int ins = clampedIns();
		if(!beginSweepDiscreteMutation(table, ins)) return;
		doStopSweepProgram(table, ins);
	}
	private void doStopSweepProgram(int table, int ins) {
		auto k = sweepKind(table);
		int close = sweepCloseRow(table, song.instrumentTable[ins + k.insCol * 48]);
		if(close < 0) return;
		ubyte[] t = k.table;
		if(t[close * 4 + 3] == 0x7f) return;
		t[close * 4 + 3] = 0x7f;
		retriggerIfSounding();
	}

	private void toggleSelectedFilterRowType() {
		if(selectedSweepTable != 1 || selectedSweepRow < 1) return;
		int ins = clampedIns();
		if(!beginSweepDiscreteMutation(1, ins)) return;
		doToggleSelectedFilterRowType(ins);
	}
	private void doToggleSelectedFilterRowType(int ins) {
		int row = selectedSweepRow;
		if(row < 1) return;
		ubyte b0 = song.filterTable[row * 4];
		if(b0 & 0x80) {
			bool[0x40] rows = sweepProgramRows(1, song.instrumentTable[ins + 4 * 48]);
			bool otherConfig;
			foreach(r; 1 .. 0x40)
				if(r != row && rows[r] && (song.filterTable[r * 4] & 0x80)) { otherConfig = true; break; }
			if(!otherConfig) {
				UI.statusline.display("A filter program must keep at least one config row.");
				return;
			}
		}
		if(b0 & 0x80) {
			// Config -> neutral one-frame sweep; preserve init cutoff and jump.
			song.filterTable[row * 4] = 0;
			song.filterTable[row * 4 + 1] = 0;
		} else {
			// Sweep -> config using the program's existing config state where possible.
			int cfg = filterFirstConfigRow(song.instrumentTable[ins + 4 * 48]);
			ubyte mode = cfg >= 0 ? cast(ubyte)(song.filterTable[cfg * 4] & 0x70) : 0x10;
			ubyte rr = cfg >= 0 ? song.filterTable[cfg * 4 + 1] : 0x01;
			song.filterTable[row * 4] = cast(ubyte)(0x80 | mode);
			song.filterTable[row * 4 + 1] = rr;
		}
		retriggerIfSounding();
	}

	private void toggleSelectedSweepCarry() {
		int table = selectedSweepTable, ins = clampedIns();
		if(table < 0 || selectedSweepRow < 1) return;
		if(!beginSweepDiscreteMutation(table, ins)) return;
		doToggleSelectedSweepCarry();
	}
	private void doToggleSelectedSweepCarry() {
		int table = selectedSweepTable, row = selectedSweepRow;
		if(table < 0 || row < 1) return;
		ubyte[] t = sweepKind(table).table;
		if(t[row * 4 + 2] == 0xff)
			t[row * 4 + 2] = encodeInitB2(table, sweepStepEnterVal(table, row));
		else
			t[row * 4 + 2] = 0xff;
		retriggerIfSounding();
	}


	private void clearSweepSelection() {
		selectedSweepTable = -1;
		selectedSweepRow = -1;
		selectedSweepRowEnd = -1;
	}

	// §21 P4c(v3) the program's distinct step rows in playback (chain) order — the basis for
	// "consecutive blocks": a multi-selection is a contiguous slice of this list.
	private int[] sweepProgramSteps(int table, int ins) {
		auto k = sweepKind(table);
		int startRow = song.instrumentTable[ins + k.insCol * 48];
		SweepSim s = sweepSim(k, startRow);
		int[] steps; bool[0x40] seen;
		foreach(r; s.rowOf)
			if(r >= 1 && r < 0x40 && !seen[r]) { seen[r] = true; steps ~= r; }
		return steps;
	}

	// True while a MULTI-block range (anchor != extent, both in the current program) is
	// selected. Then a drag sets the shared join(s), not a single step's handle.
	private bool sweepMultiSelected() {
		return selectedSweepTable >= 0 && selectedSweepRow >= 1 && selectedSweepRowEnd >= 1
			&& selectedSweepRowEnd != selectedSweepRow;
	}

	// The selected consecutive rows (anchor..extent inclusive) in program order, or [] if
	// the range is invalid (rows no longer adjacent in the program, etc.).
	private int[] sweepSelectedRange(int ins) {
		if(selectedSweepTable < 0) return [];
		int[] steps = sweepProgramSteps(selectedSweepTable, ins);
		int ia = -1, ib = -1;
		foreach(i, r; steps) { if(r == selectedSweepRow) ia = cast(int)i; if(r == selectedSweepRowEnd) ib = cast(int)i; }
		if(ia < 0 || ib < 0) return [];
		if(ia > ib) { int t = ia; ia = ib; ib = t; }
		return steps[ia .. ib + 1];
	}

	// §21 P4c(v3) pixel span of the selected multi-block range: xa = first block's left edge,
	// xb = last block's right edge, band = its graph band. false if not a valid multi-range.
	private bool sweepSelectionSpan(int ins, ref Geo g, out int xa, out int xb, out int band) {
		xa = xb = band = 0;
		int[] range = sweepSelectedRange(ins);
		if(range.length < 2) return false;
		int f0, f1, a, b, s0, s1;
		if(!sweepStepGeom(selectedSweepTable, ins, range[0], g, f0, f1, a, b, s0, s1)) return false;
		xa = a;
		if(!sweepStepGeom(selectedSweepTable, ins, range[$ - 1], g, f0, f1, a, b, s0, s1)) return false;
		xb = b;
		band = sweepKind(selectedSweepTable).band;
		return true;
	}

	private bool sweepJoinAt(int ins, ref Geo g, int cellx, int celly,
			out int leftRow, out int rightRow) {
		leftRow = rightRow = -1;
		int[] range = sweepSelectedRange(ins);
		if(range.length < 2) return false;
		int px = cellx * FONT_X + FONT_X / 2, py = celly * FONT_Y + FONT_Y / 2;
		foreach(i; 0 .. cast(int)range.length - 1) {
			int f0, f1, xa, xb, syS, syE;
			if(!sweepStepGeom(selectedSweepTable, ins, range[i], g,
					f0, f1, xa, xb, syS, syE)) continue;
			if(nearSweepHandle(selectedSweepTable, px, py, xb, syE)) {
				leftRow = range[i]; rightRow = range[i + 1]; return true;
			}
		}
		return false;
	}

	// §21 P4c ---- interactive step BOX: duration (edges) + ramp (endpoints) ----

	// Whether a row's DURATION (b0 low 7 bits) is meaningfully editable: pulse rows always;
	// filter SWEEP rows yes; filter CONFIG rows (b0 & 0x80) no — they are instantaneous.
	private bool sweepRowResizable(int table, int row) {
		if(row < 1 || row >= 0x40) return false;
		if(table == 1 && (song.filterTable[row * 4] & 0x80)) return false;
		return true;
	}

	// Whether an END/slope handle can produce a visible change. Pulse always applies
	// its add/sub at least once. A filter sweep with duration zero emits only its initial
	// cutoff; its b1 slope is never applied, so presenting an END handle would be false UI.
	private bool sweepRowHasSlope(int table, int row) {
		if(!sweepRowResizable(table, row)) return false;
		return table == 0 || (song.filterTable[row * 4] & 0x7f) > 0;
	}

	// Direct-manipulation hit test for a duration edge. Unlike rowOf-at-frame, this
	// deliberately checks every visible block so a shared boundary consistently owns
	// the block on its left. The whole band height is active.
	private int sweepDurationRowAtPress(int table, int ins, ref Geo g, int x, int y) {
		int band = sweepKind(table).band;
		int px = x * FONT_X + FONT_X / 2, py = y * FONT_Y + FONT_Y / 2;
		bool inBand = py >= g.bandTopPx[band] && py < g.bandTopPx[band + 1];
		if(table == 1 && y == g.bandTopPx[4] / FONT_Y) {
			int cellTop = y * FONT_Y, cellBot = cellTop + FONT_Y;
			inBand = cellBot > g.bandTopPx[4] && cellTop < g.bandTopPx[5];
		}
		if(!inBand) return -1;
		int best = -1, bestDist = DUR_HIT_PX + 1;
		foreach(r; sweepProgramSteps(table, ins)) {
			if(!sweepRowResizable(table, r)) continue;
			int f0, f1, xa, xb, syS, syE;
			if(!sweepStepGeom(table, ins, r, g, f0, f1, xa, xb, syS, syE)) continue;
			int d = abs(px - xb);
			if(d <= DUR_HIT_PX && d < bestDist) { best = r; bestDist = d; }
		}
		return best;
	}

	private int filterModeForSweepRow(int ins, int row) {
		SweepSim s = simFilter(song.instrumentTable[ins + 4 * 48]);
		foreach(f, emitted; s.rowOf)
			if(emitted == row && f < s.modeOf.length) return s.modeOf[f] & 0x70;
		return 0;
	}
	// §21 P4c geometry of `row`'s step box on the shared axis: its frame span [f0,f1), the
	// pixel x of its left/right EDGES, and the pixel y of its START and END value handles,
	// all from the SAME sim the band draws. false if `row` is not currently emitted.
	private bool sweepStepGeom(int table, int ins, int row, ref Geo g,
			out int f0, out int f1, out int xa, out int xb, out int syStart, out int syEnd) {
		f0 = f1 = xa = xb = syStart = syEnd = 0;
		if(row < 1 || row >= 0x40) return false;
		auto k = sweepKind(table);
		int startRow = song.instrumentTable[ins + k.insCol * 48];
		SweepSim s = sweepSim(k, startRow);
		int a = -1, b = -1;
		foreach(f, r; s.rowOf) {
			if(r == row) { if(a < 0) a = cast(int)f; b = cast(int)f + 1; }
			else if(a >= 0) break;
		}
		if(a < 0 || b > cast(int)s.val.length) return false;
		f0 = a; f1 = b;
		int band = k.band;
		int maxVal = k.maxVal;
		int topPx, botPx; bandBox(g, band, topPx, botPx);
		int h = botPx - topPx; if(h < 1) h = 1;
		xa = viewport.xForFrame(g, f0); xb = viewport.xForFrame(g, f1);
		if(xb <= xa) xb = xa + 1;
		int v0 = s.val[f0], v1 = s.val[f1 - 1];
		// The pulse player applies b1 on the same tick that it loads b2. The plotted
		// first sample is therefore already one increment past the authored START value.
		// Handles represent editable bytes, not merely samples, so decode b2 for the
		// left handle. This keeps press -> drag -> redraw stable and truly WYSIWYG.
		if(table == 0) {
			ubyte b2 = song.pulseTable[row * 4 + 2];
			if(b2 != 0xff) v0 = ((b2 & 0x0f) << 8) | (b2 & 0xf0);
			else v0 = sweepStepEnterVal(table, row);
		}
		if(table == 1) {
			syStart = filterCutoffY(g, v0);
			syEnd = filterCutoffY(g, v1);
		} else {
			syStart = botPx - cast(int)lround(cast(double)v0 * h / maxVal);
			syEnd   = botPx - cast(int)lround(cast(double)v1 * h / maxVal);
		}
		// Keep the handles inside the band's grabbable interior: a value pinned to the very
		// top/bottom would land in a half-cell edge that the cell-granular (14px) hit-test
		// can't reach. A few px of pad barely moves the marker but keeps it grabbable.
		if(table == 0) {
			int pad = FONT_Y / 2;
			syStart = clampInt(syStart, topPx + pad, botPx - pad);
			syEnd   = clampInt(syEnd,   topPx + pad, botPx - pad);
		}
		return true;
	}

	// §21 P4c which sweep step the pointer hovers (band 3=pulse / 4=filter): the SweepTable
	// row emitted at the hovered frame, or false if not over an editable program.
	private bool hoverSweepStep(ref Geo g, out int table, out int row) {
		table = -1; row = -1;
		if(!hovering) return false;
		int px = hoverCellX * FONT_X, py = hoverCellY * FONT_Y;
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx) return false;
		int ins = clampedIns();
		if(py >= g.bandTopPx[3] && py < g.bandTopPx[4]) {
			int ptr = song.instrumentTable[ins + 5 * 48];
			if(ptr < 1 || ptr > 0x3f) return false;
			table = 0;
		} else if(py >= g.bandTopPx[4] && py < g.bandTopPx[5]) {
			int ptr = song.instrumentTable[ins + 4 * 48];
			if(ptr < 1 || ptr > 0x3f) return false;
			table = 1;
		} else return false;
		int r = sweepRowAtPress(table, g, hoverCellX);
		if(r < 0) return false;
		row = r;
		return true;
	}

	// Begin editing the step selected by the current direct-manipulation press. Once the
	// gesture starts, all updates remain anchored to that step so focus cannot jump.
	// Priority: END dot (slope) -> right EDGE (duration) -> START dot (level) -> body.
	// Returns true if a drag was started.
	private bool beginSelectedStepDrag(int ins, ref Geo g, int x, int y) {
		int t = selectedSweepTable, r = selectedSweepRow;
		if((t != 0 && t != 1) || r < 1 || r >= 0x40) return false;
		int f0, f1, xa, xb, syS, syE;
		if(!sweepStepGeom(t, ins, r, g, f0, f1, xa, xb, syS, syE)) return false;
		int band = (t == 0) ? 3 : 4;
		int px = x * FONT_X + FONT_X / 2, py = y * FONT_Y + FONT_Y / 2;
		bool inBand = py >= g.bandTopPx[band] && py < g.bandTopPx[band + 1];
		if(t == 1 && y == g.bandTopPx[4] / FONT_Y) {
			int cellTop = y * FONT_Y, cellBot = cellTop + FONT_Y;
			inBand = cellBot > g.bandTopPx[4] && cellTop < g.bandTopPx[5];
		}
		if(!inBand) return false;   // wrong band
		if(px < xa - BOX_HIT_PX || px > xb + DUR_HIT_PX) return false;             // outside box
		bool resizable = sweepRowResizable(t, r);
		// The slope dot is drawn on the right boundary, so it must win in its small
		// circular hit area; the remainder of the vertical line remains duration.
		if(sweepRowHasSlope(t, r)
				&& nearSweepHandle(t, px, py, xb, syE)) {
			clickWasButton = true;
			activeGesture = new SweepEndDrag(t, r, true, sweepStepWinding(t, r));
			return true;
		}
		// Duration owns every vertical position on the right boundary.
		if(resizable && abs(px - xb) <= DUR_HIT_PX) {
			clickWasButton = true;
			activeGesture = new SweepDurDrag(t, r, f0);
			return true;
		}
		if(resizable && nearSweepHandle(t, px, py, xa, syS)) { // START dot -> init level b2
			clickWasButton = true;
			activeGesture = new SweepEndDrag(t, r, false, 0);
			return true;
		}
		if(px > xa && px < xb) {                             // BODY -> level b2 (coarse translate)
			clickWasButton = true;
			activeGesture = new SweepLevelDrag(t, r);
			return true;
		}
		return false;
	}

	// §21 P4c(v2) draw the interactive step box. A faint outline marks the HOVERED step (a
	// "click to select" hint); the SELECTED step gets a bright outline plus its editable
	// handles — the RIGHT edge (duration) and the START/END value dots — each YELLOW while
	// the pointer hovers its grab zone or a drag on it is active. All edits target the
	// SELECTED step (§ beginSelectedStepDrag) so focus never swaps to a neighbour.
	private void drawSweepStepBox(int ins, ref Geo g) {
		int hx = hovering ? hoverCellX * FONT_X + FONT_X / 2 : -9999;
		int hy = hovering ? hoverCellY * FONT_Y + FONT_Y / 2 : -9999;
		// Faint hint on the hovered-but-unselected step.
		{
			int ht, hr;
			if(hoverSweepStep(g, ht, hr) && !(ht == selectedSweepTable && hr == selectedSweepRow)) {
				int a, b, xa, xb, s0, s1;
				if(sweepStepGeom(ht, ins, hr, g, a, b, xa, xb, s0, s1)) {
					int bd = sweepKind(ht).band;
					int tp, bp; bandBox(g, bd, tp, bp);
					video.olRect(xa, tp, xb - xa, bp - tp, COL_BOX_IDLE);
				}
			}
		}
		// §21 P4c(v3) MULTI-block selection: outline the whole range and mark each shared
		// JOIN (at the left block's end value). Only the hovered/dragged join lights.
		if(sweepMultiSelected()) {
			int rxa, rxb, rband;
			if(sweepSelectionSpan(ins, g, rxa, rxb, rband)) {
				int tp, bp; bandBox(g, rband, tp, bp);
				video.olRect(rxa, tp, rxb - rxa, bp - tp, COL_STEPSEL);
				int[] range = sweepSelectedRange(ins);
				foreach(i; 0 .. cast(int)range.length - 1) {
					int a0, a1, aa, ab, as0, as1;
					if(!sweepStepGeom(selectedSweepTable, ins, range[i], g, a0, a1, aa, ab, as0, as1)) continue;
					auto joinDrag = cast(SweepJoinDrag)activeGesture;
					bool joinHot = (joinDrag && joinDrag.leftRow == range[i])
						|| (hovering && nearSweepHandle(selectedSweepTable, hx, hy, ab, as1));
					video.olFillRect(ab - 2, as1 - 2, 5, 5, joinHot ? COL_BOX_HOT : COL_HEAD);
				}
			}
			return;
		}
		int t = selectedSweepTable, r = selectedSweepRow;
		if((t != 0 && t != 1) || r < 1 || r >= 0x40) return;
		int f0, f1, xa, xb, syS, syE;
		if(!sweepStepGeom(t, ins, r, g, f0, f1, xa, xb, syS, syE)) return;
		int band = sweepKind(t).band;
		int topPx, botPx; bandBox(g, band, topPx, botPx);
		video.olRect(xa, topPx, xb - xa, botPx - topPx, COL_STEPSEL);   // selected outline
		bool inY = hy >= topPx && hy < botPx;
		bool resizable = sweepRowResizable(t, r);
		// RIGHT edge (duration): hot while resizing, or when hovered near.
		bool rHot = (cast(SweepDurDrag)activeGesture !is null) || (inY && abs(hx - xb) <= DUR_HIT_PX);
		if(resizable)
			video.olVLine(xb, topPx, botPx, rHot ? COL_BOX_HOT : COL_STEPSEL);
		// START (init b2) + END (slope b1) value dots.
		if(resizable) {
			auto endDrag = cast(SweepEndDrag)activeGesture;
			bool sHot = (endDrag && !endDrag.isEnd)
				|| (inY && nearSweepHandle(t, hx, hy, xa, syS));
			video.olFillRect(xa - 2, syS - 2, 5, 5, sHot ? COL_BOX_HOT : COL_HEAD);
			if(sweepRowHasSlope(t, r)) {
				bool eHot = (endDrag && endDrag.isEnd)
					|| (inY && nearSweepHandle(t, hx, hy, xb, syE));
				video.olFillRect(xb - 2, syE - 2, 5, 5, eHot ? COL_BOX_HOT : COL_HEAD);
			}
		}
	}

	// §21 P4c apply a duration drag: width in frames from the step's fixed start to the
	// cursor -> the row's b0 low 7 bits (emitted frames = field+1), preserving b0 bit 7
	// (pulse direction / filter config flag).
	private int nearestDurationWidth(ref Geo g, int anchorFrame, int pointerPx) {
		int period = durationRows ? trackStepTicks() : 1;
		int first = period <= 0 ? 1 : period;
		if(first > 0x80) first = 0x80;
		int best = first;
		int bestDistance = abs(viewport.xForFrame(g, anchorFrame + best) - pointerPx);
		for(int width = first + period; period > 0 && width <= 0x80; width += period) {
			int distance = abs(viewport.xForFrame(g, anchorFrame + width) - pointerPx);
			// Iterating shorter to longer makes an exact distance tie choose shorter.
			if(distance < bestDistance) { best = width; bestDistance = distance; }
		}
		return best;
	}

	private void sweepDurDragUpdate(ref Geo g, int cellx, SweepDurDrag d) {
		int sweepDurRow = d.row, sweepDurTable = d.table;
		if(sweepDurRow < 1 || sweepDurRow >= 0x40) return;
		int pointerPx = cellx * FONT_X + FONT_X / 2;
		int width = nearestDurationWidth(g, d.anchorF, pointerPx);
		d.unitClipped = durationRows && trackStepTicks() > 0x80;
		int field = clampInt(width - 1, 0, 0x7f);
		ubyte[] t = sweepKind(sweepDurTable).table;
		ubyte b0 = t[sweepDurRow * 4];
		t[sweepDurRow * 4] = cast(ubyte)((b0 & 0x80) | field);
		// Duration edits preserve the endpoint the user saw when grabbing the edge.
		// Each table's signed slope range is clamped through the normal encoder and
		// retain the legal endpoint for clear feedback on mouse-up.
		if(sweepDurTable == 0 || sweepDurTable == 1) {
			int enter = sweepStepEnterVal(sweepDurTable, sweepDurRow);
			int applications = sweepRampApplications(sweepDurTable, sweepDurRow);
			int scale = sweepKind(sweepDurTable).scale;
			int divisor = max(1, applications * scale);
			int requestedSlope = cast(int)lround(
				cast(double)(d.targetExit - enter) / divisor);
			setSweepSignedSlope(sweepDurTable, sweepDurRow, requestedSlope);
			d.legalExit = enter
				+ sweepSignedSlope(sweepDurTable, sweepDurRow) * scale * applications;
			d.clipped = d.legalExit != d.targetExit;
		}
	}

	// §21 P4c the value ENTERING a step's ramp: its explicit init (b2 != 0xff) decoded,
	// else the value carried over from the previous frame (read from the sim). Used to
	// pivot the END-endpoint tilt around a fixed start.
	private int sweepStepEnterVal(int table, int row) {
		auto k = sweepKind(table);
		const(ubyte)[] t = k.table;
		ubyte b2 = t[row * 4 + 2];
		if(b2 != 0xff) return (table == 0) ? (((b2 & 0x0f) << 8) | (b2 & 0xf0)) : (b2 << 3);
		int ins = clampedIns();
		int startRow = song.instrumentTable[ins + k.insCol * 48];
		SweepSim s = sweepSim(k, startRow);
		int f0 = -1;
		foreach(f, r; s.rowOf) if(r == row) { f0 = cast(int)f; break; }
		if(f0 <= 0) return (table == 0) ? 0x800 : 0;
		return s.val[f0 - 1];
	}

	// §21 P4c a value-endpoint handle grab zone: tight in X (it sits on the box edge) but a
	// cell-ROW tall in Y, since mouse input is cell-granular (14px) — a small radius would
	// fall between rows and miss.
	private static bool nearHandle(int px, int py, int hx, int hy) {
		return abs(px - hx) <= BOX_HIT_PX && abs(py - hy) <= FONT_Y - 2;
	}
	private static bool nearSweepHandle(int table, int px, int py, int hx, int hy) {
		int yr = sweepKind(table).isFilter ? FONT_Y / 2 + 1 : FONT_Y - 2;
		return abs(px - hx) <= BOX_HIT_PX && abs(py - hy) <= yr;
	}

	// §21 P4c encode a value to a step's init byte b2 (pulse nibble-swap / filter >>3),
	// avoiding 0xff — the player reads 0xff as "inherit the running value", not a literal
	// maximum, so a max-level drag must land on the nearest literal instead.
	private static ubyte encodeInitB2(int table, int v) {
		ubyte b2 = (table == 0) ? cast(ubyte)(((v >> 8) & 0x0f) | (v & 0xf0))
		                        : cast(ubyte)((v >> 3) & 0xff);
		if(b2 == 0xff) b2 = (table == 0) ? 0xef : 0xfe;
		return b2;
	}

	private int sweepSignedSlope(int table, int row) {
		const(ubyte)[] t = sweepKind(table).table;
		if(table == 0) return (t[row * 4] & 0x80) ? -t[row * 4 + 1] : t[row * 4 + 1];
		int raw = t[row * 4 + 1];
		return raw < 0x80 ? raw : raw - 0x100;
	}
	private int sweepRampApplications(int table, int row) {
		int n = (sweepKind(table).table[row * 4] & 0x7f);
		return table == 0 ? n + 1 : n;
	}
	private int sweepStepWinding(int table, int row) {
		auto k = sweepKind(table);
		int modulus = k.modulus;
		int scale = k.scale;
		int exit = sweepStepEnterVal(table, row)
			+ sweepSignedSlope(table, row) * scale * sweepRampApplications(table, row);
		int visible = exit % modulus; if(visible < 0) visible += modulus;
		return exit - visible;
	}
	private void setSweepSignedSlope(int table, int row, int slope) {
		ubyte[] t = sweepKind(table).table;
		if(table == 0) {
			slope = clampInt(slope, -255, 255);
			t[row * 4] = cast(ubyte)((t[row * 4] & 0x7f) | (slope < 0 ? 0x80 : 0));
			t[row * 4 + 1] = cast(ubyte)(slope < 0 ? -slope : slope);
		} else {
			slope = clampInt(slope, -128, 127);
			t[row * 4 + 1] = cast(ubyte)(slope & 0xff);
		}
	}

	// §21 P4c set a step's START value = its init byte b2 (avoids the 0xff inherit sentinel).
	private void setStepStartValue(int table, int row, int v) {
		ubyte[] t = sweepKind(table).table;
		if(row < 1 || row >= 0x40) return;
		t[row * 4 + 2] = encodeInitB2(table, v);
	}

	// §21 P4c set a step's END value by choosing its ramp slope (b1) + direction so that
	// entering + ramp == v, keeping the entering value fixed (a tilt). Sweep rows only.
	private void setStepEndValue(int table, int row, int v) {
		if(!sweepRowResizable(table, row)) return;
		ubyte[] t = sweepKind(table).table;
		int entering = sweepStepEnterVal(table, row);
		ubyte b0 = t[row * 4];
		// `v` is deliberately UNWRAPPED for endpoint drags. Keeping its winding avoids
		// direction flips at the value-ring midpoint and permits multiple wraps.
		int d = v - entering;
		if(table == 0) {
			int n = (b0 & 0x7f) + 1;                       // pulse ramps n times
			int mag = clampInt(cast(int)lround(cast(double)(d < 0 ? -d : d) / n), 0, 0xff);
			t[row * 4]     = cast(ubyte)((d < 0 ? 0x80 : 0) | (b0 & 0x7f));  // direction bit
			t[row * 4 + 1] = cast(ubyte)mag;                                 // slope magnitude
		} else {
			int nf = b0 & 0x7f; if(nf < 1) nf = 1;         // filter ramps nf times, delta=2*b1
			int sgn = clampInt(cast(int)lround(cast(double)d / (2 * nf)), -128, 127);
			t[row * 4 + 1] = cast(ubyte)(sgn & 0xff);      // signed slope in b1
		}
	}

	// Map a cell row to a band value (0..maxVal), inverting the band's Y axis.
	private int sweepValueForCell(int table, ref Geo g, int celly, int row = -1) {
		if(table == 1 && row >= 1) return filterCutoffValue(g, celly);
		auto k = sweepKind(table);
		int band = k.band;
		int maxVal = k.maxVal;
		int topPx, botPx; bandBox(g, band, topPx, botPx);
		int h = botPx - topPx; if(h < 1) h = 1;
		int py = celly * FONT_Y + FONT_Y / 2;
		return clampInt(cast(int)lround(cast(double)(botPx - py) * maxVal / h), 0, maxVal);
	}
	private int sweepUnwrappedValueForCell(int table, ref Geo g, int celly, int row = -1) {
		if(table == 1 && row >= 1) return filterCutoffValue(g, celly, false);
		auto k = sweepKind(table);
		int band = k.band;
		int maxVal = k.maxVal;
		int topPx, botPx; bandBox(g, band, topPx, botPx);
		int py = celly * FONT_Y + FONT_Y / 2;
		if(table == 0) {
			// Cell-granular input can reach the first/last ROW intersecting the band, not
			// an arbitrary pixel on its border. Those row centres are the pulse graph's
			// exact max/min rails; dragging beyond them still extrapolates for winding.
			int railTop = (topPx / FONT_Y) * FONT_Y + FONT_Y / 2;
			int railBot = ((botPx - 1) / FONT_Y) * FONT_Y + FONT_Y / 2;
			int railH = railBot - railTop; if(railH < 1) railH = 1;
			return cast(int)lround(cast(double)(railBot - py) * maxVal / railH);
		}
		int h = botPx - topPx; if(h < 1) h = 1;
		return cast(int)lround(cast(double)(botPx - py) * maxVal / h);
	}

	// §21 P4c apply a value-endpoint drag. START: set init b2 (translate). END: set slope
	// b1 + direction so the ramp ENDS at the pointer value (tilt).
	private void sweepEndDragUpdate(ref Geo g, int celly, int sweepEndTable, int sweepEndRow,
			bool sweepEndIsEnd, int sweepEndWinding) {
		if(sweepEndIsEnd) {
			if(SDL_GetModState() & KMOD_SHIFT) {
				// Fine endpoint position is ambiguous once a ramp winds. Shift maps the
				// full band directly onto the complete signed speed range.
				auto k = sweepKind(sweepEndTable);
				int band = k.band;
				int topPx, botPx; bandBox(g, band, topPx, botPx);
				int h = botPx - topPx; if(h < 1) h = 1;
				int py = celly * FONT_Y + FONT_Y / 2;
				int maxSlope = k.maxSlope;
				int minSlope = k.minSlope;
				int slope = maxSlope - cast(int)lround(cast(double)(py - topPx)
					* (maxSlope - minSlope) / h);
				setSweepSignedSlope(sweepEndTable, sweepEndRow, slope);
			} else {
				setStepEndValue(sweepEndTable, sweepEndRow,
					sweepUnwrappedValueForCell(sweepEndTable, g, celly, sweepEndRow) + sweepEndWinding);
			}
		} else {
			setStepStartValue(sweepEndTable, sweepEndRow,
				sweepValueForCell(sweepEndTable, g, celly, sweepEndRow));
		}
	}

	// Apply the clicked JOIN only: both sides move because both adjacent blocks are selected.
	private void sweepJoinDragUpdate(ref Geo g, int celly, int sweepJoinLeftRow, int sweepJoinRightRow) {
		if(sweepJoinLeftRow < 1 || sweepJoinRightRow < 1) return;
		int v = sweepValueForCell(selectedSweepTable, g, celly, sweepJoinLeftRow);
		setStepEndValue(selectedSweepTable, sweepJoinLeftRow, v);
		setStepStartValue(selectedSweepTable, sweepJoinRightRow, v);
	}

	// Keyboard parity for a selected graphical block:
	// Ctrl-Left/Right = START, Ctrl-Shift-Left/Right = END,
	// Ctrl-Up/Down = duration. Values move by the table's real quantization.
	private void editSelectedSweepKeyboard(int field, int delta) {
		int table = selectedSweepTable, ins = clampedIns();
		if(table < 0 || selectedSweepRow < 1) return;
		if(!beginSweepDiscreteMutation(table, ins)) return;
		doEditSelectedSweepKeyboard(field, delta);
	}
	private void doEditSelectedSweepKeyboard(int field, int delta) {
		int table = selectedSweepTable, row = selectedSweepRow;
		if(table < 0 || row < 1) return;
		if(field != 0 && !sweepRowResizable(table, row)) {
			UI.statusline.display("Filter config rows have no slope or duration.");
			return;
		}
		if(field == 1 && !sweepRowHasSlope(table, row)) {
			UI.statusline.display("Increase this filter step's duration before editing its end.");
			return;
		}
		auto k = sweepKind(table);
		ubyte[] t = k.table;
		int modulus = k.modulus;
		int unit = table == 0 ? 16 : (field == 1 ? 2 : 8);
		final switch(field) {
			case 0:
				setStepStartValue(table, row,
					(sweepStepEnterVal(table, row) + delta * unit + modulus) % modulus);
				break;
			case 1:
				if(table == 0) {
					int slope = (t[row * 4] & 0x80) ? -t[row * 4 + 1] : t[row * 4 + 1];
					slope = clampInt(slope + delta, -255, 255);
					t[row * 4] = cast(ubyte)((t[row * 4] & 0x7f) | (slope < 0 ? 0x80 : 0));
					t[row * 4 + 1] = cast(ubyte)(slope < 0 ? -slope : slope);
				} else {
					int slope = t[row * 4 + 1] < 0x80 ? t[row * 4 + 1] : t[row * 4 + 1] - 0x100;
					slope = clampInt(slope + delta, -128, 127);
					t[row * 4 + 1] = cast(ubyte)(slope & 0xff);
				}
				break;
			case 2:
				int n = clampInt((t[row * 4] & 0x7f) + delta, 0, 0x7f);
				t[row * 4] = cast(ubyte)((t[row * 4] & 0x80) | n);
				break;
		}
		retriggerIfSounding();
	}

	// ---- band chrome ----

	// §13.1(b) split so the TEXT label (drawn in drawTextChrome, incl. under
	// foreground chrome) is independent of the pixel baseline axis.
	private void drawBandLabelText(ref Geo g, int band, string label) {
		int row = g.bandTopPx[band] / FONT_Y;
		screen.cprint(g.labelX, row, COL_LABEL, 0, label);
	}

	// §22 true when a band's content should draw: always in the normal stack, and only
	// the maximised band in expand mode.
	private bool bandVisible(int band) { return expandedBand < 0 || expandedBand == band; }

	// §22 the expandable graph band (0..4) whose TITLE cell the pointer is over, else -1.
	// Titles sit in the label gutter on the band's top character row; double-clicking one
	// toggles expansion. The wave band (5) has no single title, so it is not a target.
	private int bandTitleAt(ref Geo g, int cellX, int cellY) {
		int plotX0c = g.plotX0px / FONT_X;
		if(cellX < g.sepX || cellX >= plotX0c) return -1;
		foreach(b; 0 .. 5)
			if(cellY == g.bandTopPx[b] / FONT_Y) return b;
		return -1;
	}

	private void drawBandAxis(ref Geo g, int band) {
		// Faint baseline axis at the band's bottom.
		int botPx = g.bandTopPx[band + 1] - 2;
		video.olHLine(g.plotX0px, g.plotX0px + g.plotWpx - 1, botPx, COL_AXIS);
	}

	// One tracker sequence row lasts effectiveSpeed+1 main-player calls: speedcnt
	// reaches zero on the row boundary, then underflows and reloads on the next call.
	// The Sound Editor axis contains EVERY multispeed sound call, so convert that
	// duration to axis ticks by multiplying by the calls-per-screen-frame multiplier.
	private int effectiveSpeed() {
		int speed = song.playSpeed;       // includes the current break-speed/groove value
		if(speed < 2) speed = song.speed; // safe before the resident player is initialized
		if(speed < 2) speed = 2;          // player_v4 floors break-speed entries to two
		return speed;
	}
	private int trackStepTicks() {
		int speed = effectiveSpeed();
		int mult = audio.audio.multiplier;
		return soundEditorStepTicks(speed, mult);
	}
	private int configuredGateTicks() {
		return soundEditorDurationTicks(durationValue, durationRows,
			effectiveSpeed(), audio.audio.multiplier);
	}
	private void syncKeyjamConfiguration() {
		inputKeyjam.setKeyjamVoice(keyjamChannel);
		inputKeyjam.setFixedGateTicks(configuredGateTicks());
	}
	private void changeDurationUnit(bool rows) {
		if(rows == durationRows) return;
		int ticks = configuredGateTicks();
		durationRows = rows;
		if(rows) {
			int period = trackStepTicks();
			durationValue = max(1, cast(int)lround(cast(double)ticks / period));
			if(durationValue * period != ticks)
				UI.statusline.display(format("Gate hold quantised to %d rows (%d ticks).",
					durationValue, durationValue * period));
		} else durationValue = ticks;
		syncKeyjamConfiguration();
	}
	// Subtle dashed grid across the shared timeline. Tick 0 is already the brighter red
	// note-trigger divider; subsequent lines mark exactly one tracker-row period. Keep
	// only one line per output pixel when zoomed far out so the graph never becomes a fill.
	private void drawTrackStepGrid(ref Geo g) {
		int period = trackStepTicks();
		if(period < 1) return;
		int first = max(period, cast(int)ceil(max(0.0, viewport.startTick) / period) * period);
		int lastX = -1_000_000;
		for(int f = first; f <= viewport.endTick; f += period) {
			if(!viewport.frameInView(f)) continue;
			int x = viewport.xForFrame(g, f);
			if(x == lastX) continue;
			for(int y = g.stackTopPx; y < g.stackBotPx; y += 7)
				video.olVLine(x, y, min(y + 3, g.stackBotPx), COL_TRACKSTEP);
			lastX = x;
		}
	}

	private void bandBox(ref Geo g, int band, out int topPx, out int botPx) {
		topPx = g.bandTopPx[band] + 2;
		botPx = g.bandTopPx[band + 1] - 3;
		if(botPx <= topPx) botPx = topPx + 1;
	}

	// ---- output waveform band (§11.2 RECORDING VIEW, §9.5 pixel-perfect min/max) ----
	// A recording of the played note's actual output, NOT a live oscilloscope: one
	// column per horizontal PIXEL of the per-note capture buffer (captureBuf), frame-
	// aligned to the note region (frames 0..visFrames, from the trigger divider
	// rightwards). captureBuf is filled by the audio device during a keyjam note, so
	// headless / song playback (no capture) shows a flat baseline — the SID-state
	// bands below still populate from the per-frame recording either way.
	private void drawOutputBand(ref Geo g) {
		int topPx, botPx; bandBox(g, 0, topPx, botPx);
		int mid = (topPx + botPx) / 2;
		int half = (botPx - topPx) / 2;
		if(half < 1) return;

		// §17.1 note region in absolute pixels: from the trigger (frame 0, clamped into
		// view) to the plot's right edge. Under zoom/pan the trigger may sit at the left
		// plot edge (panned right into the note) or partway across (fit / panned left).
		int plotEndPx = g.plotX0px + g.plotWpx;
		int noteX0px = viewport.xForFrame(g, 0);
		if(noteX0px < g.plotX0px) noteX0px = g.plotX0px;
		int noteWpx = plotEndPx - noteX0px;
		if(noteWpx < 1) return;

		// Sample source is the per-note recording only (never the live mixbuf).
		short* buf = audio.audio.captureBuf.ptr;
		int total = audio.audio.captureLen;
		int fs = audio.audio.captureFrameSamples;
		// §16 START-alignment: captureBuf begins at note-trigger, but its first frames are
		// the pre-gate hard/soft-restart phase (gate low). The rec* bands reset at the gate
		// 0->1 edge, so their frame 0 == the audible ONSET. `onset` is that onset's sample
		// offset in captureBuf; mapping axis tick 0 -> sample `onset` puts the Output
		// waveform's start at the SAME x as the other bands (was shifted right by the
		// restart pre-roll, ~3 frames / 60 ms).
		int onset = audio.audio.captureOnsetSample;
		if(onset < 0) onset = 0;
		// §16.2/§16.3 samples-per-tick on the SHARED real-time axis: one axis tick spans
		// `spTick` samples (== fs, the recorded stride, but derived from real time so it is
		// robust to any tick/multiplier). The window of interest is the visFrames ticks
		// AFTER the onset, clamped to what was actually recorded.
		int sfreq = audio.audio.freq;
		double spTick = sfreq * (tickMs / 1000.0);   // samples per axis tick (== fs)
		int winSamples = spTick > 0 ? cast(int)(visFrames * spTick) : (total - onset);
		int spanEnd = onset + winSamples;
		if(spanEnd > total) spanEnd = total;
		if(buf is null || fs < 1 || spTick < 1.0 || onset >= total || spanEnd - onset < 2) {
			// Flat baseline when nothing has been recorded (headless / song playback).
			video.olHLine(noteX0px, plotEndPx - 1, mid, COL_AXIS);
			return;
		}

		// AUTO-GAIN: scale to the window's PEAK |sample| (a self-adjusting scope)
		// instead of a fixed sample ceiling, so a quiet-but-audible single voice —
		// e.g. a slow-attack triangle whose envelope only reaches a fraction of full —
		// fills the band instead of rendering as a near-flat line with tiny wiggles.
		// Peak==0 means nothing audible was captured, so keep a flat baseline (and it
		// avoids a divide-by-zero). Computed over the same [0,span) the columns read.
		// This auto-gain is CORRECT here (raw-sample level is arbitrary) — see §15.4; the
		// ADSR/Freq/Pulse/Filter bands, being absolute quantities, are NOT auto-gained.
		int peak = 0;
		foreach(s; onset .. spanEnd) {
			int a = buf[s]; if(a < 0) a = -a;
			if(a > peak) peak = a;
		}
		if(peak < 1) {
			video.olHLine(noteX0px, plotEndPx - 1, mid, COL_AXIS);
			return;
		}

		// §16.3 Per-pixel oscilloscope, mapped through the SHARED REAL-TIME axis (the
		// exact inverse of xForFrame): pixel column x covers axis time [t0,t1) in ticks,
		// which maps to samples [t0*spTick, t1*spTick) of captureBuf. Drawing the min/max
		// of that sample range gives the pixel-accurate waveform (real detail, not a
		// blocky per-frame block) AND places it at the SAME instant as the ADSR/Freq/
		// Pulse/Filter/Wave bands and the playhead/probe (all via the one axis). Where a
		// column lies past the recording, draw the flat baseline (note ended / silent).
		foreach(i; 0 .. noteWpx) {
			int x = noteX0px + i;
			// §17.1 invert the VIEWPORT axis at x and x+1 -> tick range on the shared axis
			double t0 = viewport.tickForPixel(g, x);
			double t1 = viewport.tickForPixel(g, x + 1);
			if(t0 < 0) t0 = 0;
			if(t1 <= t0) t1 = t0 + (viewport.endTick - viewport.startTick) / g.plotWpx;
			// §16 map axis time -> captureBuf, shifted past the pre-gate restart phase so
			// tick 0 == the audible onset (== rec* frame 0).
			int s0 = onset + cast(int)(t0 * spTick);
			int s1 = onset + cast(int)(t1 * spTick);
			if(s0 >= total) {           // past the recording → flat baseline
				video.olPoint(x, mid, COL_AXIS);
				continue;
			}
			if(s1 > total) s1 = total;
			if(s1 <= s0) s1 = s0 + 1;
			int mn = short.max, mx = short.min;
			for(int s = s0; s < s1; s++) {
				int v = buf[s];
				if(v < mn) mn = v;
				if(v > mx) mx = v;
			}
			int yhi = mid - normOff(mx, half, peak);   // max -> up
			int ylo = mid - normOff(mn, half, peak);   // min -> down
			if(ylo < yhi) { int t = ylo; ylo = yhi; yhi = t; }
			video.olVLine(x, ylo, yhi, COL_TRACE);
		}
	}

	// Sample value -> vertical pixel offset from the band centre, normalised so the
	// window's peak |sample| maps to the half-band height (clamped).
	private int normOff(int v, int half, int peak) {
		int off = cast(int)lround(cast(real)v * half / peak);
		return max(-half, min(half, off));
	}

	// ---- ADSR band (§9.1 per-frame envelope on the shared axis + §9.2 restart) ----

	private void drawAdsrBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 1, topPx, botPx);
		int h = botPx - topPx;
		if(h < 1) return;

		// Both vivid keyjam and dim idle paths use raw 8-bit counters from reSID. The
		// only smoothing is the line drawn between adjacent player-tick samples.
		const(ubyte)[] envelope;
		int traceCol;
		if(useRec) {
			envelope = audio.visualizer.getRecordedEnvelope(viewVoice);
			traceCol = COL_CURVE;
		} else {
			ensureSilentEnvelopePreview(visFrames);
			envelope = silentEnvPreview;
			traceCol = COL_DIM;
		}
		int n = min(cast(int)envelope.length, visFrames);
		int prevX = -1, prevY = -1;
		int lo, hi; viewport.visRange(n, lo, hi);
		foreach(f; lo .. hi) {
			int y = botPx - cast(int)lround(envelope[f] / 255.0 * h);
			int x = viewport.xForFrame(g, f);
			if(prevX >= 0) video.olLine(prevX, prevY, x, y, traceCol);
			else video.olPoint(x, y, traceCol);
			prevX = x; prevY = y;
		}

		// §9.2 restart pre-roll (frames -RESTART_FRAMES..0), shaded distinctly, showing
		// the hard/soft/3-frame restart forced by col2 using HR SR (col6) + HR wave
		// (col3) before the note. It's a display of "the envelope was being killed",
		// not a cycle-exact sim.
		// §17.1 pre-roll region, clamped to the plot (it can be fully/partly off-view
		// when the user has panned/zoomed past the trigger).
		ubyte rst = song.instrumentTable[ins + 2 * 48];
		int plotEndPx = g.plotX0px + g.plotWpx;
		int preX0 = viewport.xForFrame(g, -prerollTicks);
		int preX1 = viewport.xForFrame(g, 0);
		if(preX1 > preX0 && preX0 < plotEndPx && preX1 > g.plotX0px) {
			video.olFillRect(preX0, topPx, preX1 - preX0, h, 16); // dim gradient wash
			bool hard = (rst & 0xc0) == 0x80;
			bool soft = (rst & 0xc0) == 0x40;
			// Start level of the restart ramp: hard drops from full, soft from mid,
			// 3-frame from a low level; all decay to 0 by the trigger.
			float startLvl = hard ? 1.0f : (soft ? 0.5f : 0.25f);
			int rprevY = -1;
			foreach(x; preX0 .. preX1) {
				float t = preX1 > preX0 ? cast(float)(x - preX0) / (preX1 - preX0) : 1.0f;
				int y = botPx - cast(int)lround(clamp01(startLvl * (1.0f - t)) * h);
				video.olVLine(x, botPx, y, COL_RSTFILL);
				if(rprevY >= 0) video.olLine(x - 1, rprevY, x, y, COL_RSTCURVE);
				rprevY = y;
			}
			string rlabel = hard ? "rst:hard" : (soft ? "rst:soft" : "rst:3fr");
			screen.cprint(preX0 / FONT_X, topPx / FONT_Y, COL_RSTCURVE, 0, rlabel);
		}

	}

	// ---- pulse / filter bands (recording, with the table sim as dimmed preview) ----

	// §11.2/§11.3 Pulse-width band: the RECORDED per-frame pulse width when a note has
	// played (vivid), else the table simulation as a dimmed idle preview. The sim is
	// always computed for its loop period so the subtle loop-boundary lines mark the
	// same repeating section in either path.
	private void drawPulseBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 3, topPx, botPx);
		int ptr = song.instrumentTable[ins + 5 * 48];
		SweepSim s = simPulse(ptr);           // loop period + idle-preview values
		if(useRec) {
			auto rp = audio.visualizer.getRecordedPulse(viewVoice);
			drawValueBand(rp, 4095, COL_PULSE_FILL, COL_PULSE_LINE, topPx, botPx, g);
		} else if(ptr < 0x80) {               // direct fixed pulse ($80+) = no program
			drawValueBand(s.val, 4095, COL_DIMFILL, COL_DIM, topPx, botPx, g);
		}
	}

	// §10.1/§10.2 Filter band: cutoff fill/line coloured PER FRAME by the active
	// filter mode (LP/BP/HP), plus a distinct thin bright resonance-over-time overlay
	// on the same frame axis. Mode/resonance come per-frame from simFilter.
	private void drawFilterBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 4, topPx, botPx);
		int ptr = song.instrumentTable[ins + 4 * 48];
		SweepSim s = simFilter(ptr);          // loop period + idle-preview values
		int h = botPx - topPx;
		if(h < 2) return;
		enum int maxVal = 2047;

		// §11.2 source: recorded cutoff/mode/resonance when a note has played, else the
		// simulation (dimmed). `dim` greys the whole band so the idle preview is obvious.
		const(int)[] cutoff, modeA, resA;
		bool dim;
		if(useRec) {
			cutoff = audio.visualizer.getRecordedCutoff(viewVoice);
			modeA  = audio.visualizer.getRecordedMode(viewVoice);
			resA   = audio.visualizer.getRecordedResonance(viewVoice);
			dim = false;
		} else {
			cutoff = s.val; modeA = s.modeOf; resA = s.resOf;
			dim = true;
		}
		int n = min(cast(int)cutoff.length, visFrames);
		int lo, hi; viewport.visRange(n, lo, hi);       // §17.1 only emit on-screen frames

		// R58 response silhouette on one absolute cutoff axis. LP fills below cutoff,
		// BP is a fixed one-third-height centred ribbon, HP fills above cutoff, and
		// combined flags are their union. Resonance never changes these bounds.
		foreach(f; lo .. hi) {
			int mode = f < modeA.length ? modeA[f] : 0;
			int mc = filterModeColor(mode);
			if(mc < 0) continue;              // filter off -> empty band this frame
			FilterRegions regions = filterRegions(g, mode, cutoff[f]);
			int fillCol = dim ? COL_DIMFILL : mc;
			int traceCol = dim ? COL_DIM : COL_FILT_LINE;
			int xa, xb; frameXSpan(g, f, xa, xb);
			for(int x = xa; x < xb; x++) {
				if(regions.lp) video.olVLine(x, regions.lpTop, regions.lpBottom, fillCol);
				if(regions.bp) video.olVLine(x, regions.bpTop, regions.bpBottom, fillCol);
				if(regions.hp) video.olVLine(x, regions.hpTop, regions.hpBottom, fillCol);
				video.olPoint(x, regions.y, traceCol); // exactly one cutoff trace
			}
		}

		// §10.2 resonance (0..15) over time: a thin step line, clearly separate from the
		// cutoff fill. Bright yellow on the recording path, dim grey on the sim preview.
		int rescol = dim ? COL_DIM : COL_RES;
		drawStaircase(g, lo, hi, (int f) {
			int res = f < resA.length ? resA[f] : 0;
			if(res < 0) res = 0; if(res > 15) res = 15;
			return botPx - res * h / 15;
		}, rescol);

		// §20 P4b-3 clickable mode chip (cycles LP/BP/HP combos, recolours the fill live).
		drawFilterModeChip(ins, g);
		drawFilterRouteChip(ins, g);
	}

	// PAL SID raw frequency -> absolute note index in the NOTES domain (C-0 = 0 ..
	// B-7 = 95), or -1 when silent. NOTES index = midi - 12 (C-4 = midi 60 = index 48).
	private static int freqToNoteIndex(int rawFreq) {
		if(rawFreq <= 0) return -1;
		double hz = rawFreq * 985248.0 / 16777216.0;
		if(hz < 8.0) return -1;
		int idx = cast(int)lround(57.0 + 12.0 * log2(hz / 440.0));   // 57 = A-4 index
		if(idx < 0) idx = 0;
		if(idx > 95) idx = 95;
		return idx;
	}

	// §10.3 Pitch band, drawn as a mini PIANO ROLL on one absolute-note axis (C-0..B-7).
	// The wave/arp transpose column carries two note kinds that can interleave and loop:
	// RELATIVE offsets ($00..$5F, added to the played note — arps) and ABSOLUTE notes
	// ($80..$DF, a fixed pitch). Both are resolved onto the SAME semitone axis so a mixed
	// program reads as notes over time: a relative frame sits at (playedNote + offset)
	// and the whole relative shape shifts live as you keyjam a different note; an absolute
	// frame sits at its own fixed note and never moves. A bright reference line marks the
	// played note (relative "0"); octave gridlines + note-name gutter labels make the
	// pitch readable; the loop-back is marked as on the other bands. Recording view places
	// the ACTUAL measured pitch on the very same axis (cyan) so you see it track the arp.
	private void drawFreqBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 2, topPx, botPx);
		int h = botPx - topPx;
		if(h < 6) return;

		// Played/preview note index (C-0=0 .. B-7=95); C-4 baseline before any note.
		int played = inputKeyjam.previewNote();
		if(played < 0 || played > 95) played = 48;   // C-4

		int ptr = song.instrumentTable[ins + 7 * 48];
		WaveFrameSim s = simWaveFrames(ptr, waveTimeForInstrument(ins));
		const(int)[] fr;
		int n;
		if(useRec) {
			fr = audio.visualizer.getRecordedFreq(viewVoice);
			n = min(cast(int)fr.length, visFrames);
		} else {
			n = min(cast(int)s.transOf.length, visFrames);
		}
		if(n <= 0) return;

		// Frame -> absolute note index (-1 = silent/unknown), and the frame's colour.
		int idxOf(int f) {
			if(useRec) return freqToNoteIndex(fr[f]);
			return s.absOf[f] ? s.transOf[f] : played + s.transOf[f];
		}
		int colOf(int f) {
			if(useRec) return COL_FREQ_ABS;                        // a real, measured pitch
			return s.absOf[f] ? COL_FREQ_ABS : COL_FREQ_REL;      // authored abs vs relative
		}

		int flo, fhi; viewport.visRange(n, flo, fhi);   // §17.1 only emit on-screen frames

		// Fit the visible pitch range, always including the played-note reference. To keep
		// the (short) band readable we cap the window at two octaves: within that, fit the
		// content and snap to whole octaves for a clean labelled grid; a rarer wider spread
		// (e.g. one transient absolute note far away) centres a fixed window on the played
		// note and pins the outliers to the band edge rather than crushing the main shape.
		enum int MAX_SPAN = 24;   // at most two octaves visible at once
		int clo = played, chi = played;
		foreach(f; flo .. fhi) {
			int m = idxOf(f);
			if(m < 0) continue;
			if(m < clo) clo = m;
			if(m > chi) chi = m;
		}
		int lo, hi;
		// §22 when the Pitch band is expanded there is room for the whole range, so drop
		// the two-octave cap and fit every note (with per-octave labels).
		if(expandedBand == 2 || chi - clo <= MAX_SPAN) {
			lo = clo - 1; hi = chi + 1;              // one-semitone breathing room
			lo -= ((lo % 12) + 12) % 12;            // snap down to a C
			hi += 11 - (((hi % 12) + 12) % 12);     // snap up to a B
		} else {
			lo = played - MAX_SPAN / 2;              // centre the window on the played note
			hi = played + MAX_SPAN / 2;
		}
		if(lo < 0) lo = 0;
		if(hi > 95) hi = 95;
		if(hi - lo < 12) hi = min(95, lo + 12);     // at least one octave tall
		int span = hi - lo; if(span < 1) span = 1;

		int yOf(int m) { return botPx - cast(int)lround(cast(double)(m - lo) * h / span); }

		// Octave gridlines + note-name gutter labels (only at C boundaries to stay legible;
		// never on the band-name row so the "Pitch" label stays readable).
		int bandNameRow = g.bandTopPx[2] / FONT_Y;
		for(int m = lo - (lo % 12); m <= hi; m += 12) {
			if(m < lo) continue;
			int y = yOf(m);
			video.olHLine(g.plotX0px, g.plotX0px + g.plotWpx - 1, y, COL_AXIS);
			int row = y / FONT_Y;
			if(row != bandNameRow && m < NOTES.length)
				screen.cprint(g.labelX, row, COL_DIM, 0, NOTES[m]);
		}

		// Played-note reference line (relative "0") + its name, a touch brighter.
		int refY = yOf(played);
		video.olHLine(g.plotX0px, g.plotX0px + g.plotWpx - 1, refY, COL_HEAD);
		int refRow = refY / FONT_Y;
		if(refRow != bandNameRow && played < NOTES.length)
			screen.cprint(g.labelX, refRow, COL_TRIGGER, 0, NOTES[played]);

		// One piano-roll cell per frame at its resolved pitch. Relative frames also get a
		// faint stem from the reference line so "offset from your note" reads at a glance.
		int cellH = h / span;
		if(cellH < 2) cellH = 2;
		if(cellH > FONT_Y) cellH = FONT_Y;
		foreach(f; flo .. fhi) {
			int m = idxOf(f);
			if(m < 0) continue;                       // silent / unknown frame
			int mc = m < lo ? lo : (m > hi ? hi : m); // pin outliers to the band edge
			int xa, xb; frameXSpan(g, f, xa, xb);
			int cy = yOf(mc);
			if(!useRec && !s.absOf[f] && s.transOf[f] != 0)
				video.olVLine(xa, min(refY, cy), max(refY, cy), COL_DIM);
			video.olFillRect(xa, cy - cellH / 2, xb - xa, cellH, colOf(f));
		}

		// §14.2 loop-back marker (recording derives it from the actual pitch staircase).
		int lf = s.loopFrame, lp = s.loopPeriod;
		if(useRec) loopFromRecording(fr, n, lf, lp);
		drawLoopLines(g, topPx, botPx, lf, lp, n);
	}

	// ---- wave band = §9.3 stacked SID control-bit lanes ----
	// Simulate the wave program per frame to get the effective SID control byte, then
	// draw one thin lane per control bit (b7 Noise at top .. b0 Gate at bottom) with a
	// filled coloured block wherever the bit is ON. A combined-waveform frame lights
	// more than one waveform lane -- honest to the hardware. Loop back-edge marked.
	private void drawWaveBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 5, topPx, botPx);
		// Anchor the 8 bit-lanes to the CHARACTER grid so each lane is exactly one
		// text row tall. The gutter labels are text (font-row aligned); when the
		// lanes were pixel-height (h/8) they drifted off the 14px font grid, so the
		// coloured blocks no longer lined up with their labels (a lane's block would
		// sit beside the next lane's label, and one label was overwritten/dropped).
		// One lane == one row makes blocks and labels align 1:1.
		int topRow = (topPx + FONT_Y - 1) / FONT_Y;   // first full char row in the band
		int availRows = botPx / FONT_Y - topRow + 1;
		if(availRows < 8) return;                     // no room for 8 lanes
		int ptr = song.instrumentTable[ins + 7 * 48];
		WaveFrameSim s = simWaveFrames(ptr, waveTimeForInstrument(ins));

		// §11.2 source: the RECORDED control byte per frame when a note has played
		// (vivid per-bit lane colours), else the sim's effective control byte (dimmed).
		const(int)[] ctrlA;
		bool dim;
		if(useRec) { ctrlA = audio.visualizer.getRecordedControl(viewVoice); dim = false; }
		else       { ctrlA = s.ctrlOf; dim = true; }
		int n = min(cast(int)ctrlA.length, visFrames);

		// §11.4 lane labels (full words) in the left gutter + a faint divider per lane.
		foreach(li; 0 .. 8) {
			int bit = 7 - li;                       // top lane = bit7 (Noise)
			int lrow = topRow + li;
			int ly = lrow * FONT_Y;
			screen.cprint(g.labelX, lrow, BITLANE_COL[bit], 0, BITLANE_LBL[bit]);
			video.olHLine(g.plotX0px, g.plotX0px + g.plotWpx - 1, ly, COL_AXIS);
		}

		int flo, fhi; viewport.visRange(n, flo, fhi);   // §17.1 only emit on-screen frames
		foreach(f; flo .. fhi) {
			int ctrl = ctrlA[f];
			int xa, xb; frameXSpan(g, f, xa, xb);
			foreach(li; 0 .. 8) {
				int bit = 7 - li;
				if(!(ctrl & (1 << bit))) continue;
				int ly = (topRow + li) * FONT_Y;
				video.olFillRect(xa, ly + 1, xb - xa, FONT_Y - 2,
					dim ? COL_DIM : BITLANE_COL[bit]);
			}
		}
		// §14.2 loop lines: recording path derives the loop from the ACTUAL recorded
		// control bytes (so a line lands exactly where the bit-lane block pattern
		// restarts); sim path uses the sim's loopFrame/period.
		int lf = s.loopFrame, lp = s.loopPeriod;
		if(useRec) loopFromRecording(ctrlA, n, lf, lp);
		drawLoopLines(g, topPx, botPx, lf, lp,
			useRec ? n : min(cast(int)s.ctrlOf.length, visFrames));
	}

	// ---- raw table data strip (bottom) ----

	private void drawRawData(int ins, ref Geo g) {
		int y = g.rawTopRow;
		int x = area.x + 2;
		// Horizontal separator across the interior above the strip.
		for(int cx = area.x + 1; cx < area.x + area.width - 1; cx++)
			screen.setChar(cx, y, 0x0500 | 192);
		screen.cprint(x + 1, y, COL_TITLE, 0, " Raw table data / edit state ");

		ubyte b(int col) { return song.instrumentTable[ins + col * 48]; }
		screen.cprint(x, y + 1, COL_LABEL, 0, format(
			"Ins %02X:  AD %02X  SR %02X  Rst %02X  HRw %02X  Flt %02X  Pul %02X  HRsr %02X  Wav %02X",
			ins, b(0), b(1), b(2), b(3), b(4), b(5), b(6), b(7)));

		int maxw = area.width - 4;

		// Wave rows the instrument walks (wave1/wave2 pairs).
		{
			int ptr = b(7);
			WaveSim w = simWave(ptr);
			string ln = ptr == 0 ? "Wave: EMPTY" : selectedWaveNormal(ins)
				? format("Wave $%02X [row $%02X]: ", b(7), selectedWaveRow)
				: format("Wave $%02X: ", b(7));
			if(ptr != 0) foreach(c; w.cells) {
				string cell = format("%02X/%02X ", c.transpose & 0xff, c.ctrl & 0xff);
				if(ln.length + cell.length > maxw) { ln ~= ".."; break; }
				ln ~= cell;
			}
			int close = ptr == 0 ? -1 : waveCloseRow(ptr);
			if(close >= 0) {
				string marker = song.waveTable[close] == 0x7f
					? format(" LOOP $%02X->$%02X", close, song.waveTable[close + 256])
					: format(" END $%02X", close);
				if(ln.length + marker.length <= maxw) ln ~= marker;
			}
			screen.cprint(x, y + 2, COL_VALUE, 0, ln);
		}
		// Pulse rows used (unique, in first-seen order).
		{
			int ptr = b(5);
			string ln;
			if(ptr == 0) ln = "Pulse: EMPTY";
			else if(ptr >= 0x80) ln = format("Pulse: direct fixed $%03X", (ptr & 0x0f) << 8);
			else {
				SweepSim s = simPulse(ptr);
				int close = sweepCloseRow(0, ptr);
				string marker;
				if(close >= 0) {
					int jump = song.pulseTable[close * 4 + 3];
					marker = jump == 0x7f ? format("END $%02X", close)
						: (jump >= 1 && jump <= 0x3f
							? format("LOOP $%02X->$%02X", close, jump) : "INVALID");
				}
				ln = format("Pulse $%02X %s: ", ptr, marker);
				bool[0x40] seen;
				foreach(r; s.rowOf) {
					if(r < 0 || r >= 0x40 || seen[r]) continue;
					seen[r] = true;
					string cell = format("%02X:%02X %02X %02X %02X  ", r,
						song.pulseTable[r*4], song.pulseTable[r*4+1],
						song.pulseTable[r*4+2], song.pulseTable[r*4+3]);
					if(ln.length + cell.length > maxw) { ln ~= ".."; break; }
					ln ~= cell;
				}
			}
			screen.cprint(x, y + 3, COL_VALUE, 0, ln);
		}
		// Filter rows used.
		{
			int ptr = b(4);
			string ln;
			if(ptr <= 0) ln = "Filter: EMPTY";
			else {
				SweepSim s = simFilter(ptr);
				int close = sweepCloseRow(1, ptr);
				string marker;
				if(close >= 0) {
					int jump = song.filterTable[close * 4 + 3];
					marker = jump == 0x7f ? format("END $%02X", close)
						: (jump >= 1 && jump <= 0x3f
							? format("LOOP $%02X->$%02X", close, jump) : "INVALID");
				}
				ln = format("Filter $%02X %s: ", ptr, marker);
				bool[0x40] seen;
				foreach(r; s.rowOf) {
					if(r < 0 || r >= 0x40 || seen[r]) continue;
					seen[r] = true;
					string cell = format("%02X:%02X %02X %02X %02X  ", r,
						song.filterTable[r*4], song.filterTable[r*4+1],
						song.filterTable[r*4+2], song.filterTable[r*4+3]);
					if(ln.length + cell.length > maxw) { ln ~= ".."; break; }
					ln ~= cell;
				}
			}
			screen.cprint(x, y + 4, COL_VALUE, 0, ln);
		}
		// Live filter routing/resonance/mode. "SID-global" avoids confusing this hardware
		// property with a table program shared by two instruments (which has fork semantics).
		ubyte r17 = audio.audio.sidreg[0x17];
		ubyte r18 = audio.audio.sidreg[0x18];
		string routeStr;
		if(r17 & 1) routeStr ~= "1"; if(r17 & 2) routeStr ~= "2"; if(r17 & 4) routeStr ~= "3";
		if(routeStr.length == 0) routeStr = "-";
		string modeStr;
		if(r18 & 0x10) modeStr ~= "LP"; if(r18 & 0x20) modeStr ~= "BP"; if(r18 & 0x40) modeStr ~= "HP";
		if(modeStr.length == 0) modeStr = "off";
		screen.cprint(x, y + 5, COL_LABEL, 0,
			format("Live filter: Res %X  Route %s  Mode %s (SID-global)", r17 >> 4, routeStr, modeStr));
	}

	// ---- §14.1 mouse-hover probe + numeric readout ----

	private @property int COL_PROBE() { return idx(Role.cursor); }  // hover probe line
	                                   // (white; dashed to distinguish it from the SOLID white playhead)

	// SDL forwards a plain mouse-motion (no button) here as screen char-cells (see
	// UI.hoverAt / WindowSwitcher.hoverAt). We only record the cell; update() maps it
	// to a frame on the fresh geometry and draws / clears the probe. Read-only.
	override void hoverAt(int scrx, int scry) {
		hoverCellX = scrx;
		hoverCellY = scry;
		hovering = scrx >= 0 && scry >= 0;
		// §17.3 light the zoom button under the pointer (-1 = none / disabled).
		Geo g = layout();
		hoveredBtn = hovering ? visualButtonAt(g, scrx, scry) : -1;
		string actionId = hovering ? controlActionAt(clampedIns(), g) : "";
		if(actionId != hoveredControlAction) {
			hoveredControlAction = actionId;
			if(actionId.length && state.displayHelp) {
				auto def = mainui.sm.getAction(actionId);
				if(def !is null) {
					string keys = formatShortcuts(mainui.sm.getShortcuts(actionId));
					UI.statusline.display(def.description ~ (keys.length ? "  " ~ keys : ""));
				}
			}
		}
		if(!hovering) { setEditCursor(CURSOR_NORMAL); return; }
		bool waveLoopCursor = waveLoopHandleAt(clampedIns(), g, scrx, scry) >= 0;
		int dotCursor = graphDotCursorAt(g, scrx, scry);
		int waveCursor = waveGraphCursorAt(g, scrx, scry);
		bool loopCursor = sweepLoopHandleAt(0, g, scrx, scry) >= 0
			|| sweepLoopHandleAt(1, g, scrx, scry) >= 0;
		setEditCursor(waveLoopCursor ? CURSOR_HORIZONTAL
			: dotCursor != CURSOR_NORMAL ? dotCursor
			: waveCursor != CURSOR_NORMAL ? waveCursor
			: loopCursor ? CURSOR_HORIZONTAL
			: durationBoundaryAt(g, scrx, scry) ? CURSOR_HORIZONTAL
			: resonanceLineAt(g, scrx, scry) ? CURSOR_VERTICAL : CURSOR_NORMAL);
	}

	private bool resonanceLineAt(ref Geo g, int cellx, int celly) {
		int targetRow;
		return filterResHandleAt(g, cellx, celly, targetRow) >= 0;
	}

	// Cursor direction mirrors what each graph dot actually edits.
	private int graphDotCursorAt(ref Geo g, int cellx, int celly) {
		int ah = adsrHandleAt(g, cellx, celly);
		if(ah == ADSR_ATTACK || ah == ADSR_RELEASE) return CURSOR_HORIZONTAL;
		if(ah == ADSR_DECAY) return CURSOR_BOTH;       // time + sustain level
		if(ah == ADSR_SUSTAIN) return CURSOR_VERTICAL;

		int px = cellx * FONT_X + FONT_X / 2;
		int py = celly * FONT_Y + FONT_Y / 2;
		if(sweepMultiSelected()) {
			int[] range = sweepSelectedRange(clampedIns());
			if(range.length < 2) return CURSOR_NORMAL;
			foreach(i; 0 .. cast(int)range.length - 1) {
				int f0, f1, xa, xb, syS, syE;
				if(sweepStepGeom(selectedSweepTable, clampedIns(), range[i], g,
						f0, f1, xa, xb, syS, syE)
						&& nearSweepHandle(selectedSweepTable, px, py, xb, syE))
					return CURSOR_VERTICAL;
			}
			return CURSOR_NORMAL;
		}
		int t = selectedSweepTable, r = selectedSweepRow;
		if((t != 0 && t != 1) || !sweepRowResizable(t, r)) return CURSOR_NORMAL;
		int f0, f1, xa, xb, syS, syE;
		if(!sweepStepGeom(t, clampedIns(), r, g, f0, f1, xa, xb, syS, syE)) return CURSOR_NORMAL;
		if(nearSweepHandle(t, px, py, xa, syS)) return CURSOR_VERTICAL;
		if(sweepRowHasSlope(t, r) && nearSweepHandle(t, px, py, xb, syE)) return CURSOR_VERTICAL;
		return CURSOR_NORMAL;
	}

	// Match the duration-drag hit priority exactly: only advertise horizontal resize
	// where pressing will resize the selected pulse/filter sweep row. The END/slope dot
	// keeps its own drag behavior, and instantaneous filter CONFIG rows never claim it.
	private bool durationBoundaryAt(ref Geo g, int cellx, int celly) {
		int t = sweepBandAt(g, cellx, celly);
		// The first character row can straddle the pixel-precise Filter band top.
		// Treat an intersecting cell as Filter geometry so its true terminal edge
		// advertises the same duration gesture that beginSelectedStepDrag starts.
		if(t < 0 && selectedSweepTable == 1) {
			int cellTop = celly * FONT_Y, cellBot = cellTop + FONT_Y;
			if(cellBot > g.bandTopPx[4] && cellTop < g.bandTopPx[5]) t = 1;
		}
		if(t < 0) return false;
		int r = sweepDurationRowAtPress(t, clampedIns(), g, cellx, celly);
		if(r < 0) return false;
		int f0, f1, xa, xb, syS, syE;
		if(!sweepStepGeom(t, clampedIns(), r, g, f0, f1, xa, xb, syS, syE)) return false;
		int band = t == 0 ? 3 : 4;
		int px = cellx * FONT_X + FONT_X / 2;
		int py = celly * FONT_Y + FONT_Y / 2;
		bool inBand = py >= g.bandTopPx[band] && py < g.bandTopPx[band + 1];
		if(t == 1 && celly == g.bandTopPx[4] / FONT_Y) {
			int cellTop = celly * FONT_Y, cellBot = cellTop + FONT_Y;
			inBand = cellBot > g.bandTopPx[4] && cellTop < g.bandTopPx[5];
		}
		if(!inBand) return false;
		if(abs(px - xb) > DUR_HIT_PX) return false;
		return true;
	}

	private void setEditCursor(int cursor) {
		if(cursor == editCursor) return;
		if(cursor == CURSOR_HORIZONTAL) {
			if(sizeWeCursor is null)
				sizeWeCursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEWE);
			if(sizeWeCursor !is null) SDL_SetCursor(sizeWeCursor);
		} else if(cursor == CURSOR_VERTICAL) {
			if(sizeNsCursor is null)
				sizeNsCursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZENS);
			if(sizeNsCursor !is null) SDL_SetCursor(sizeNsCursor);
		} else if(cursor == CURSOR_BOTH) {
			if(sizeAllCursor is null)
				sizeAllCursor = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEALL);
			if(sizeAllCursor !is null) SDL_SetCursor(sizeAllCursor);
		} else {
			SDL_SetCursor(SDL_GetDefaultCursor());
		}
		editCursor = cursor;
	}

	override void deactivate() {
		hoveredControlAction = "";
		setEditCursor(CURSOR_NORMAL);
	}

	// Note name from a raw 16-bit SID frequency register value (PAL). "if easy": a
	// straight reg->Hz->MIDI conversion. Empty for silence / out-of-range.
	private static string noteName(int rawFreq) {
		if(rawFreq <= 0) return "";
		// PAL SID: Hz = raw * clock / 2^24, clock = 985248.
		double hz = rawFreq * 985248.0 / 16777216.0;
		if(hz < 8.0) return "";
		double midi = 69.0 + 12.0 * log2(hz / 440.0);
		int m = cast(int)lround(midi);
		if(m < 0 || m > 127) return "";
		static immutable string[12] nm =
			["C-","C#","D-","D#","E-","F-","F#","G-","G#","A-","A#","B-"];
		return format("%s%d", nm[m % 12], m / 12 - 1);
	}

	// Idle probe amplitude from the same silent raw reSID trace as drawAdsrBand. Linear
	// interpolation is display geometry only; both endpoints remain true tick samples.
	private float adsrAmpAt(int ins, float f) {
		if(f < 0) f = 0;
		int i0 = cast(int)floor(f);
		ensureSilentEnvelopePreview(i0 + 2);
		if(silentEnvPreview.length == 0) return 0;
		if(i0 >= silentEnvPreview.length - 1)
			return silentEnvPreview[$ - 1] / 255.0f;
		float frac = f - i0;
		float a = silentEnvPreview[i0] / 255.0f;
		float b = silentEnvPreview[i0 + 1] / 255.0f;
		return a + (b - a) * frac;
	}

	// §14.1 Draw the hover probe: a dashed WHITE vertical line at the hovered frame
	// across all bands (distinct from the SOLID white playhead) + a compact numeric
	// readout of the register values at that frame in the left param gutter. Nothing
	// is drawn (probe cleared) when the cursor is not over the plot region.
	private void drawProbe(int ins, ref Geo g) {
		if(!hovering) return;
		int hx = hoverCellX * FONT_X + FONT_X / 2;
		int hy = hoverCellY * FONT_Y + FONT_Y / 2;
		// Over the plot region? (same pixel box every band shares + the band stack.)
		if(hx < g.plotX0px || hx >= g.plotX0px + g.plotWpx) return;
		if(hy < g.stackTopPx || hy >= g.stackBotPx) return;

		// §17.1 Pixel -> nearest frame on the VIEWPORT axis, snapped + clamped to the note.
		int f = cast(int)lround(viewport.tickForPixel(g, hx));
		if(f < 0) f = 0;
		if(f >= visFrames) f = visFrames - 1;
		if(f < 0) f = 0;

		// Dashed white probe line at that frame across the whole band stack.
		int px = viewport.xForFrame(g, f);
		for(int yy = g.stackTopPx; yy < g.stackBotPx; yy += 6) {
			int ye = min(yy + 3, g.stackBotPx);
			video.olVLine(px, yy, ye, COL_PROBE);
		}

		// Gather the register values at frame f: from the RECORDING when a note has
		// played, else from the read-only table sims (interpolated where continuous).
		int freq = -1, pw = -1, cutoff = -1, res = -1, mode = -1, route = -1, ctrl = 0;
		float amp = -1;
		bool haveFreq = false, haveArp = false;
		int arpVal = 0; bool arpAbs = false;
		if(useRec) {
			auto fr = audio.visualizer.getRecordedFreq(viewVoice);
			auto pu = audio.visualizer.getRecordedPulse(viewVoice);
			auto cu = audio.visualizer.getRecordedCutoff(viewVoice);
			auto re = audio.visualizer.getRecordedResonance(viewVoice);
			auto mo = audio.visualizer.getRecordedMode(viewVoice);
			auto ro = audio.visualizer.getRecordedRouting(viewVoice);
			auto ct = audio.visualizer.getRecordedControl(viewVoice);
			auto am = audio.visualizer.getRecordedAmp(viewVoice);
			int rf = f < cast(int)fr.length ? f : cast(int)fr.length - 1;
			if(rf >= 0) {
				if(rf < fr.length) { freq = fr[rf]; haveFreq = true; }
				if(rf < pu.length) pw = pu[rf];
				if(rf < cu.length) cutoff = cu[rf];
				if(rf < re.length) res = re[rf];
				if(rf < mo.length) mode = mo[rf];
				if(rf < ro.length) route = ro[rf];
				if(rf < ct.length) ctrl = ct[rf];
				if(rf < am.length) amp = am[rf];
			}
		} else {
			SweepSim ps = simPulse(song.instrumentTable[ins + 5 * 48]);
			SweepSim fs = simFilter(song.instrumentTable[ins + 4 * 48]);
			WaveFrameSim ws = simWaveFrames(song.instrumentTable[ins + 7 * 48],
				waveTimeForInstrument(ins));
			if(f < cast(int)ps.val.length) pw = ps.val[f];
			if(f < cast(int)fs.val.length) {
				cutoff = fs.val[f];
				res = f < fs.resOf.length ? fs.resOf[f] : 0;
				mode = f < fs.modeOf.length ? fs.modeOf[f] : 0;
				route = f < fs.routeOf.length ? fs.routeOf[f] : 0;
			}
			if(f < cast(int)ws.ctrlOf.length) ctrl = ws.ctrlOf[f];
			if(f < cast(int)ws.transOf.length) {
				haveArp = true; arpVal = ws.transOf[f]; arpAbs = ws.absOf[f];
			}
			amp = adsrAmpAt(ins, cast(float)f);   // interpolated envelope value
		}

		// Compact readout box in the left param gutter, below the parameter rows.
		int rx = g.paramX;
		int rw = g.sepX - g.paramX - 1;
		int ry = area.y + 3 + PARAM_ROWS + 1;
		void put(int r, int col, string s) {
			if(cast(int)s.length > rw) s = s[0 .. rw];
			// clear the row first so a shorter line doesn't leave stale chars.
			foreach(cx; 0 .. rw) screen.setChar(rx + cx, ry + r, 0x0500 | ' ');
			screen.cprint(rx, ry + r, col, 0, s);
		}
		float ms = f * tickMs;   // §16.2 real time at the current multiplier
		put(0, COL_TITLE, "-- Probe (hover) --");
		put(1, COL_VALUE, format("frame %d  ~%.1f ms", f, ms));
		if(haveFreq) {
			string nn = noteName(freq);
			put(2, COL_LABEL, format("Freq $%04X %s", freq & 0xffff, nn));
		} else if(haveArp) {
			put(2, COL_LABEL, arpAbs ? format("Note  abs %d", arpVal)
				: format("Arp   +%d st", arpVal));
		} else {
			put(2, COL_LABEL, "Freq  n/a");
		}
		put(3, COL_LABEL, pw >= 0 ? format("Pulse $%03X", pw & 0xfff) : "Pulse n/a");
		if(cutoff >= 0) {
			put(4, COL_LABEL, format("Cut $%04X Res %X", cutoff & 0xffff, res & 0xf));
			put(5, COL_LABEL, format("Mode %s Rt%X", filterModeName(mode), route & 0xf));
		} else {
			put(4, COL_LABEL, "Filter n/a");
			put(5, COL_LABEL, "");
		}
		put(6, COL_VALUE, format("Ctrl $%02X", ctrl & 0xff));
		put(7, COL_LABEL, ctrlBits(ctrl));
		put(8, COL_VALUE, amp >= 0 ? format("Env %d%%", cast(int)lround(clamp01(amp) * 100))
			: "Env n/a");
	}

	// Decode a SID control byte to a short list of the ON bits (Noise/Pulse/Saw/Tri/
	// Test/Ring/Sync/Gate) for the probe readout.
	private static string ctrlBits(int ctrl) {
		string s;
		if(ctrl & 0x80) s ~= "Noi ";
		if(ctrl & 0x40) s ~= "Pul ";
		if(ctrl & 0x20) s ~= "Saw ";
		if(ctrl & 0x10) s ~= "Tri ";
		if(ctrl & 0x08) s ~= "Tst ";
		if(ctrl & 0x04) s ~= "Rng ";
		if(ctrl & 0x02) s ~= "Snc ";
		if(ctrl & 0x01) s ~= "Gat ";
		return s.length ? stripRight(s) : "(silent)";
	}

	// §14.2 Derive the loop (start frame, period) DIRECTLY from an ACTUAL recorded
	// per-frame value array — honestly marking the frames where the played value
	// pattern actually repeats, INCLUDING the real gate-on/arp-delay start offset that
	// the frame-0 sim ignores (the old bug: loop lines were drawn from the sim's
	// frame-0 loopFrame, so they drifted left of where the recorded values repeat).
	// We find the SMALLEST period P>=2 for which the recording's tail is exactly
	// P-periodic, and the EARLIEST frame L at which that periodicity begins. A period
	// whose one cycle is constant (a steady hold, e.g. a sustained waveform) is NOT a
	// repeating pattern and is skipped. loopStart<0 (=> no line) when nothing repeats
	// (too short a recording, or a non-repeating sweep) — an honest "no loop here".
	private enum int LOOP_MAX_PERIOD = 256;   // instrument loops are short; cap the scan
	private void loopFromRecording(const(int)[] v, int n, out int loopStart, out int period) {
		loopStart = -1; period = 0;
		if(n > cast(int)v.length) n = cast(int)v.length;
		if(n < 4) return;
		int pmax = min(n / 2, LOOP_MAX_PERIOD);
		for(int p = 2; p <= pmax; p++) {
			// Earliest L such that v[i]==v[i+p] for ALL i in [L, n-p): one past the last
			// index that breaks the period.
			int L = 0;
			for(int i = n - p - 1; i >= 0; i--)
				if(v[i] != v[i + p]) { L = i + 1; break; }
			if(n - L < 2 * p) continue;          // need >=2 full cycles to call it a loop
			// Reject a constant cycle (a hold, not a repeating pattern).
			bool constant = true;
			for(int i = L + 1; i < L + p; i++)
				if(v[i] != v[L]) { constant = false; break; }
			if(constant) continue;
			loopStart = L; period = p; return;    // smallest meaningful period wins
		}
	}

	// ---- timeline simulators (read-only; mirror src/c64/player_v4.acme) ----

	// What simPulse/simFilter should do after emitting a row's frame(s): keep
	// going from a fresh row, jump back into an already-visited (looping)
	// section, or stop the program outright ($7F / out-of-range jump).
	private enum SweepStep { advance, loopBack, stop }

	// Shared tail of simPulse/simFilter: decode the row's jump byte `b3` into
	// the next row, and if that row has already been visited, record the loop
	// window (§11.3) exactly once. Mutates `row` (and `s.loopFrame`/`loopPeriod`
	// on first loop detection) in place; the caller acts on the returned step.
	private SweepStep advanceSweepRow(ref int row, ubyte b3, ref bool[0x40] visited,
			ref int[0x40] firstFrame, ref SweepSim s) {
		int nextRow;
		if(b3 == 0) nextRow = (row + 1) & 0x3f;
		else if(b3 == 0x7f) return SweepStep.stop;
		else if(b3 <= 0x3f) nextRow = b3;
		else return SweepStep.stop;
		if(visited[nextRow]) {
			if(s.loopFrame < 0) {
				s.loopFrame = firstFrame[nextRow];
				s.loopPeriod = cast(int)s.val.length - firstFrame[nextRow];
				if(s.loopPeriod < 1) s.loopPeriod = 1;
			}
			row = nextRow;
			return SweepStep.loopBack;
		}
		visited[nextRow] = true;
		row = nextRow;
		return SweepStep.advance;
	}

	// Simulate the pulse-width program starting at table row `startRow`.
	private SweepSim simPulse(int startRow) {
		SweepSim s;
		int MAXF = visFrames;   // §12.2 sims produce/replicate up to the dynamic window
		if(startRow < 0 || startRow >= 0x40) return s;
		int pw = 0x800;
		int row = startRow;
		bool[0x40] visited;
		int[0x40] firstFrame; firstFrame[] = -1;
		visited[row] = true;
		simPulseLoop: while(s.val.length < MAXF) {
			int base = row * 4;
			ubyte b0 = song.pulseTable[base + 0];
			ubyte b1 = song.pulseTable[base + 1];
			ubyte b2 = song.pulseTable[base + 2];
			ubyte b3 = song.pulseTable[base + 3];
			if(firstFrame[row] < 0) firstFrame[row] = cast(int)s.val.length;
			if(b2 != 0xff) pw = ((b2 & 0x0f) << 8) | (b2 & 0xf0);
			int n = (b0 & 0x7f) + 1;
			int dir = (b0 & 0x80) ? -1 : 1;
			foreach(f; 0 .. n) {
				pw = (pw + dir * b1) & 0xfff;
				s.val ~= pw;
				s.rowOf ~= row;
				if(s.val.length >= MAXF) break;
			}
			// §11.3 loop: on the FIRST return to an already-emitted row, record where
			// the looped section starts and its period, then KEEP replicating it across
			// the visible window (the real player repeats it too) instead of breaking.
			final switch(advanceSweepRow(row, b3, visited, firstFrame, s)) {
				case SweepStep.stop: s.stops = true; break simPulseLoop;
				case SweepStep.loopBack: continue simPulseLoop;
				case SweepStep.advance: break;
			}
		}
		return s;
	}

	// Simulate the filter program starting at row `startRow`, returning per-frame
	// cutoff (0..2047) AND per-frame mode/resonance/routing (§10.1/§10.2 decode from
	// §10.6): a CONFIG row (b0 & 0x80) sets mode=b0&0x70, res=b1>>4, routing=b1&0x0F
	// and (if b2!=0xFF) cutoff=b2<<3; a SWEEP row sweeps the cutoff while mode/res/
	// routing PERSIST from the last CONFIG row.
	private SweepSim simFilter(int startRow) {
		SweepSim s;
		int MAXF = visFrames;   // §12.2 sims produce/replicate up to the dynamic window
		if(startRow <= 0 || startRow >= 0x40) return s;
		int cutoff = 0;
		int mode = 0, res = 0, routing = 0;   // persist across rows
		int curCfgRow = -1;                    // §20 P4b-3 last CONFIG row seen (-1 = none)
		int row = startRow;
		bool[0x40] visited;
		int[0x40] firstFrame; firstFrame[] = -1;
		visited[row] = true;
		// Emit one frame at the current cutoff carrying the persisting mode/res/routing.
		void emit() {
			s.val ~= cutoff; s.rowOf ~= row;
			s.modeOf ~= mode; s.resOf ~= res; s.routeOf ~= routing;
			s.cfgRowOf ~= curCfgRow;
		}
		simFilterLoop: while(s.val.length < MAXF) {
			int base = row * 4;
			ubyte b0 = song.filterTable[base + 0];
			ubyte b1 = song.filterTable[base + 1];
			ubyte b2 = song.filterTable[base + 2];
			ubyte b3 = song.filterTable[base + 3];
			if(firstFrame[row] < 0) firstFrame[row] = cast(int)s.val.length;
			if(b0 & 0x80) {
				mode = b0 & 0x70;
				res = b1 >> 4;
				routing = b1 & 0x0f;
				curCfgRow = row;               // §20 P4b-3 this row now governs mode/res
				if(b2 != 0xff) cutoff = (b2 << 3);
				emit();
			}
			else {
				if(b2 != 0xff) cutoff = (b2 << 3);
				int n = b0 & 0x7f;
				int delta = 2 * (b1 < 0x80 ? b1 : b1 - 0x100);
				emit();
				foreach(f; 0 .. n) {
					// The player's 8-bit cutoff-high byte + 3-bit fractional low
					// accumulator wraps naturally; it does not saturate at either rail.
					cutoff = (cutoff + delta) & 0x7ff;
					emit();
					if(s.val.length >= MAXF) break;
				}
			}
			// §11.3 loop replication (see simPulse).
			final switch(advanceSweepRow(row, b3, visited, firstFrame, s)) {
				case SweepStep.stop: s.stops = true; break simFilterLoop;
				case SweepStep.loopBack: continue simFilterLoop;
				case SweepStep.advance: break;
			}
		}
		return s;
	}

	// Walk the wave/arp program starting at row `startRow`.
	private WaveSim simWave(int startRow) {
		WaveSim w;
		int MAXR = visFrames;   // §12.2 dynamic window (loop stops early on revisit)
		if(startRow < 0 || startRow > 0xff) return w;
		int row = startRow & 0xff;
		bool[256] visited;
		while(w.cells.length < MAXR) {
			int w1 = song.waveTable[row];
			int w2 = song.waveTable[row + 256];
			if(w1 == 0x7f) { w.loopIndex = cast(int)w.cells.length; w.loopTargetRow = w2; break; }
			if(w1 == 0x7e) { w.loopIndex = cast(int)w.cells.length; w.loopTargetRow = -2; break; }
			WaveCell c;
			c.row = row; c.transpose = w1; c.ctrl = w2;
			w.cells ~= c;
			if(visited[row]) break;
			visited[row] = true;
			row = (row + 1) & 0xff;
		}
		return w;
	}

	// §9.3: flatten the wave program to one control byte per FRAME, following $7F
	// jump / $7E loop-to-previous exactly like simPulse/simFilter follow their jumps.
	// Carries the last real control byte forward across delay/unchanged rows.
	private WaveFrameSim simWaveFrames(int startRow, int waveTime = 0, int requestedFrames = 0) {
		WaveFrameSim s;
		int MAXF = requestedFrames > 0 ? requestedFrames : visFrames;
		if(startRow < 0 || startRow > 0xff) return s;
		if(waveTime < 0) waveTime = 0;
		if(waveTime > 0x0f) waveTime = 0x0f;
		int row = startRow & 0xff, producer = -1;
		int cur = 0, curTrans = 0;       // carried effective values
		bool curAbs = false;
		int waveCnt = 0;                 // player initializes wavecnt to zero
		int[256] firstFrame; firstFrame[] = -1;
		foreach(tick; 0 .. MAXF) {
			waveCnt--;
			if(waveCnt < 0) {
				waveCnt = waveTime;
				// Markers are consumed by look-ahead in the real player and emit no value.
				// Normalize a malformed pointer that starts directly on one without spinning.
				int guard;
				while((song.waveTable[row] == 0x7e || song.waveTable[row] == 0x7f)
						&& guard++ < 256)
					row = song.waveTable[row] == 0x7f
						? song.waveTable[row + 256] : ((row - 1) & 0xff);
				if(guard >= 256) break;

				if(firstFrame[row] >= 0 && s.loopFrame < 0) {
					s.loopFrame = firstFrame[row];
					s.loopPeriod = tick - firstFrame[row];
					if(s.loopPeriod < 1) s.loopPeriod = 1;
				}
				if(firstFrame[row] < 0) firstFrame[row] = tick;

				int w1 = song.waveTable[row];
				int w2 = song.waveTable[row + 256];
				producer = row;
				cur = decodeWaveControl(w2, cur);
				if(w1 >= 0x80) { curTrans = w1 & 0x7f; curAbs = true; }
				else           { curTrans = w1;        curAbs = false; }

				// Resolve the destination exactly in player order, then let that row's
				// $01..$0F wave2 override the countdown. Delay D holds this producer for
				// D+1 emitted ticks before the destination is processed.
				int next = (row + 1) & 0xff;
				int nextW1 = song.waveTable[next];
				if(nextW1 == 0x7e) next = row;
				else if(nextW1 == 0x7f) next = song.waveTable[next + 256];
				int nextW2 = song.waveTable[next + 256];
				if(nextW2 >= 1 && nextW2 <= 0x0f) waveCnt = nextW2;
				row = next & 0xff;
			}
			if(producer < 0) break;
			s.ctrlOf ~= cur;
			s.rowOf ~= producer;
			s.transOf ~= curTrans;
			s.absOf ~= curAbs;
		}
		return s;
	}

	// ---- §17.2 selection highlight + §17.3 zoom controls ----

	// The clamped pixel X range of the current selection within the plot, or false if
	// the selection is entirely off-view / absent.
	private bool selectionPixels(ref Geo g, out int xa, out int xb) {
		if(!hasSelection) return false;
		xa = viewport.xForFrame(g, selStartTick);
		xb = viewport.xForFrame(g, selEndTick);
		if(xb < xa) { int t = xa; xa = xb; xb = t; }
		if(xb <= xa) xb = xa + 1;
		int pe = g.plotX0px + g.plotWpx;
		if(xb <= g.plotX0px || xa >= pe) return false;   // fully off-view
		return true;
	}

	// §17.2 subtle translucent-looking highlight wash across the whole band stack for
	// the selection: a SPARSE vertical hatch (every 3px) in a dim blue, drawn BEFORE the
	// bands so the graphs paint over it and stay legible while the tint shows through
	// the gaps. Drawn only when zoomed/relevant; always harmless when there's no sel.
	private enum int SEL_ALPHA = 72;   // translucency of the selection wash (0..255)
	private void drawSelectionFill(ref Geo g) {
		int xa, xb;
		if(!selectionPixels(g, xa, xb)) return;
		int pe = g.plotX0px + g.plotWpx;
		if(xa < g.plotX0px) xa = g.plotX0px;
		if(xb > pe) xb = pe;
		if(xb <= xa) return;
		// A single TRANSLUCENT blue wash over the whole stack (semantic colour, not a
		// magic index), instead of the old opaque striped vertical-line grid. The bands
		// draw on top and stay fully legible through the light overlay.
		video.olFillRectA(xa, g.stackTopPx, xb - xa, g.stackBotPx - g.stackTopPx,
						  idx(Role.soundeditSelection), SEL_ALPHA);
	}

	// §17.2 the two selection edges, drawn AFTER the bands (bright, solid) so the range
	// boundaries are clearly visible over the graphs.
	private void drawSelectionEdges(ref Geo g) {
		if(!hasSelection) return;
		if(viewport.frameInView(selStartTick))
			video.olVLine(viewport.xForFrame(g, selStartTick), g.stackTopPx, g.stackBotPx, COL_SEL_EDGE);
		if(viewport.frameInView(selEndTick))
			video.olVLine(viewport.xForFrame(g, selEndTick), g.stackTopPx, g.stackBotPx, COL_SEL_EDGE);
	}

	// View controls plus a selected-program Stop action, left-to-right.
	private enum int BTN_ZOOMOUT = 0, BTN_ZOOMIN = 1, BTN_FIT = 2, BTN_SEL = 3,
		BTN_ADD = 4, BTN_DEL = 5, BTN_STOP = 6, BTN_TYPE = 7, BTN_CARRY = 8,
		BTN_NEW = 9, BTN_WPREV = 10, BTN_WNEXT = 11, BTN_W1 = 12, BTN_W2 = 13,
		BTN_WLOOP = 14, BTN_RESDEC = 15, BTN_RESINC = 16, BTN_LINKED = 17;
	private static string controlActionId(int i) {
		static immutable string[18] actions = [
			"se_zoom_out", "se_zoom_in", "se_fit", "se_selection",
			"se_add", "se_delete", "se_stop", "se_type", "se_carry", "se_new",
			"se_wave_prev", "se_wave_next", "se_wave_1", "se_wave_2", "se_wave_loop",
			"se_res_down", "se_res_up", "se_linked"
		];
		return i >= 0 && i < actions.length ? actions[i] : "";
	}

	// §17.3 Build the four zoom buttons as ordinary ui.button widgets, laid out
	// left-to-right on the control row from the plot's left edge with a 1-cell gap,
	// each pre-loaded with its current interaction/state flags. Recomputed identically
	// by the drawer, the hover probe and the click hit-test so they always agree:
	//   * hovered/pressed track the pointer (see hoverAt + the press/release gesture);
	//   * [Fit] is `active` while the view is auto-fitted (not user-zoomed);
	//   * [Selection] needs a selection — it is `disabled` without one, and `active`
	//     while the viewport currently equals that selection.
	// Padded button labels, computed once at compile time instead of re-concatenating
	// " " ~ text ~ " " on every zoomButtons() call. Indexed by the BTN_* constants
	// above; entries for the currently-unused BTN_NEW/BTN_W1/BTN_W2 slots are blank
	// because those buttons are never place()d.
	private static immutable string[18] ZOOM_BTN_LABELS = [
		" - ", " + ", " Fit ", " Selection ", " Add ", " Delete ", " Stop ", " Type ",
		" Carry ", "", " Previous ", " Next ", "", "", " Loop ", " Res- ", " Res+ ",
		" Linked edits "
	];

	private Button[18] zoomButtons(ref Geo g) {
		Button[18] b;
		foreach(i, ref button; b) {
			button.x0 = -1000; button.x1 = -1000; button.row = g.controlRow;
			// commandEnabled() is computed once here per button; place() below reuses
			// this value instead of recomputing it.
			button.enabled = commandEnabled(controlActionId(cast(int)i));
		}
		int cx = g.plotX0px / FONT_X;
		void place(int i) {
			string label = ZOOM_BTN_LABELS[i];
			b[i].x0 = cx; b[i].x1 = cx + cast(int)label.length;
			b[i].label = label;
			b[i].hovered = (hoveredBtn == i);
			b[i].pressed = (pressedBtn == i && pressedOver);
			cx = b[i].x1 + 1;
		}
		place(BTN_ZOOMOUT); place(BTN_ZOOMIN);
		place(BTN_FIT); place(BTN_SEL);
		place(BTN_LINKED);
		cx += 1; // two-cell separation between View and contextual graph actions
		int ins = clampedIns();
		if(selectedWaveNormal(ins)) {
			place(BTN_ADD); place(BTN_DEL);
			place(BTN_WPREV); place(BTN_WNEXT); place(BTN_WLOOP);
		} else if(selectedSweepTable == 0 && selectedSweepRow >= 1) {
			place(BTN_ADD); place(BTN_DEL);
			place(BTN_STOP); place(BTN_CARRY);
		} else if(selectedSweepTable == 1 && selectedSweepRow >= 1) {
			bool config = (song.filterTable[selectedSweepRow * 4] & 0x80) != 0;
			place(BTN_ADD); place(BTN_DEL);
			place(BTN_STOP); place(BTN_TYPE);
			if(config) { place(BTN_RESDEC); place(BTN_RESINC); }
			else place(BTN_CARRY);
		}
		b[BTN_FIT].active = !viewport.userZoomed;
		b[BTN_SEL].active = hasSelection
			&& cast(int)lround(viewport.startTick) == selStartTick
			&& cast(int)lround(viewport.endTick) == selEndTick;
		b[BTN_LINKED].active = debugOwnershipMode() == "linked";
		if(b[BTN_STOP].enabled) {
			auto k = sweepKind(selectedSweepTable);
			int close = sweepCloseRow(selectedSweepTable, song.instrumentTable[ins + k.insCol * 48]);
			b[BTN_STOP].active = close >= 0 && k.table[close * 4 + 3] == 0x7f;
		}
		b[BTN_TYPE].active = b[BTN_TYPE].enabled
			&& (song.filterTable[selectedSweepRow * 4] & 0x80) != 0;
		if(b[BTN_CARRY].enabled) {
			const(ubyte)[] t = sweepKind(selectedSweepTable).table;
			b[BTN_CARRY].active = t[selectedSweepRow * 4 + 2] == 0xff;
		}
		int wstart = song.instrumentTable[ins + 7 * 48];
		int wclose = waveCloseRow(wstart);
		b[BTN_WLOOP].active = wclose >= 0 && song.waveTable[wclose] == 0x7f;
		return b;
	}

	// §17.3 The enabled zoom button under screen cell (x,y), or -1. Disabled buttons and
	// cells off the control row never match, so hover/click only react where a click
	// would actually do something.
	private int buttonAt(ref Geo g, int x, int y) {
		auto btns = zoomButtons(g);
		foreach(int i, ref b; btns)
			if(b.enabled && b.contains(x, y)) return i;
		return -1;
	}
	private int visualButtonAt(ref Geo g, int x, int y) {
		auto btns = zoomButtons(g);
		foreach(int i, ref b; btns) if(b.contains(x, y)) return i;
		return -1;
	}
	private string controlActionAt(int ins, ref Geo g) {
		if(hoveredBtn >= 0 && hoveredBtn < 18) return controlActionId(hoveredBtn);
		if(hovering && filterModeChipVisible(g)) {
			auto b = filterModeButtons(ins, g);
			static immutable string[3] modeActions = ["se_lp", "se_bp", "se_hp"];
			foreach(i; 0 .. 3)
				if(b[i].contains(hoverCellX, hoverCellY)) return modeActions[i];
		}
		if(hovering && filterRouteChipVisible(g)) {
			auto route = filterRouteButton(ins, g);
			if(route.contains(hoverCellX, hoverCellY)) return "se_route";
		}
		return "";
	}

	// §17.3 Perform a zoom button's action (fired on release over the pressed button).
	private void activateZoomButton(int i) {
		switch(i) {
			case BTN_ZOOMOUT: viewport.zoomBy(2.0, prerollTicks, contentMaxFrames); break;  // [-] zoom out
			case BTN_ZOOMIN:  viewport.zoomBy(0.5, prerollTicks, contentMaxFrames); break;  // [+] zoom in
			case BTN_FIT:     viewport.userZoomed = false; viewport.fit(prerollTicks, visFrames); break;  // [Fit]
			case BTN_SEL:     zoomToSelection(); break;       // [Selection]
			case BTN_ADD:
				if(selectedSweepTable >= 0) sweepRowOp(selectedSweepTable, true);
				else waveRowOp(true);
				break;
			case BTN_DEL:
				if(selectedSweepTable >= 0) sweepRowOp(selectedSweepTable, false);
				else waveRowOp(false);
				break;
			case BTN_STOP:    stopSelectedSweepProgram(); break;
			case BTN_TYPE:    toggleSelectedFilterRowType(); break;
			case BTN_CARRY:   toggleSelectedSweepCarry(); break;
			case BTN_NEW:     createNewIsolatedSound(); break;
			case BTN_WPREV:   moveSelectedWave(-1); break;
			case BTN_WNEXT:   moveSelectedWave(+1); break;
			case BTN_W1:      querySelectedWaveByte(0); break;
			case BTN_W2:      querySelectedWaveByte(1); break;
			case BTN_WLOOP:   queryWaveLoopTarget(); break;
			case BTN_RESDEC:  nudgeSelectedFilterRes(-1); break;
			case BTN_RESINC:  nudgeSelectedFilterRes(+1); break;
			case BTN_LINKED:  toggleLinkedEdits(); break;
			default: break;
		}
	}

	// §17.3 Draw the subtle control-button row + the current selection readout (its tick
	// range + ms) to its right — all as TEXT (no overlay pixels), so it composites like
	// the rest of the chrome.
	private void drawZoomControls(ref Geo g) {
		auto btns = zoomButtons(g);
		int rx = g.plotX0px / FONT_X;
		foreach(ref b; btns) if(b.x0 >= 0) {
			b.draw();
			rx = max(rx, b.x1 + 1);
		}
		int rw = (g.plotX0px + g.plotWpx) / FONT_X - rx;
		if(rw < 4) return;
		string txt;
		if(hasSelection) {
			int a = selStartTick, e = selEndTick;
			float ma = a * tickMs, me = e * tickMs;
			txt = format("sel %d-%d t  (~%.0f-%.0f ms, %d t)", a, e, ma, me, e - a);
		} else {
			txt = format("view %d-%d t   (drag to select)",
				cast(int)lround(viewport.startTick), cast(int)lround(viewport.endTick));
		}
		if(cast(int)txt.length > rw) txt = txt[0 .. rw];
		screen.cprint(rx, g.controlRow, COL_CTRL, 0, txt);
	}

	// §17.3 Zoom the viewport to the current selection (no-op if none). Thin
	// wrapper so call sites don't need the `if(!hasSelection) return;` guard.
	private void zoomToSelection() {
		if(!hasSelection) return;
		viewport.zoomToSelection(selStartTick, selEndTick, prerollTicks, contentMaxFrames);
	}

	// ---- §17.4 horizontal scrollbar ----

	// The scrollbar TRACK's inclusive-exclusive cell X span on the scroll row = the plot
	// width (same columns the bands span), so the track represents the whole Fit range.
	private void scrollTrackCells(ref Geo g, out int x0, out int w) {
		x0 = g.plotX0px / FONT_X;
		w  = g.plotWpx / FONT_X;
		if(w < 1) w = 1;
	}

	// The THUMB's inclusive-exclusive cell X span = the current viewport as a fraction of
	// the whole Fit range [-RESTART_FRAMES, visFrames]. At Fit the thumb fills the track;
	// zoomed in it's a shorter run you can slide. Recomputed identically in the drawer and
	// the hit-test so they always agree.
	private void scrollThumbCells(ref Geo g, out int x0, out int x1) {
		int trackX0, trackW;
		scrollTrackCells(g, trackX0, trackW);
		double full = cast(double)contentMaxFrames - (-prerollTicks);
		if(full < 1e-6) full = 1;
		double f0 = (viewport.startTick - (-prerollTicks)) / full;
		double f1 = (viewport.endTick   - (-prerollTicks)) / full;
		if(f0 < 0) f0 = 0;
		if(f1 > 1) f1 = 1;
		x0 = trackX0 + cast(int)lround(f0 * trackW);
		x1 = trackX0 + cast(int)lround(f1 * trackW);
		if(x0 < trackX0) x0 = trackX0;
		if(x1 > trackX0 + trackW) x1 = trackX0 + trackW;
		if(x1 <= x0) x1 = x0 + 1;              // always at least one cell wide
		if(x1 > trackX0 + trackW) { x1 = trackX0 + trackW; x0 = x1 - 1; }
	}

	// Map a scrollbar cell column to a tick on the whole/Fit axis (the track spans the
	// entire Fit range across trackW cells), clamped to the note extent.
	private double scrollTickForCell(ref Geo g, int cellX) {
		int trackX0, trackW;
		scrollTrackCells(g, trackX0, trackW);
		double frac = (cellX + 0.5 - trackX0) / trackW;
		if(frac < 0) frac = 0;
		if(frac > 1) frac = 1;
		return -prerollTicks + frac * (cast(double)contentMaxFrames - (-prerollTicks));
	}

	// §17.4 Draw the scrollbar: a dim darkgray track across the whole plot width, with the
	// brighter lightgray thumb over the viewport's fraction of the Fit range. All TEXT
	// cells (full-block glyph), so it composites like the rest of the chrome.
	private void drawScrollbar(ref Geo g) {
		int trackX0, trackW;
		scrollTrackCells(g, trackX0, trackW);
		if(trackW < 2) return;
		foreach(cx; trackX0 .. trackX0 + trackW)
			screen.setChar(cx, g.scrollRow, (COL_SCROLL_TRACK << 8) | GLYPH_DOTS);
		int tx0, tx1;
		scrollThumbCells(g, tx0, tx1);
		foreach(cx; tx0 .. tx1)
			screen.setChar(cx, g.scrollRow, (COL_SCROLL_THUMB << 8) | GLYPH_BLOCK);
	}

	// ---- §17.2/§17.3 mouse: drag-select + control-button clicks ----

	// Snap an absolute pixel column to the nearest integer tick on the viewport axis,
	// clamped to the content extent [-RESTART_FRAMES, contentMaxFrames]. Integer ticks
	// ARE the native per-tick grid (1/frame at 1×, 2/frame at 2×), so this is the §17.2
	// snap. Uses contentMaxFrames (not visFrames) so a selection can extend into the
	// zoomed/scrolled-out release-tail region past the fitted note (§17.3).
	private int snapPixelToTick(ref Geo g, int cellX) {
		int px = cellX * FONT_X + FONT_X / 2;
		int t = cast(int)lround(viewport.tickForPixel(g, px));
		if(t < -prerollTicks) t = -prerollTicks;
		if(t > contentMaxFrames) t = contentMaxFrames;
		return t;
	}

	// True if screen cell (x,y) is over the plot region (the band stack) — where a drag
	// starts/marks a selection.
	private bool inPlotCell(ref Geo g, int x, int y) {
		int px = x * FONT_X, py = y * FONT_Y;
		return px >= g.plotX0px && px < g.plotX0px + g.plotWpx
			&& py >= g.stackTopPx && py < g.stackBotPx;
	}

	override void clickedAt(int x, int y, int button, int clicks = 1) {
		if(button != 1) return;
		Geo g = layout();
		// clampedIns() only reads state.activeInstrument, which nothing in this
		// handler mutates, so it is safe to read once and reuse for the whole press.
		int ins = clampedIns();
		clickWasButton = false;
		scrollDragging = false;
		// A fresh press cannot belong to a previously completed button gesture.
		pressedBtn = -1;
		pressedOver = false;
		// §22 double-click a graph band's title to maximise it for fine-tuning; double-click
		// the maximised title (or any strip title) to switch/restore. Consumes the click.
		if(clicks >= 2) {
			int tb = bandTitleAt(g, x, y);
			if(tb >= 0) { expandedBand = (expandedBand == tb) ? -1 : tb; clickWasButton = true; return; }
		}
		// The retro parameter list is also a mouse target: clicking a row selects it,
		// after which Left/Right is the same predictable edit gesture as keyboard focus.
		int paramY0 = area.y + 3;
		if(x >= g.paramX && x < g.sepX && y >= paramY0 && y < paramY0 + PARAM_ROWS) {
			paramCursor = y - paramY0;
			clickWasButton = true;
			return;
		}
		// §17.4 scrollbar row: grab the thumb to pan, or click the track to page. Hit-test
		// by ROW so a press here never starts a plot selection (and vice versa).
		if(y == g.scrollRow) {
			clickWasButton = true;   // consume the paired release (no sel change)
			int tx0, tx1;
			scrollThumbCells(g, tx0, tx1);
			if(x >= tx0 && x < tx1) {                 // on the thumb -> drag to pan
				scrollDragging = true;
				scrollGrabOffset = scrollTickForCell(g, x) - viewport.startTick;
			} else {                                  // on the track -> page one view width
				double span = viewport.endTick - viewport.startTick;
				viewport.panBy(x < tx0 ? -span : span, prerollTicks, contentMaxFrames);
			}
			return;
		}
		// §17.3 control-button row: arm the button under the press (its action fires on
		// release over the same button, so the user sees the pressed style meanwhile).
		// The whole row is consumed (never starts/clears a plot selection), like the
		// scrollbar row above.
		if(y == g.controlRow) {
			clickWasButton = true;   // consume the paired release for selection purposes
			int hit = buttonAt(g, x, y);
			if(hit >= 0) { pressedBtn = hit; pressedOver = true; }
			return;
		}
		// Exact top-cell Wave END/LOOP triangles own their cell before the trailing
		// creation target and the pitch/delay graph beneath them.
		if(waveLoopHandleAt(ins, g, x, y) >= 0) {
			beginWaveLoopDrag(ins);
			return;
		}
		// The trailing '+' owns only its exact in-band cell, before the frequency graph
		// beneath it. A disabled full-table target still consumes the click predictably.
		{
			bool enabled;
			if(waveAddTargetAt(ins, g, x, y, enabled)) {
				clickWasButton = true;
				if(enabled) appendWaveRowAtEnd(ins);
				else UI.statusline.display("Wave table full - cannot append row.");
				return;
			}
		}
		// Filter gutter controls use the same release-over-target activation as the
		// graph-row buttons, including their whitespace padding.
		string filterAction = filterActionAt(ins, g, x, y);
		if(filterAction.length) {
			clickWasButton = true;
			pressedFilterAction = filterAction;
			pressedFilterOver = true;
			return;
		}
		{
			int wr;
			if(waveGraphRowAt(g, x, y, wr)) {
				beginWaveGraphDrag(g, x, y, wr);
				return;
			}
		}
		// Empty Filter or absent/fixed Pulse: allocate immediately and keep this same
		// press/move/release gesture alive. Fixed Pulse conversion preserves its audible
		// starting width inside createSweepProgram before motion applies the final value.
		{
			int eb = emptySweepBandAt(g, x, y);
			if(eb >= 0) {
				clickWasButton = true;
				if(createSweepProgram(eb, ins, sweepValueForCell(eb, g, y))) {
					auto d = new SweepLevelDrag(eb, selectedSweepRow);
					d.moved = true; // creation already took the gesture's one snapshot
					activeGesture = d;
				}
				return;
			}
		}
		// Wave band: one click toggles the control bit for the row producing this frame.
		// This is intentionally immediate (no select-first step); shared programmes are
		// copied automatically unless the visible Linked edits mode is active.
		{
			int wf, wb;
			if(waveLaneAt(g, x, y, wf, wb)) {
				clickWasButton = true;
				// Reject an unrepresentable initial toggle before authorization/snapshot:
				// a true no-op must consume neither undo nor a release-time rerender.
				if(canBeginWaveBitPaint(ins, wf, wb))
					authorizeWaveMutation(ins,
						(int delta) { beginWaveBitPaint(ins, wf, wb); });
				return;
			}
		}
		// §19 P4a: grab an A/D/S/R handle on the ADSR curve if the press landed on one
		// (checked BEFORE the plot drag-select, since the ADSR band is inside the plot).
		// One undo snapshot per drag gesture is taken here at press.
		int ah = adsrHandleAt(g, x, y);
		if(ah >= 0) {
			activeGesture = new AdsrDrag(ah);   // snapshot + first write happen on the first drag tick
			clickWasButton = true;   // consume the paired release (no selection change)
			return;
		}
		int sb = sweepBandAt(g, x, y);
		// Shift-click extends selection before any direct manipulation at the boundary.
		if((SDL_GetModState() & KMOD_SHIFT) && sb >= 0 && selectedSweepTable == sb
				&& selectedSweepRow >= 1) {
			int row = sweepRowAtPress(sb, g, x);
			if(row >= 1) {
				clickWasButton = true;
				selectedSweepRowEnd = row;
				return;
			}
		}
		// If both neighbours are selected, the exact shared dot outranks either block's
		// individual endpoint/boundary behavior.
		if(sweepMultiSelected()) {
			int jl, jr;
			if(sweepJoinAt(ins, g, x, y, jl, jr)) {
				clickWasButton = true;
				activeGesture = new SweepJoinDrag(jl, jr);
				return;
			}
		}
		// A dot belonging to the already-selected single block wins at a shared edge.
		// Thus selecting the right block first edits only its START; selecting the left
		// block first edits only its END slope.
		if(!sweepMultiSelected() && graphDotCursorAt(g, x, y) == CURSOR_VERTICAL
				&& beginSelectedStepDrag(ins, g, x, y)) return;
		// END/LOOP grips are explicit top-strip controls and may intersect a character
		// cell whose centre is just outside sweepBandAt's band ownership. Hit-test both
		// drawn grips directly, after the higher-priority slope dot.
		foreach(loopTable; 0 .. 2) {
			int lc = sweepLoopHandleAt(loopTable, g, x, y);
			if(lc >= 0) {
				clickWasButton = true;
				activeGesture = new SweepLoopDrag(loopTable, lc);
				return;
			}
		}
		int edgeRow = sb >= 0
			? sweepDurationRowAtPress(sb, ins, g, x, y) : -1;
		int cfg = sb == 1 ? filterConfigRowAtPress(g, x) : -1;
		// At a shared Filter CONFIG/boundary X, the already-selected sweep owns its
		// complete edge; otherwise the instantaneous CONFIG marker remains selectable.
		bool selectedEdge = edgeRow >= 1 && selectedSweepTable == sb
			&& (selectedSweepRow == edgeRow || selectedSweepRowEnd == edgeRow);
		if(edgeRow >= 1 && (cfg < 1 || selectedEdge)) {
			selectedWaveRow = -1;
			selectedSweepTable = sb;
			selectedSweepRow = selectedSweepRowEnd = edgeRow;
			if(beginSelectedStepDrag(ins, g, x, y)) return;
		}
		if(cfg >= 1) {
			clickWasButton = true;
			selectedWaveRow = -1;
			selectedSweepTable = 1;
			selectedSweepRow = selectedSweepRowEnd = cfg;
			int targetRow;
			int rcfg = filterResHandleAt(g, x, y, targetRow);
			if(rcfg >= 0) {
				activeGesture = new SweepResDrag(rcfg, targetRow);
			}
			return;
		}
		if(edgeRow >= 1) {
			selectedWaveRow = -1;
			selectedSweepTable = sb;
				selectedSweepRow = selectedSweepRowEnd = edgeRow;
				if(beginSelectedStepDrag(ins, g, x, y)) return;
		}
		// §20 P4b-3 RESONANCE drag: grabbing the resonance overlay line in the Filter band
		// starts a res drag of the governing config row's b1 hi nibble. Block boundary and
		// slope-dot hits were checked first; elsewhere the resonance line precedes cutoff.
		{
			int targetRow;
			int rcfg = filterResHandleAt(g, x, y, targetRow);
			if(rcfg >= 0) {
				clickWasButton = true;   // this press never starts/clears a selection
				selectedWaveRow = -1;
				selectedSweepTable = 1;
				selectedSweepRow = selectedSweepRowEnd = targetRow >= 1 ? targetRow : rcfg;
				activeGesture = new SweepResDrag(rcfg, targetRow);   // shared check + snapshot on the first drag tick
				return;
			}
		}
		// §21 P4c(v2) SINGLE-step edits are anchored to the selected step's box handles: if
		// the press lands on one, edit it (stable focus, no swapping). Checked before
		// sweepBandAt (whose cell-top gate misses a handle in the band's top/bottom cell).
		if(!sweepMultiSelected() && beginSelectedStepDrag(ins, g, x, y)) return;
		// Otherwise, in a sweep band: grab the loop line, else directly edit the block
		// under the pointer. Its interior controls level/cutoff; selection is also updated.
		if(sb >= 0) {
			int lc = sweepLoopHandleAt(sb, g, x, y);
			if(lc >= 0) {
				clickWasButton = true;   // this press never starts/clears a selection
				activeGesture = new SweepLoopDrag(sb, lc);
				return;
			}
			int row = sweepRowAtPress(sb, g, x);
			if(row >= 0) {
				clickWasButton = true;   // this press never starts/clears a plot selection
				selectedWaveRow = -1;
				selectedSweepTable = sb; // fresh single selection (anchor == extent)
				selectedSweepRow = row;
				selectedSweepRowEnd = row;
				beginSelectedStepDrag(ins, g, x, y);
				return;
			}
		}
		// §17.2 empty plot area: clear the step selection, then begin a tick-snapped drag-
		// select (or clear it).
		clearSweepSelection();
		if(inPlotCell(g, x, y)) {
			selecting = true;
			dragMoved = false;
			dragAnchorTick = snapPixelToTick(g, x);
		} else {
			selecting = false;
			hasSelection = false;
		}
	}

	override void draggedTo(int x, int y) {
		// clampedIns() only reads state.activeInstrument, which nothing in this
		// handler mutates, so it is safe to read once and reuse for the whole call.
		int ins = clampedIns();
		if(waveLoopDragging) {
			Geo g = layout();
			updateWaveLoopDrag(g, x);
			return;
		}
		if(waveBitPainting) {
			Geo g = layout();
			updateWaveBitPaint(g, x, y);
			return;
		}
		if(waveGraphDragging) {
			Geo g = layout();
			updateWaveGraphDrag(g, x, y);
			return;
		}
		// Unified drag dispatch: on the first motion tick take the one gesture undo
		// snapshot / resolve ownership (abort ⇒ clear), then run the per-tick update.
		// Safe first: the drags are mutually exclusive, so this never shadows the
		// remaining bool-flag arms below. (§19 P4a ADSR handle drag flows through here.)
		if(activeGesture) {
			Geo g = layout();
			if(!activeGesture.moved) {
				if(!activeGesture.onFirstMotion()) { activeGesture = null; return; }
				activeGesture.moved = true;
			}
			activeGesture.update(g, x, y);
			return;
		}
		// §17.3 while a zoom button is held, keep its pressed style only while the pointer
		// stays on it — drag off and it un-presses (and the release will not fire it).
		if(pressedBtn >= 0) {
			Geo g = layout();
			pressedOver = (buttonAt(g, x, y) == pressedBtn);
			return;
		}
		if(pressedFilterAction.length) {
			Geo g = layout();
			pressedFilterOver = filterActionAt(ins, g, x, y)
				== pressedFilterAction;
			return;
		}
		// §17.4 dragging the scrollbar thumb pans the viewport (span kept, thumb follows
		// the grab point). Takes priority over plot selection; they never overlap (the
		// scrollbar drag only starts on the scroll row).
		if(scrollDragging) {
			Geo g = layout();
			double span = viewport.endTick - viewport.startTick;
			double ns = scrollTickForCell(g, x) - scrollGrabOffset;
			viewport.startTick = ns;
			viewport.endTick = ns + span;
			viewport.userZoomed = true;
			viewport.clamp(prerollTicks, contentMaxFrames);
			return;
		}
		if(!selecting) return;
		Geo g = layout();
		dragMoved = true;
		int cur = snapPixelToTick(g, x);
		int a = min(dragAnchorTick, cur), e = max(dragAnchorTick, cur);
		if(e <= a) e = a + 1;               // at least one tick wide
		selStartTick = a; selEndTick = e;
		hasSelection = true;
	}

	override void releasedAt(int x, int y) {
		// clampedIns() only reads state.activeInstrument, which nothing in this
		// handler mutates, so it is safe to read once and reuse for the whole call.
		int ins = clampedIns();
		if(waveLoopDragging) {
			waveLoopDragging = false;
			waveLoopAuthorizing = false;
			waveLoopCloseRow = -1;
			waveLoopIns = -1;
			clickWasButton = false;
			if(waveLoopMoved) retriggerIfSounding();
			waveLoopMoved = false;
			return;
		}
		if(waveBitPainting) {
			waveBitPainting = false;
			waveBitPaintIns = -1;
			waveBitLastRow = waveBitLastBit = -1;
			clickWasButton = false;
			if(waveBitChanged) retriggerIfSounding();
			waveBitChanged = false;
			return;
		}
		if(waveGraphDragging) {
			waveGraphDragging = false;
			waveGraphAuthorizing = false;
			waveGraphRow = -1;
			waveGraphScale = -1;   // release the latched band scale: the axis auto-fits again
			clickWasButton = false;
			if(waveGraphMoved) retriggerIfSounding();
			waveGraphMoved = false;
			return;
		}
		// Unified drag teardown: shared reset + re-trigger-if-moved. Safe first (drags are
		// mutually exclusive). A plain click with no motion never set `moved`, so it wrote
		// nothing and re-triggers nothing. (§19 P4a ADSR handle drag flows through here.)
		if(activeGesture) {
			activeGesture.end();
			clickWasButton = false;
			if(activeGesture.moved && activeGesture.retriggersOnMove()) retriggerIfSounding();
			activeGesture = null;
			return;
		}
		// §17.4 end any scrollbar-thumb drag.
		scrollDragging = false;
		// §17.3 a held zoom button fires only if the release lands back on it (drag off
		// then release = cancel). Clears the pressed style either way.
		if(pressedBtn >= 0) {
			Geo g = layout();
			if(buttonAt(g, x, y) == pressedBtn)
				activateZoomButton(pressedBtn);
			pressedBtn = -1;
			pressedOver = false;
			clickWasButton = false;
			return;
		}
		if(pressedFilterAction.length) {
			Geo g = layout();
			string action = pressedFilterAction;
			bool fire = filterActionAt(ins, g, x, y) == action;
			if(fire) activateFilterAction(ins, action);
			pressedFilterAction = "";
			pressedFilterOver = false;
			clickWasButton = false;
			return;
		}
		// A press on a control button / the scrollbar consumes its paired release.
		if(clickWasButton) { clickWasButton = false; return; }
		if(!selecting) return;
		selecting = false;
		// §17.2 a plain click (no drag motion) clears the selection.
		if(!dragMoved) { hasSelection = false; return; }
	}

	override int keypress(Keyinfo key) {
		int ins = clampedIns();
		bool ctrl = (key.mods & KMOD_CTRL) != 0;
		bool alt = (key.mods & KMOD_ALT) != 0;
		bool shift = (key.mods & KMOD_SHIFT) != 0;
		bool gui = (key.mods & KMOD_GUI) != 0;
		bool mode = (key.mods & KMOD_MODE) != 0;
		bool exact(bool c, bool a, bool s) {
			return ctrl == c && alt == a && shift == s
				&& !gui && !mode && !key.fromGui;
		}
		Geo kg = layout();
		auto kb = zoomButtons(kg);
		void buttonKey(int id) {
			if(id >= 0 && id < 18 && kb[id].enabled) activateZoomButton(id);
		}
		// R66-R68: portable primary chords. Exact modifiers prevent AltGr and
		// GUI/Super compatibility translations from becoming Sound commands.
		if(exact(true, false, true) && key.raw == SDLK_o) { buttonKey(BTN_ZOOMOUT); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_i) { buttonKey(BTN_ZOOMIN); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_a) { buttonKey(BTN_FIT); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_g) { buttonKey(BTN_SEL); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_j) { buttonKey(BTN_ADD); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_d) { buttonKey(BTN_DEL); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_s) { buttonKey(BTN_STOP); return OK; }
		if(exact(true, false, false) && key.raw == SDLK_t) { buttonKey(BTN_TYPE); return OK; }
		if(exact(true, false, false) && key.raw == SDLK_i) { buttonKey(BTN_CARRY); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_n) { buttonKey(BTN_NEW); return OK; }
		if(exact(false, false, true) && key.raw == SDLK_PAGEUP) { buttonKey(BTN_WPREV); return OK; }
		if(exact(false, false, true) && key.raw == SDLK_PAGEDOWN) { buttonKey(BTN_WNEXT); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_1) { buttonKey(BTN_W1); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_2) { buttonKey(BTN_W2); return OK; }
		if(exact(true, false, false) && key.raw == SDLK_l) { buttonKey(BTN_WLOOP); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_3) { buttonKey(BTN_RESDEC); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_4) { buttonKey(BTN_RESINC); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_e) { buttonKey(BTN_LINKED); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_l) { toggleFilterModeBit(ins, 0x10); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_b) { toggleFilterModeBit(ins, 0x20); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_h) { toggleFilterModeBit(ins, 0x40); return OK; }
		if(exact(true, false, true) && key.raw == SDLK_r) { cycleFilterRoute(ins); return OK; }

		// Selected Pulse/Filter raw edits: start, end and duration.
		if(exact(true, false, true) && key.raw >= SDLK_0 && key.raw <= SDLK_9) {
			switch(key.raw) {
				case SDLK_5: editSelectedSweepKeyboard(0, -1); return OK;
				case SDLK_6: editSelectedSweepKeyboard(0, +1); return OK;
				case SDLK_7: editSelectedSweepKeyboard(1, -1); return OK;
				case SDLK_8: editSelectedSweepKeyboard(1, +1); return OK;
				case SDLK_9: editSelectedSweepKeyboard(2, -1); return OK;
				case SDLK_0: editSelectedSweepKeyboard(2, +1); return OK;
				default: break;
			}
		}
		if(exact(true, false, true) && key.raw == SDLK_PAGEDOWN) {
			if(state.octave > 0) state.octave--;
			return OK;
		}
		if(exact(true, false, true) && key.raw == SDLK_PAGEUP) {
			if(state.octave < 6) state.octave++;
			return OK;
		}
		void changeInstrument(int delta) {
			UI.activateInstrument(state.activeInstrument + delta);
			clearSweepSelection();
			selectedWaveRow = -1;
			linkedEditKind = linkedEditStart = -1;
		}
		if(exact(true, false, false) && key.raw == SDLK_PAGEUP) {
			changeInstrument(-1); return OK;
		}
		if(exact(true, false, false) && key.raw == SDLK_PAGEDOWN) {
			changeInstrument(+1); return OK;
		}

		// A physical GUI/Super chord is never a Sound command, even if the legacy
		// platform translator produced a key that resembles one.
		if(key.fromGui || gui || mode) return OK;
		switch(key.raw) {
		// Move the parameter cursor.
		case SDLK_UP:
			if(exact(false, false, false) && paramCursor > 0) paramCursor--;
			return OK;
		case SDLK_DOWN:
			if(exact(false, false, false) && paramCursor < PARAM_ROWS - 1) paramCursor++;
			return OK;
		// §19 P4a Left/Right EDIT the selected value (decrement/increment); on the
		// pointer rows (nothing editable) or with Shift held they PAN the viewport
		// instead (view control moved off bare Left/Right). Letters/digits stay keyjam.
		case SDLK_LEFT:
			if(exact(false, false, false) && isEditableRow(paramCursor)) editSelected(ins, -1);
			else if(exact(false, false, true))
				viewport.panBy(-(viewport.endTick - viewport.startTick) / 4.0,
					prerollTicks, contentMaxFrames);
			return OK;
		case SDLK_RIGHT:
			if(exact(false, false, false) && isEditableRow(paramCursor)) editSelected(ins, +1);
			else if(exact(false, false, true))
				viewport.panBy((viewport.endTick - viewport.startTick) / 4.0,
					prerollTicks, contentMaxFrames);
			return OK;
		case SDLK_HOME:
			if(exact(false, false, false)) { viewport.userZoomed = false; viewport.fit(prerollTicks, visFrames); }
			return OK;
		case SDLK_END:
			if(exact(false, false, false)) zoomToSelection();
			return OK;
		case SDLK_BACKSPACE:
			if(exact(false, false, false)) hasSelection = false;
			return OK;
		// §20 P4b-2 add / delete a sweep step (row-op) on the selected Pulse/Filter step.
		case SDLK_INSERT:
			if(exact(false, false, false)) {
				if(selectedSweepTable >= 0) sweepRowOp(selectedSweepTable, true);
				else if(selectedWaveNormal(ins)) waveRowOp(true);
				else UI.statusline.display("Select a pulse/filter/wave step first.");
			}
			return OK;
		case SDLK_DELETE:
			if(exact(false, false, false)) {
				if(selectedSweepTable >= 0) sweepRowOp(selectedSweepTable, false);
				else if(selectedWaveNormal(ins)) waveRowOp(false);
				else UI.statusline.display("Select a pulse/filter/wave step first.");
			}
			return OK;
		// Octave nudges (mirrors the classic keypad octave keys).
		case SDLK_KP_DIVIDE:
			if(exact(false, false, false) && state.octave > 0) state.octave--;
			return OK;
		case SDLK_KP_MULTIPLY:
			if(exact(false, false, false) && state.octave < 6) state.octave++;
			return OK;
		// Switch the instrument under view inline (shared activateInstrument keeps
		// the classic screen in sync when we leave).
		case SDLK_KP_PLUS:
			if(exact(false, false, false)) changeInstrument(+1);
			return OK;
		case SDLK_KP_MINUS:
			if(exact(false, false, false)) changeInstrument(-1);
			return OK;
		default:
			break;
		}
		// Modified non-command chords are inert in Sound Editor. Shift-only note keys
		// remain available to the existing piano layout.
		if(ctrl || alt) return OK;
		// Everything else is a note key for the screen's own keyjam.
		inputKeyjam.keypress(key);
		return OK;
	}

	override int keyrelease(Keyinfo key) {
		inputKeyjam.keyrelease(key);
		return OK;
	}
}
