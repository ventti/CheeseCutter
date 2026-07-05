/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Toggleable oscilloscope overlay: a live combined-output trace during song
playback, and a recorded-note waveform (Audition-style min/max envelope) during
keyjam.

Non-modal: drawn on top of the editor each frame (via UI.drawScope) while
keypresses keep flowing to the sequencer, so playback controls and keyjam stay
usable with the scope open. Playback reads the live reSID mix buffer
(audio.audio.mixbuf); keyjam reads the per-note recording (audio.audio.captureBuf)
that the audio callback fills from each note-on. Both traces and the zero axis are
drawn pixel-sharp by the Video layer (see Video.setScopeTrace / setScopeEnvelope),
not stamped into character cells.
*/

module ui.oscilloscope;

import std.algorithm : max, min;
import std.math : lround;
import com.fb;
import com.session : screen, video;
import ui.window;
import ct.base;
import audio.player;
static import audio.audio;

/// Non-modal framed oscilloscope (see module doc).
class OscilloscopeWindow : Window {
	// Colours (palette indices): bright green trace, dim grey axis, yellow gate.
	private enum int COL_TRACE = 13;
	private enum int COL_AXIS = 11;
	private enum int COL_GATE = 7;
	private enum int COL_TITLE = 1;
	// Fixed vertical gain: this many sample units map to one half-window height.
	// reSID mixes to a full-scale S16 range but music rarely peaks there; this
	// keeps typical output filling the window while loud signals clip.
	private enum int FULLSCALE = 12000;
	// Playback timespan: samples of the live mix shown across the width.
	private enum int PLAY_SPAN = 1280;
	private enum int MIN_VIEW = 128;
	// Keyjam time-zoom: 0 = fit the whole recorded note, each step halves the
	// visible window (zoom in, anchored at the note onset). Remembered for the
	// session. Clamped to [0, ZOOM_MAX].
	private enum int ZOOM_MAX = 8;
	private int zoomShift;

	// Reused per-frame buffers, so a live redraw doesn't allocate every frame.
	private int[] ys;              // playback polyline (one y per pixel column)
	private int[] lo, hi;          // keyjam envelope min/max y per column
	private ubyte[] gate;          // keyjam gate bit per column

	this(Rectangle a) {
		super(a);
	}

	// Keyjam time-zoom: dir > 0 zooms in (shorter window, more detail), dir < 0
	// zooms out toward the whole note. Playback is unaffected (fixed span).
	void zoom(int dir) {
		zoomShift += dir;
		if(zoomShift > ZOOM_MAX) zoomShift = ZOOM_MAX;
		if(zoomShift < 0) zoomShift = 0;
	}

	// Current keyjam zoom factor (1 = whole note), for the status line.
	int zoomFactor() { return 1 << zoomShift; }

	override void update() {
		drawFrame(area);

		immutable int x0 = area.x + 1;
		immutable int innerW = area.width - 2;
		immutable int y0 = area.y + 1;
		immutable int innerH = area.height - 2;
		if(innerW < 1 || innerH < 1) { video.clearScopeTrace(); return; }
		immutable int mid = y0 + innerH / 2;

		immutable bool keyjam = audio.player.keyjamEnabled();
		screen.cprint(area.x + 2, area.y, COL_TITLE, 0,
			keyjam ? " Keyjam waveform - Alt-Up/Down zoom, Shift-F12 close "
				   : " Oscilloscope (combined) - Shift-F12 to close ");

		// Pixel geometry: the inner cell box mapped to screen pixels. Zero sits at
		// the vertical centre; full scale spans half the inner height.
		immutable int x0px = x0 * FONT_X;
		immutable int wpx = innerW * FONT_X;
		immutable int y0px = y0 * FONT_Y;
		immutable int midYpx = mid * FONT_Y + FONT_Y / 2;
		immutable int halfHpx = (innerH / 2) * FONT_Y;
		if(wpx < 2) { video.clearScopeTrace(); return; }

		if(keyjam) drawKeyjam(x0px, wpx, y0px, midYpx, halfHpx);
		else drawPlayback(x0px, wpx, midYpx, halfHpx);
	}

	// Sample value -> vertical pixel offset from the centre (clamped/clipped).
	private int offOf(int v, int halfHpx) {
		int off = cast(int)lround(cast(real)v * halfHpx / FULLSCALE);
		return max(-halfHpx, min(halfHpx, off));
	}

	// Live combined-output oscilloscope (song playback).
	private void drawPlayback(int x0px, int wpx, int midYpx, int halfHpx) {
		short* buf = audio.audio.mixbuf;
		int bufsize = audio.audio.getbufsize();
		if(buf is null || bufsize <= 0 || !audio.player.isPlaying()) {
			video.clearScopeTrace();
			return;
		}
		int span = PLAY_SPAN;
		if(span > bufsize) span = bufsize;
		immutable float stride = wpx > 1 ? cast(float)(span - 1) / (wpx - 1) : 0.0f;
		ys.length = wpx;
		foreach(px; 0 .. wpx) {
			int idx = cast(int)(px * stride);
			if(idx >= bufsize) idx = bufsize - 1;
			ys[px] = midYpx - offOf(buf[idx], halfHpx);
		}
		video.setScopeTrace(x0px, midYpx, ys, COL_TRACE, COL_AXIS, FONT_X);
	}

	// Recorded-note waveform (keyjam): a min/max amplitude envelope over the
	// captured note, auto-fit to the width (zoomable), with a gate on/off bar.
	private void drawKeyjam(int x0px, int wpx, int y0px, int midYpx, int halfHpx) {
		int total = audio.audio.captureLen;
		int frameSamples = audio.audio.captureFrameSamples;
		if(total < 2 || frameSamples <= 0) { video.clearScopeTrace(); return; }
		short* buf = audio.audio.captureBuf.ptr;
		ubyte[] cgate = audio.audio.captureGate;

		// Visible window: whole note at zoom 0, halved per zoom step (anchored at
		// the onset). Clamped to the recorded length.
		int view = total >> zoomShift;
		if(view < MIN_VIEW) view = MIN_VIEW;
		if(view > total) view = total;
		immutable double sPerCol = cast(double)view / wpx;

		lo.length = wpx; hi.length = wpx; gate.length = wpx;
		foreach(px; 0 .. wpx) {
			int s0 = cast(int)(px * sPerCol);
			int s1 = cast(int)((px + 1) * sPerCol);
			if(s1 <= s0) s1 = s0 + 1;
			if(s1 > total) s1 = total;
			int mn = short.max, mx = short.min;
			for(int s = s0; s < s1; s++) {
				int v = buf[s];
				if(v < mn) mn = v;
				if(v > mx) mx = v;
			}
			if(s0 >= s1) { mn = 0; mx = 0; }
			hi[px] = midYpx - offOf(mx, halfHpx);   // max -> top (smaller y)
			lo[px] = midYpx - offOf(mn, halfHpx);   // min -> bottom
			int gidx = ((s0 + s1) / 2) / frameSamples;
			gate[px] = (gidx < cast(int)cgate.length && cgate[gidx]) ? cast(ubyte)1 : cast(ubyte)0;
		}
		video.setScopeEnvelope(x0px, midYpx, y0px, lo, hi, gate, COL_TRACE, COL_AXIS, COL_GATE);
	}
}
