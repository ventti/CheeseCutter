/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Visual Sound Editor screen: a live, keyjam-driven view of the selected instrument (chrome, output scope, ADSR curve, and per-tick pulse/filter/wave-arp timelines with playheads).

This is the full-screen alternative sound-editing mode toggled from the classic
editor (Ctrl-E). P1 provided the screen skeleton: framed chrome (title, selected
instrument number/name, current octave), a self-contained keyjam so notes play
while the panel is focused, and a live output oscilloscope reusing
ui.oscilloscope's sample->pixel trace. P2 added a read-only ADSR envelope curve
for the selected instrument, drawn with the com.fb immediate-mode overlay using
the real SID ms timing tables, plus a live playhead that rides the curve from the
jammed voice's envelope. P3 adds the per-tick TABLE TIMELINES for the selected
instrument -- pulse-width-over-time, filter-cutoff-over-time and the wave/arp
lane -- simulated read-only from the exact ct.base byte tables the C64 player
interprets each frame, with loop/jump markers and realtime playheads driven from
audio.visualizer's active table rows. All read-only; data editing arrives in P4+.
*/

module ui.soundedit;

import std.conv : to;
import std.string : format, stripRight;
import std.algorithm : max, min;
import std.math : lround;
import derelict.sdl2.sdl;
import com.fb : FONT_X, FONT_Y;
import com.session : screen, video, state, song;
import com.shortcuts : Ctx;
import ui.window;
import ui.input;
import ui.ui : UI;
import ui.oscilloscope;
static import audio.player;
static import audio.audio;
static import audio.visualizer;

// SID ADSR timing (ms) per 4-bit nibble value 0..15 — the real, non-linear MOS
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

/// Full-screen visual Sound Editor (see module doc). P3: chrome + keyjam + scope
/// + ADSR curve + pulse/filter/wave-arp per-tick timelines, all read-only.
class SoundEditor : Window {
	// Palette indices (mirroring ui.oscilloscope's language): white title,
	// yellow values, dim grey labels.
	private enum int COL_TITLE = 1;
	private enum int COL_VALUE = 7;
	private enum int COL_LABEL = 11;
	// Envelope panel colours: green curve, dim-grey axis, yellow playhead marker,
	// dim playhead stem.
	private enum int COL_CURVE = 13;
	private enum int COL_AXIS = 11;
	private enum int COL_HEAD = 1;      // playhead / active-row highlight (white)
	private enum int COL_HEADSTEM = 8;
	private enum int COL_LOOP = 8;      // loop/jump marker (orange)
	// Timeline graph colours.
	private enum int COL_PULSE_FILL = 6;  // blue area
	private enum int COL_PULSE_LINE = 14; // light-blue top edge
	private enum int COL_FILT_FILL  = 4;  // purple area
	private enum int COL_FILT_LINE  = 10; // light-red top edge

	// Previous per-voice brightness, so we can tell attack (rising) from decay
	// (falling) when placing the playhead along the ADSR curve.
	private float[3] prevBright = 0.0f;

	// The screen owns its own keyjam so note keys play while the panel is
	// focused and navigating (the classic editor's global inputKeyjam is
	// bypassed for this window by the Toplevel routing guard).
	private InputKeyjam inputKeyjam;
	// Live output scope, reused wholesale from the classic editor overlay: it
	// draws its own frame + trace via video.setScopeTrace each frame.
	private OscilloscopeWindow scopeView;

	this(Rectangle a) {
		super(a);
		inputKeyjam = new InputKeyjam();
		// Top-right band: the live resulting waveform (ADSR curve sits top-left,
		// the three timelines stack full-width below).
		scopeView = new OscilloscopeWindow(
			Rectangle(area.x + 56, area.y + 4, 11, area.width - 58));
	}

	override @property string contextId() { return Ctx.soundEditor; }

	override void update() {
		drawFrame(area);

		int ins = state.activeInstrument;
		if(ins < 0) ins = 0;
		if(ins > 47) ins = 47;
		string name = stripRight(to!string(song.insLabels[ins][]));

		screen.cprint(area.x + 2, area.y, COL_TITLE, 0,
					  " Sound Editor - Ctrl-E to exit, jam with the keyboard ");
		screen.cprint(area.x + 3, area.y + 2, COL_LABEL, 0, "Instrument:");
		screen.cprint(area.x + 15, area.y + 2, COL_VALUE, 0,
					  format("%02X  %s", ins, name));
		screen.cprint(area.x + 30, area.y + 2, COL_LABEL, 0, "Octave:");
		screen.cprint(area.x + 38, area.y + 2, COL_VALUE, 0,
					  format("%d", state.octave));

		// Rebuild the overlay draw-list from scratch this frame (every graph +
		// playhead lives here; the scope trace uses its own single slot).
		video.olClear();
		drawEnvelope(ins);

		// The resulting-audio scope proves live audio data reaches this screen
		// (it draws its own framed title).
		scopeView.update();

		// P3: the three per-tick table timelines, stacked full-width below the top
		// band. Full content width, ~8 rows each.
		int tx = area.x + 1;
		int tw = area.width - 3;
		drawPulseTimeline(ins, tx, area.y + 16, tw, 8);
		drawFilterTimeline(ins, tx, area.y + 24, tw, 8);
		drawWaveLane(ins, tx, area.y + 32, tw, 8);
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

	// Draw the classic A->D->S->R envelope polyline for instrument `ins` in a
	// dedicated framed panel, using the real SID ms timing tables for the segment
	// slopes, plus a live playhead that rides the curve from the jammed voice.
	// Read-only: never writes song data.
	private void drawEnvelope(int ins) {
		// Instrument ADSR nibbles (column-major table: col0 AD, col1 SR).
		ubyte ad = song.instrumentTable[ins + 0 * 48];
		ubyte sr = song.instrumentTable[ins + 1 * 48];
		int attack  = (ad >> 4) & 0x0f;
		int decay   =  ad       & 0x0f;
		int sustain = (sr >> 4) & 0x0f;
		int release =  sr       & 0x0f;

		// Panel geometry (character cells): top-left band, beside the scope.
		int px0 = area.x + 1;
		int py0 = area.y + 4;
		int pw  = 54;
		int ph  = 11;
		if(pw < 8) return;
		drawFrame(Rectangle(px0, py0, ph, pw));
		screen.cprint(px0 + 2, py0, COL_TITLE, 0, " ADSR Envelope ");
		// Segment values as hex nibbles + real ms, on the label row inside the top.
		screen.cprint(px0 + 2, py0 + 1, COL_LABEL, 0,
			format("A:%X D:%X S:%X R:%X", attack, decay, sustain, release));
		screen.cprint(px0 + 2, py0 + 2, COL_LABEL, 0,
			format("%gms %gms lvl%d/15 %gms",
				   ATTACK_TIME_MS[attack], DECAY_RELEASE_TIME_MS[decay],
				   sustain, DECAY_RELEASE_TIME_MS[release]));

		// Pixel drawing box (device pixels). Reserve the top rows for the title
		// + value labels so the curve never draws over the text.
		immutable int ix0 = (px0 + 1) * FONT_X;
		immutable int iw  = (pw - 2) * FONT_X;
		immutable int iyTop = (py0 + 3) * FONT_Y;
		immutable int iyBot = (py0 + ph - 1) * FONT_Y - 2;
		if(iw < 8 || iyBot <= iyTop) return;

		int ampToY(float a) {
			if(a < 0) a = 0; if(a > 1) a = 1;
			return iyBot - cast(int)lround(a * (iyBot - iyTop));
		}

		immutable float sLvl = sustain / 15.0f;
		// Fixed sustain-hold width; the remaining width is shared among A/D/R in
		// proportion to their real ms so the whole curve fills the panel and the
		// slopes stay honest relative to one another.
		int sustainW = iw / 5;
		if(sustainW < 4) sustainW = 4;
		int availW = iw - sustainW;
		if(availW < 3) availW = 3;
		float aMs = ATTACK_TIME_MS[attack];
		float dMs = DECAY_RELEASE_TIME_MS[decay];
		float rMs = DECAY_RELEASE_TIME_MS[release];
		float totMs = aMs + dMs + rMs;
		if(totMs <= 0) totMs = 1;
		int aW = max(1, cast(int)lround(aMs / totMs * availW));
		int dW = max(1, cast(int)lround(dMs / totMs * availW));
		int rW = availW - aW - dW;
		if(rW < 1) rW = 1;

		immutable int x0 = ix0;
		immutable int x1 = x0 + aW;          // attack peak
		immutable int x2 = x1 + dW;          // decay -> sustain knee
		immutable int x3 = x2 + sustainW;    // end of sustain hold
		immutable int x4 = x3 + rW;          // release -> zero
		immutable int yZero = ampToY(0);
		immutable int yPeak = ampToY(1);
		immutable int yS    = ampToY(sLvl);

		// Zero (baseline) axis, then the envelope polyline.
		video.olHLine(x0, x4, yZero, COL_AXIS);
		video.olLine(x0, yZero, x1, yPeak, COL_CURVE);   // attack
		video.olLine(x1, yPeak, x2, yS,    COL_CURVE);   // decay
		video.olLine(x2, yS,    x3, yS,    COL_CURVE);   // sustain
		video.olLine(x3, yS,    x4, yZero, COL_CURVE);   // release

		// Live playhead: find a voice playing this instrument, ride the curve at
		// its current envelope amplitude (brightness). Phase (attack/decay/sustain/
		// release) is disambiguated by gate state + brightness direction.
		int lv = findVoiceFor(ins);
		foreach(v; 0 .. 3) {
			float b = audio.visualizer.getVoiceBrightness(v);
			// remember for next-frame direction; done after use below for lv
			if(v != lv) prevBright[v] = b;
		}
		if(lv >= 0) {
			float amp = audio.visualizer.getVoiceBrightness(lv);
			if(amp < 0) amp = 0; if(amp > 1) amp = 1;
			bool gate = (audio.audio.sidreg[4 + lv * 7] & 1) != 0;
			float dir = amp - prevBright[lv];
			prevBright[lv] = amp;
			int phx;
			if(!gate) {
				// Release: amp falls sLvl -> 0 along x3..x4.
				float t = sLvl > 0 ? (sLvl - amp) / sLvl : 1.0f;
				phx = x3 + cast(int)lround(clamp01(t) * (x4 - x3));
			}
			else if(dir > 0.002f && amp < 0.999f) {
				// Attack: amp rises 0 -> 1 along x0..x1.
				phx = x0 + cast(int)lround(clamp01(amp) * (x1 - x0));
			}
			else if(dir < -0.002f && amp > sLvl + 0.02f) {
				// Decay: amp falls 1 -> sLvl along x1..x2.
				float span = 1.0f - sLvl;
				float t = span > 0 ? (1.0f - amp) / span : 1.0f;
				phx = x1 + cast(int)lround(clamp01(t) * (x2 - x1));
			}
			else {
				// Sustain hold.
				phx = x2 + (x3 - x2) / 2;
			}
			int phy = ampToY(amp);
			video.olVLine(phx, yPeak, yZero, COL_HEADSTEM);
			video.olFillRect(phx - 2, phy - 2, 5, 5, COL_HEAD);
		}
	}

	// ---- P3 timeline simulators (read-only; mirror src/c64/player_v4.acme) ----

	// Simulate the pulse-width program starting at table row `startRow`.
	// pulstab is 4 bytes/row: b0 duration|dir (bit7 subtract, low7 frames),
	// b1 add magnitude, b2 initial 12-bit PW (nibbles swapped, $FF=keep),
	// b3 jump ($00 next / $7F stop / <=$3F row). PW delta = +/- b1 per frame.
	private SweepSim simPulse(int startRow) {
		SweepSim s;
		enum int MAXF = 128;
		if(startRow < 0 || startRow >= 0x40) return s;
		int pw = 0x800;              // fallback initial PW (mid) until a row sets it
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
			int n = (b0 & 0x7f) + 1; // step applies the add on load frame + low7 more
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
	// Sweep row (b0 bit7 clear): b0 frames, b1 signed add (11-bit delta = 2*b1),
	// b2 initial cutoff-hi (<<3, $FF=keep). Config row (b0 bit7 set): sets mode
	// + $d417; instantaneous. b3 jump as pulse. Cutoff is 11-bit 0..2047 global.
	private SweepSim simFilter(int startRow) {
		SweepSim s;
		enum int MAXF = 128;
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
				// Filter-type/config row: instantaneous (holds one frame here so the
				// row still occupies the timeline and can carry a playhead).
				if(b2 != 0xff) cutoff = (b2 << 3);
				s.val ~= cutoff; s.rowOf ~= row;
			}
			else {
				if(b2 != 0xff) cutoff = (b2 << 3);
				int n = b0 & 0x7f;
				int delta = 2 * (b1 < 0x80 ? b1 : b1 - 0x100);
				s.val ~= cutoff; s.rowOf ~= row;   // load frame holds init, no add
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

	// Walk the wave/arp program starting at row `startRow`, collecting one cell
	// per step until a marker or a revisit. wave1 markers: $7F jump (target in
	// wave2), $7E loop-to-previous/end.
	private WaveSim simWave(int startRow) {
		WaveSim w;
		enum int MAXR = 64;
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

	// ---- P3 timeline drawing ----

	// Shared area/line graph for a sweep program, plus loop marker + a playhead
	// that outlines the active table row's frame span.
	private void drawSweepGraph(ref SweepSim s, int maxVal,
			int px0, int py0, int pw, int ph, int fillCol, int lineCol, int activeRow) {
		immutable int ix0 = (px0 + 1) * FONT_X;
		immutable int iw  = (pw - 2) * FONT_X;
		immutable int iyTop = (py0 + 2) * FONT_Y;
		immutable int iyBot = (py0 + ph - 1) * FONT_Y - 2;
		if(iw < 4 || iyBot <= iyTop || maxVal <= 0) return;
		video.olHLine(ix0, ix0 + iw - 1, iyBot, COL_AXIS);
		int N = cast(int)s.val.length;
		if(N <= 0) return;
		foreach(px; 0 .. iw) {
			int f = px * N / iw;
			if(f >= N) f = N - 1;
			int v = s.val[f];
			if(v < 0) v = 0; if(v > maxVal) v = maxVal;
			int y = iyBot - v * (iyBot - iyTop) / maxVal;
			video.olVLine(ix0 + px, iyBot, y, fillCol);
			video.olPoint(ix0 + px, y, lineCol);
		}
		if(s.loopFrame >= 0 && s.loopFrame < N) {
			int lx = ix0 + s.loopFrame * iw / N;
			video.olVLine(lx, iyTop, iyBot, COL_LOOP);
		}
		if(activeRow >= 0) {
			int fa = -1, fb = -1;
			foreach(i; 0 .. N) if(s.rowOf[i] == activeRow) { if(fa < 0) fa = i; fb = i; }
			if(fa >= 0) {
				int xa = ix0 + fa * iw / N;
				int xb = ix0 + (fb + 1) * iw / N;
				if(xb <= xa) xb = xa + 1;
				video.olRect(xa, iyTop, xb - xa, iyBot - iyTop, COL_HEAD);
			}
		}
	}

	private void drawPulseTimeline(int ins, int px0, int py0, int pw, int ph) {
		drawFrame(Rectangle(px0, py0, ph, pw));
		screen.cprint(px0 + 2, py0, COL_TITLE, 0, " Pulse Width (0-4095) ");
		int ptr = song.instrumentTable[ins + 5 * 48];
		if(ptr >= 0x80) {
			screen.cprint(px0 + 2, py0 + 1, COL_LABEL, 0,
				format("direct fixed pulse $%03X - no pulse program", (ptr & 0x0f) << 8));
			return;
		}
		SweepSim s = simPulse(ptr);
		screen.cprint(px0 + 2, py0 + 1, COL_LABEL, 0,
			format("start row $%02X   %d frames   %s", ptr, cast(int)s.val.length,
				   s.loopFrame >= 0 ? "loops" : (s.stops ? "stops" : "runs")));
		int v = findVoiceFor(ins);
		int actRow = v >= 0 ? audio.visualizer.getActivePulseRow(v) : -1;
		drawSweepGraph(s, 4095, px0, py0, pw, ph, COL_PULSE_FILL, COL_PULSE_LINE, actRow);
	}

	private void drawFilterTimeline(int ins, int px0, int py0, int pw, int ph) {
		drawFrame(Rectangle(px0, py0, ph, pw));
		screen.cprint(px0 + 2, py0, COL_TITLE, 0, " Filter Cutoff (0-2047, global) ");
		int ptr = song.instrumentTable[ins + 4 * 48];

		// Live filter routing/resonance/mode annotation from the SID regs.
		ubyte r17 = audio.audio.sidreg[0x17];
		ubyte r18 = audio.audio.sidreg[0x18];
		int res = r17 >> 4;
		int route = r17 & 0x0f;
		string routeStr;
		if(route & 1) routeStr ~= "1";
		if(route & 2) routeStr ~= "2";
		if(route & 4) routeStr ~= "3";
		if(route & 8) routeStr ~= "X";
		if(routeStr.length == 0) routeStr = "-";
		string modeStr;
		if(r18 & 0x10) modeStr ~= "LP";
		if(r18 & 0x20) modeStr ~= "BP";
		if(r18 & 0x40) modeStr ~= "HP";
		if(modeStr.length == 0) modeStr = "off";

		if(ptr <= 0) {
			screen.cprint(px0 + 2, py0 + 1, COL_LABEL, 0,
				format("instrument sets no filter program   live: Res%X Route:%s Mode:%s",
					   res, routeStr, modeStr));
			return;
		}
		SweepSim s = simFilter(ptr);
		screen.cprint(px0 + 2, py0 + 1, COL_LABEL, 0,
			format("start $%02X  %d frames  %s   live: Res%X Route:%s Mode:%s (shared)",
				   ptr, cast(int)s.val.length,
				   s.loopFrame >= 0 ? "loops" : (s.stops ? "stops" : "runs"),
				   res, routeStr, modeStr));
		int actRow = audio.visualizer.getActiveFilterRow();
		drawSweepGraph(s, 2047, px0, py0, pw, ph, COL_FILT_FILL, COL_FILT_LINE, actRow);
	}

	// Map a wave1 transpose byte to a note-lane offset (relative semitones or
	// absolute note number) for the step graph.
	private static int waveNoteOffset(int transpose) {
		if(transpose <= 0x5f) return transpose;              // relative +semitones
		if(transpose >= 0x80 && transpose <= 0xdf) return transpose & 0x7f; // absolute note
		return 0;
	}

	// Colour a wave/arp cell by its control byte's waveform bits.
	private int waveformColor(int ctrl) {
		if(ctrl == 0) return COL_HEADSTEM;          // leave waveform unchanged (dim)
		if(ctrl <= 0x0f) return 12;                 // wave-delay override (grey)
		if(ctrl >= 0xe0 && ctrl <= 0xef) return COL_HEADSTEM; // raw control, no waveform
		if(ctrl & 0x80) return 11;                  // noise (grey)
		if(ctrl & 0x40) return 7;                   // pulse (yellow)
		if(ctrl & 0x20) return 5;                   // saw (green)
		if(ctrl & 0x10) return 3;                   // triangle (cyan)
		return COL_HEADSTEM;
	}

	private void drawWaveLane(int ins, int px0, int py0, int pw, int ph) {
		drawFrame(Rectangle(px0, py0, ph, pw));
		screen.cprint(px0 + 2, py0, COL_TITLE, 0, " Wave / Arp Lane (waveform + note step) ");
		int ptr = song.instrumentTable[ins + 7 * 48];
		WaveSim w = simWave(ptr);
		string loopInfo = w.loopIndex < 0 ? "no loop"
			: (w.loopTargetRow == -2 ? "loop prev" : format("jump $%02X", w.loopTargetRow));
		screen.cprint(px0 + 2, py0 + 1, COL_LABEL, 0,
			format("start row $%02X   %d steps   %s", ptr, cast(int)w.cells.length, loopInfo));

		immutable int ix0 = (px0 + 1) * FONT_X;
		immutable int iw  = (pw - 2) * FONT_X;
		immutable int iyTop = (py0 + 2) * FONT_Y;
		immutable int iyBot = (py0 + ph - 1) * FONT_Y - 2;
		int N = cast(int)w.cells.length;
		if(N <= 0 || iw < 4 || iyBot <= iyTop) return;

		int waveBandBot = iyTop + (iyBot - iyTop) * 55 / 100;
		int noteBandTop = waveBandBot + 2;

		// Scale the note step graph to the largest offset present.
		int maxNote = 12;
		foreach(c; w.cells) {
			int off = waveNoteOffset(c.transpose);
			if(off > maxNote) maxNote = off;
		}

		int vph = findVoiceFor(ins);
		int actRow = vph >= 0 ? audio.visualizer.getActiveWaveRow(vph) : -1;

		foreach(i; 0 .. N) {
			WaveCell c = w.cells[i];
			int xa = ix0 + i * iw / N;
			int xb = ix0 + (i + 1) * iw / N;
			int cw = max(1, xb - xa);
			// Waveform colour block.
			int col = waveformColor(c.ctrl);
			video.olFillRect(xa + 1, iyTop + 3, max(1, cw - 1), waveBandBot - iyTop - 3, col);
			// Control-bit markers along the very top (gate/sync/ring).
			if(c.ctrl & 0x01) video.olHLine(xa + 1, xb - 1, iyTop,     13); // gate (green)
			if(c.ctrl & 0x02) video.olHLine(xa + 1, xb - 1, iyTop + 1, 14); // sync
			if(c.ctrl & 0x04) video.olHLine(xa + 1, xb - 1, iyTop + 2, 10); // ring
			// Note step: relative in light-blue, absolute in yellow.
			int off = waveNoteOffset(c.transpose);
			int ny = iyBot - off * (iyBot - noteBandTop) / max(1, maxNote);
			video.olHLine(xa, xb - 1, ny, c.transpose >= 0x80 ? 7 : 14);
			// Playhead: outline the active wave row's cell.
			if(actRow >= 0 && c.row == actRow)
				video.olRect(xa, iyTop, cw, iyBot - iyTop, COL_HEAD);
		}

		if(w.loopIndex >= 0) {
			int lx = ix0 + w.loopIndex * iw / N;
			if(lx >= ix0 + iw) lx = ix0 + iw - 1;
			video.olVLine(lx, iyTop, iyBot, COL_LOOP);
		}
	}

	override int keypress(Keyinfo key) {
		// Octave nudges stay usable inside the screen (mirrors the classic
		// editor's keypad octave keys) so jamming spans the whole range.
		switch(key.raw) {
		case SDLK_KP_DIVIDE:
			if(state.octave > 0) state.octave--;
			return OK;
		case SDLK_KP_MULTIPLY:
			if(state.octave < 6) state.octave++;
			return OK;
		// Switch the instrument under view inline (mirrors the classic editor's
		// instrument-table +/-). Routes through the shared activateInstrument so
		// the classic screen stays in sync when we leave.
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
