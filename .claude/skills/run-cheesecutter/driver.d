/*
 * ccdriver — headless driver for the CheeseCutter-Extended editor.
 *
 * Builds the real editor UI (SDL2 under the "dummy" video driver, which still
 * software-renders to a readable framebuffer), then runs a sequence of
 * commands passed as argv so an agent can drive the editor without a window.
 * Run with -h/--help for the full command list (see usage() below).
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
static import audio.vice;
static import audio.remote;
import std.stdio, std.conv, std.string;
import std.algorithm.searching : startsWith, findSplit;
static import core.thread;
import core.time : dur;

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
		case "BACKSPACE", "BS": return SDLK_BACKSPACE;
		case "DEL", "DELETE": return SDLK_DELETE;
		case "INS", "INSERT": return SDLK_INSERT;
		case "SCRLOCK", "SCROLLLOCK": return SDLK_SCROLLLOCK;
		case "F1": return SDLK_F1; case "F2": return SDLK_F2; case "F3": return SDLK_F3;
		case "F4": return SDLK_F4; case "F5": return SDLK_F5; case "F6": return SDLK_F6;
		case "F7": return SDLK_F7; case "F8": return SDLK_F8; case "F9": return SDLK_F9;
		case "F10": return SDLK_F10; case "F11": return SDLK_F11; case "F12": return SDLK_F12;
		// Keypad — several editor shortcuts bind these (e.g. Alt-KP+/- multispeed).
		case "KP_PLUS", "KP+": return SDLK_KP_PLUS;
		case "KP_MINUS", "KP-": return SDLK_KP_MINUS;
		case "KP_MUL", "KP*": return SDLK_KP_MULTIPLY;
		case "KP_DIV", "KP/": return SDLK_KP_DIVIDE;
		case "KP_PERIOD", "KP.": return SDLK_KP_PERIOD;
		case "KP_ENTER": return SDLK_KP_ENTER;
		case "KP0": return SDLK_KP_0; case "KP1": return SDLK_KP_1; case "KP2": return SDLK_KP_2;
		case "KP3": return SDLK_KP_3; case "KP4": return SDLK_KP_4; case "KP5": return SDLK_KP_5;
		case "KP6": return SDLK_KP_6; case "KP7": return SDLK_KP_7; case "KP8": return SDLK_KP_8;
		case "KP9": return SDLK_KP_9;
		default:
			if(n.length == 1) return cast(int)(n[0]);   // SDLK_a..z / 0..9 == ASCII
			throw new Exception("unknown key: " ~ n ~ " (try --help)");
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
	stderr.writefln("state: title='%s' author='%s' seqs=%d playing=%s exitRequested=%s octave=%d speed=%d mult=%d",
		(cast(string)song.title).strip, (cast(string)song.author).strip,
		song.numOfSeqs, audio.player.isPlaying(), mainui.exitRequested,
		state.octave, song.speed, song.multiplier);
	stderr.writef("       SID $d400..: ");
	foreach(i; 0 .. 9) stderr.writef("%02x ", song.sidbuf[i]);
	stderr.writeln();
}

private void usage(File f) {
	f.write(
"ccdriver — headless driver for the CheeseCutter-Extended editor.\n" ~
"\n" ~
"Usage: ccdriver <cmd>... [serve]\n" ~
"  Run under the dummy SDL drivers, e.g.:\n" ~
"    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccdriver <cmd>...\n" ~
"  Commands run in order; each ':' command takes the text after the colon.\n" ~
"  'serve' (or '-') keeps the editor alive afterwards and reads one command\n" ~
"  per line from stdin (a persistent, stateful session; 'quit' to exit) — e.g.\n" ~
"    ./ccdriver load:song.ct serve   then feed key:/shot:/state on stdin.\n" ~
"\n" ~
"Editor commands:\n" ~
"  load:<file.ct>   load a song\n" ~
"  key:<spec>       inject a keypress; spec = [Ctrl-][Alt-][Shift-]NAME\n" ~
"                   NAME = F1..F12, ESC, RET, SPACE, TAB, UP/DOWN/LEFT/RIGHT,\n" ~
"                   HOME, END, PGUP, PGDN, INS, DEL, BACKSPACE, SCRLOCK,\n" ~
"                   KP0..KP9, KP_PLUS/KP_MINUS/KP_MUL/KP_DIV/KP_PERIOD/KP_ENTER,\n" ~
"                   or a single char (a, 2, +, ...)\n" ~
"  click:cx,cy[,b[,n]]  inject a mouse click at char-cell coords (b=button,\n" ~
"                   n=clicks); e.g. click:3,0 opens the File menu\n" ~
"  play             start playback (player.start)\n" ~
"  mult:<n>         set the multispeed multiplier (1..16)\n" ~
"  ff:<n>           advance playback n*16 frames (synchronous; no audio device)\n" ~
"  frames:<n>       render n UI frames\n" ~
"  tick:[n]         drive the 50Hz timerEvent n times (default 2) for\n" ~
"                   timerEvent-only rendering (e.g. SID regs while playing)\n" ~
"  shot:<file.bmp>  write a screenshot (BMP) of the current screen\n" ~
"  sleep:<ms>       sleep this many milliseconds\n" ~
"  state            print editor state to stderr (title/seqs/playing/SID regs)\n" ~
"\n" ~
"Remote backend (--vice/--ultimate) testing:\n" ~
"  vice:[target]    enable the VICE backend: empty = launch x64sc from PATH,\n" ~
"                   host:port = attach to a running -binarymonitor,\n" ~
"                   /path/x64sc = launch that binary\n" ~
"  ensure           run ensureLoaded+syncDeltas (inject/mirror to the backend)\n" ~
"  vcheck           report how many resident player vars changed (>0 = playing)\n" ~
"  killemu          kill the launched emulator + drop the connection (recovery test)\n" ~
"\n" ~
"  -h, --help       show this help and exit\n" ~
"\n" ~
"Example:\n" ~
"  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccdriver \\\n" ~
"    load:tunes/vent-arkijuusto.ct key:F2 ff:50 shot:/tmp/play.bmp state\n");
}

// Run a single command. Returns false for an unrecognized command (caller
// decides whether that's fatal). Exceptions propagate to the caller.
private bool processCommand(string arg) {
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
		case "click": {
			// click:CX,CY[,BUTTON[,CLICKS]] — coords in character cells, like
			// main.d's mouse handler (it passes x/FONT_X, y/FONT_Y to clickedAt).
			auto parts = val.split(",");
			int cx = to!int(parts[0]), cy = to!int(parts[1]);
			int button = parts.length > 2 ? to!int(parts[2]) : 1;
			int clicks = parts.length > 3 ? to!int(parts[3]) : 1;
			mainui.clickedAt(cx, cy, button, clicks);
			mainui.update();
			stderr.writefln("click %d,%d b%d x%d", cx, cy, button, clicks);
			break;
		}
		case "ff":
			audio.player.fastForward(to!int(val));   // val*16 frames
			break;
		case "frames":
			foreach(i; 0 .. to!int(val)) { mainui.update(); video.updateFrame(); }
			break;
		case "tick":
			// Drive the 50Hz timer N times (default 2 = one UPDATE_RATE cycle), so
			// timerEvent-only rendering (e.g. the SID register readout shown while
			// playing) is produced. Lets headless shots capture it.
			foreach(i; 0 .. (val.length ? to!int(val) : 2)) mainui.timerEvent(1);
			video.updateFrame();
			break;
		case "shot":
			mainui.update(); video.updateFrame();
			video.saveScreenshot(val);
			stderr.writefln("shot %s", val);
			break;
		case "vice":
			audio.vice.configure(val, 0, false);
			stderr.writefln("vice configured: %s", val);
			break;
		case "sleep":
			core.thread.Thread.sleep(dur!"msecs"(to!int(val)));
			break;
		case "play":
			stderr.writeln("play: calling player.start()");
			audio.player.start();
			stderr.writeln("play: start() returned");
			break;
		case "mult":
			audio.player.setMultiplier(to!int(val));
			stderr.writefln("mult set to %s", val);
			break;
		case "ensure":
			audio.remote.ensureLoaded(song);
			audio.remote.syncDeltas(song);
			stderr.writeln("ensure: ran ensureLoaded+syncDeltas");
			break;
		case "vcheck":
			stderr.writefln("vcheck: remote player vars changed = %d (>0 means playing)",
				audio.vice.debugRunningCheck());
			break;
		case "killemu":
			audio.vice.debugKillEmulator();
			stderr.writeln("killemu: killed emulator + dropped connection");
			break;
		case "state":
			dumpState();
			break;
		default:
			stderr.writefln("unknown cmd: %s (try --help)", arg);
			return false;
	}
	stderr.flush();
	return true;
}

int main(string[] args) {
	foreach(arg; args[1 .. $])
		if(arg == "-h" || arg == "--help") { usage(stdout); return 0; }
	if(args.length < 2) {
		usage(stderr);
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

	// Batch: run argv commands in order. `serve`/`-` (anywhere) switches to a
	// persistent stdin loop afterwards, so the editor + Song stay alive across
	// many commands (a true stateful session, no per-step replay/rebuild).
	bool serve = false;
	foreach(arg; args[1 .. $]) {
		if(arg == "serve" || arg == "-") { serve = true; continue; }
		if(!processCommand(arg)) return 2;   // batch: unknown command fails the run
	}

	if(serve) {
		stderr.writeln("serve: ready — one command per line on stdin; 'quit' to exit.");
		stderr.flush();
		for(string line; (line = readln()) !is null; ) {
			line = line.strip();
			if(line.length == 0) continue;
			if(line == "quit" || line == "exit") break;
			// Keep the session alive even if a command errors.
			try { processCommand(line); }
			catch(Exception e) { stderr.writefln("error: %s", e.msg); stderr.flush(); }
		}
	}
	return 0;
}
