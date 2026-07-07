/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Visual Sound Editor screen: a live, keyjam-driven view of the selected instrument laid out as a left parameter column, a stack of time-aligned graph bands sharing one frames-from-note-on X axis (output waveform, ADSR, pulse, filter, wave/arp) with a single vertical playhead, and a raw-hex table strip along the bottom.

This is the full-screen alternative sound-editing mode toggled from the classic
editor (Ctrl-E). It runs keyjam (notes play) but uses the *normal* background,
not the dark-blue keyjam tint. The v2 layout (design doc §7) stacks every
time-varying graph on ONE shared horizontal axis = frames since note-on
(~19.95 ms PAL ticks): the output/keyjam waveform (min/max per frame from
audio.audio.captureBuf), the ADSR envelope (SID ms tables converted to frames),
and the pulse / filter / wave-arp table programs (simulated read-only from the
ct.base byte tables the C64 player interprets each frame). All bands share the
same left edge and pixel width so a single full-height vertical playhead, placed
at the current frame-since-trigger of the sounding voice, crosses them all in
lockstep. Left of the graphs a parameter column lists the instrument's editable
fields with a movable cursor (display-only this pass); the bottom strip shows the
raw hex of the instrument's 8 bytes plus the wave/pulse/filter rows it points
into. Everything is READ-ONLY -- data editing / write-back / undo arrive in P4+.
*/

module ui.soundedit;

import std.conv : to;
import std.string : format, stripRight;
import std.algorithm : max, min;
import std.math : lround;
import derelict.sdl2.sdl;
import com.fb : FONT_X, FONT_Y, keyjamBackground;
import com.session : screen, video, state, song;
import com.shortcuts : Ctx;
import ui.window;
import ui.input;
import ui.ui : UI;
static import audio.player;
static import audio.audio;
static import audio.visualizer;

// PAL player tick period (ms) -- the frame quantum every over-time graph shares.
private enum float FRAME_MS = 19.95f;
// Visible frames across the shared X axis (~2.5 s at PAL).
private enum int VISIBLE_FRAMES = 128;
// Vertical gain for the output-waveform band (sample units per half-band height);
// mirrors ui.oscilloscope's FULLSCALE so typical output fills the band.
private enum int FULLSCALE = 12000;

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
	int loopFrame = -1; // frame index the program loops back to (-1 = none)
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

	// Left parameter column: fixed set of rows, cursor moved with Up/Down.
	// Display-only this pass (no byte writes).
	private enum int PARAM_ROWS = 11;
	private int paramCursor;

	// Per-voice frame-since-trigger counter (drives the shared playhead) and the
	// previous gate bit used to detect a retrigger (gate 0->1).
	private int[3] frameSinceTrigger = 0;
	private bool[3] prevGate = false;

	// The screen owns its own keyjam so note keys play while the panel is
	// focused and navigating (the classic editor's global inputKeyjam is
	// bypassed for this window by the Toplevel routing guard).
	private InputKeyjam inputKeyjam;

	this(Rectangle a) {
		super(a);
		inputKeyjam = new InputKeyjam();
	}

	override @property string contextId() { return Ctx.soundEditor; }

	// ---- shared geometry (recomputed each frame from `area`) ----
	private struct Geo {
		int paramX, paramW;     // left parameter column (cells)
		int sepX;               // vertical separator column (cells)
		int labelX;             // band label gutter start (cells)
		int plotX0px, plotWpx;  // shared pixel X origin + width for every band
		int stackTopPx, stackBotPx;
		int[6] bandTopPx;       // 5 bands + trailing bottom bound
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

		// Five bands: output, adsr, pulse, filter, wave (thin). Weights sum ~4.6.
		immutable float[5] wgt = [1.0f, 1.0f, 1.0f, 1.0f, 0.55f];
		float tot = 0; foreach(w; wgt) tot += w;
		float acc = 0;
		int span = g.stackBotPx - g.stackTopPx;
		g.bandTopPx[0] = g.stackTopPx;
		foreach(i; 0 .. 5) {
			acc += wgt[i];
			g.bandTopPx[i + 1] = g.stackTopPx + cast(int)lround(acc / tot * span);
		}
		return g;
	}

	private int xForFrame(ref Geo g, int f) {
		if(f < 0) f = 0;
		if(f > VISIBLE_FRAMES) f = VISIBLE_FRAMES;
		return g.plotX0px + f * g.plotWpx / VISIBLE_FRAMES;
	}

	override void update() {
		// v2: keep note routing but never the blue keyjam tint on this screen.
		keyjamBackground = false;
		// We drive our own overlay each frame; make sure no stale single-slot scope
		// trace lingers underneath the bands.
		video.clearScopeTrace();

		drawFrame(area);

		int ins = state.activeInstrument;
		if(ins < 0) ins = 0;
		if(ins > 47) ins = 47;
		string name = stripRight(to!string(song.insLabels[ins][]));

		screen.cprint(area.x + 2, area.y, COL_TITLE, 0,
					  " Sound Editor - Ctrl-E exit - jam keys - +/- instrument - Up/Down param ");
		screen.cprint(area.x + 2, area.y + 1, COL_LABEL, 0, "Instrument");
		screen.cprint(area.x + 13, area.y + 1, COL_VALUE, 0,
					  format("%02X %s", ins, name));
		screen.cprint(area.x + 40, area.y + 1, COL_LABEL, 0, "Octave");
		screen.cprint(area.x + 47, area.y + 1, COL_VALUE, 0, format("%d", state.octave));

		Geo g = layout();

		// Advance the per-voice frame-since-trigger counters (gate 0->1 = retrigger).
		foreach(v; 0 .. 3) {
			bool gate = (audio.audio.sidreg[4 + v * 7] & 1) != 0;
			if(gate && !prevGate[v]) frameSinceTrigger[v] = 0;
			else if(frameSinceTrigger[v] < 1_000_000) frameSinceTrigger[v]++;
			prevGate[v] = gate;
		}

		// Vertical separator between the param column and the graph stack.
		for(int y = area.y + 2; y <= g.rawTopRow - 1; y++)
			screen.setChar(g.sepX, y, 0x0500 | 216);

		// Rebuild the overlay draw-list from scratch (all bands + the playhead).
		video.olClear();

		drawParamColumn(ins, g);

		// Stacked, frame-aligned graph bands (top -> bottom).
		drawBandLabel(g, 0, "Output");
		drawOutputBand(g);
		drawBandLabel(g, 1, "ADSR");
		drawAdsrBand(ins, g);
		drawBandLabel(g, 2, "Pulse");
		drawPulseBand(ins, g);
		drawBandLabel(g, 3, "Filter");
		drawFilterBand(ins, g);
		drawBandLabel(g, 4, "Wave");
		drawWaveBand(ins, g);

		// One full-height playhead across every band, at the sounding voice's
		// current frame-since-trigger.
		int pv = findVoiceFor(ins);
		if(pv >= 0) {
			int px = xForFrame(g, frameSinceTrigger[pv]);
			video.olVLine(px, g.stackTopPx, g.stackBotPx, COL_HEAD);
		}

		drawRawData(ins, g);
	}

	// Find a voice currently sounding instrument `ins` (for playhead placement);
	// -1 if none.
	private int findVoiceFor(int ins) {
		foreach(v; 0 .. 3) {
			if(audio.visualizer.getVoiceInstrument(v) == ins
			   && audio.visualizer.getVoiceBrightness(v) > 0.01f) return v;
		}
		return -1;
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

		string rstStr = (rst & 0xc0) == 0x80 ? "hard"
			: ((rst & 0xc0) == 0x40 ? "soft" : "3fr");

		// 6-char text bar for a 0..15 nibble.
		static string nibbleBar(int n) {
			int fill = n * 6 / 15;
			char[6] b = '.';
			foreach(k; 0 .. 6) if(k < fill) b[k] = '#';
			return cast(string)b.dup;
		}

		string[PARAM_ROWS] labels = [
			"Attack", "Decay", "Sustain", "Release", "Waveform", "Wave ptr",
			"Pulse ptr", "Filter ptr", "HardRst", "HR wave", "HR SR"
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
		vals[8]  = format("$%02X %s", rst, rstStr);
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

	private void drawBandLabel(ref Geo g, int band, string label) {
		int row = g.bandTopPx[band] / FONT_Y;
		screen.cprint(g.labelX, row, COL_LABEL, 0, label);
		// Faint baseline axis at the band's bottom.
		int botPx = g.bandTopPx[band + 1] - 2;
		video.olHLine(g.plotX0px, g.plotX0px + g.plotWpx - 1, botPx, COL_AXIS);
	}

	private void bandBox(ref Geo g, int band, out int topPx, out int botPx) {
		topPx = g.bandTopPx[band] + 2;
		botPx = g.bandTopPx[band + 1] - 3;
		if(botPx <= topPx) botPx = topPx + 1;
	}

	// ---- output/keyjam waveform band (min/max per frame from captureBuf) ----

	private void drawOutputBand(ref Geo g) {
		int topPx, botPx; bandBox(g, 0, topPx, botPx);
		int mid = (topPx + botPx) / 2;
		int half = (botPx - topPx) / 2;
		if(half < 1) return;

		int total = audio.audio.captureLen;
		int fs = audio.audio.captureFrameSamples;
		short* buf = audio.audio.captureBuf.ptr;
		bool haveCapture = (total >= 2 && fs > 0 && buf !is null);

		foreach(px; 0 .. g.plotWpx) {
			int f = px * VISIBLE_FRAMES / g.plotWpx;
			if(!haveCapture) {
				video.olPoint(g.plotX0px + px, mid, COL_TRACE);
				continue;
			}
			int s0 = f * fs;
			int s1 = s0 + fs;
			if(s0 >= total) { video.olPoint(g.plotX0px + px, mid, COL_TRACE); continue; }
			if(s1 > total) s1 = total;
			int mn = short.max, mx = short.min;
			for(int s = s0; s < s1; s++) {
				int v = buf[s];
				if(v < mn) mn = v;
				if(v > mx) mx = v;
			}
			int yhi = mid - clampOff(mx, half);   // max -> up
			int ylo = mid - clampOff(mn, half);   // min -> down
			video.olVLine(g.plotX0px + px, ylo, yhi, COL_TRACE);
		}
	}

	private int clampOff(int v, int half) {
		int off = cast(int)lround(cast(real)v * half / FULLSCALE);
		return max(-half, min(half, off));
	}

	// ---- ADSR band (SID ms tables -> frame axis, nominal gate hold) ----

	private void drawAdsrBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 1, topPx, botPx);
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		ubyte sr = song.instrumentTable[ins + 1 * 48];
		int attack  = (ad >> 4) & 0x0f, decay = ad & 0x0f;
		int sustain = (sr >> 4) & 0x0f, release = sr & 0x0f;
		float sLvl = sustain / 15.0f;
		float aF = ATTACK_TIME_MS[attack]         / FRAME_MS;
		float dF = DECAY_RELEASE_TIME_MS[decay]   / FRAME_MS;
		float rF = DECAY_RELEASE_TIME_MS[release] / FRAME_MS;
		if(rF < 1) rF = 1;
		float relStart = VISIBLE_FRAMES - rF;
		if(relStart < aF + dF) relStart = aF + dF;

		float amp(float f) {
			if(f < aF) return aF > 0 ? f / aF : 1.0f;
			f -= aF;
			if(f < dF) return dF > 0 ? 1.0f - (1.0f - sLvl) * (f / dF) : sLvl;
			float fromStart = aF + dF + f;
			if(fromStart < relStart) return sLvl;
			float rt = (fromStart - relStart) / rF;
			return clamp01(sLvl * (1.0f - rt));
		}

		int prevY = -1;
		foreach(px; 0 .. g.plotWpx) {
			float f = cast(float)px * VISIBLE_FRAMES / g.plotWpx;
			int y = botPx - cast(int)lround(clamp01(amp(f)) * (botPx - topPx));
			int x = g.plotX0px + px;
			if(prevY >= 0) video.olLine(x - 1, prevY, x, y, COL_CURVE);
			else video.olPoint(x, y, COL_CURVE);
			prevY = y;
		}
	}

	// ---- pulse / filter bands (sweep sims on the frame axis) ----

	private void drawSweepBand(ref SweepSim s, int maxVal, int fillCol, int lineCol,
			int topPx, int botPx, ref Geo g) {
		int len = cast(int)s.val.length;
		if(len <= 0 || maxVal <= 0) return;
		int n = min(len, VISIBLE_FRAMES);
		foreach(f; 0 .. n) {
			int v = s.val[f];
			if(v < 0) v = 0; if(v > maxVal) v = maxVal;
			int y = botPx - v * (botPx - topPx) / maxVal;
			int xa = xForFrame(g, f);
			int xb = xForFrame(g, f + 1);
			if(xb <= xa) xb = xa + 1;
			for(int x = xa; x < xb; x++) {
				video.olVLine(x, botPx, y, fillCol);
				video.olPoint(x, y, lineCol);
			}
		}
		if(s.loopFrame >= 0 && s.loopFrame < VISIBLE_FRAMES)
			video.olVLine(xForFrame(g, s.loopFrame), topPx, botPx, COL_LOOP);
	}

	private void drawPulseBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 2, topPx, botPx);
		int ptr = song.instrumentTable[ins + 5 * 48];
		if(ptr >= 0x80) return;               // direct fixed pulse: no program
		SweepSim s = simPulse(ptr);
		drawSweepBand(s, 4095, COL_PULSE_FILL, COL_PULSE_LINE, topPx, botPx, g);
	}

	private void drawFilterBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 3, topPx, botPx);
		int ptr = song.instrumentTable[ins + 4 * 48];
		if(ptr <= 0) return;
		SweepSim s = simFilter(ptr);
		drawSweepBand(s, 2047, COL_FILT_FILL, COL_FILT_LINE, topPx, botPx, g);
	}

	// ---- wave/arp thin band (one colored step per frame) ----

	private void drawWaveBand(int ins, ref Geo g) {
		int topPx, botPx; bandBox(g, 4, topPx, botPx);
		int ptr = song.instrumentTable[ins + 7 * 48];
		WaveSim w = simWave(ptr);
		int N = cast(int)w.cells.length;
		if(N <= 0) return;
		int vph = findVoiceFor(ins);
		int actRow = vph >= 0 ? audio.visualizer.getActiveWaveRow(vph) : -1;
		int steps = min(N, VISIBLE_FRAMES);
		foreach(i; 0 .. steps) {
			WaveCell c = w.cells[i];
			int xa = xForFrame(g, i);
			int xb = xForFrame(g, i + 1);
			if(xb <= xa + 1) xb = xa + 1;
			int col = waveformColor(c.ctrl);
			video.olFillRect(xa, topPx, max(1, xb - xa - 1), botPx - topPx, col);
			// gate/sync/ring ticks along the very top of the lane.
			if(c.ctrl & 0x01) video.olHLine(xa, xb - 1, topPx,     13);
			if(c.ctrl & 0x02) video.olHLine(xa, xb - 1, topPx + 1, 14);
			if(c.ctrl & 0x04) video.olHLine(xa, xb - 1, topPx + 2, 10);
			if(actRow >= 0 && c.row == actRow)
				video.olRect(xa, topPx, max(1, xb - xa), botPx - topPx, COL_HEAD);
		}
		if(w.loopIndex >= 0 && w.loopIndex < VISIBLE_FRAMES)
			video.olVLine(xForFrame(g, w.loopIndex), topPx, botPx, COL_LOOP);
	}

	// Colour a wave/arp cell by its control byte's waveform bits.
	private int waveformColor(int ctrl) {
		if(ctrl == 0) return 8;                     // leave waveform unchanged (dim)
		if(ctrl <= 0x0f) return 12;                 // wave-delay override (grey)
		if(ctrl >= 0xe0 && ctrl <= 0xef) return 8;  // raw control, no waveform
		if(ctrl & 0x80) return 11;                  // noise (grey)
		if(ctrl & 0x40) return 7;                   // pulse (yellow)
		if(ctrl & 0x20) return 5;                   // saw (green)
		if(ctrl & 0x10) return 3;                   // triangle (cyan)
		return 8;
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
		enum int MAXF = VISIBLE_FRAMES;
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
			if(visited[nextRow]) { s.loopFrame = firstFrame[nextRow]; break; }
			visited[nextRow] = true;
			row = nextRow;
		}
		return s;
	}

	// Simulate the filter cutoff program starting at row `startRow`.
	private SweepSim simFilter(int startRow) {
		SweepSim s;
		enum int MAXF = VISIBLE_FRAMES;
		if(startRow <= 0 || startRow >= 0x40) return s;
		int cutoff = 0;
		int row = startRow;
		bool[0x40] visited;
		int[0x40] firstFrame; firstFrame[] = -1;
		visited[row] = true;
		while(s.val.length < MAXF) {
			int base = row * 4;
			ubyte b0 = song.filterTable[base + 0];
			ubyte b1 = song.filterTable[base + 1];
			ubyte b2 = song.filterTable[base + 2];
			ubyte b3 = song.filterTable[base + 3];
			if(firstFrame[row] < 0) firstFrame[row] = cast(int)s.val.length;
			if(b0 & 0x80) {
				if(b2 != 0xff) cutoff = (b2 << 3);
				s.val ~= cutoff; s.rowOf ~= row;
			}
			else {
				if(b2 != 0xff) cutoff = (b2 << 3);
				int n = b0 & 0x7f;
				int delta = 2 * (b1 < 0x80 ? b1 : b1 - 0x100);
				s.val ~= cutoff; s.rowOf ~= row;
				foreach(f; 0 .. n) {
					cutoff += delta;
					if(cutoff < 0) cutoff = 0;
					if(cutoff > 2047) cutoff = 2047;
					s.val ~= cutoff; s.rowOf ~= row;
					if(s.val.length >= MAXF) break;
				}
			}
			int nextRow;
			if(b3 == 0) nextRow = (row + 1) & 0x3f;
			else if(b3 == 0x7f) { s.stops = true; break; }
			else if(b3 <= 0x3f) nextRow = b3;
			else { s.stops = true; break; }
			if(visited[nextRow]) { s.loopFrame = firstFrame[nextRow]; break; }
			visited[nextRow] = true;
			row = nextRow;
		}
		return s;
	}

	// Walk the wave/arp program starting at row `startRow`.
	private WaveSim simWave(int startRow) {
		WaveSim w;
		enum int MAXR = VISIBLE_FRAMES;
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
