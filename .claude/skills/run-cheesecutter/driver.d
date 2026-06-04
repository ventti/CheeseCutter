/*
 * ccdriver — headless driver for the CheeseCutter-Extended editor.
 *
 * Builds the real editor UI (SDL2 under the "dummy" video driver, which still
 * software-renders to a readable framebuffer), then runs a sequence of
 * commands passed as argv so an agent can drive the editor without a window:
 *
 *   load:<file.ct>    load a song
 *   key:<spec>        inject a keypress; spec = [Ctrl-][Alt-][Shift-]NAME
 *                     NAME = F1..F12, ESC, RET, SPACE, TAB, UP/DOWN/LEFT/RIGHT,
 *                     HOME, END, PGUP, PGDN, or a single char (a, 2, ...)
 *   ff:<n>            advance playback n frames (calls audio_frame directly;
 *                     deterministic — no audio device needed)
 *   frames:<n>        render n UI frames
 *   shot:<file.bmp>   write a screenshot (BMP) of the current screen
 *   state             print editor state to stderr (title/seqs/playing/...)
 *
 * Example:
 *   SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccdriver \
 *     load:tunes/vent-arkijuusto.ct key:F2 ff:50 shot:/tmp/play.bmp state
 *
 * This is module `main` (it provides the `main` ModuleInfo the editor modules
 * import) and links against every object except src/main.o — see the
 * `ccdriver` target in Makefile.mac.
 */
module main;

import derelict.sdl2.sdl;
import com.fb, com.session, com.kbd, com.util, ct.base;
import ui.ui, ui.input, seq.sequencer;
import audio.player;
static import audio.callback;
import std.stdio, std.conv, std.string;
import std.algorithm.searching : startsWith, findSplit;

private int keyName(string n) {
	switch(n.toUpper) {
		case "ESC": return SDLK_ESCAPE;
		case "RET", "RETURN", "ENTER": return SDLK_RETURN;
		case "SPACE": return SDLK_SPACE;
		case "TAB": return SDLK_TAB;
		case "UP": return SDLK_UP;
		case "DOWN": return SDLK_DOWN;
		case "LEFT": return SDLK_LEFT;
		case "RIGHT": return SDLK_RIGHT;
		case "HOME": return SDLK_HOME;
		case "END": return SDLK_END;
		case "PGUP": return SDLK_PAGEUP;
		case "PGDN": return SDLK_PAGEDOWN;
		case "F1": return SDLK_F1; case "F2": return SDLK_F2; case "F3": return SDLK_F3;
		case "F4": return SDLK_F4; case "F5": return SDLK_F5; case "F6": return SDLK_F6;
		case "F7": return SDLK_F7; case "F8": return SDLK_F8; case "F9": return SDLK_F9;
		case "F10": return SDLK_F10; case "F11": return SDLK_F11; case "F12": return SDLK_F12;
		default:
			if(n.length == 1) return cast(int)(n[0]);   // SDLK_a..z / 0..9 == ASCII
			throw new Exception("unknown key: " ~ n);
	}
}

private void press(string spec) {
	int mods = 0;
	for(;;) {
		if(spec.startsWith("Ctrl-"))  { mods |= KMOD_LCTRL;  spec = spec[5..$]; }
		else if(spec.startsWith("Alt-"))   { mods |= KMOD_LALT;   spec = spec[4..$]; }
		else if(spec.startsWith("Shift-")) { mods |= KMOD_LSHIFT; spec = spec[6..$]; }
		else break;
	}
	int sym = keyName(spec);
	int uni = (sym >= 0 && sym <= 127) ? sym : 0;
	auto k = Keyinfo(sym, mods, uni);
	com.kbd.translate(k);
	mainui.keypress(k);
	mainui.update();
}

private void dumpState() {
	stderr.writefln("state: title='%s' author='%s' seqs=%d playing=%s exitRequested=%s octave=%d speed=%d",
		(cast(string)song.title).strip, (cast(string)song.author).strip,
		song.numOfSeqs, audio.player.isPlaying(), mainui.exitRequested,
		state.octave, song.speed);
	stderr.writef("       SID $d400..: ");
	foreach(i; 0 .. 9) stderr.writef("%02x ", song.sidbuf[i]);
	stderr.writeln();
}

int main(string[] args) {
	if(args.length < 2) {
		stderr.writeln("usage: ccdriver <cmd>...   cmds: load:f.ct key:SPEC ff:N frames:N shot:f.bmp state");
		return 2;
	}
	audio.player.init();
	if(SDL_Init(SDL_INIT_VIDEO) < 0) {
		stderr.writeln("SDL video init failed: ", to!string(SDL_GetError()));
		return 1;
	}
	screen = new Screen(160, 50);
	video = new VideoStandard(160 * FONT_X, 50 * FONT_Y, screen, 0);
	seq.sequencer.initialHeight = 40;
	initSession();
	mainui = new UI();
	mainui.update();

	foreach(arg; args[1 .. $]) {
		auto c = arg.findSplit(":");
		string cmd = c[0], val = c[2];
		switch(cmd) {
			case "load":
				mainui.loadCallback(val);
				stderr.writefln("loaded %s", val);
				break;
			case "key":
				press(val);
				stderr.writefln("key %s", val);
				break;
			case "ff":
				audio.player.fastForward(to!int(val));   // val*16 frames
				break;
			case "frames":
				foreach(i; 0 .. to!int(val)) { mainui.update(); video.updateFrame(); }
				break;
			case "shot":
				mainui.update(); video.updateFrame();
				video.saveScreenshot(val);
				stderr.writefln("shot %s", val);
				break;
			case "state":
				dumpState();
				break;
			default:
				stderr.writefln("unknown cmd: %s", arg);
				return 2;
		}
	}
	return 0;
}
