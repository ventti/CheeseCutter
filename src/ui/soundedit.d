/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Visual Sound Editor screen: a live, keyjam-driven view of the selected instrument (P1 skeleton).

This is the full-screen alternative sound-editing mode toggled from the classic
editor (Ctrl-E). Phase P1 provides the screen skeleton only: the framed chrome
(title, selected instrument number/name, current octave), a self-contained
keyjam so notes play while the panel is focused, and a live output oscilloscope
reusing ui.oscilloscope's sample->pixel trace. The ADSR curve, the wave/pulse/
filter timelines and any data editing arrive in later phases (P2+).
*/

module ui.soundedit;

import std.conv : to;
import std.string : format, stripRight;
import derelict.sdl2.sdl;
import com.session : screen, video, state, song;
import com.shortcuts : Ctx;
import ui.window;
import ui.input;
import ui.oscilloscope;
static import audio.player;

/// Full-screen visual Sound Editor (see module doc). P1: chrome + keyjam + scope.
class SoundEditor : Window {
	// Palette indices (mirroring ui.oscilloscope's language): white title,
	// yellow values, dim grey labels.
	private enum int COL_TITLE = 1;
	private enum int COL_VALUE = 7;
	private enum int COL_LABEL = 11;

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
		screen.cprint(area.x + 3, area.y + 5, COL_LABEL, 0,
					  "Live output waveform:");

		// The resulting-audio scope proves live audio data reaches this screen.
		scopeView.update();
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
