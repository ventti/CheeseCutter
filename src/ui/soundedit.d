/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Visual Sound Editor screen: a live, keyjam-driven view of the selected instrument (chrome, output scope, ADSR envelope curve with playhead).

This is the full-screen alternative sound-editing mode toggled from the classic
editor (Ctrl-E). P1 provided the screen skeleton: framed chrome (title, selected
instrument number/name, current octave), a self-contained keyjam so notes play
while the panel is focused, and a live output oscilloscope reusing
ui.oscilloscope's sample->pixel trace. P2 adds a read-only ADSR envelope curve
for the selected instrument, drawn with the com.fb immediate-mode overlay using
the real SID ms timing tables, plus a live playhead that rides the curve from the
jammed voice's envelope. The wave/pulse/filter timelines and any data editing
arrive in later phases (P3+).
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

/// Full-screen visual Sound Editor (see module doc). P1: chrome + keyjam + scope.
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
	private enum int COL_HEAD = 7;
	private enum int COL_HEADSTEM = 8;

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
		// Bottom portion of the screen: the live resulting waveform.
		int sh = area.height / 2;
		if(sh < 6) sh = 6;
		scopeView = new OscilloscopeWindow(
			Rectangle(area.x + 2, area.y + area.height - sh - 1,
					  sh, area.width - 4));
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
		screen.cprint(area.x + 3, area.y + 3, COL_LABEL, 0, "Octave:");
		screen.cprint(area.x + 15, area.y + 3, COL_VALUE, 0,
					  format("%d", state.octave));
		// Rebuild the overlay draw-list from scratch this frame (the ADSR curve +
		// playhead live here; the scope trace uses its own single slot).
		video.olClear();
		drawEnvelope(ins);

		// The resulting-audio scope proves live audio data reaches this screen
		// (it draws its own framed title).
		scopeView.update();
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

		// Panel geometry (character cells). Sits below the chrome, above the scope
		// in the top half of the screen.
		int px0 = area.x + 2;
		int py0 = area.y + 5;
		int pw  = area.width - 4;
		int ph  = area.height / 2 - 6;
		if(ph < 6) ph = 6;
		if(pw < 8) return;
		drawFrame(Rectangle(px0, py0, ph, pw));
		screen.cprint(px0 + 2, py0, COL_TITLE, 0, " ADSR Envelope ");
		// Segment values as hex nibbles + real ms, on the label row inside the top.
		screen.cprint(px0 + 2, py0 + 1, COL_LABEL, 0,
			format("A:%X (%gms)  D:%X (%gms)  S:%X (%d/15)  R:%X (%gms)",
				   attack, ATTACK_TIME_MS[attack], decay, DECAY_RELEASE_TIME_MS[decay],
				   sustain, sustain, release, DECAY_RELEASE_TIME_MS[release]));

		// Pixel drawing box (device pixels). Reserve the top two rows for the title
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
		int lv = -1;
		foreach(v; 0 .. 3) {
			if(audio.visualizer.getVoiceInstrument(v) == ins
			   && audio.visualizer.getVoiceBrightness(v) > 0.01f) { lv = v; break; }
		}
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
