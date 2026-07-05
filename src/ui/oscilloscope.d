/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Toggleable oscilloscope overlay drawing the combined synthesized audio waveform.

Unlike the modal help/export/render dialogs, this is a NON-modal overlay: it is
drawn on top of the editor each frame (via UI.drawScope) while keypresses keep
flowing to the sequencer, so playback controls and keyjam stay usable with the
scope open. It reads the mono reSID mix buffer (audio.audio.mixbuf) that carries
the combined output of all three voices -- the same signal sent to the sound
card during playback and keyjam (and kept running, muted, under remote backends).
*/

module ui.oscilloscope;

import std.algorithm : max, min;
import std.math : abs, lround;
import com.fb;
import com.session : screen, video;
import ui.window;
import ct.base;
import audio.player;
static import audio.audio;

/// Non-modal framed oscilloscope: the frame, title and zero axis are text
/// cells, but the waveform trace is drawn pixel-sharp — as a screen-pixel
/// polyline composited over the grid by the Video layer (see Video.setScopeTrace),
/// not stamped into character cells.
class OscilloscopeWindow : Window {
	// CP437 glyphs (the editor font is a CP437-style 8-bit charset).
	private enum ubyte GLYPH_MIDLINE = 196; // horizontal line, the zero axis
	// Colours (palette indices): bright green trace, dim grey axis / edge fade.
	private enum int COL_TRACE = 13;
	private enum int COL_AXIS = 11;
	private enum int COL_TITLE = 1;
	// Fixed vertical gain: this many sample units map to one half-window height.
	// reSID mixes to a full-scale S16 range but music rarely peaks there; this
	// keeps typical output filling the window while loud signals clip
	// (real-scope behaviour). Tuned by eye.
	private enum int FULLSCALE = 12000;
	// Base timespan (samples of audio spanned across the window width) before the
	// zoom offset is applied. Song playback shows ~1.3 PAL frames; a held keyjam
	// note gets a wider window by default so more of its cycles are visible.
	private enum int PLAY_SPAN = 1280;
	private enum int KEYJAM_SPAN = 4096;
	private enum int MIN_SPAN = 128;
	// Zoom offset shared by both modes: >0 widens the timespan (zoom out, span
	// doubled per step), <0 narrows it (zoom in). Clamped to this range; the
	// effective span is further clamped to the available buffer.
	private enum int ZOOM_MAX = 3, ZOOM_MIN = -3;
	private int zoomShift;

	// Reused per-frame trace buffer (one screen-pixel y per horizontal pixel), so
	// a live redraw doesn't allocate every frame.
	private int[] ys;

	// Keyjam capture-and-hold. During keyjam the scope freezes the struck note's
	// waveform and keeps showing it until another note is played (a bumped
	// audio.player.keyjamNoteTrigger) or playback/keyjam ends. A brief settle lets
	// the attack develop before the snapshot is frozen.
	private enum int SETTLE_FRAMES = 4;
	private int lastNoteTrigger;
	private int settleFrames;
	private bool held;
	private short[] heldSamples;

	this(Rectangle a) {
		super(a);
	}

	// Adjust the keyjam timebase: `dir` > 0 widens the window (zoom out, longer
	// timespan), `dir` < 0 narrows it (zoom in). Only affects the held keyjam
	// waveform; playback uses a fixed span.
	void zoom(int dir) {
		zoomShift += dir;
		if(zoomShift > ZOOM_MAX) zoomShift = ZOOM_MAX;
		if(zoomShift < ZOOM_MIN) zoomShift = ZOOM_MIN;
	}

	// Nominal keyjam timespan (samples) at the current zoom, for the status line.
	int nominalSpan() {
		int s = zoomShift >= 0 ? (KEYJAM_SPAN << zoomShift) : (KEYJAM_SPAN >> (-zoomShift));
		return s < MIN_SPAN ? MIN_SPAN : s;
	}

	override void update() {
		drawFrame(area);
		screen.cprint(area.x + 2, area.y, COL_TITLE, 0,
					  " Oscilloscope (combined) - Shift-F12 to close ");

		immutable int x0 = area.x + 1;
		immutable int innerW = area.width - 2;
		immutable int y0 = area.y + 1;
		immutable int innerH = area.height - 2;
		if(innerW < 1 || innerH < 1) { video.clearScopeTrace(); return; }
		immutable int mid = y0 + innerH / 2;

		// Zero axis (text cell); the pixel trace is drawn over it by the renderer.
		foreach(x; 0 .. innerW)
			screen.setChar(x0 + x, mid, cast(uint)((COL_AXIS << 8) | GLYPH_MIDLINE));

		// Pixel geometry: map the inner cell box to screen pixels. The trace's
		// zero sits at the vertical centre of the axis cell, and full scale spans
		// half the inner height.
		immutable int x0px = x0 * FONT_X;
		immutable int wpx = innerW * FONT_X;
		immutable int midYpx = mid * FONT_Y + FONT_Y / 2;
		immutable int halfHpx = (innerH / 2) * FONT_Y;
		if(wpx < 2) { video.clearScopeTrace(); return; }

		short* buf = audio.audio.mixbuf;
		int bufsize = audio.audio.getbufsize();
		// Nothing playing (or no buffer yet): the mix buffer holds stale samples,
		// so drop the trace and leave just the (grey) zero axis.
		if(buf is null || bufsize <= 0 || !audio.player.isPlaying()) {
			held = false;             // audio stopped: drop any held snapshot
			video.clearScopeTrace();
			return;
		}

		// Choose the sample source. Song playback: always the live mix buffer.
		// Keyjam: freeze the struck note's waveform and hold it (see fields above).
		short* src = buf;
		int srcsize = bufsize;
		if(audio.player.keyjamEnabled()) {
			int trig = audio.player.keyjamNoteTrigger;
			if(trig != lastNoteTrigger) {   // a new note was struck -> re-capture
				lastNoteTrigger = trig;
				held = false;
				settleFrames = SETTLE_FRAMES;
			}
			if(!held) {
				// Show the note live while its attack develops, then snapshot it.
				if(settleFrames > 0) settleFrames--;
				else {
					heldSamples.length = bufsize;
					heldSamples[] = buf[0 .. bufsize];
					held = true;
				}
			}
			if(held) { src = heldSamples.ptr; srcsize = cast(int)heldSamples.length; }
		}
		else {
			held = false;
			lastNoteTrigger = audio.player.keyjamNoteTrigger; // re-arm for later keyjam
		}

		// Timespan across the width. Playback uses a fixed span (zooming the live
		// combined mix isn't meaningful); keyjam holds one note, so it scales its
		// wider base by the zoom offset. Clamped to the available buffer.
		int span;
		if(audio.player.keyjamEnabled())
			span = zoomShift >= 0 ? (KEYJAM_SPAN << zoomShift) : (KEYJAM_SPAN >> (-zoomShift));
		else
			span = PLAY_SPAN;
		if(span < MIN_SPAN) span = MIN_SPAN;
		if(span > srcsize) span = srcsize;
		immutable float stride = wpx > 1 ? cast(float)(span - 1) / (wpx - 1) : 0.0f;

		ys.length = wpx;
		foreach(px; 0 .. wpx) {
			int idx = cast(int)(px * stride);
			if(idx >= srcsize) idx = srcsize - 1;
			int off = cast(int)lround(cast(real)src[idx] * halfHpx / FULLSCALE);
			off = max(-halfHpx, min(halfHpx, off));
			ys[px] = midYpx - off; // positive sample -> up (smaller y)
		}
		// Dim the outermost columns (a subtle scope-edge fade, palette COL_AXIS).
		immutable int edgeMargin = FONT_X;
		video.setScopeTrace(x0px, ys, COL_TRACE, COL_AXIS, edgeMargin);
	}
}
