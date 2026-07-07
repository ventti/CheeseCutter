/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Visual Sound Editor screen: a live, keyjam-driven view of the selected instrument laid out as a left parameter column, a stack of time-aligned graph bands sharing one frames-from-note-on X axis (pixel-perfect output waveform, ADSR envelope, a frequency/arp pitch band, pulse, a filter band coloured per frame by filter type with a resonance-over-time overlay, and a stacked SID control-bit-lane wave view) with a restart pre-roll, a note-trigger divider and a single vertical playhead, a raw-hex table strip along the bottom, and a context F12 help page.

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
fields with a movable cursor (display-only this pass); the bottom strip shows the
raw hex of the instrument's 8 bytes plus the wave/pulse/filter rows it points
into. Everything is READ-ONLY -- data editing / write-back / undo arrive in P4+.
*/

module ui.soundedit;

import std.conv : to;
import std.string : format, stripRight;
import std.algorithm : max, min;
import std.math : lround, log2;
import derelict.sdl2.sdl;
import com.fb : FONT_X, FONT_Y, keyjamBackground;
import com.session : screen, video, state, song, mainui;
import com.shortcuts : Ctx;
import ui.window;
import ui.input;
import ui.ui : UI;
import ui.menubar : MenuBar;
import ui.palette : CommandPalette;
import ui.help;
static import audio.player;
static import audio.audio;
static import audio.visualizer;

// PAL player tick period (ms) -- the frame quantum every over-time graph shares.
private enum float FRAME_MS = 19.95f;
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
// Nominal note gate length (frames the gate is held before release) used to slope
// the drawn ADSR sustain->release knee on the shared frame axis.
private enum int NOMINAL_GATE_FRAMES = 46;

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
class SoundEditor : Window {
	// Palette indices (mirroring ui.oscilloscope's language): white title,
	// yellow values, dim grey labels.
	private enum int COL_TITLE = 1;
	private enum int COL_VALUE = 7;
	private enum int COL_LABEL = 11;
	private enum int COL_SEP   = 11;    // separators / band frames (dim grey)
	private enum int COL_CURVE = 13;    // ADSR curve (green)
	private enum int COL_AXIS  = 11;    // baseline axis (dim grey)
	private enum int COL_HEAD  = 1;     // playhead (white)
	private enum int COL_LOOP  = 8;     // loop/jump marker (orange)
	private enum int COL_TRACE = 13;    // output waveform (green)
	private enum int COL_PULSE_FILL = 6;  // blue area
	private enum int COL_PULSE_LINE = 14; // light-blue top edge
	private enum int COL_FILT_FILL  = 4;  // purple area
	private enum int COL_FILT_LINE  = 10; // light-red top edge
	private enum int COL_TRIGGER = 2;   // note-trigger divider (red)
	private enum int COL_RESTART = 3;   // §13.4 restart-phase marker (cyan; distinct
	                                    // from the red trigger + white playhead)
	private enum int COL_RSTFILL = 9;   // restart pre-roll shading (brown, dim)
	private enum int COL_RSTCURVE = 10; // restart envelope ramp (light-red)
	private enum int COL_RES = 7;       // §10.2 resonance-over-time overlay (yellow)
	private enum int COL_FREQ_REL = 13; // §10.3 relative transpose step (light-green)
	private enum int COL_FREQ_ABS = 3;  // §10.3 absolute-tuning step (cyan)
		// §11 recording view: dim colours for the idle table-sim preview + loop lines.
		private enum int COL_LOOPLINE = 11; // §11.3 subtle loop-boundary line (darkgray)
		// §11.2 dimmed idle-preview: line + fill both use the darkest gradient (navy) so
		// they read as a muted preview AND sit *below* the darkgray loop lines, which
		// therefore stay visible over the dimmed sim too.
		private enum int COL_DIM      = 16;
		private enum int COL_DIMFILL  = 16;

	// §10.1 filter cutoff fill/line colour per active mode (b0 & 0x70), C64 palette
	// indices in the standard order. -1 = no mode (filter off -> empty band).
	private static int filterModeColor(int mode) {
		switch(mode & 0x70) {
			case 0x10: return 2;   // LP        -> red
			case 0x20: return 5;   // BP        -> green
			case 0x40: return 14;  // HP        -> light-blue
			case 0x30: return 8;   // LP+BP     -> orange
			case 0x60: return 3;   // BP+HP     -> cyan
			case 0x50: return 4;   // LP+HP     -> purple
			case 0x70: return 12;  // LP+HP+BP  -> gray
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
	private static immutable int[8]    BITLANE_COL = [13, 14, 8, 4, 3, 5, 7, 15];
	private static immutable string[8] BITLANE_LBL = ["Gate","Sync","Ring","Test","Tri","Saw","Pulse","Noise"];

	// Left parameter column: fixed set of rows, cursor moved with Up/Down.
	// Display-only this pass (no byte writes).
	private enum int PARAM_ROWS = 11;
	private int paramCursor;

	// §11.2 the voice whose real recording feeds the bands this frame (-1 = none),
	// and whether that voice actually has a recording (else the bands fall back to
	// the dimmed table simulation). Recomputed at the top of update().
	private int viewVoice = -1;
	private bool useRec = false;

	// §12 dynamic X window, computed ONCE per draw at the top of update() and threaded
	// through xForFrame + every band so they all share the exact same zoom. visFrames
	// = the auto-fitted post-trigger span (frames); totalFrames = pre-roll + visFrames.
	private int visFrames = MIN_VIS;
	private int totalFrames = RESTART_FRAMES + MIN_VIS;

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
		int stackBotRow = g.rawTopRow - 1;
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
		int aF = cast(int)lround(ATTACK_TIME_MS[attack]         / FRAME_MS);
		int dF = cast(int)lround(DECAY_RELEASE_TIME_MS[decay]   / FRAME_MS);
		int rF = cast(int)lround(DECAY_RELEASE_TIME_MS[release] / FRAME_MS);
		int vf = aF + dF + NOMINAL_GATE_FRAMES + rF;

		// Recorded extent overrides the estimate when we have real audio.
		if(useRec) {
			int rl = audio.visualizer.getRecordingLength(viewVoice);
			int ampEnd = audio.visualizer.getRecordedAmpEnd(viewVoice, AMP_EPS);
			if(ampEnd > 0 && ampEnd < rl)
				vf = ampEnd;            // note ENDED: the actual end wins over the table
			else
				vf = max(vf, rl);       // still sounding: grow the window to fit
		}

		if(vf < MIN_VIS) vf = MIN_VIS;
		if(vf > MAX_VIS) vf = MAX_VIS;
		return vf;
	}

	// §9.1/§12.2 THE one true frame->pixel map every band shares, now over the DYNAMIC
	// window [-RESTART_FRAMES, visFrames] (dynamic frames-per-pixel = zoom). Frame f may
	// be negative (pre-roll / restart); f=0 is the note-trigger divider.
	private int xForFrame(ref Geo g, int f) {
		int rel = f + RESTART_FRAMES;
		if(rel < 0) rel = 0;
		if(rel > totalFrames) rel = totalFrames;
		return g.plotX0px + rel * g.plotWpx / totalFrames;
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

		// §12.2 unobtrusive scale label so the current zoom is legible.
		float secs = visFrames * FRAME_MS / 1000.0f;
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

		int ins = state.activeInstrument;
		if(ins < 0) ins = 0;
		if(ins > 47) ins = 47;

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
		totalFrames = RESTART_FRAMES + visFrames;

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

		// §13.4 restart marker: a vertical line at the START of the restart phase
		// (frame -restartFrames, the actual hard/soft/3-frame restart length for this
		// instrument's col2 type), in a colour DISTINCT from the red trigger divider
		// (frame 0) and the white playhead — so the short trigger<->restart interval
		// is visible. Drawn before the trigger so the (brighter) trigger wins on any
		// pixel overlap at extreme zoom.
		int restF = restartFramesFor(ins);
		video.olVLine(xForFrame(g, -restF), g.stackTopPx, g.stackBotPx, COL_RESTART);

		// §9.2 note-trigger divider at frame 0 across ALL bands: everything left of it
		// is the restart pre-roll, everything right of it is the same frame index in
		// every band.
		video.olVLine(xForFrame(g, 0), g.stackTopPx, g.stackBotPx, COL_TRIGGER);

		// §11.2 one full-height playhead = the recording's current record head. It
		// advances right as the recording grows during a live note and freezes at the
		// end once the note has finished. Only shown when a recording is driving the
		// bands (the idle sim preview has no record head).
		if(useRec) {
			int rh = audio.visualizer.getRecordingLength(viewVoice);
			if(rh > visFrames) rh = visFrames;
			video.olVLine(xForFrame(g, rh), g.stackTopPx, g.stackBotPx, COL_HEAD);
		}
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
		foreach(f; 0 .. n) {
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

	// ---- left parameter column (display-only, movable cursor) ----

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
		// restart; the low nibble is the gate-on / arp delay.
		string rstStr = (rst & 0xc0) == 0x80 ? "hard"
			: ((rst & 0xc0) == 0x40 ? "soft" : "3fr");
		int gateOn = rst & 0x0f;

		// 6-char text bar for a 0..15 nibble.
		static string nibbleBar(int n) {
			int fill = n * 6 / 15;
			char[6] b = '.';
			foreach(k; 0 .. 6) if(k < fill) b[k] = '#';
			return cast(string)b.dup;
		}

		string[PARAM_ROWS] labels = [
			"Attack", "Decay", "Sustain", "Release", "Waveform", "Wave ptr",
			"Pulse ptr", "Filter ptr", "Restart", "HR wave", "HR SR"
		];
		string[PARAM_ROWS] vals;
		vals[0]  = format("%X %s", attack,  nibbleBar(attack));
		vals[1]  = format("%X %s", decay,   nibbleBar(decay));
		vals[2]  = format("%X %s", sustain, nibbleBar(sustain));
		vals[3]  = format("%X %s", release, nibbleBar(release));
		vals[4]  = waveformName(firstCtrl);
		vals[5]  = format("$%02X", wpt);
		vals[6]  = ppt >= 0x80 ? format("fix $%03X", (ppt & 0x0f) << 8) : format("$%02X", ppt);
		vals[7]  = fpt == 0 ? "off" : format("$%02X", fpt);
		vals[8]  = format("$%02X %s g%X", rst, rstStr, gateOn);
		vals[9]  = format("$%02X", hrw);
		vals[10] = format("$%02X", hsr);

		int y0 = area.y + 3;
		immutable int valX = g.paramX + 12;
		immutable int valMax = g.sepX - valX;   // chars available before separator
		screen.cprint(g.paramX, area.y + 2, COL_LABEL, 0, "Parameters");
		foreach(i; 0 .. PARAM_ROWS) {
			int y = y0 + i;
			bool sel = (i == paramCursor);
			int lc = sel ? COL_TITLE : COL_LABEL;
			int vc = sel ? COL_TITLE : COL_VALUE;
			screen.cprint(g.paramX, y, lc, 0, sel ? ">" : " ");
			screen.cprint(g.paramX + 1, y, lc, 0, labels[i]);
			string v = vals[i];
			if(v.length > valMax) v = v[0 .. valMax];
			screen.cprint(valX, y, vc, 0, v);
		}
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

		// Note region in absolute pixels: [noteX0px, plotEndPx).
		int noteX0px = xForFrame(g, 0);
		int plotEndPx = g.plotX0px + g.plotWpx;
		int noteWpx = plotEndPx - noteX0px;
		if(noteWpx < 1) return;

		// Sample source is the per-note recording only (never the live mixbuf).
		short* buf = audio.audio.captureBuf.ptr;
		int total = audio.audio.captureLen;
		int fs = audio.audio.captureFrameSamples;
		// Spread the visible note span (visFrames frames) across noteWpx, clamped
		// to what was actually recorded.
		int span = fs > 0 ? visFrames * fs : total;
		if(span > total) span = total;
		if(buf is null || span < 2) {
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
		int peak = 0;
		foreach(s; 0 .. span) {
			int a = buf[s]; if(a < 0) a = -a;
			if(a > peak) peak = a;
		}
		if(peak < 1) {
			video.olHLine(noteX0px, plotEndPx - 1, mid, COL_AXIS);
			return;
		}

		// Per-pixel min/max: column px covers samples [s0,s1). This is exactly the
		// classic oscilloscope's per-pixel approach, but mapped onto the note region.
		foreach(i; 0 .. noteWpx) {
			int s0 = cast(int)(cast(long)i * span / noteWpx);
			int s1 = cast(int)(cast(long)(i + 1) * span / noteWpx);
			if(s1 <= s0) s1 = s0 + 1;
			if(s1 > span) s1 = span;
			int mn = short.max, mx = short.min;
			for(int s = s0; s < s1; s++) {
				int v = buf[s];
				if(v < mn) mn = v;
				if(v > mx) mx = v;
			}
			int x = noteX0px + i;
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
			// AUTO-GAIN to the window's PEAK amplitude: a note that only reaches a
			// fraction of full envelope (e.g. a briefly-held 8s-attack triangle whose
			// recorded amp peaks well below 1.0) otherwise draws as a shallow line
			// hugging the baseline that reads as empty/flat — inconsistent with the
			// (also peak-normalised) Output band, which visibly grows. Normalising the
			// peak to full band height makes the RISING shape clear and keeps the two
			// amplitude bands consistent. Below AMP_EPS the note is silent -> no gain.
			float peak = 0;
			foreach(f; 0 .. n) if(amp[f] > peak) peak = amp[f];
			float gain = peak > AMP_EPS ? 1.0f / peak : 1.0f;
			int prevY = -1;
			foreach(f; 0 .. n) {
				int y = botPx - cast(int)lround(clamp01(amp[f] * gain) * h);
				int xa = xForFrame(g, f);
				int xb = xForFrame(g, f + 1);
				if(xb <= xa) xb = xa + 1;
				video.olHLine(xa, xb - 1, y, COL_CURVE);
				if(prevY >= 0 && prevY != y)
					video.olVLine(xa, min(prevY, y), max(prevY, y), COL_CURVE);
				prevY = y;
			}
			return;
		}

		ubyte ad = song.instrumentTable[ins + 0 * 48];
		ubyte sr = song.instrumentTable[ins + 1 * 48];
		int attack  = (ad >> 4) & 0x0f, decay = ad & 0x0f;
		int sustain = (sr >> 4) & 0x0f, release = sr & 0x0f;
		float sLvl = sustain / 15.0f;
		// SID ms tables -> frames (real, non-linear MOS timing). The knee frames are
		// absolute frame indices, so they line up in time with pulse/filter/wave.
		float aF = ATTACK_TIME_MS[attack]         / FRAME_MS;
		float dF = DECAY_RELEASE_TIME_MS[decay]   / FRAME_MS;
		float rF = DECAY_RELEASE_TIME_MS[release] / FRAME_MS;
		if(rF < 0.5f) rF = 0.5f;
		// Nominal gate: release begins NOMINAL_GATE_FRAMES after the trigger (but never
		// before attack+decay have completed), so all four A/D/S/R phases are visible.
		float gateEnd = aF + dF + NOMINAL_GATE_FRAMES;

		// Amplitude 0..1 at absolute frame f (f>=0, i.e. after the trigger).
		float amp(float f) {
			if(f < aF) return aF > 0 ? f / aF : 1.0f;             // attack ramp -> 1.0
			if(f < aF + dF) return dF > 0 ? 1.0f - (1.0f - sLvl) * ((f - aF) / dF) : sLvl;
			if(f < gateEnd) return sLvl;                          // sustain hold
			float rt = (f - gateEnd) / rF;                        // release
			return clamp01(sLvl * (1.0f - rt));
		}

		// §9.2 restart pre-roll (frames -RESTART_FRAMES..0), shaded distinctly, showing
		// the hard/soft/3-frame restart forced by col2 using HR SR (col6) + HR wave
		// (col3) before the note. It's a display of "the envelope was being killed",
		// not a cycle-exact sim.
		ubyte rst = song.instrumentTable[ins + 2 * 48];
		int preX0 = xForFrame(g, -RESTART_FRAMES);
		int preX1 = xForFrame(g, 0);
		if(preX1 > preX0) {
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

		// Note envelope: one point per horizontal pixel across the note region, mapped
		// pixel->frame through the SAME axis so its knees align with the other bands.
		int noteX0px = xForFrame(g, 0);
		int plotEndPx = g.plotX0px + g.plotWpx;
		int prevY = -1;
		for(int x = noteX0px; x < plotEndPx; x++) {
			float f = cast(float)(x - g.plotX0px) * totalFrames / g.plotWpx - RESTART_FRAMES;
			if(f < 0) f = 0;
			int y = botPx - cast(int)lround(clamp01(amp(f)) * h);
			// §11.2 sim = dimmed idle preview.
			if(prevY >= 0) video.olLine(x - 1, prevY, x, y, COL_DIM);
			else video.olPoint(x, y, COL_DIM);
			prevY = y;
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
			drawValueBand(audio.visualizer.getRecordedPulse(viewVoice), 4095,
				COL_PULSE_FILL, COL_PULSE_LINE, topPx, botPx, g);
		} else if(ptr < 0x80) {               // direct fixed pulse ($80+) = no program
			drawValueBand(s.val, 4095, COL_DIMFILL, COL_DIM, topPx, botPx, g);
		}
		drawLoopLines(g, topPx, botPx, s.loopFrame, s.loopPeriod,
			min(cast(int)s.val.length, visFrames));
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

		// Cutoff fill + top line, coloured by the mode active on each frame. A "filter
		// off" frame (mode 0x00 -> col < 0) leaves that column empty; dim uses grey.
		foreach(f; 0 .. n) {
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
		foreach(f; 0 .. n) {
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

		// §11.3 subtle loop-boundary lines (from the sim's period, in both paths).
		drawLoopLines(g, topPx, botPx, s.loopFrame, s.loopPeriod,
			min(cast(int)s.val.length, visFrames));

		// Label the resonance overlay in the band's left gutter (row below "Filter").
		int lrow = g.bandTopPx[4] / FONT_Y + 1;
		if(lrow < g.bandTopPx[5] / FONT_Y)
			screen.cprint(g.labelX, lrow, rescol, 0, "res");
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
			foreach(f; 0 .. n) {
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
			drawLoopLines(g, topPx, botPx, s.loopFrame, s.loopPeriod, n);
			return;
		}

		// Idle dimmed sim: the wave-table transpose/arp program (semitones), floor at
		// 12 semitones (one octave) so small arps stay visible.
		int n = min(cast(int)s.transOf.length, visFrames);
		if(n <= 0) return;
		int scale = 12;
		foreach(f; 0 .. n) if(s.transOf[f] > scale) scale = s.transOf[f];
		int prevY = -1;
		foreach(f; 0 .. n) {
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

		foreach(f; 0 .. n) {
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
		// §11.3 subtle loop-boundary lines (from the sim's period, in both paths).
		drawLoopLines(g, topPx, botPx, s.loopFrame, s.loopPeriod,
			min(cast(int)s.ctrlOf.length, visFrames));
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
		int row = startRow;
		bool[0x40] visited;
		int[0x40] firstFrame; firstFrame[] = -1;
		visited[row] = true;
		// Emit one frame at the current cutoff carrying the persisting mode/res/routing.
		void emit() {
			s.val ~= cutoff; s.rowOf ~= row;
			s.modeOf ~= mode; s.resOf ~= res; s.routeOf ~= routing;
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

	override int keypress(Keyinfo key) {
		switch(key.raw) {
		// Move the parameter cursor (display-only this pass; no byte writes).
		case SDLK_UP:
			if(paramCursor > 0) paramCursor--;
			return OK;
		case SDLK_DOWN:
			if(paramCursor < PARAM_ROWS - 1) paramCursor++;
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
			return OK;
		case SDLK_MINUS:
		case SDLK_KP_MINUS:
			UI.activateInstrument(state.activeInstrument - 1);
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
