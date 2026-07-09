/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Visual Sound Editor screen: a live, keyjam-driven view of the selected instrument laid out as a left parameter column, a stack of time-aligned graph bands sharing one zoomable/pannable tick-based X axis (pixel-perfect output waveform, ADSR envelope, a frequency/arp pitch band, pulse, a filter band coloured per frame by filter type with a resonance-over-time overlay, and a stacked SID control-bit-lane wave view) with a restart pre-roll, a note-trigger divider, a single vertical playhead, a tick-snapped drag selection, a subtle zoom-control row, a raw-hex table strip along the bottom, and a context F12 help page.

This is the full-screen alternative sound-editing mode toggled from the classic
editor (Ctrl-E). It runs keyjam (notes play) but uses the *normal* background,
not the dark-blue keyjam tint. The layout (design doc §7, §9 v4) stacks every
time-varying graph on ONE shared horizontal axis = frames since note-on
(~19.95 ms PAL ticks). The X span AUTO-FITS the note's full duration (§12):
visFrames is computed once per draw as the max of the ADSR-derived length (SID ms
tables) and the actual recorded extent, so short sounds zoom in and long releases
zoom out to fit; every band maps frame->pixel through the single xForFrame(): a pixel-perfect
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
import std.string : format, stripRight;
import std.algorithm : max, min;
import std.math : lround, log2, floor, ceil, abs;
import derelict.sdl2.sdl;
import com.fb : FONT_X, FONT_Y, keyjamBackground;
import com.session : screen, video, state, song, mainui, insertUndo, UndoValue, Undoable;
import com.shortcuts : Ctx;
import com.palette : idx, Role, BaseColor;
import ct.base : Song;
static import ct.purge;
import ui.window;
import ui.input;
import ui.button : Button;
import ui.dialogs : ConfirmationDialog;
import ui.ui : UI;
import ui.menubar : MenuBar;
import ui.palette : CommandPalette;
import ui.help;
static import audio.player;
static import audio.audio;
static import audio.visualizer;

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
// §19: exponential envelope level for the ADSR ESTIMATE curve, mirroring the
// recording's exponential decay/release shape (audio.visualizer). frac 0->1 maps a
// segment's progress to a level 1->0 with the same e^-5 curvature the recorder uses,
// so the estimate curve, the hover Env% helper, and the recording all agree in shape.
private float expEnvLevel(float frac) nothrow {
	import std.math : exp;
	if(frac <= 0.0f) return 1.0f;
	if(frac >= 1.0f) return 0.0f;
	immutable float e = exp(-5.0f);
	return (exp(-5.0f * frac) - e) / (1.0f - e);
}
// §12.1: the post-trigger X span is no longer a fixed constant -- it AUTO-FITS the
// note's full duration each frame (see SoundEditor.computeVisFrames). These are the
// sane clamp bounds: a floor so a tiny sound isn't absurdly zoomed in, and a ceiling
// so a pathological length still renders (long sounds get <1px/frame = zoomed out).
private enum int MIN_VIS = 24;
private enum int MAX_VIS = 1600;
// §12.1: envelope-amplitude threshold for "the note is still audible" when reading
// the recorded extent (below this counts as silence / note ended).
private enum float AMP_EPS = 0.02f;
// §9.2: pre-roll region reserved at the LEFT of the shared axis for the hard/soft
// restart phase that runs in the frames BEFORE the note triggers (frames
// -RESTART_FRAMES .. 0). Frame 0 = the note-trigger divider. Every band maps
// frame->pixel through xForFrame(), which folds this offset in, so a single
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
	private enum int COL_PULSE_FILL = BaseColor.blue;
	private enum int COL_PULSE_LINE = BaseColor.lightblue;
	private enum int COL_FILT_LINE  = BaseColor.lightred;
	private enum int COL_TRIGGER  = BaseColor.red;
	private enum int COL_ESTIMATE = BaseColor.white;   // §19 white-dotted ADSR estimate
	private enum int COL_STEPSEL  = BaseColor.white;   // §20 P4b-2 selected-step outline
	private enum int COL_RESTART  = BaseColor.cyan;
	private enum int COL_RSTFILL  = BaseColor.brown;
	private enum int COL_RSTCURVE = BaseColor.lightred;
	private enum int COL_RES      = BaseColor.yellow;
	private enum int COL_FREQ_REL = BaseColor.lightgreen;
	private enum int COL_FREQ_ABS = BaseColor.cyan;
	private enum int GLYPH_BLOCK  = 197;
	private enum int GLYPH_DOTS   = 6 * 32 + 16;   // font glyph 208 — sparse dots (scroll track)

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
		ROW_RESTART = 8, ROW_GATE = 9, ROW_HRWAVE = 10, ROW_HRSR = 11;
	private enum int PARAM_ROWS = 12;
	private int paramCursor;

	// §19 P4a ADSR-curve drag: which handle (ADSR_*) the user grabbed on the ADSR band,
	// and whether a handle drag is in progress. One insertUndo is taken at press
	// (clickedAt), the byte(s) are rewritten each draggedTo tick (curve + column redraw
	// from the bytes automatically), and the held note is re-triggered once at release.
	private enum int ADSR_ATTACK = 0, ADSR_DECAY = 1, ADSR_SUSTAIN = 2, ADSR_RELEASE = 3;
	private enum int ADSR_HIT_PX = 9;      // handle grab radius (device pixels; ~one cell)
	private bool adsrDragging = false;
	private int  adsrHandle = -1;
	private bool adsrMoved = false;    // a byte was actually written this gesture

	// §20 P4b-1 pulse/filter program LEVEL drag: a vertical grab inside the Pulse
	// (band 3) or Filter (band 4) plot region rewrites the SweepTable row active at
	// the grabbed frame — its init byte b2 (pulse width 0..4095 nibble-swapped, or
	// filter cutoff 0..2047 >> 3) — so the sweep starts at the dragged level. sweepTable
	// 0 = pulse, 1 = filter; sweepRow = the SweepTable row being edited (from the sim's
	// rowOf[frame]); sweepMoved gates the ONE undo snapshot per gesture (first drag tick).
	private bool sweepDragging = false;
	private int  sweepTable = -1;
	private int  sweepRow = -1;
	private bool sweepMoved = false;
	// §20.2 shared-program decision memory (per session): [table][programStartRow] ->
	// true means the user chose "edit shared in place" for that program, so we don't
	// re-prompt. A fork changes the pointer (private rows), so a forked program is no
	// longer shared and never prompts again either.
	private bool[int][2] sweepEditShared;

	// §20 P4b-2 SELECTED STEP: a plain CLICK (press+release, no motion) inside the Pulse
	// (0) or Filter (1) band selects the SweepTable row active at that frame; a bright
	// outline is drawn on that step's frame span. Ins/Del then insert/delete a row via the
	// ct.purge row-ops. selectedSweepTable = -1 means no step selected; selecting in one
	// band clears the other; switching instrument clears it (the row index is table-local).
	private int selectedSweepTable = -1;
	private int selectedSweepRow = -1;
	// §20 P4b-2 LOOP-MARKER drag: grabbing the subtle loop line (or, for a stopping
	// program, its end marker) drags the program's loop-BACK point. sweepLoopCloseRow =
	// the row whose b3 jump we rewrite (the loop-closing / terminal row); dragging sets it
	// to the SweepTable row active at the dragged frame (converting a $7f stop into a loop
	// if needed). sweepLoopMoved gates the ONE undo snapshot per gesture (first drag tick).
	private bool sweepLoopDragging = false;
	private int  sweepLoopTable = -1;
	private int  sweepLoopCloseRow = -1;
	private bool sweepLoopMoved = false;

	// §20 P4b-3 filter RESONANCE drag: a vertical grab on the resonance overlay line in
	// the Filter band (band 4) rewrites the b1 HIGH nibble (res 0..15, low nibble =
	// routing preserved) of the CONFIG row governing the grabbed frame. Distinct from the
	// P4b-1 cutoff-level drag (hit-tested BEFORE it). sweepResRow = the config row whose
	// b1 we edit; sweepResMoved gates the ONE undo snapshot per gesture (first drag tick).
	private bool sweepResDragging = false;
	private int  sweepResRow = -1;
	private bool sweepResMoved = false;
	// §20 P4b-3 the filter mode chip cycles through the LP/BP/HP combos (§10.1) writing the
	// first config row's b0 mode bits (0x70). This is the requested cycle order.
	private static immutable int[7] FILTER_MODE_CYCLE =
		[0x10, 0x20, 0x40, 0x30, 0x60, 0x50, 0x70];   // LP BP HP LP+BP BP+HP LP+HP all

	// §11.2 the voice whose real recording feeds the bands this frame (-1 = none),
	// and whether that voice actually has a recording (else the bands fall back to
	// the dimmed table simulation). Recomputed at the top of update().
	private int viewVoice = -1;
	private bool useRec = false;

	// §14.1 mouse-hover probe: the last cell the pointer hovered (screen char-cells),
	// and whether we have a hover position to consider. update() maps it to a frame
	// on the fresh geometry, draws a white vertical probe line + a numeric readout of
	// the register values at that frame, and skips the probe when the cursor is
	// outside the plot region (so leaving the plot clears it).
	private int hoverCellX = -1, hoverCellY = -1;
	private bool hovering = false;

	// §12 dynamic X window, computed ONCE per draw at the top of update() and threaded
	// through xForFrame + every band so they all share the exact same zoom. visFrames
	// = the auto-fitted post-trigger span (frames); totalFrames = pre-roll + visFrames.
	private int visFrames = MIN_VIS;
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

	// §17.1 zoomable/pannable VIEWPORT over the shared tick axis. The axis maps
	// [viewStartTick, viewEndTick] (a sub-window of the whole note) across plotWpx
	// instead of always the whole note, so zoom = narrow the window, pan = slide it,
	// and every band/playhead/marker/loop-line/probe follows for free (they all go
	// through xForFrame / tickForPixel). Default = FIT = the whole note incl. the
	// restart pre-roll ([-RESTART_FRAMES, visFrames]); userZoomed keeps a user's zoom
	// across instrument/recording changes until they hit Fit. Ticks are floats so
	// repeated ×2/×0.5 zoom steps + panning stay smooth; the axis clamps to
	// [-RESTART_FRAMES, visFrames] with a MIN_VIEW_SPAN floor.
	private double viewStartTick = -RESTART_FRAMES;
	private double viewEndTick = MIN_VIS;
	private bool userZoomed = false;
	// Integer visible-frame bounds derived from the viewport each draw, so band loops
	// only emit the frames actually on screen (no off-view pile-up at the clamped
	// plot edges). viewFrameLo = floor(viewStart), viewFrameHi = ceil(viewEnd)+1.
	private int viewFrameLo = 0, viewFrameHi = MIN_VIS;

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

	// §17.4 horizontal-scrollbar drag state. A left-press ON the scrollbar row grabs
	// the thumb; while dragging, the viewport start follows the pointer so the thumb
	// stays under the grab point (span kept constant, clamped). scrollGrabOffset = the
	// tick (on the FULL/Fit axis) under the initial press minus viewStartTick, so the
	// grab point on the thumb is preserved across the drag.
	private bool scrollDragging = false;
	private double scrollGrabOffset = 0;

	// The screen owns its own keyjam so note keys play while the panel is
	// focused and navigating (the classic editor's global inputKeyjam is
	// bypassed for this window by the Toplevel routing guard).
	private InputKeyjam inputKeyjam;

	this(Rectangle a) {
		super(a);
		inputKeyjam = new InputKeyjam();
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

	private Geo layout() {
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

		// Six bands (§10.3): output, adsr, frequency, pulse, filter, wave. The wave
		// band stacks 8 SID control-bit lanes, ONE per character row, so its gutter
		// labels line up with the lane blocks — give it a FIXED height of WAVE_ROWS
		// character rows at the bottom of the stack (a weight that merely rounds to
		// ~8 rows is fragile), and share the remaining span among bands 0..4 by weight.
		enum int WAVE_ROWS = 9;   // 8 lanes + 1 row of slack for the bandBox inset
		int waveTopPx = g.stackBotPx - WAVE_ROWS * FONT_Y;
		immutable float[5] wgt = [1.0f, 1.0f, 0.9f, 0.9f, 0.9f];
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
		int vf = aF + dF + nominalGateFrames + rF;

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

		if(vf < MIN_VIS) vf = MIN_VIS;
		if(vf > MAX_VIS) vf = MAX_VIS;
		return vf;
	}

	// §9.1/§12.2/§17.1 THE one true tick->pixel map every band shares, now over the
	// zoomable/pannable VIEWPORT [viewStartTick, viewEndTick] (a sub-window of the whole
	// note; dynamic ticks-per-pixel = zoom). Frame/tick f may be negative (pre-roll /
	// restart); f=0 is the note-trigger divider. The returned pixel is CLAMPED to the
	// plot box so a partially-off-view edge frame lands exactly at the plot edge; band
	// loops additionally skip fully-off-view frames (see visRange) so nothing piles up.
	private int xForFrame(ref Geo g, double f) {
		double span = viewEndTick - viewStartTick;
		if(span < 1e-6) span = 1e-6;
		double p = (f - viewStartTick) / span;   // 0..1 across the plot width
		if(p < 0) p = 0;
		if(p > 1) p = 1;
		return g.plotX0px + cast(int)lround(p * g.plotWpx);
	}

	// §17.1 inverse of xForFrame: the (fractional) tick at absolute pixel column px.
	private double tickForPixel(ref Geo g, int px) {
		double span = viewEndTick - viewStartTick;
		return viewStartTick + cast(double)(px - g.plotX0px) * span / g.plotWpx;
	}

	// §17.1 True when tick/frame f falls within the current viewport (so a single
	// vertical marker at f should be drawn; off-view markers are skipped rather than
	// clamped to a plot edge, which would misplace them).
	private bool frameInView(double f) {
		return f >= viewStartTick - 1e-6 && f <= viewEndTick + 1e-6;
	}

	// §17.1 Visible integer-frame range for a band loop of length n: only the frames
	// whose cell intersects the viewport (plus a one-frame margin each side so a
	// partially-visible edge cell still draws). Clamped to [0, n).
	private void visRange(int n, out int lo, out int hi) {
		lo = viewFrameLo; hi = viewFrameHi;
		if(lo < 0) lo = 0;
		if(hi > n) hi = n;
		if(hi < lo) hi = lo;
	}

	// §17.1 Reset the viewport to FIT (the whole note incl. the restart pre-roll) — the
	// v12 default, and what [Fit]/Home restore. Recomputed whenever !userZoomed so the
	// axis keeps auto-fitting as the instrument/recording changes.
	private void fitViewport() {
		viewStartTick = -prerollTicks;
		viewEndTick = visFrames;
	}

	// §17.1 Clamp the (user) viewport within [-RESTART_FRAMES, visFrames] and enforce
	// the MIN_VIEW_SPAN floor, keeping the view centre where possible.
	private void clampViewport() {
		double lo = -prerollTicks;
		double hi = visFrames;
		double full = hi - lo;
		if(full <= MIN_VIEW_SPAN) { viewStartTick = lo; viewEndTick = hi; return; }
		double span = viewEndTick - viewStartTick;
		if(span < MIN_VIEW_SPAN) span = MIN_VIEW_SPAN;
		if(span > full) span = full;
		double centre = (viewStartTick + viewEndTick) / 2.0;
		viewStartTick = centre - span / 2.0;
		viewEndTick = centre + span / 2.0;
		if(viewStartTick < lo) { viewEndTick += lo - viewStartTick; viewStartTick = lo; }
		if(viewEndTick > hi)   { viewStartTick -= viewEndTick - hi; viewEndTick = hi; }
		if(viewStartTick < lo) viewStartTick = lo;
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
	// pixels, so it is safe to draw as the sole backdrop under chromeActive() (behind a
	// dialog/menu/palette). On the normal path the graph bands + axis lines + playhead
	// are layered on top afterwards.
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

		// Octave kept in the row below (nothing else there now).
		screen.cprint(area.x + 2, area.y + 1, COL_LABEL, 0, "Octave");
		screen.cprint(area.x + 9, area.y + 1, COL_VALUE, 0, format("%d", state.octave));

		// §12.2/§16.2 unobtrusive scale label so the current zoom is legible. Seconds
		// use the REAL tick duration, so the same note reads the SAME seconds at any
		// multiplier (visFrames doubles at mult=2, tickMs halves -> product constant).
		float secs = visFrames * tickMs / 1000.0f;
		screen.cprint(g.labelX, area.y + 2, COL_LABEL, 0,
					  format("scale 0-%d f (~%.1fs)", visFrames, secs));

		// Vertical separator between the param column and the graph stack.
		for(int y = area.y + 2; y <= g.rawTopRow - 1; y++)
			screen.setChar(g.sepX, y, 0x0500 | 216);

		drawParamColumn(ins, g);

		// Band TEXT labels (the pixel axis lines are drawn with the bands themselves).
		drawBandLabelText(g, 0, "Output");
		drawBandLabelText(g, 1, "ADSR");
		drawBandLabelText(g, 2, "Freq");
		drawBandLabelText(g, 3, "Pulse");
		drawBandLabelText(g, 4, "Filter");
		// band 5 (wave) is self-labelled by its 8 bit-lane gutter labels.

		drawRawData(ins, g);
	}

	override void update() {
		// v2: keep note routing but never the blue keyjam tint on this screen.
		keyjamBackground = false;
		// We drive our own overlay each frame; make sure no stale single-slot scope
		// trace lingers underneath the bands.
		video.clearScopeTrace();

		int ins = clampedIns();

		// §16.2 refresh the real-time axis unit from the live multiplier BEFORE any
		// ms<->tick conversion (computeVisFrames, ADSR sim, scale label, probe) so
		// they all share one axis at the current multiplier.
		int mult = audio.audio.multiplier;
		if(mult < 1) mult = 1;
		tickMs = SCREEN_FRAME_MS / mult;
		// estimate sustain hold, in axis units = 50 "frames" as shown on the scale
		nominalGateFrames = 50;

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
		visFrames = computeVisFrames(ins);
		prerollTicks = restartFramesFor(ins);   // thin restart strip -> graphs start at the left edge
		totalFrames = prerollTicks + visFrames;

		// §17.1 refresh the viewport over the (possibly changed) note extent: keep the
		// user's zoom until they hit Fit, else auto-fit to the whole note. Then derive
		// the integer visible-frame bounds every band loop clips to.
		if(userZoomed) clampViewport();
		else fitViewport();
		viewFrameLo = cast(int)floor(viewStartTick);
		viewFrameHi = cast(int)ceil(viewEndTick) + 1;

		// v3 (§8.1) / §13.1(b): higher-Z chrome (a modal dialog/pop-up, an open menu
		// dropdown, or the command palette) must render UNOBSTRUCTED. The com.fb overlay
		// is a post-composite PIXEL layer drawn on top of ALL text cells, so any graph
		// pixels would bleed over that chrome. Yield the pixel layer (olClear + no ol*
		// this frame) BUT still repaint the full TEXT chrome so the Sound Editor — never
		// the classic tables or stale content — is the backdrop behind the dialog/menu.
		// The chrome (drawMenu / dialog.update, both text) is drawn after us and shows
		// cleanly over our text cells, exactly like the classic editor.
		if(chromeActive()) {
			video.olClear();
			drawTextChrome(ins, g);
			return;
		}

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
		drawBandAxis(g, 0);
		drawOutputBand(g);
		drawBandAxis(g, 1);
		drawAdsrBand(ins, g);
		drawBandAxis(g, 2);
		drawFreqBand(ins, g);
		drawBandAxis(g, 3);
		drawPulseBand(ins, g);
		drawBandAxis(g, 4);
		drawFilterBand(ins, g);
		drawBandAxis(g, 5);
		drawWaveBand(ins, g);

		// §20 P4b-2 bright outline on the selected pulse/filter step (Ins/Del target).
		drawSweepSelection(ins, g);

		// §13.4 restart marker: a vertical line at the START of the restart phase
		// (frame -restartFrames, the actual hard/soft/3-frame restart length for this
		// instrument's col2 type), in a colour DISTINCT from the red trigger divider
		// (frame 0) and the white playhead — so the short trigger<->restart interval
		// is visible. Drawn before the trigger so the (brighter) trigger wins on any
		// pixel overlap at extreme zoom.
		int restF = restartFramesFor(ins);
		if(frameInView(-restF))
			video.olVLine(xForFrame(g, -restF), g.stackTopPx, g.stackBotPx, COL_RESTART);

		// §9.2 note-trigger divider at frame 0 across ALL bands: everything left of it
		// is the restart pre-roll, everything right of it is the same frame index in
		// every band. (Skipped when frame 0 is panned out of the viewport.)
		if(frameInView(0))
			video.olVLine(xForFrame(g, 0), g.stackTopPx, g.stackBotPx, COL_TRIGGER);

		// §17.2 selection edges on top of the bands (bright, distinct from the wash).
		drawSelectionEdges(g);

		// §11.2 one full-height playhead = the recording's current record head. It
		// advances right as the recording grows during a live note and freezes at the
		// end once the note has finished. Only shown when a recording is driving the
		// bands (the idle sim preview has no record head).
		if(useRec) {
			int rh = audio.visualizer.getRecordingLength(viewVoice);
			if(rh > visFrames) rh = visFrames;
			if(frameInView(rh))
				video.olVLine(xForFrame(g, rh), g.stackTopPx, g.stackBotPx, COL_HEAD);
		}

		// §19 P4a draggable A/D/S/R handles on the ADSR curve (drawn on top of the band
		// so the grab targets are visible; the grabbed one lights up while dragging).
		drawAdsrHandles(ins, g);

		// §17.3 subtle zoom-control button row + the current selection readout.
		drawZoomControls(g);

		// §17.4 horizontal scrollbar (row just below the control row): track = the whole
		// Fit range, thumb = the current viewport. Text cells, so it composites with the
		// rest of the chrome (drawTextChrome already wiped this row this frame).
		drawScrollbar(g);

		// §14.1 mouse-hover probe + numeric readout (only while the cursor is over the
		// plot region). Drawn last so the dashed white probe line sits on top.
		drawProbe(ins, g);
	}

	// True while any higher-Z chrome is up (§8.1): a modal dialog/pop-up, an open
	// menu dropdown, or the command palette. Used to yield the pixel overlay so the
	// chrome renders unobstructed. All three are read-only queries.
	private bool chromeActive() {
		if(mainui is null) return false;
		if(mainui.dialogActive) return true;
		if(mainui.menubar !is null && mainui.menubar.active) return true;
		if(mainui.palette !is null && mainui.palette.active) return true;
		return false;
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
	private void drawLoopLines(ref Geo g, int topPx, int botPx, int loopFrame, int period, int n) {
		// A period < 2 is a single-row "hold" (waveform sustained), not a repeating
		// section worth marking — skip it so it doesn't draw a line every frame.
		if(loopFrame < 0 || period < 2) return;
		int lastX = -1_000_000;
		for(int f = loopFrame; f < n && f < visFrames; f += period) {
			if(!frameInView(f)) continue;                          // §17.1 skip off-view
			int x = xForFrame(g, f);
			if(lastX > -1_000_000 && x - lastX < MIN_LOOP_PX) continue; // stay subtle, no comb
			video.olVLine(x, topPx, botPx, COL_LOOPLINE);
			lastX = x;
		}
	}

	// A per-frame value staircase (pulse width or filter cutoff) as an area fill +
	// top line on the shared frame axis. Fed from either the recording or the sim.
	private void drawValueBand(const(int)[] vals, int maxVal, int fillCol, int lineCol,
			int topPx, int botPx, ref Geo g) {
		int hh = botPx - topPx;
		if(hh <= 0 || maxVal <= 0) return;
		int n = min(cast(int)vals.length, visFrames);
		int lo, hi; visRange(n, lo, hi);       // §17.1 only emit on-screen frames
		foreach(f; lo .. hi) {
			int v = vals[f];
			if(v < 0) v = 0; if(v > maxVal) v = maxVal;
			int y = botPx - v * hh / maxVal;
			int xa = xForFrame(g, f);
			int xb = xForFrame(g, f + 1);
			if(xb <= xa) xb = xa + 1;
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
			"Pulse ptr", "Filter ptr", "Restart", "Arpeggio speed", "HR wave", "HR SR"
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

		// §19 P4a on-screen key hint (one row below the param block, above the probe box).
		int hintY = y0 + PARAM_ROWS;
		screen.cprint(g.paramX, hintY, COL_LABEL, 0, "L/R edit  Shift+L/R pan");
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
				 ROW_RESTART, ROW_GATE, ROW_HRWAVE, ROW_HRSR:
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
			default: break;
		}
	}

	// One keyboard edit gesture: snapshot for undo, mutate, then make it audible.
	private void editSelected(int ins, int delta) {
		if(!isEditableRow(paramCursor)) return;
		snapshotInstruments();
		applyRowDelta(ins, paramCursor, delta);
		retriggerIfSounding();
	}

	// §19.5 P4a immediate audibility: if a keyjam note is currently held on this screen,
	// re-trigger it so the just-edited envelope is heard at once (AD/SR only take effect
	// on the NEXT trigger). Never called per drag tick — only on keypress / drag release.
	private void retriggerIfSounding() {
		if(inputKeyjam.noteHeld())
			inputKeyjam.retrigger();
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
		float gateEnd = aF + dF + nominalGateFrames;
		float sustMid = (aF + dF + gateEnd) / 2.0f;    // middle of the sustain plateau
		float[4] hf   = [aF, aF + dF, sustMid, gateEnd + rF];
		float[4] hlvl = [1.0f, sLvl, sLvl, 0.0f];
		foreach(i; 0 .. 4) {
			hx[i] = xForFrame(g, hf[i]);
			hy[i] = botPx - cast(int)lround(clamp01(hlvl[i]) * h);
			inView[i] = frameInView(hf[i]);
		}
	}

	// Draw a small square marker at each in-view A/D/S/R handle (the grabbed one lights
	// up red while dragging). Read-only sizing; positions come straight from the bytes.
	private void drawAdsrHandles(int ins, ref Geo g) {
		int[4] hx, hy; bool[4] inView;
		adsrHandlePositions(ins, g, hx, hy, inView);
		foreach(i; 0 .. 4) {
			if(!inView[i]) continue;
			int c = (adsrDragging && adsrHandle == i) ? COL_TRIGGER : COL_HEAD;
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
	private void adsrDragUpdate(ref Geo g, int cellx, int celly) {
		int ins = clampedIns();
		int px = cellx * FONT_X + FONT_X / 2;
		int py = celly * FONT_Y + FONT_Y / 2;
		double t = tickForPixel(g, px);
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		int attack = (ad >> 4) & 0x0f, decay = ad & 0x0f;
		float aF = ATTACK_TIME_MS[attack]       / tickMs;
		float dF = DECAY_RELEASE_TIME_MS[decay] / tickMs;
		switch(adsrHandle) {
			case ADSR_ATTACK: {
				double ms = t * tickMs; if(ms < 0) ms = 0;
				setNibbleAbs(ins, 0, true, nearestMs(ATTACK_TIME_MS, ms));
				break;
			}
			case ADSR_DECAY: {
				double ms = (t - aF) * tickMs; if(ms < 0) ms = 0;
				setNibbleAbs(ins, 0, false, nearestMs(DECAY_RELEASE_TIME_MS, ms));
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
				double ms = (t - (aF + dF + nominalGateFrames)) * tickMs; if(ms < 0) ms = 0;
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
		int px = x * FONT_X, py = y * FONT_Y;
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx) return -1;
		int ins = clampedIns();
		if(py >= g.bandTopPx[3] && py < g.bandTopPx[4]) {
			int ptr = song.instrumentTable[ins + 5 * 48];
			if(ptr >= 1 && ptr <= 0x3f) return 0;    // pulse program (not fixed $80+/off)
		}
		if(py >= g.bandTopPx[4] && py < g.bandTopPx[5]) {
			int ptr = song.instrumentTable[ins + 4 * 48];
			if(ptr >= 1 && ptr <= 0x3f) return 1;    // filter program (not off)
		}
		return -1;
	}

	// The SweepTable row producing the frame under the press x (via the sim's per-frame
	// rowOf), or -1 if the program is empty. This is the row whose init b2 the drag edits.
	private int sweepRowAtPress(int table, ref Geo g, int x) {
		int px = x * FONT_X + FONT_X / 2;
		int f = cast(int)lround(tickForPixel(g, px));
		if(f < 0) f = 0;
		int ins = clampedIns();
		SweepSim s = (table == 0)
			? simPulse(song.instrumentTable[ins + 5 * 48])
			: simFilter(song.instrumentTable[ins + 4 * 48]);
		if(s.rowOf.length == 0) return -1;
		if(f >= cast(int)s.rowOf.length) f = cast(int)s.rowOf.length - 1;
		return s.rowOf[f];
	}

	// The set of SweepTable rows reachable from startRow via the b3 jump chain (the
	// program). Empty for a fixed/off pointer (<=0 or >=0x40). Same traversal simPulse/
	// simFilter use, so it matches exactly what plays.
	private bool[0x40] sweepProgramRows(int table, int startRow) {
		bool[0x40] rows;
		if(startRow <= 0 || startRow >= 0x40) return rows;
		const(ubyte)[] t = (table == 0) ? song.pulseTable : song.filterTable;
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
		int col = (table == 0) ? 5 : 4;
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

	// Whether the user already chose "edit shared in place" for this instrument's
	// current program this session (keyed by the program start row = pointer byte).
	private bool sweepDecided(int table, int ins) {
		int col = (table == 0) ? 5 : 4;
		int ptr = song.instrumentTable[ins + col * 48];
		return (ptr in sweepEditShared[table]) !is null;
	}

	// §20.2 fork: allocate a private copy of this instrument's program at seekTableEnd,
	// copy its rows, relocate their internal b3 jump targets to the new base, and repoint
	// ONLY this instrument. Snapshots ALL tables + insLabels for undo (pointer shifts).
	// Returns false (no mutation) if the sweep table can't fit the copy — never corrupts.
	private bool forkSweepProgram(int table, int ins) {
		int col = (table == 0) ? 5 : 4;
		ubyte[] t = (table == 0) ? song.pulseTable : song.filterTable;
		int startRow = song.instrumentTable[ins + col * 48];
		bool[0x40] mine = sweepProgramRows(table, startRow);
		int[] rows;
		foreach(r; 0 .. 0x40) if(mine[r]) rows ~= r;
		int count = cast(int)rows.length;
		if(count == 0) return false;
		int base = (table == 0) ? song.tPulse.seekTableEnd() : song.tFilter.seekTableEnd();
		// Capacity: mirror insertInstrument's guard (data length 256 bytes - 4 => row 63).
		if(base + count > 0x3f) {
			UI.statusline.display(format("%s table full - cannot fork program.",
				table == 0 ? "Pulse" : "Filter"));
			return false;
		}
		snapshotAllTables(true);
		// old row -> new row. Ascending placement keeps b3==0 "fall through to next row"
		// adjacency (a b3==0 row's successor is the immediately-following row, which is
		// the next element of the ascending set), and remaps explicit jumps below.
		int[0x40] newRow; newRow[] = -1;
		foreach(i, r; rows) newRow[r] = base + cast(int)i;
		// Copy source rows into a buffer FIRST (source/dest may alias), relocate jumps.
		ubyte[] buf = new ubyte[count * 4];
		foreach(i, r; rows) buf[i * 4 .. i * 4 + 4] = t[r * 4 .. r * 4 + 4];
		foreach(i; 0 .. count) {
			ubyte b3 = buf[i * 4 + 3];
			if(b3 >= 1 && b3 <= 0x3f) buf[i * 4 + 3] = cast(ubyte)newRow[b3];
		}
		t[base * 4 .. base * 4 + count * 4] = buf[];
		song.instrumentTable[ins + col * 48] = cast(ubyte)newRow[startRow];
		// §20 P4b-2 keep the selected step pointing at the SAME step in the private copy
		// (its row index moved with the fork), so a post-fork Ins/Del acts on it.
		if(selectedSweepTable == table && selectedSweepRow >= 0 && selectedSweepRow < 0x40
				&& newRow[selectedSweepRow] >= 0)
			selectedSweepRow = newRow[selectedSweepRow];
		retriggerIfSounding();
		return true;
	}

	// §20.2 pop the shared-program confirmation at PRESS. Y = fork a private copy,
	// N = edit the shared program in place (remembered so it doesn't re-prompt). Either
	// choice ends this press without starting a drag — the user drags again after.
	private void promptSweepFork(int table, int ins) {
		int col = (table == 0) ? 5 : 4;
		int startRow = song.instrumentTable[ins + col * 48];
		string what = (table == 0) ? "pulse" : "filter";
		mainui.activateDialog(new ConfirmationDialog(
			format("This %s program is shared. Fork a private copy (y/n)? ", what),
			(int param) {
				if(param == 0) forkSweepProgram(table, ins);       // Y = fork
				else sweepEditShared[table][startRow] = true;      // N = edit shared
			}));
	}

	// Map the current level drag's mouse Y to the target value and write the edited
	// row's init byte b2 (pulse width nibble-swapped 0..4095 step 16, or filter cutoff
	// 0..2047 >> 3). The band redraws live from the byte (WYSIWYG). No undo/re-trigger
	// here — the gesture snapshot is at the first drag tick, the re-trigger at release.
	private void sweepLevelDragUpdate(ref Geo g, int celly) {
		int band = (sweepTable == 0) ? 3 : 4;
		int maxVal = (sweepTable == 0) ? 4095 : 2047;
		int topPx, botPx; bandBox(g, band, topPx, botPx);
		int h = botPx - topPx; if(h < 1) h = 1;
		int py = celly * FONT_Y + FONT_Y / 2;
		int v = cast(int)lround(cast(double)(botPx - py) * maxVal / h);
		v = clampInt(v, 0, maxVal);
		if(sweepRow < 0 || sweepRow >= 0x40) return;
		if(sweepTable == 0) {
			// invert simPulse's pw=((b2&0x0f)<<8)|(b2&0xf0): sets pw in steps of 16.
			ubyte b2 = cast(ubyte)(((v >> 8) & 0x0f) | (v & 0xf0));
			song.pulseTable[sweepRow * 4 + 2] = b2;
		} else {
			ubyte b2 = cast(ubyte)((v >> 3) & 0xff);          // cutoff >> 3
			song.filterTable[sweepRow * 4 + 2] = b2;
		}
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

	// Hit-test the resonance overlay line in the Filter band at press (x,y screen cells).
	// The grab zone is a small band (RES_HIT_PX) around the DRAWN res line (which lives in
	// the filter band by construction) at a column the filter program actually emits — a
	// zone distinct from the cutoff-level drag area. Returns the CONFIG row governing the
	// pressed frame (whose b1 hi nibble the drag edits), or -1 (press not on the res line /
	// no config row governs this frame). Checked in clickedAt BEFORE the P4b-1 cutoff-level
	// drag (and before sweepBandAt, whose cell-top band split can't reach a top-edge res
	// line) so grabbing the resonance line always wins over a cutoff-level drag.
	private enum int RES_HIT_PX = 6;
	private int filterResHandleAt(ref Geo g, int x, int y) {
		int px = x * FONT_X;
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx) return -1;
		int ins = clampedIns();
		int ptr = song.instrumentTable[ins + 4 * 48];
		if(ptr < 1 || ptr > 0x3f) return -1;
		SweepSim s = simFilter(ptr);
		if(s.resOf.length == 0) return -1;
		int fx = px + FONT_X / 2;
		int f = cast(int)lround(tickForPixel(g, fx));
		if(f < 0 || f >= cast(int)s.resOf.length) return -1;   // press x is off the drawn program
		int cfg = (f < cast(int)s.cfgRowOf.length) ? s.cfgRowOf[f] : -1;
		if(cfg < 0 || cfg > 0x3f) return -1;    // no config row here -> no res edit
		int res = s.resOf[f]; if(res < 0) res = 0; if(res > 15) res = 15;
		int topPx, botPx; bandBox(g, 4, topPx, botPx);
		int hh = botPx - topPx; if(hh < 1) hh = 1;
		int ry = botPx - res * hh / 15;
		int clickPy = y * FONT_Y + FONT_Y / 2;
		if(abs(clickPy - ry) <= RES_HIT_PX) return cfg;   // click is on the drawn res line
		return -1;
	}

	// Map the resonance drag's mouse Y to res 0..15 (across the filter band height, the
	// inverse of the drawer's ry = botPx - res*h/15) and write the CONFIG row's b1 HIGH
	// nibble, PRESERVING the low nibble (routing). No undo/re-trigger here — the gesture
	// snapshot is at the first drag tick, the re-trigger at release.
	private void sweepResDragUpdate(ref Geo g, int celly) {
		if(sweepResRow < 0 || sweepResRow >= 0x40) return;
		int topPx, botPx; bandBox(g, 4, topPx, botPx);
		int hh = botPx - topPx; if(hh < 1) hh = 1;
		int py = celly * FONT_Y + FONT_Y / 2;
		int v = cast(int)lround(cast(double)(botPx - py) * 15.0 / hh);
		v = clampInt(v, 0, 15);
		ubyte b1 = song.filterTable[sweepResRow * 4 + 1];
		song.filterTable[sweepResRow * 4 + 1] = cast(ubyte)((v << 4) | (b1 & 0x0f));
	}

	// The Filter band's clickable MODE CHIP lives in the band's left gutter, two rows below
	// the "Filter" label (below "res"), showing the first config row's mode name in its
	// §10.1 colour. Fixed-width click target across the gutter (nothing else is drawn there).
	private void filterModeChipCell(ref Geo g, out int cx, out int cy) {
		cx = g.labelX;
		cy = g.bandTopPx[4] / FONT_Y + 2;
	}
	private bool filterModeChipVisible(ref Geo g) {
		int cx, cy; filterModeChipCell(g, cx, cy);
		return cy < g.bandTopPx[5] / FONT_Y;      // fits inside the filter band
	}
	private bool filterModeChipAt(ref Geo g, int x, int y) {
		if(!filterModeChipVisible(g)) return false;
		int cx, cy; filterModeChipCell(g, cx, cy);
		return y == cy && x >= cx && x < g.labelX + 8;   // whole 8-cell gutter row
	}
	private void drawFilterModeChip(int ins, ref Geo g) {
		if(!filterModeChipVisible(g)) return;
		int cx, cy; filterModeChipCell(g, cx, cy);
		int cfg = filterFirstConfigRow(song.instrumentTable[ins + 4 * 48]);
		string name; int col;
		if(cfg < 0) { name = "n/a"; col = COL_DIM; }
		else {
			int mode = song.filterTable[cfg * 4] & 0x70;
			name = filterModeName(mode);          // "LP".."LPBPHP" or "off"
			int mc = filterModeColor(mode);
			col = (mc < 0) ? COL_DIM : mc;
		}
		screen.cprint(cx, cy, col, 0, "[" ~ name ~ "]");
	}

	// §20 P4b-3 cycle the first filter config row's mode (LP->BP->HP->LP+BP->BP+HP->LP+HP->
	// LP+HP+BP-> back to LP). Runs the §20.2 shared check first (fork/edit-shared prompt),
	// then rewrites the config row's b0 mode bits (0x70), preserving the 0x80 config flag +
	// low nibble. No-op with a status hint if the program has no config row.
	private void cycleFilterMode(int ins) {
		if(filterFirstConfigRow(song.instrumentTable[ins + 4 * 48]) < 0) {
			UI.statusline.display("No filter config row - add a filter program to set mode.");
			return;
		}
		if(sweepProgramShared(1, ins) && !sweepDecided(1, ins)) {
			int startRow = song.instrumentTable[ins + 4 * 48];
			mainui.activateDialog(new ConfirmationDialog(
				"This filter program is shared. Fork a private copy (y/n)? ",
				(int param) {
					if(param == 0) { if(!forkSweepProgram(1, ins)) return; }  // Y = fork
					else sweepEditShared[1][startRow] = true;                 // N = shared
					doCycleFilterMode(ins);
				}));
			return;
		}
		doCycleFilterMode(ins);
	}
	private void doCycleFilterMode(int ins) {
		int cfg = filterFirstConfigRow(song.instrumentTable[ins + 4 * 48]);
		if(cfg < 0) return;
		snapshotAllTables(false);
		ubyte b0 = song.filterTable[cfg * 4];
		int cur = b0 & 0x70;
		int idx = -1;
		foreach(i, m; FILTER_MODE_CYCLE) if(m == cur) { idx = cast(int)i; break; }
		int next = FILTER_MODE_CYCLE[(idx + 1) % cast(int)FILTER_MODE_CYCLE.length];
		song.filterTable[cfg * 4] = cast(ubyte)((b0 & 0x8f) | (next & 0x70));
		retriggerIfSounding();
	}

	// ---- §20 P4b-2 add/delete step + loop-marker drag ----

	// The loop-CLOSING row of the program at startRow: the row whose b3 either stops
	// ($7f / illegal) or jumps back to an already-visited row. This is the row whose b3
	// the loop-marker drag rewrites. Same chain traversal simPulse/simFilter use. -1 if
	// the program is empty (fixed/off pointer).
	private int sweepCloseRow(int table, int startRow) {
		if(startRow <= 0 || startRow >= 0x40) return -1;
		const(ubyte)[] t = (table == 0) ? song.pulseTable : song.filterTable;
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
		const(ubyte)[] t = (table == 0) ? song.pulseTable : song.filterTable;
		int b = 0x3f * 4;
		return t[b] != 0 || t[b + 1] != 0 || t[b + 2] != 0 || t[b + 3] != 0;
	}

	// Hit-test the loop marker in the Pulse/Filter band at press (x,y screen cells).
	// Returns the loop-closing row if the press is within LOOP_HIT_PX of a drawn loop
	// line (loopFrame + k*period) or, for a stopping program, its subtle end marker;
	// else -1. Checked in clickedAt BEFORE the level-drag so grabbing the loop line
	// neither pans nor edits levels.
	private enum int LOOP_HIT_PX = 5;
	private int sweepLoopHandleAt(int table, ref Geo g, int x, int y) {
		int band = (table == 0) ? 3 : 4;
		int px = x * FONT_X, py = y * FONT_Y;
		if(px < g.plotX0px || px >= g.plotX0px + g.plotWpx) return -1;
		if(py < g.bandTopPx[band] || py >= g.bandTopPx[band + 1]) return -1;
		int ins = clampedIns();
		int col = (table == 0) ? 5 : 4;
		int startRow = song.instrumentTable[ins + col * 48];
		int closeRow = sweepCloseRow(table, startRow);
		if(closeRow < 0) return -1;
		SweepSim s = (table == 0) ? simPulse(startRow) : simFilter(startRow);
		int pressX = px + FONT_X / 2;
		if(s.loopFrame >= 0 && s.loopPeriod >= 2) {
			int n = min(cast(int)s.val.length, visFrames);
			for(int f = s.loopFrame; f < n && f < visFrames; f += s.loopPeriod) {
				if(!frameInView(f)) continue;
				if(abs(pressX - xForFrame(g, f)) <= LOOP_HIT_PX) return closeRow;
			}
		} else if(s.stops) {
			int f = min(cast(int)s.val.length, visFrames);
			if(frameInView(f) && abs(pressX - xForFrame(g, f)) <= LOOP_HIT_PX)
				return closeRow;
		}
		return -1;
	}

	// Map the loop-marker drag's mouse X to a frame -> the SweepTable row active there,
	// and set the loop-closing row's b3 jump to that row (the new loop-start). Converts a
	// $7f stop into a loop. The band + loop line follow live from the byte (WYSIWYG). No
	// undo/re-trigger here — snapshot is at the first drag tick, re-trigger at release.
	private void sweepLoopDragUpdate(ref Geo g, int cellx) {
		int table = sweepLoopTable;
		if(sweepLoopCloseRow < 0 || sweepLoopCloseRow >= 0x40) return;
		int px = cellx * FONT_X + FONT_X / 2;
		int f = cast(int)lround(tickForPixel(g, px));
		if(f < 0) f = 0;
		int ins = clampedIns();
		int col = (table == 0) ? 5 : 4;
		int startRow = song.instrumentTable[ins + col * 48];
		SweepSim s = (table == 0) ? simPulse(startRow) : simFilter(startRow);
		if(s.rowOf.length == 0) return;
		if(f >= cast(int)s.rowOf.length) f = cast(int)s.rowOf.length - 1;
		int target = s.rowOf[f];
		if(target < 0 || target > 0x3f) return;
		ubyte[] t = (table == 0) ? song.pulseTable : song.filterTable;
		t[sweepLoopCloseRow * 4 + 3] = cast(ubyte)target;
	}

	// §20.1/§20.4 insert (after the selected row) or delete the selected sweep step via
	// the ct.purge row-ops (which shift the table AND fix every instrument pointer +
	// sequence command globally). Runs the §20.2 shared-program check first: if shared &
	// undecided, prompts fork/edit-shared and performs the row-op in the dialog callback
	// (on the private copy if forked). Snapshots ALL tables + insLabels for undo.
	private void sweepRowOp(int table, bool insert) {
		int ins = clampedIns();
		if(selectedSweepRow < 0 || selectedSweepRow >= 0x40) return;
		if(insert && sweepTableFull(table)) {
			UI.statusline.display(format("%s table full - cannot insert step.",
				table == 0 ? "Pulse" : "Filter"));
			return;
		}
		if(sweepProgramShared(table, ins) && !sweepDecided(table, ins)) {
			int col = (table == 0) ? 5 : 4;
			int startRow = song.instrumentTable[ins + col * 48];
			string what = (table == 0) ? "pulse" : "filter";
			mainui.activateDialog(new ConfirmationDialog(
				format("This %s program is shared. Fork a private copy (y/n)? ", what),
				(int param) {
					if(param == 0) { if(!forkSweepProgram(table, ins)) return; }  // Y = fork
					else sweepEditShared[table][startRow] = true;                 // N = shared
					doSweepRowOp(table, insert);   // operate on private (forked) or shared
				}));
			return;
		}
		doSweepRowOp(table, insert);
	}

	// The actual row-op, once sharing is resolved. INSERT: a new row after the selected
	// one, seeded with the selected row's shape (b0/b1/b2) and taking over its jump role
	// (the selected row now falls through to it) so the program stays valid; selection ->
	// the new row. DELETE: remove the selected row; selection -> an adjacent program row.
	private void doSweepRowOp(int table, bool insert) {
		int sel = selectedSweepRow;
		if(sel < 0 || sel >= 0x40) return;
		ubyte[] t = (table == 0) ? song.pulseTable : song.filterTable;
		snapshotAllTables(true);                 // row-ops shift pointers + seq commands
		if(insert) {
			int nr = sel + 1;
			ubyte b0 = t[sel * 4], b1 = t[sel * 4 + 1], b2 = t[sel * 4 + 2];
			if(table == 0) ct.purge.pulseInsertRow(song, nr);
			else ct.purge.filterInsertRow(song, nr);
			// Seed the new row with the selected step's shape; the new row inherits the
			// selected row's (possibly-adjusted) jump so the terminal/loop still resolves,
			// and the selected row now falls through (b3=0) into the new row.
			ubyte cur = t[sel * 4 + 3];
			t[nr * 4 + 0] = b0; t[nr * 4 + 1] = b1; t[nr * 4 + 2] = b2; t[nr * 4 + 3] = cur;
			t[sel * 4 + 3] = 0;
			selectedSweepRow = nr;
		} else {
			if(table == 0) ct.purge.pulseDeleteRow(song, sel);
			else ct.purge.filterDeleteRow(song, sel);
			// Move the selection to an adjacent row still inside the (shifted) program.
			int ins = clampedIns();
			int col = (table == 0) ? 5 : 4;
			int startRow = song.instrumentTable[ins + col * 48];
			bool[0x40] rows = sweepProgramRows(table, startRow);
			int pick = -1;
			if(sel - 1 >= 0 && rows[sel - 1]) pick = sel - 1;
			else if(sel < 0x40 && rows[sel]) pick = sel;
			else foreach(r; 0 .. 0x40) if(rows[r]) { pick = r; break; }
			selectedSweepRow = pick;
			if(pick < 0) selectedSweepTable = -1;   // program emptied -> no selection
		}
		retriggerIfSounding();
	}

	// §20 P4b-2 draw a bright outline around the selected step's frame span in its band,
	// so the click target Ins/Del acts on is unmistakable. Uses the sim's rowOf to find
	// the first contiguous run of the selected row on the shared frame axis. Clears the
	// selection if the row is no longer part of the instrument's program (e.g. deleted).
	private void drawSweepSelection(int ins, ref Geo g) {
		if(selectedSweepTable < 0 || selectedSweepRow < 0) return;
		int band = (selectedSweepTable == 0) ? 3 : 4;
		int col = (selectedSweepTable == 0) ? 5 : 4;
		int startRow = song.instrumentTable[ins + col * 48];
		SweepSim s = (selectedSweepTable == 0) ? simPulse(startRow) : simFilter(startRow);
		int f0 = -1, f1 = -1;
		foreach(f, r; s.rowOf) {
			if(r == selectedSweepRow) { if(f0 < 0) f0 = cast(int)f; f1 = cast(int)f + 1; }
			else if(f0 >= 0) break;
		}
		if(f0 < 0) return;                       // selected row not in the current program
		int topPx, botPx; bandBox(g, band, topPx, botPx);
		int xa = xForFrame(g, f0), xb = xForFrame(g, f1);
		if(xb <= xa) xb = xa + 1;
		video.olRect(xa, topPx, xb - xa, botPx - topPx, COL_STEPSEL);
	}

	private void clearSweepSelection() {
		selectedSweepTable = -1;
		selectedSweepRow = -1;
	}

	// ---- band chrome ----

	// §13.1(b) split so the TEXT label (drawn in drawTextChrome, incl. under
	// chromeActive) is independent of the pixel baseline axis (drawn only with the
	// graph bands on the normal path).
	private void drawBandLabelText(ref Geo g, int band, string label) {
		int row = g.bandTopPx[band] / FONT_Y;
		screen.cprint(g.labelX, row, COL_LABEL, 0, label);
	}

	private void drawBandAxis(ref Geo g, int band) {
		// Faint baseline axis at the band's bottom.
		int botPx = g.bandTopPx[band + 1] - 2;
		video.olHLine(g.plotX0px, g.plotX0px + g.plotWpx - 1, botPx, COL_AXIS);
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
		int noteX0px = xForFrame(g, 0);
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
			double t0 = tickForPixel(g, x);
			double t1 = tickForPixel(g, x + 1);
			if(t0 < 0) t0 = 0;
			if(t1 <= t0) t1 = t0 + (viewEndTick - viewStartTick) / g.plotWpx;
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

		// §11.2 recording path: draw the ACTUAL per-frame envelope amplitude the voice
		// produced (the real A/D/S/R the ear heard, including retrigger/release), as a
		// bright step line on the shared frame axis. No restart pre-roll here — the
		// recording begins at the note trigger (frame 0).
		if(useRec) {
			auto amp = audio.visualizer.getRecordedAmp(viewVoice);
			int n = min(cast(int)amp.length, visFrames);
			// §15.4 FIXED 0..1 scale — NOT auto-gained. The envelope amplitude is an
			// ABSOLUTE quantity (0..1, sustain 0..15) governed by the SID's CONSTANT
			// attack/decay/release times, so it must plot on the fixed band scale: a slow
			// AD=FF attack then reads as a steady RAMP over the attack (a note reaching only
			// 37% draws a ramp to 37%), not an instant jump to the top that peak-normalising
			// produced. The peak auto-gain stays ONLY on the Output waveform band (raw
			// samples, whose absolute level is arbitrary). With §15.2 fit-to-recording the
			// fixed-scale ramp already fills the width.
			// Draw the envelope as a connected DIAGONAL polyline (one line segment between
			// consecutive per-frame samples), NOT a sample-and-hold staircase. The old
			// flat-tread (olHLine) + vertical-riser (olVLine) style quantised a gentle
			// slope into wide flat steps: the envelope FSM advances once per SCREEN frame
			// but the axis is in finer player ticks, so each level spanned several pixels
			// horizontally while dropping ~1px vertically -> visible treads. A polyline
			// interpolates between samples so the slope reads as a slope (matches the
			// smooth idle-sim path below). The envelope is a continuous quantity, so this
			// is honest; genuinely discrete lanes (wave bits, arp notes) stay stepped.
			int prevX = -1, prevY = -1;
			int lo, hi; visRange(n, lo, hi);       // §17.1 only emit on-screen frames
			foreach(f; lo .. hi) {
				int y = botPx - cast(int)lround(clamp01(amp[f]) * h);
				int x = xForFrame(g, f);
				if(prevX >= 0) video.olLine(prevX, prevY, x, y, COL_CURVE);
				else video.olPoint(x, y, COL_CURVE);
				prevX = x; prevY = y;
			}
			// §19: DON'T return — fall through to overlay the white-dotted ADSR estimate
			// (from the current AD/SR nibbles) on top of the solid green recording, so the
			// estimate updates live as the user edits A/D/S/R.
		}

		ubyte ad = song.instrumentTable[ins + 0 * 48];
		ubyte sr = song.instrumentTable[ins + 1 * 48];
		int attack  = (ad >> 4) & 0x0f, decay = ad & 0x0f;
		int sustain = (sr >> 4) & 0x0f, release = sr & 0x0f;
		float sLvl = sustain / 15.0f;
		// SID ms tables -> frames (real, non-linear MOS timing). The knee frames are
		// absolute frame indices, so they line up in time with pulse/filter/wave.
		float aF = ATTACK_TIME_MS[attack]         / tickMs;
		float dF = DECAY_RELEASE_TIME_MS[decay]   / tickMs;
		float rF = DECAY_RELEASE_TIME_MS[release] / tickMs;
		if(rF < 0.5f) rF = 0.5f;
		// Nominal gate: release begins nominalGateFrames after the trigger (but never
		// before attack+decay have completed), so all four A/D/S/R phases are visible.
		float gateEnd = aF + dF + nominalGateFrames;

		// Amplitude 0..1 at absolute frame f (f>=0, i.e. after the trigger).
		// §19: decay/release use the exponential shape (expEnvLevel) that the recorder
		// produces, so the estimate curve matches the recording's shape. Attack stays
		// linear; sustain hold unchanged.
		float amp(float f) {
			if(f < aF) return aF > 0 ? f / aF : 1.0f;             // attack ramp -> 1.0
			if(f < aF + dF) return dF > 0 ? sLvl + (1.0f - sLvl) * expEnvLevel((f - aF) / dF) : sLvl;
			if(f < gateEnd) return sLvl;                          // sustain hold
			return clamp01(sLvl * expEnvLevel((f - gateEnd) / rF)); // release (exponential)
		}

		// §9.2 restart pre-roll (frames -RESTART_FRAMES..0), shaded distinctly, showing
		// the hard/soft/3-frame restart forced by col2 using HR SR (col6) + HR wave
		// (col3) before the note. It's a display of "the envelope was being killed",
		// not a cycle-exact sim.
		// §17.1 pre-roll region, clamped to the plot (it can be fully/partly off-view
		// when the user has panned/zoomed past the trigger).
		ubyte rst = song.instrumentTable[ins + 2 * 48];
		int plotEndPx = g.plotX0px + g.plotWpx;
		int preX0 = xForFrame(g, -prerollTicks);
		int preX1 = xForFrame(g, 0);
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

		// §19 ADSR ESTIMATE: one point per horizontal pixel across the visible note
		// region, mapped pixel->tick through the SAME viewport axis so its knees align
		// with the other bands at any zoom. Skip columns before the trigger (pre-roll,
		// f<0). Drawn as a WHITE DOTTED line (2-on/2-off pixel pattern) — ALWAYS, both
		// idle (estimate only) and after a keyjam note (overlaid on the solid green
		// recording); it updates live as the user edits A/D/S/R.
		for(int x = g.plotX0px; x < plotEndPx; x++) {
			double f = tickForPixel(g, x);
			if(f < 0) continue;
			int y = botPx - cast(int)lround(clamp01(amp(cast(float)f)) * h);
			if((x & 2) == 0) video.olPoint(x, y, COL_ESTIMATE);
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
		// §14.2 loop lines: in the recording path derive the loop start/period from the
		// ACTUAL recorded pulse values (honours the real gate-on delay); else use the sim.
		int lf = s.loopFrame, lp = s.loopPeriod, ln = min(cast(int)s.val.length, visFrames);
		if(useRec) {
			auto rp = audio.visualizer.getRecordedPulse(viewVoice);
			drawValueBand(rp, 4095, COL_PULSE_FILL, COL_PULSE_LINE, topPx, botPx, g);
			ln = min(cast(int)rp.length, visFrames);
			loopFromRecording(rp, ln, lf, lp);
		} else if(ptr < 0x80) {               // direct fixed pulse ($80+) = no program
			drawValueBand(s.val, 4095, COL_DIMFILL, COL_DIM, topPx, botPx, g);
		}
		drawLoopLines(g, topPx, botPx, lf, lp, ln);
		drawSweepEndMarker(g, topPx, botPx, s);   // §20 P4b-2 grabbable stop marker
	}

	// §20 P4b-2 for a STOPPING program (no loop line to grab), draw a subtle marker at the
	// program's end so the loop-marker drag has something to grab (dragging it converts the
	// stop into a loop). Looping programs already draw grabbable loop lines.
	private void drawSweepEndMarker(ref Geo g, int topPx, int botPx, ref SweepSim s) {
		if(s.loopFrame >= 0 || !s.stops) return;
		int f = min(cast(int)s.val.length, visFrames);
		if(!frameInView(f)) return;
		video.olVLine(xForFrame(g, f), topPx, botPx, COL_LOOPLINE);
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
		int lo, hi; visRange(n, lo, hi);       // §17.1 only emit on-screen frames

		// Cutoff fill + top line, coloured by the mode active on each frame. A "filter
		// off" frame (mode 0x00 -> col < 0) leaves that column empty; dim uses grey.
		foreach(f; lo .. hi) {
			int mode = f < modeA.length ? modeA[f] : 0;
			int mc = filterModeColor(mode);
			if(mc < 0) continue;              // filter off -> empty band this frame
			int col = dim ? COL_DIMFILL : mc;
			int v = cutoff[f];
			if(v < 0) v = 0; if(v > maxVal) v = maxVal;
			int y = botPx - v * h / maxVal;
			int xa = xForFrame(g, f);
			int xb = xForFrame(g, f + 1);
			if(xb <= xa) xb = xa + 1;
			for(int x = xa; x < xb; x++) {
				video.olVLine(x, botPx, y, col);   // fill in the mode colour
				video.olPoint(x, y, col);          // top edge (line) in the mode colour
			}
		}

		// §10.2 resonance (0..15) over time: a thin step line, clearly separate from the
		// cutoff fill. Bright yellow on the recording path, dim grey on the sim preview.
		int rescol = dim ? COL_DIM : COL_RES;
		int prevY = -1;
		foreach(f; lo .. hi) {
			int res = f < resA.length ? resA[f] : 0;
			if(res < 0) res = 0; if(res > 15) res = 15;
			int ry = botPx - res * h / 15;
			int xa = xForFrame(g, f);
			int xb = xForFrame(g, f + 1);
			if(xb <= xa) xb = xa + 1;
			video.olHLine(xa, xb - 1, ry, rescol);              // level segment
			if(prevY >= 0 && prevY != ry)
				video.olVLine(xa, min(prevY, ry), max(prevY, ry), rescol); // riser
			prevY = ry;
		}

		// §14.2 loop lines: recording path derives the loop from the ACTUAL recorded
		// cutoff (real gate-on delay); sim path uses the sim's loopFrame/period.
		int lf = s.loopFrame, lp = s.loopPeriod;
		if(useRec) loopFromRecording(cutoff, n, lf, lp);
		drawLoopLines(g, topPx, botPx, lf, lp,
			useRec ? n : min(cast(int)s.val.length, visFrames));
		drawSweepEndMarker(g, topPx, botPx, s);   // §20 P4b-2 grabbable stop marker

		// Label the resonance overlay in the band's left gutter (row below "Filter").
		int lrow = g.bandTopPx[4] / FONT_Y + 1;
		if(lrow < g.bandTopPx[5] / FONT_Y)
			screen.cprint(g.labelX, lrow, rescol, 0, "res");

		// §20 P4b-3 clickable mode chip (cycles LP/BP/HP combos, recolours the fill live).
		drawFilterModeChip(ins, g);
	}

	// §10.3 Frequency/pitch band: the instrument's per-frame semitone program taken
	// from the wave-table transpose/arp column (wave1), drawn as a step graph. Relative
	// transpose ($00..$5F) and absolute tuning ($80..$DF) are coloured distinctly.
	private void drawFreqBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 2, topPx, botPx);
		int h = botPx - topPx;
		if(h < 2) return;
		int ptr = song.instrumentTable[ins + 7 * 48];
		WaveFrameSim s = simWaveFrames(ptr);   // sim pitch program + loop period

		// §11.2 recording path: the ACTUAL 16-bit SID frequency per frame, drawn on a
		// log2 (pitch) scale auto-fitted to the recorded range so pitch moves read as
		// even semitone steps. Absolute-tuning colour (cyan) — it is a real pitch.
		if(useRec) {
			auto fr = audio.visualizer.getRecordedFreq(viewVoice);
			int n = min(cast(int)fr.length, visFrames);
			if(n <= 0) return;
			float lo = 1e9f, hi = -1e9f;
			foreach(f; 0 .. n) if(fr[f] > 0) {
				float l = log2(cast(float)fr[f]);
				if(l < lo) lo = l;
				if(l > hi) hi = l;
			}
			if(hi <= lo) hi = lo + 1.0f;       // flat / silent: avoid divide-by-zero
			int prevY = -1;
			int flo, fhi; visRange(n, flo, fhi);   // §17.1 only emit on-screen frames
			foreach(f; flo .. fhi) {
				float l = fr[f] > 0 ? log2(cast(float)fr[f]) : lo;
				int y = botPx - cast(int)lround((l - lo) / (hi - lo) * h);
				int xa = xForFrame(g, f);
				int xb = xForFrame(g, f + 1);
				if(xb <= xa) xb = xa + 1;
				video.olHLine(xa, xb - 1, y, COL_FREQ_ABS);
				if(prevY >= 0 && prevY != y)
					video.olVLine(xa, min(prevY, y), max(prevY, y), COL_FREQ_ABS);
				prevY = y;
			}
			// §14.2 derive the loop from the ACTUAL recorded frequency staircase.
			int lf, lp;
			loopFromRecording(fr, n, lf, lp);
			drawLoopLines(g, topPx, botPx, lf, lp, n);
			return;
		}

		// Idle dimmed sim: the wave-table transpose/arp program (semitones), floor at
		// 12 semitones (one octave) so small arps stay visible.
		int n = min(cast(int)s.transOf.length, visFrames);
		if(n <= 0) return;
		int scale = 12;
		foreach(f; 0 .. n) if(s.transOf[f] > scale) scale = s.transOf[f];
		int prevY = -1;
		int flo, fhi; visRange(n, flo, fhi);   // §17.1 only emit on-screen frames
		foreach(f; flo .. fhi) {
			int pv = s.transOf[f];
			int y = botPx - pv * h / scale;
			int xa = xForFrame(g, f);
			int xb = xForFrame(g, f + 1);
			if(xb <= xa) xb = xa + 1;
			video.olHLine(xa, xb - 1, y, COL_DIM);               // level segment (dim)
			if(prevY >= 0 && prevY != y)
				video.olVLine(xa, min(prevY, y), max(prevY, y), COL_DIM); // step riser
			prevY = y;
		}
		drawLoopLines(g, topPx, botPx, s.loopFrame, s.loopPeriod, n);
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
		WaveFrameSim s = simWaveFrames(ptr);    // loop period + idle-preview control bytes

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

		int flo, fhi; visRange(n, flo, fhi);   // §17.1 only emit on-screen frames
		foreach(f; flo .. fhi) {
			int ctrl = ctrlA[f];
			int xa = xForFrame(g, f);
			int xb = xForFrame(g, f + 1);
			if(xb <= xa) xb = xa + 1;
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
		screen.cprint(x + 1, y, COL_TITLE, 0, " Raw table data (read-only) ");

		ubyte b(int col) { return song.instrumentTable[ins + col * 48]; }
		screen.cprint(x, y + 1, COL_LABEL, 0, format(
			"Ins %02X:  AD %02X  SR %02X  Rst %02X  HRw %02X  Flt %02X  Pul %02X  HRsr %02X  Wav %02X",
			ins, b(0), b(1), b(2), b(3), b(4), b(5), b(6), b(7)));

		int maxw = area.width - 4;

		// Wave rows the instrument walks (wave1/wave2 pairs).
		{
			WaveSim w = simWave(b(7));
			string ln = format("Wave $%02X: ", b(7));
			foreach(c; w.cells) {
				string cell = format("%02X/%02X ", c.transpose & 0xff, c.ctrl & 0xff);
				if(ln.length + cell.length > maxw) { ln ~= ".."; break; }
				ln ~= cell;
			}
			screen.cprint(x, y + 2, COL_VALUE, 0, ln);
		}
		// Pulse rows used (unique, in first-seen order).
		{
			int ptr = b(5);
			string ln;
			if(ptr >= 0x80) ln = format("Pulse: direct fixed $%03X", (ptr & 0x0f) << 8);
			else {
				SweepSim s = simPulse(ptr);
				ln = format("Pulse $%02X: ", ptr);
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
			if(ptr <= 0) ln = "Filter: none";
			else {
				SweepSim s = simFilter(ptr);
				ln = format("Filter $%02X: ", ptr);
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
		// Live filter routing/resonance/mode (filter is shared/global).
		ubyte r17 = audio.audio.sidreg[0x17];
		ubyte r18 = audio.audio.sidreg[0x18];
		string routeStr;
		if(r17 & 1) routeStr ~= "1"; if(r17 & 2) routeStr ~= "2"; if(r17 & 4) routeStr ~= "3";
		if(routeStr.length == 0) routeStr = "-";
		string modeStr;
		if(r18 & 0x10) modeStr ~= "LP"; if(r18 & 0x20) modeStr ~= "BP"; if(r18 & 0x40) modeStr ~= "HP";
		if(modeStr.length == 0) modeStr = "off";
		screen.cprint(x, y + 5, COL_LABEL, 0,
			format("Live filter: Res %X  Route %s  Mode %s (shared)", r17 >> 4, routeStr, modeStr));
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
		hovering = true;
		// §17.3 light the zoom button under the pointer (-1 = none / disabled).
		Geo g = layout();
		hoveredBtn = buttonAt(g, scrx, scry);
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

	// Interpolated ADSR envelope amplitude 0..1 at absolute frame f (>=0) for the sim
	// (idle) path — the same continuous A/D/S/R model drawAdsrBand samples, so the
	// probe readout shows an INTERPOLATED value between the SID ms-table knees.
	private float adsrAmpAt(int ins, float f) {
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		ubyte sr = song.instrumentTable[ins + 1 * 48];
		int attack = (ad >> 4) & 0x0f, decay = ad & 0x0f;
		int sustain = (sr >> 4) & 0x0f, release = sr & 0x0f;
		float sLvl = sustain / 15.0f;
		float aF = ATTACK_TIME_MS[attack]         / tickMs;
		float dF = DECAY_RELEASE_TIME_MS[decay]   / tickMs;
		float rF = DECAY_RELEASE_TIME_MS[release] / tickMs;
		if(rF < 0.5f) rF = 0.5f;
		float gateEnd = aF + dF + nominalGateFrames;
		// §19: exponential decay/release matching the recording + drawAdsrBand estimate.
		if(f < aF) return aF > 0 ? f / aF : 1.0f;
		if(f < aF + dF) return dF > 0 ? sLvl + (1.0f - sLvl) * expEnvLevel((f - aF) / dF) : sLvl;
		if(f < gateEnd) return sLvl;
		return clamp01(sLvl * expEnvLevel((f - gateEnd) / rF));
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
		int f = cast(int)lround(tickForPixel(g, hx));
		if(f < 0) f = 0;
		if(f >= visFrames) f = visFrames - 1;
		if(f < 0) f = 0;

		// Dashed white probe line at that frame across the whole band stack.
		int px = xForFrame(g, f);
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
			WaveFrameSim ws = simWaveFrames(song.instrumentTable[ins + 7 * 48]);
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
		while(s.val.length < MAXF) {
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
			int nextRow;
			if(b3 == 0) nextRow = (row + 1) & 0x3f;
			else if(b3 == 0x7f) { s.stops = true; break; }
			else if(b3 <= 0x3f) nextRow = b3;
			else { s.stops = true; break; }
			// §11.3 loop: on the FIRST return to an already-emitted row, record where
			// the looped section starts and its period, then KEEP replicating it across
			// the visible window (the real player repeats it too) instead of breaking.
			if(visited[nextRow]) {
				if(s.loopFrame < 0) {
					s.loopFrame = firstFrame[nextRow];
					s.loopPeriod = cast(int)s.val.length - firstFrame[nextRow];
					if(s.loopPeriod < 1) s.loopPeriod = 1;
				}
				row = nextRow;
				continue;
			}
			visited[nextRow] = true;
			row = nextRow;
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
		while(s.val.length < MAXF) {
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
					cutoff += delta;
					if(cutoff < 0) cutoff = 0;
					if(cutoff > 2047) cutoff = 2047;
					emit();
					if(s.val.length >= MAXF) break;
				}
			}
			int nextRow;
			if(b3 == 0) nextRow = (row + 1) & 0x3f;
			else if(b3 == 0x7f) { s.stops = true; break; }
			else if(b3 <= 0x3f) nextRow = b3;
			else { s.stops = true; break; }
			// §11.3 loop replication (see simPulse).
			if(visited[nextRow]) {
				if(s.loopFrame < 0) {
					s.loopFrame = firstFrame[nextRow];
					s.loopPeriod = cast(int)s.val.length - firstFrame[nextRow];
					if(s.loopPeriod < 1) s.loopPeriod = 1;
				}
				row = nextRow;
				continue;
			}
			visited[nextRow] = true;
			row = nextRow;
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
	private WaveFrameSim simWaveFrames(int startRow) {
		WaveFrameSim s;
		int MAXF = visFrames;   // §12.2 sims produce/replicate up to the dynamic window
		if(startRow < 0 || startRow > 0xff) return s;
		int row = startRow & 0xff;
		int cur = 0;                    // carried effective control byte
		int[256] firstFrame; firstFrame[] = -1;
		// §11.3 REPLICATE the looped section across the window instead of stopping at
		// the loop. `steps` bounds jump-only cycles (no frame emitted) so we can't spin.
		int steps = 0;
		while(s.ctrlOf.length < MAXF && steps < MAXF * 8) {
			steps++;
			int w1 = song.waveTable[row];
			int w2 = song.waveTable[row + 256];
			// Loop back-edge: $7F jumps to the row in wave2; $7E loops to previous.
			if(w1 == 0x7f || w1 == 0x7e) {
				int tgt = (w1 == 0x7f) ? (w2 & 0xff) : ((row - 1) & 0xff);
				if(firstFrame[tgt] >= 0 && s.loopFrame < 0) {
					s.loopFrame = firstFrame[tgt];
					s.loopPeriod = cast(int)s.ctrlOf.length - firstFrame[tgt];
					if(s.loopPeriod < 1) s.loopPeriod = 1;
				}
				row = tgt;
				continue;
			}
			// A sequential advance back onto an already-emitted row is also a loop.
			if(firstFrame[row] >= 0 && s.loopFrame < 0) {
				s.loopFrame = firstFrame[row];
				s.loopPeriod = cast(int)s.ctrlOf.length - firstFrame[row];
				if(s.loopPeriod < 1) s.loopPeriod = 1;
			}
			if(firstFrame[row] < 0) firstFrame[row] = cast(int)s.ctrlOf.length;
			if(w2 >= 0x10) cur = w2;    // real SID control byte (else 0/delay = keep)
			s.ctrlOf ~= cur;
			// §10.3 wave1 pitch: $80..$DF = absolute tuning (note = w1 & 0x7F),
			// $00..$5F = relative transpose up (semitone offset). Recorded per frame.
			if(w1 >= 0x80) { s.transOf ~= w1 & 0x7f; s.absOf ~= true; }
			else           { s.transOf ~= w1;        s.absOf ~= false; }
			row = (row + 1) & 0xff;
		}
		return s;
	}

	// ---- §17.2 selection highlight + §17.3 zoom controls ----

	// The clamped pixel X range of the current selection within the plot, or false if
	// the selection is entirely off-view / absent.
	private bool selectionPixels(ref Geo g, out int xa, out int xb) {
		if(!hasSelection) return false;
		xa = xForFrame(g, selStartTick);
		xb = xForFrame(g, selEndTick);
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
		if(frameInView(selStartTick))
			video.olVLine(xForFrame(g, selStartTick), g.stackTopPx, g.stackBotPx, COL_SEL_EDGE);
		if(frameInView(selEndTick))
			video.olVLine(xForFrame(g, selEndTick), g.stackTopPx, g.stackBotPx, COL_SEL_EDGE);
	}

	// §17.3 The four zoom controls, left-to-right on the control row.
	private enum int BTN_ZOOMOUT = 0, BTN_ZOOMIN = 1, BTN_FIT = 2, BTN_SEL = 3;

	// §17.3 Build the four zoom buttons as ordinary ui.button widgets, laid out
	// left-to-right on the control row from the plot's left edge with a 1-cell gap,
	// each pre-loaded with its current interaction/state flags. Recomputed identically
	// by the drawer, the hover probe and the click hit-test so they always agree:
	//   * hovered/pressed track the pointer (see hoverAt + the press/release gesture);
	//   * [Fit] is `active` while the view is auto-fitted (not user-zoomed);
	//   * [Selection] needs a selection — it is `disabled` without one, and `active`
	//     while the viewport currently equals that selection.
	private Button[4] zoomButtons(ref Geo g) {
		static immutable string[4] labels = ["[-]", "[+]", "[Fit]", "[Selection]"];
		Button[4] b;
		int cx = g.plotX0px / FONT_X;
		foreach(int i; 0 .. 4) {
			b[i].x0 = cx;
			b[i].x1 = cx + cast(int)labels[i].length;
			b[i].row = g.controlRow;
			b[i].label = labels[i];
			b[i].hovered = (hoveredBtn == i);
			b[i].pressed = (pressedBtn == i && pressedOver);
			cx = b[i].x1 + 1;   // 1-cell gap
		}
		b[BTN_FIT].active = !userZoomed;
		b[BTN_SEL].enabled = hasSelection;
		b[BTN_SEL].active = hasSelection
			&& cast(int)lround(viewStartTick) == selStartTick
			&& cast(int)lround(viewEndTick) == selEndTick;
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

	// §17.3 Perform a zoom button's action (fired on release over the pressed button).
	private void activateZoomButton(int i) {
		switch(i) {
			case BTN_ZOOMOUT: zoomBy(2.0); break;             // [-] zoom out
			case BTN_ZOOMIN:  zoomBy(0.5); break;             // [+] zoom in
			case BTN_FIT:     userZoomed = false; fitViewport(); break;  // [Fit]
			case BTN_SEL:     zoomToSelection(); break;       // [Selection]
			default: break;
		}
	}

	// §17.3 Draw the subtle control-button row + the current selection readout (its tick
	// range + ms) to its right — all as TEXT (no overlay pixels), so it composites like
	// the rest of the chrome.
	private void drawZoomControls(ref Geo g) {
		auto btns = zoomButtons(g);
		foreach(ref b; btns)
			b.draw();
		int rx = btns[3].x1 + 2;
		int rw = (g.plotX0px + g.plotWpx) / FONT_X - rx;
		if(rw < 4) return;
		string txt;
		if(hasSelection) {
			int a = selStartTick, e = selEndTick;
			float ma = a * tickMs, me = e * tickMs;
			txt = format("sel %d-%d t  (~%.0f-%.0f ms, %d t)", a, e, ma, me, e - a);
		} else {
			txt = format("view %d-%d t   (drag to select)",
				cast(int)lround(viewStartTick), cast(int)lround(viewEndTick));
		}
		if(cast(int)txt.length > rw) txt = txt[0 .. rw];
		screen.cprint(rx, g.controlRow, COL_CTRL, 0, txt);
	}

	// §17.3 Zoom the viewport about its centre by `factor` (>1 = zoom out, <1 = in),
	// clamped. Marks the view as user-zoomed so it survives instrument changes until Fit.
	private void zoomBy(double factor) {
		double centre = (viewStartTick + viewEndTick) / 2.0;
		double span = (viewEndTick - viewStartTick) * factor;
		if(span < MIN_VIEW_SPAN) span = MIN_VIEW_SPAN;
		viewStartTick = centre - span / 2.0;
		viewEndTick = centre + span / 2.0;
		userZoomed = true;
		clampViewport();
	}

	// §17.3 Pan the viewport by `dticks` (keeping its span), clamped.
	private void panBy(double dticks) {
		viewStartTick += dticks;
		viewEndTick += dticks;
		userZoomed = true;
		clampViewport();
	}

	// §17.3 Zoom the viewport to the current selection (no-op if none).
	private void zoomToSelection() {
		if(!hasSelection) return;
		viewStartTick = selStartTick;
		viewEndTick = selEndTick;
		userZoomed = true;
		clampViewport();
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
		double full = cast(double)visFrames - (-prerollTicks);
		if(full < 1e-6) full = 1;
		double f0 = (viewStartTick - (-prerollTicks)) / full;
		double f1 = (viewEndTick   - (-prerollTicks)) / full;
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
		return -prerollTicks + frac * (cast(double)visFrames - (-prerollTicks));
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
	// clamped to the note extent [-RESTART_FRAMES, visFrames]. Integer ticks ARE the
	// native per-tick grid (1/frame at 1×, 2/frame at 2×), so this is the §17.2 snap.
	private int snapPixelToTick(ref Geo g, int cellX) {
		int px = cellX * FONT_X + FONT_X / 2;
		int t = cast(int)lround(tickForPixel(g, px));
		if(t < -prerollTicks) t = -prerollTicks;
		if(t > visFrames) t = visFrames;
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
		clickWasButton = false;
		scrollDragging = false;
		// §17.4 scrollbar row: grab the thumb to pan, or click the track to page. Hit-test
		// by ROW so a press here never starts a plot selection (and vice versa).
		if(y == g.scrollRow) {
			clickWasButton = true;   // consume the paired release (no sel change)
			int tx0, tx1;
			scrollThumbCells(g, tx0, tx1);
			if(x >= tx0 && x < tx1) {                 // on the thumb -> drag to pan
				scrollDragging = true;
				scrollGrabOffset = scrollTickForCell(g, x) - viewStartTick;
			} else {                                  // on the track -> page one view width
				double span = viewEndTick - viewStartTick;
				panBy(x < tx0 ? -span : span);
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
		// §20 P4b-3: a click on the Filter band's mode chip cycles the filter mode. Checked
		// BEFORE step-selection so clicking the chip cycles rather than selecting a step (the
		// chip lives in the gutter, so this also never starts a plot selection).
		if(filterModeChipAt(g, x, y)) {
			clickWasButton = true;   // consume the paired release (no selection change)
			cycleFilterMode(clampedIns());
			return;
		}
		// §19 P4a: grab an A/D/S/R handle on the ADSR curve if the press landed on one
		// (checked BEFORE the plot drag-select, since the ADSR band is inside the plot).
		// One undo snapshot per drag gesture is taken here at press.
		int ah = adsrHandleAt(g, x, y);
		if(ah >= 0) {
			adsrDragging = true;
			adsrHandle = ah;
			adsrMoved = false;       // snapshot + first write happen on the first drag tick
			clickWasButton = true;   // consume the paired release (no selection change)
			return;
		}
		// §20 P4b-3 RESONANCE drag: grabbing the resonance overlay line in the Filter band
		// starts a res drag of the governing config row's b1 hi nibble. Checked BEFORE the
		// P4b-1 cutoff-level drag AND before sweepBandAt (whose cell-top band split can miss
		// a res line sitting at the filter band's top edge) so the two never conflict.
		{
			int rcfg = filterResHandleAt(g, x, y);
			if(rcfg >= 0) {
				clickWasButton = true;   // this press never starts/clears a selection
				sweepResDragging = true;
				sweepResRow = rcfg;
				sweepResMoved = false;   // shared check + snapshot on the first drag tick
				return;
			}
		}
		// §20 P4b-1: a vertical grab in the Pulse or Filter band begins a LEVEL drag of
		// the SweepTable row active at the grabbed frame. Checked AFTER the ADSR handles /
		// scrollbar / zoom buttons (above), before the plot drag-select (below).
		int sb = sweepBandAt(g, x, y);
		if(sb >= 0) {
			// §20 P4b-2 loop-marker drag FIRST: if the press grabs the subtle loop line
			// (or a stopping program's end marker) start a loop-back drag, not a level
			// edit. The shared check + prompt happens on the first drag tick (not here),
			// so a plain click never pops a modal.
			int lc = sweepLoopHandleAt(sb, g, x, y);
			if(lc >= 0) {
				clickWasButton = true;   // this press never starts/clears a selection
				sweepLoopDragging = true;
				sweepLoopTable = sb;
				sweepLoopCloseRow = lc;
				sweepLoopMoved = false;
				return;
			}
			int row = sweepRowAtPress(sb, g, x);
			if(row >= 0) {
				clickWasButton = true;   // this press never starts/clears a plot selection
				// §20 P4b-2 SELECT the step immediately (non-mutating; selecting in one
				// band clears the other). A vertical DRAG turns into a level edit; a plain
				// click (no motion) leaves just this selection.
				selectedSweepTable = sb;
				selectedSweepRow = row;
				sweepDragging = true;
				sweepTable = sb;
				sweepRow = row;
				sweepMoved = false;      // shared check + snapshot on the first drag tick
				return;
			}
		}
		// §17.2 begin a drag-select when the press lands in the plot; else clear.
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
		// §19 P4a ADSR-handle drag: on the first drag tick take the one gesture undo
		// snapshot, then rewrite the mapped byte every tick (curve + column redraw from
		// the byte). No re-trigger here — that fires once on release.
		if(adsrDragging) {
			Geo g = layout();
			if(!adsrMoved) { snapshotInstruments(); adsrMoved = true; }
			adsrDragUpdate(g, x, y);
			return;
		}
		// §20 P4b-2 loop-marker drag: on the first motion tick do the shared check (prompt
		// fork/edit-shared and abort if undecided — the user drags again after choosing),
		// else snapshot ALL tables and rewrite the loop-closing row's b3 every tick.
		if(sweepLoopDragging) {
			Geo g = layout();
			if(!sweepLoopMoved) {
				int ins = clampedIns();
				if(sweepProgramShared(sweepLoopTable, ins) && !sweepDecided(sweepLoopTable, ins)) {
					promptSweepFork(sweepLoopTable, ins);
					sweepLoopDragging = false; sweepLoopTable = -1; sweepLoopCloseRow = -1;
					return;
				}
				snapshotAllTables(false); sweepLoopMoved = true;
			}
			sweepLoopDragUpdate(g, x);
			return;
		}
		// §20 P4b-3 filter RESONANCE drag: on the first motion tick do the §20.2 shared
		// check (prompt + abort if undecided; the user drags again after choosing), else
		// take one all-tables undo snapshot, then rewrite the config row's b1 hi nibble.
		if(sweepResDragging) {
			Geo g = layout();
			if(!sweepResMoved) {
				int ins = clampedIns();
				if(sweepProgramShared(1, ins) && !sweepDecided(1, ins)) {
					promptSweepFork(1, ins);
					sweepResDragging = false; sweepResRow = -1;
					return;
				}
				snapshotAllTables(false); sweepResMoved = true;
			}
			sweepResDragUpdate(g, y);
			return;
		}
		// §20 P4b-1 pulse/filter LEVEL drag: on the first motion tick do the §20.2 shared
		// check (prompt + abort if undecided; the user drags again after choosing), else
		// take one all-tables undo snapshot, then rewrite the edited row's b2 every tick.
		if(sweepDragging) {
			Geo g = layout();
			if(!sweepMoved) {
				int ins = clampedIns();
				if(sweepProgramShared(sweepTable, ins) && !sweepDecided(sweepTable, ins)) {
					promptSweepFork(sweepTable, ins);
					sweepDragging = false; sweepTable = -1; sweepRow = -1;
					return;
				}
				snapshotAllTables(false); sweepMoved = true;
			}
			sweepLevelDragUpdate(g, y);
			return;
		}
		// §17.3 while a zoom button is held, keep its pressed style only while the pointer
		// stays on it — drag off and it un-presses (and the release will not fire it).
		if(pressedBtn >= 0) {
			Geo g = layout();
			pressedOver = (buttonAt(g, x, y) == pressedBtn);
			return;
		}
		// §17.4 dragging the scrollbar thumb pans the viewport (span kept, thumb follows
		// the grab point). Takes priority over plot selection; they never overlap (the
		// scrollbar drag only starts on the scroll row).
		if(scrollDragging) {
			Geo g = layout();
			double span = viewEndTick - viewStartTick;
			double ns = scrollTickForCell(g, x) - scrollGrabOffset;
			viewStartTick = ns;
			viewEndTick = ns + span;
			userZoomed = true;
			clampViewport();
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
		// §19 P4a end an ADSR-handle drag: make the new envelope audible once (if a note
		// is held) — never per drag tick. A plain click with no drag wrote nothing.
		if(adsrDragging) {
			adsrDragging = false;
			adsrHandle = -1;
			clickWasButton = false;
			if(adsrMoved) retriggerIfSounding();
			adsrMoved = false;
			return;
		}
		// §20 P4b-2 end a loop-marker drag: make the new loop audible once if a note is held.
		if(sweepLoopDragging) {
			sweepLoopDragging = false;
			sweepLoopTable = -1;
			sweepLoopCloseRow = -1;
			clickWasButton = false;
			if(sweepLoopMoved) retriggerIfSounding();
			sweepLoopMoved = false;
			return;
		}
		// §20 P4b-3 end a filter RESONANCE drag: make the new resonance audible once if a
		// note is held. A plain click (no motion) wrote nothing.
		if(sweepResDragging) {
			sweepResDragging = false;
			sweepResRow = -1;
			clickWasButton = false;
			if(sweepResMoved) retriggerIfSounding();
			sweepResMoved = false;
			return;
		}
		// §20 P4b-1 end a pulse/filter LEVEL drag: make the edited program audible once
		// (if a note is held) — never per drag tick. A plain click (no motion) wrote
		// nothing; it only left the §20 P4b-2 step selection set at press.
		if(sweepDragging) {
			sweepDragging = false;
			sweepTable = -1;
			sweepRow = -1;
			clickWasButton = false;
			if(sweepMoved) retriggerIfSounding();
			sweepMoved = false;
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
		// A press on a control button / the scrollbar consumes its paired release.
		if(clickWasButton) { clickWasButton = false; return; }
		if(!selecting) return;
		selecting = false;
		// §17.2 a plain click (no drag motion) clears the selection.
		if(!dragMoved) { hasSelection = false; return; }
	}

	override int keypress(Keyinfo key) {
		int ins = clampedIns();
		switch(key.raw) {
		// Move the parameter cursor.
		case SDLK_UP:
			if(paramCursor > 0) paramCursor--;
			return OK;
		case SDLK_DOWN:
			if(paramCursor < PARAM_ROWS - 1) paramCursor++;
			return OK;
		// §19 P4a Left/Right EDIT the selected value (decrement/increment); on the
		// pointer rows (nothing editable) or with Shift held they PAN the viewport
		// instead (view control moved off bare Left/Right). Letters/digits stay keyjam.
		case SDLK_LEFT:
			if(!(key.mods & KMOD_SHIFT) && isEditableRow(paramCursor)) editSelected(ins, -1);
			else panBy(-(viewEndTick - viewStartTick) / 4.0);
			return OK;
		case SDLK_RIGHT:
			if(!(key.mods & KMOD_SHIFT) && isEditableRow(paramCursor)) editSelected(ins, +1);
			else panBy((viewEndTick - viewStartTick) / 4.0);
			return OK;
		case SDLK_HOME:
			userZoomed = false; fitViewport();
			return OK;
		case SDLK_END:
			zoomToSelection();
			return OK;
		case SDLK_BACKSPACE:
			hasSelection = false;
			return OK;
		// §20 P4b-2 add / delete a sweep step (row-op) on the selected Pulse/Filter step.
		case SDLK_INSERT:
			if(selectedSweepTable >= 0) sweepRowOp(selectedSweepTable, true);
			else UI.statusline.display("Select a pulse/filter step first (click it).");
			return OK;
		case SDLK_DELETE:
			if(selectedSweepTable >= 0) sweepRowOp(selectedSweepTable, false);
			else UI.statusline.display("Select a pulse/filter step first (click it).");
			return OK;
		// Octave nudges (mirrors the classic keypad octave keys).
		case SDLK_KP_DIVIDE:
			if(state.octave > 0) state.octave--;
			return OK;
		case SDLK_KP_MULTIPLY:
			if(state.octave < 6) state.octave++;
			return OK;
		// Switch the instrument under view inline (shared activateInstrument keeps
		// the classic screen in sync when we leave).
		case SDLK_PLUS:
		case SDLK_KP_PLUS:
			UI.activateInstrument(state.activeInstrument + 1);
			clearSweepSelection();   // §20 P4b-2 row index is table-local to the old ins
			return OK;
		case SDLK_MINUS:
		case SDLK_KP_MINUS:
			UI.activateInstrument(state.activeInstrument - 1);
			clearSweepSelection();
			return OK;
		default:
			break;
		}
		// Everything else is a note key for the screen's own keyjam.
		inputKeyjam.keypress(key);
		return OK;
	}

	override int keyrelease(Keyinfo key) {
		inputKeyjam.keyrelease(key);
		return OK;
	}
}
