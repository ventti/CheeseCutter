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
 *     load:tunes/vent-arkijuusto.ct key:F2 ff:50 shot:/tmp/play.png state
 *
 * This is module `main` (it provides the `main` ModuleInfo the editor modules
 * import) and links against every object except src/main.o — see the
 * `ccdriver` target in Makefile.mac.
 */
module main;

import derelict.sdl2.sdl;
import com.fb, com.session, com.kbd, com.util, ct.base;
import com.shortcuts : formatShortcuts;
static import com.palette;
import ui.ui, ui.input, seq.sequencer;
import audio.player;
static import audio.audio;
static import audio.callback;
static import audio.vice;
static import audio.remote;
import std.stdio, std.conv, std.string;
import std.algorithm.searching : startsWith, findSplit;
import std.range : walkLength;
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
		else if(spec.startsWith("RAlt-"))  { mods |= KMOD_RALT;   spec = spec[5..$]; }
		else if(spec.startsWith("Mode-"))  { mods |= KMOD_MODE;   spec = spec[5..$]; }
		else if(spec.startsWith("Gui-"))   { mods |= KMOD_LGUI;   spec = spec[4..$]; }
		else if(spec.startsWith("Shift-")) { mods |= KMOD_LSHIFT; spec = spec[6..$]; }
		else break;
	}
	int sym = keyName(spec);
	int uni = (sym >= 0 && sym <= 127) ? sym : 0;
	auto k = Keyinfo(sym, mods, uni);
	com.kbd.translate(k);
	mainui.keypress(k);
	// Mirror real SDL: a printable key also yields an SDL_TEXTINPUT event with the
	// composed character. Text fields take their input from there now, so feed it
	// (no Ctrl/Alt/GUI held). e.g. `key:$` types '$' into a focused text field.
	if(uni >= 0x20 && uni <= 0x7e && !(mods & (KMOD_CTRL | KMOD_ALT | KMOD_GUI)))
		mainui.textInput("" ~ cast(char)uni);
	mainui.update();
}

// Mirror an SDL_KEYUP (key release) — for testing keyjam gate-off / held-key logic.
private void release(string spec) {
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
	mainui.keyrelease(k);
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
"  palette:<file>   load a JSON color palette at runtime (repaints)\n" ~
"  key:<spec>       inject a keypress; spec = [Ctrl-][Alt-/RAlt-][Mode-][Gui-][Shift-]NAME\n" ~
"  keyprobe:<spec>  inject through the real UI and report shortcut consumed/action/invoked\n" ~
"                   NAME = F1..F12, ESC, RET, SPACE, TAB, UP/DOWN/LEFT/RIGHT,\n" ~
"                   HOME, END, PGUP, PGDN, INS, DEL, BACKSPACE, SCRLOCK,\n" ~
"                   KP0..KP9, KP_PLUS/KP_MINUS/KP_MUL/KP_DIV/KP_PERIOD/KP_ENTER,\n" ~
"                   or a single char (a, 2, +, ...)\n" ~
"  click:cx,cy[,b[,n]]  inject a mouse click at char-cell coords (b=button,\n" ~
"                   n=clicks); e.g. click:3,0 opens the File menu\n" ~
"  drag:x1,y1,x2,y2 left-drag from (x1,y1) to (x2,y2) (press, move, release)\n" ~
"  dragpx:x1,py1,x2,py2  same, but Y in GRID PIXELS (publishes com.fb.mousePixelY)\n" ~
"                   for widgets with sub-cell precision, e.g. the pitch drag\n" ~
"  press:cx,cy[,b]  mouse button-down only (no release) — e.g. to capture the\n" ~
"                   menu bar's armed/yellow pressed state in a screenshot\n" ~
"  release:cx,cy    mouse button-up at a cell (pairs with press)\n" ~
"  move:cx,cy       mouse drag-motion only (between press and release)\n" ~
"  hover:cx,cy      mouse motion with no button held (drives menu-bar hover)\n" ~
"  play             start playback (player.start)\n" ~
"  mult:<n>         set the multispeed multiplier (1..16)\n" ~
"  backend:<name>   select local SID engine: resid-fp (default) or resid\n" ~
"  ff:<n>           advance playback n*16 frames (synchronous; no audio device)\n" ~
"  jamrender:<k>,<t>  press keyjam key k, then offline-render t player ticks so the\n" ~
"                   Output waveform (captureBuf) fills headless (default t=120)\n" ~
"  scopefill:[n]    fill the reSID mix buffer via the real audio callback (n reps,\n" ~
"                   default 4) so the oscilloscope overlay shows a waveform headless\n" ~
"  frames:<n>       render n UI frames\n" ~
"  tick:[n]         drive the 50Hz timerEvent n times (default 2) for\n" ~
"                   timerEvent-only rendering (e.g. SID regs while playing)\n" ~
"  shot:<file.png>  write a screenshot (PNG) of the current screen\n" ~
"  sleep:<ms>       sleep this many milliseconds\n" ~
"  state            print editor state to stderr (title/seqs/playing/SID regs)\n" ~
"  undostate        print undo/redo depths and edit generation (read-only)\n" ~
"  checkpoint:<id>  print an ordered protocol marker for persistent test sessions\n" ~
"  capturestate     dump deterministic keyjam PCM/gate signatures + active voice\n" ~
"  sounddump        dump every instrument and wave/pulse/filter byte (read-only)\n" ~
"  seqdump:<n>      dump sequence n's rows as hex (read-only edit oracle)\n" ~
"  tracks           dump each voice's tracklist entries (trans,number)\n" ~
"  voices           per-voice visualizer: instrument, brightness, recording len\n" ~
"  wavedump:<row>   dump 24 wave-table rows (w1/w2) from row (Sound Editor oracle)\n" ~
"  wavepreview:<n>  independently evaluate the active instrument's wave rows for n\n" ~
"                   player ticks, including wave-speed, delay and loop semantics\n" ~
"  recdump:<voice>  dump a voice's recorded per-frame control/freq/pulse arrays\n" ~
"  envpreview:<n>   dump the Sound Editor's silent reSID envelope preview\n" ~
"  filtershape[:mode,cutoff] dump filter response regions or active one-axis handles\n" ~
"  soundstate       dump semantic Sound Editor viewport/recording/cursor state\n" ~
"  waveaddstate     dump the trailing in-band Wave-row creation target\n" ~
"  waveloopstate    dump Wave END/LOOP triangle geometry\n" ~
"  sweeploopstate:P|F dump Pulse/Filter END/LOOP triangle geometry\n" ~
"  wavefixture:<state> seed Wave edge/shared states for tests\n" ~
"  ownershipfixture:<state> seed full-table/fixed-P/shared-F ownership states\n" ~
"  screendump       dump the 160x50 text framebuffer (usage-test oracle)\n" ~
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
"    load:tunes/vent-arkijuusto.ct key:F2 ff:50 shot:/tmp/play.png state\n");
}

// Run a single command. Returns false for an unrecognized command (caller
// decides whether that's fatal). Exceptions propagate to the caller.
private bool processCommand(string arg) {
	auto c = arg.findSplit(":");
	string cmd = c[0], val = c[2];
	switch(cmd) {
		case "keyprobe": {
			press(val);
			stderr.writefln("shortcut probe: consumed=%s action=%s invoked=%s",
				mainui.sm.debugLastConsumed(), mainui.sm.debugLastAction(),
				mainui.sm.debugLastInvoked());
			break;
		}
		case "backend": {
			string name = val.toLower;
			if(name == "resid-fp" || name == "fp") audio.player.usefp = 1;
			else if(name == "resid" || name == "standard") audio.player.usefp = 0;
			else throw new Exception("backend must be resid-fp or resid");
			audio.player.init();
			stderr.writefln("backend: %s", audio.player.usefp ? "resid-fp" : "resid");
			break;
		}
		case "load":
			mainui.loadCallback(val);
			stderr.writefln("loaded %s", val);
			break;
		case "modimport":
			// modimport:<file.mod> — import a ProTracker module (File-menu action).
			mainui.modImportCallback(val);
			stderr.writefln("modimport %s", val);
			break;
		case "save":
			// save:<file.ct> — write the current song as a .ct (round-trip test).
			song.save(val);
			stderr.writefln("saved %s", val);
			break;
		case "dumptables":
			// dumptables — print chord table + command table + speed (import test).
			stderr.writef("chord: ");
			foreach(i; 0 .. 12) stderr.writef("%02x ", song.chordTable[i]);
			stderr.writeln();
			stderr.writef("cmd:   ");
			foreach(i; 0 .. 8)
				stderr.writef("[%x:%02x%02x] ", song.superTable[i] & 15,
					song.superTable[i + 64], song.superTable[i + 128]);
			stderr.writefln("\nspeed: %d", song.speed);
			foreach(nn; 1 .. 5) {
				int wp = song.instrumentTable[nn + 7 * 48];
				stderr.writefln("ins%d: AD=%02x SR=%02x wave=%02x wf=%02x", nn,
					song.instrumentTable[nn], song.instrumentTable[nn + 48],
					wp, song.tWave.wave2[wp]);
			}
			break;
		case "insbytes": {
			// insbytes — dump the ACTIVE instrument's 8 raw bytes (AD SR Rst HRw Flt Pul
			// HRsr Wav) straight from the live instrumentTable — the exact array both the
			// classic InsTable and the Sound Editor write, so it is the byte-parity oracle.
			int ins = state.activeInstrument;
			stderr.writef("ins%02x:", ins);
			foreach(col; 0 .. 8) stderr.writef(" %02x", song.instrumentTable[ins + col * 48]);
			stderr.writeln();
			break;
		}
		case "sweepdump": {
			// sweepdump:P|F — dump every instrument's pointer for the pulse (P) or filter
			// (F) table, then all 64 SweepTable rows (b0 b1 b2 b3). Read-only byte-parity /
			// no-clobber oracle for the Sound Editor's P4b program editing.
			bool filt = val.length && (val[0] == 'F' || val[0] == 'f');
			const(ubyte)[] t = filt ? song.filterTable : song.pulseTable;
			int col = filt ? 4 : 5;
			stderr.writef("%s ptrs:", filt ? "filt" : "puls");
			foreach(i; 0 .. 48) stderr.writef(" %02x", song.instrumentTable[i + col * 48]);
			stderr.writeln();
			foreach(r; 0 .. 64) {
				stderr.writef("%02x:%02x%02x%02x%02x ", r, t[r * 4], t[r * 4 + 1],
					t[r * 4 + 2], t[r * 4 + 3]);
				if((r & 7) == 7) stderr.writeln();
			}
			break;
		}
		case "palette":
			// palette:<file> — load a JSON palette at runtime, then force a full
			// repaint so the new colors take effect on the next shot.
			com.palette.initPalette(val);
			screen.refresh();
			stderr.writefln("palette %s", val);
			break;
		case "key":
			press(val);
			stderr.writefln("key %s", val);
			break;
		case "keyup":
			release(val);
			stderr.writefln("keyup %s", val);
			break;
		case "click": {
			// click:CX,CY[,BUTTON[,CLICKS]] — coords in character cells, like
			// main.d's mouse handler (it passes x/FONT_X, y/FONT_Y to clickedAt).
			auto parts = val.split(",");
			int cx = to!int(parts[0]), cy = to!int(parts[1]);
			int button = parts.length > 2 ? to!int(parts[2]) : 1;
			int clicks = parts.length > 3 ? to!int(parts[3]) : 1;
			mainui.clickedAt(cx, cy, button, clicks);
			// Complete the gesture (button-up) so a click is a full press+release
			// — matches real input and clears a freshly-anchored selection.
			if(button == 1) mainui.releasedAt(cx, cy);
			mainui.update();
			stderr.writefln("click %d,%d b%d x%d", cx, cy, button, clicks);
			break;
		}
		case "shiftclick": {
			// shiftclick:CX,CY — a left click with Shift held (SDL_GetModState
			// reports it), for shift-click block selection.
			auto parts = val.split(",");
			int cx = to!int(parts[0]), cy = to!int(parts[1]);
			SDL_SetModState(KMOD_LSHIFT);
			mainui.clickedAt(cx, cy, 1, 1);
			mainui.releasedAt(cx, cy);
			SDL_SetModState(KMOD_NONE);
			mainui.update();
			stderr.writefln("shiftclick %d,%d", cx, cy);
			break;
		}
		case "press": {
			// press:CX,CY[,BUTTON] — button-down only (no release), so the menu
			// bar's armed/pressed (yellow) state can be screenshotted.
			auto parts = val.split(",");
			int cx = to!int(parts[0]), cy = to!int(parts[1]);
			int button = parts.length > 2 ? to!int(parts[2]) : 1;
			mainui.clickedAt(cx, cy, button, 1); mainui.update();
			stderr.writefln("press %d,%d b%d", cx, cy, button);
			break;
		}
		case "release": {
			// release:CX,CY — button-up at the given cell (pairs with press).
			auto parts = val.split(",");
			int cx = to!int(parts[0]), cy = to!int(parts[1]);
			mainui.releasedAt(cx, cy); mainui.update();
			stderr.writefln("release %d,%d", cx, cy);
			break;
		}
		case "move": {
			// move:CX,CY — motion with the left button already held by `press`.
			auto parts = val.split(",");
			int cx = to!int(parts[0]), cy = to!int(parts[1]);
			mainui.draggedTo(cx, cy); mainui.update();
			stderr.writefln("move %d,%d", cx, cy);
			break;
		}
		case "hover": {
			// hover:CX,CY — mouse motion with no button held (drives ui.hoverAt).
			auto parts = val.split(",");
			int cx = to!int(parts[0]), cy = to!int(parts[1]);
			mainui.hoverAt(cx, cy); mainui.update();
			stderr.writefln("hover %d,%d", cx, cy);
			break;
		}
		case "drag": {
			// drag:CX1,CY1,CX2,CY2 — left-button press at (1), motion to (2)
			// with the button held, then release. Simulates a drag-select.
			auto p = val.split(",");
			int x1 = to!int(p[0]), y1 = to!int(p[1]);
			int x2 = to!int(p[2]), y2 = to!int(p[3]);
			mainui.clickedAt(x1, y1, 1, 1); mainui.update();
			// a couple of intermediate motions, like a real drag
			int mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
			mainui.draggedTo(mx, my); mainui.update();
			mainui.draggedTo(x2, y2); mainui.update();
			mainui.releasedAt(x2, y2); mainui.update();
			stderr.writefln("drag %d,%d -> %d,%d", x1, y1, x2, y2);
			break;
		}
		case "dragpx": {
			// dragpx:CX1,PY1,CX2,PY2 — like `drag`, but the Y values are GRID PIXELS,
			// not character cells: each step publishes com.fb.mousePixelY exactly as
			// main.mainloop does, so widgets that read sub-cell precision (the pitch
			// drag) see a real pixel instead of falling back to the cell centre. X
			// stays cell-granular — no widget needs sub-cell X.
			auto p = val.split(",");
			int x1 = to!int(p[0]), py1 = to!int(p[1]);
			int x2 = to!int(p[2]), py2 = to!int(p[3]);
			void at(int cx, int py, void delegate(int, int) dispatch) {
				com.fb.mousePixelX = cx * FONT_X + FONT_X / 2;
				com.fb.mousePixelY = py;
				dispatch(cx, py / FONT_Y);
				mainui.update();
			}
			at(x1, py1, (cx, cy) => mainui.clickedAt(cx, cy, 1, 1));
			at((x1 + x2) / 2, (py1 + py2) / 2, (cx, cy) => mainui.draggedTo(cx, cy));
			at(x2, py2, (cx, cy) => mainui.draggedTo(cx, cy));
			at(x2, py2, (cx, cy) => mainui.releasedAt(cx, cy));
			stderr.writefln("dragpx %d,%dpx -> %d,%dpx", x1, py1, x2, py2);
			break;
		}
		case "ff":
			audio.player.fastForward(to!int(val));   // val*16 frames
			break;
		case "jamrender": {
			// jamrender:<key>,<ticks> — press a keyjam piano key (arms the note +
			// capture via the normal keypress -> playNote path), then run the OFFLINE
			// capture (audio.audio.renderKeyjamCapture) for <ticks> player ticks. Under
			// dummy audio the SDL callback never fires, so captureBuf/rec* would stay
			// empty; this fills them deterministically so the Sound Editor's Output
			// waveform is screenshottable headless. Read-only re: song data.
			auto p = val.findSplit(",");
			string keySpec = p[0];
			int ticks = p[2].length ? to!int(p[2]) : 120;
			press(keySpec);                              // arm keyjam note + capture
			audio.audio.renderKeyjamCapture(ticks);
			// Count leading gate=0 frames (hard-restart pre-gate) + first gate-high.
			int lead = 0;
			foreach(gi; 0 .. audio.audio.captureGateLen) {
				if(audio.audio.captureGate[gi] != 0) break;
				lead++;
			}
			stderr.writefln("jamrender key=%s ticks=%d capLen=%d gateLen=%d fs=%d leadGate0=%d gateHighSample=%d",
							keySpec, ticks, audio.audio.captureLen,
							audio.audio.captureGateLen, audio.audio.captureFrameSamples,
							lead, lead * audio.audio.captureFrameSamples);
			break;
		}
		case "scopefill":
			// Fill the reSID mix buffer (audio.audio.mixbuf) by driving the REAL
			// audio callback path — sid_fillbuffer + audio_frame, exactly as the
			// SDL audio thread does live. Under dummy audio that thread never
			// fires, so the oscilloscope overlay would otherwise flatline in
			// headless shots. Requires playback/keyjam active. n reps (default 4).
			int reps = val.length ? to!int(val) : 4;
			int lenBytes = audio.audio.getbufsize() * cast(int)short.sizeof;
			auto stream = new ubyte[lenBytes];
			foreach(i; 0 .. reps)
				audio.audio.audio_callback_2(null, stream.ptr, lenBytes);
			stderr.writefln("scopefill x%d (len=%d, playing=%s)",
							reps, lenBytes, audio.player.isPlaying());
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
		case "undostate":
			stderr.writefln("undo: depth=%d redo=%d generation=%d",
				state.undoQueue.stages[].walkLength,
				state.redoQueue.stages[].walkLength, state.editGeneration);
			break;
		case "checkpoint":
			// A flush-delimited marker for stateful `serve` clients. It deliberately
			// changes no editor state, so a Python master test can bracket each user
			// action and fail at the first named checkpoint without restarting ccdriver.
			stderr.writefln("checkpoint: %s", val);
			break;
		case "capturestate": {
			// Stable, read-only keyjam oracle. FNV-1a covers the exact signed PCM bytes;
			// gateOn/gateOff are player-tick indices (including any restart pre-roll).
			uint hash = 2_166_136_261u;
			int peak = 0;
			ulong sumAbs = 0;
			int n = audio.audio.captureLen;
			if(n > cast(int)audio.audio.captureBuf.length)
				n = cast(int)audio.audio.captureBuf.length;
			foreach(i; 0 .. n) {
				ushort bits = cast(ushort)audio.audio.captureBuf[i];
				hash = (hash ^ (bits & 0xff)) * 16_777_619u;
				hash = (hash ^ (bits >> 8)) * 16_777_619u;
				int sample = audio.audio.captureBuf[i];
				int magnitude = sample < 0 ? -sample : sample;
				if(magnitude > peak) peak = magnitude;
				sumAbs += cast(ulong)magnitude;
			}
			int gateOn = -1, gateOff = -1, gateHigh = 0;
			int gn = audio.audio.captureGateLen;
			if(gn > cast(int)audio.audio.captureGate.length)
				gn = cast(int)audio.audio.captureGate.length;
			foreach(i; 0 .. gn) {
				bool high = audio.audio.captureGate[i] != 0;
				if(high) {
					if(gateOn < 0) gateOn = cast(int)i;
					gateHigh++;
				} else if(gateOn >= 0 && gateOff < 0) gateOff = cast(int)i;
			}
			stderr.writefln(
				"capture: samples=%d hash=%08x peak=%d sumAbs=%d gates=%d gateOn=%d gateOff=%d gateHigh=%d onsetSample=%d frameSamples=%d instr=%d voice=%d",
				n, hash, peak, sumAbs, gn, gateOn, gateOff, gateHigh,
				audio.audio.captureOnsetSample, audio.audio.captureFrameSamples,
				audio.audio.captureInstr, audio.audio.captureVoice + 1);
			break;
		}
		case "sounddump": {
			// Complete read-only isolation oracle. Tests mask only the active sound's
			// newly allocated rows; every byte outside those ranges must remain identical.
			stderr.writef("all instruments:");
			foreach(x; song.instrumentTable) stderr.writef("%02x", x);
			stderr.writeln();
			stderr.writef("all wave:");
			foreach(x; song.waveTable) stderr.writef("%02x", x);
			stderr.writeln();
			stderr.writef("all pulse:");
			foreach(x; song.pulseTable) stderr.writef("%02x", x);
			stderr.writeln();
			stderr.writef("all filter:");
			foreach(x; song.filterTable) stderr.writef("%02x", x);
			stderr.writeln();
			break;
		}
		case "presspx": case "movepx": case "releasepx": {
			// presspx/movepx/releasepx:CX,PY — the three phases of a pixel-precise drag
			// as SEPARATE commands, so an oracle (e.g. pitchprobe) can be read MID-gesture.
			// `dragpx` runs all three at once and therefore only ever shows the released
			// state. Y is a grid pixel; com.fb.mousePixelY is published as main.mainloop does.
			auto p = val.split(",");
			int cx = to!int(p[0]), py = to!int(p[1]);
			com.fb.mousePixelX = cx * FONT_X + FONT_X / 2;
			com.fb.mousePixelY = py;
			int cy = py / FONT_Y;
			if(cmd == "presspx") mainui.clickedAt(cx, cy, 1, 1);
			else if(cmd == "movepx") mainui.draggedTo(cx, cy);
			else mainui.releasedAt(cx, cy);
			mainui.update();
			stderr.writefln("%s %d,%dpx", cmd, cx, py);
			break;
		}
		case "pitchprobe": {
			if(!mainui.toplevel.soundEditorActive) {
				stderr.writeln("pitch: inactive");
				break;
			}
			auto p = mainui.toplevel.soundEditor.pitchProbe();
			// delta = how far the drawn block sits from the cursor. Should stay within
			// one value step (stepPx) if the drag maps 1:1 to the UI.
			int delta = (p.drawnY >= 0 && p.mouseY >= 0) ? p.drawnY - p.mouseY : 0;
			stderr.writefln("pitch: plot=%d..%d band=%d..%d h=%d scale=%d latched=%d row=%d value=$%02x "
				~ "pitch=%d note=%d played=%d window=%d..%d drawnY=%d mouseY=%d "
				~ "valueAtMouseY=%d delta=%d stepPx=%.2f dragging=%s clamped=%s",
				p.plotLeft, p.plotRight,
				p.bandTop, p.bandBottom, p.bandHeight, p.scale, p.latchedScale,
				p.row, p.value, p.pitch, p.note, p.played, p.windowLo, p.windowHi,
				p.drawnY, p.mouseY, p.valueAtMouseY,
				delta, p.stepPixels1000 / 1000.0, p.dragging, p.clampedByScale);
			break;
		}
		case "soundstate": {
			if(!mainui.toplevel.soundEditorActive) {
				stderr.writeln("sound: inactive");
				break;
			}
			auto s = mainui.toplevel.soundEditor.debugState();
			stderr.writefln("sound: tickUs=%d stepTicks=%d vis=%d preroll=%d view=%.3f..%.3f zoomed=%s selection=%s:%d..%d recording=%s cursor=%d captureLen=%d captureInstr=%d trigger=%d preview=%d/%d ownership=%s",
				s.tickMillis1000, s.trackStepTicks, s.visibleFrames, s.prerollTicks,
				s.viewStartTick, s.viewEndTick, s.userZoomed, s.hasSelection,
				s.selectionStart, s.selectionEnd, s.usesRecording,
				s.cursorDirection, audio.audio.captureLen, audio.audio.captureInstr,
				audio.player.keyjamNoteTrigger, s.previewInstrument, s.previewNote,
				mainui.toplevel.soundEditor.debugOwnershipMode());
			break;
		}
		case "waveaddstate": {
			if(!mainui.toplevel.soundEditorActive) {
				stderr.writeln("wave add: inactive");
				break;
			}
			auto a = mainui.toplevel.soundEditor.debugWaveAdd();
			stderr.writefln("wave add: visible=%d enabled=%d frame=%d x=%d y=%d close=%d reason=%s",
				a.visible ? 1 : 0, a.enabled ? 1 : 0, a.frame, a.x, a.y, a.close, a.reason);
			break;
		}
		case "waveloopstate": {
			if(!mainui.toplevel.soundEditorActive) {
				stderr.writeln("wave loop: inactive");
				break;
			}
			auto s = mainui.toplevel.soundEditor.debugWaveLoopGeometry();
			stderr.writefln("wave loop: looped=%d stopped=%d startVisible=%d endVisible=%d startFrame=%d endFrame=%d start=%d..%d end=%d..%d top=%d..%d startDir=%s endDir=%s",
				s.looped ? 1 : 0, s.stopped ? 1 : 0,
				s.startVisible ? 1 : 0, s.endVisible ? 1 : 0,
				s.startFrame, s.endFrame,
				s.startLeft, s.startRight, s.endLeft, s.endRight,
				s.top, s.bottom,
				s.startVisible ? "right" : "none",
				s.endVisible ? "left" : "none");
			break;
		}
		case "sweeploopstate": {
			if(!mainui.toplevel.soundEditorActive) {
				stderr.writeln("sweep loop: inactive");
				break;
			}
			int table = val == "P" ? 0 : val == "F" ? 1 : -1;
			if(table < 0) throw new Exception("sweeploopstate expects P or F");
			auto s = mainui.toplevel.soundEditor.debugSweepLoopGeometry(table);
			stderr.writefln("sweep loop: table=%s looped=%d stopped=%d startVisible=%d endVisible=%d start=%d..%d end=%d..%d top=%d..%d",
				val, s.looped ? 1 : 0, s.stopped ? 1 : 0,
				s.startVisible ? 1 : 0, s.endVisible ? 1 : 0,
				s.startLeft, s.startRight, s.endLeft, s.endRight, s.top, s.bottom);
			break;
		}
		case "ownershipfixture": {
			// Deterministic destination-capacity setup. The active shared programme stays
			// intact; only the table tail is occupied so automatic COW must fail safely.
			if(val == "full-W") {
				// WaveTable.seekTableEnd scans wave1[254] as the last allocatable row.
				song.waveTable[254] = 1;
				song.waveTable[510] = 1;
			} else if(val == "full-P") {
				song.pulseTable[0x3f * 4 .. 0x3f * 4 + 4] = [1, 1, 1, 0x7f];
			} else if(val == "full-F") {
				song.filterTable[0x3f * 4 .. 0x3f * 4 + 4] = [0x90, 1, 1, 0x7f];
			} else if(val == "fixed-P-84") {
				// Direct fixed Pulse $84 audibly starts at width $400. The real first-drag
				// path must preserve that value before applying the same gesture's motion.
				song.instrumentTable[state.activeInstrument + 5 * 48] = 0x84;
			} else if(val == "shared-F-struct") {
				// Two shared logical Filter blocks with a loop to block one. This gives
				// Add/Delete/loop ownership tests real structure without UI setup edits.
				song.filterTable[1 * 4 .. 1 * 4 + 4] = [0x90, 0x01, 0x20, 0x00];
				song.filterTable[2 * 4 .. 2 * 4 + 4] = [0x04, 0x01, 0xff, 0x00];
				song.filterTable[3 * 4 .. 3 * 4 + 4] = [0xa0, 0x11, 0x60, 0x00];
				song.filterTable[4 * 4 .. 4 * 4 + 4] = [0x04, 0xff, 0xff, 0x01];
			} else throw new Exception("unknown ownershipfixture state");
			stderr.writefln("ownership fixture: %s", val);
			break;
		}
		case "wavefixture": {
			// Edge-state setup only; all behavior under test still goes through the real
			// rendered target and mouse path. The disposable master fixture contains the
			// mutations, never a user's song.
			int ins = state.activeInstrument;
			int start = song.instrumentTable[ins + 7 * 48];
			if(val == "end-only") {
				song.waveTable[start] = 0x7e;
				song.waveTable[start + 256] = 0;
				if(start < 255) { song.waveTable[start + 1] = 0; song.waveTable[start + 257] = 0; }
			} else if(val == "invalid") {
				// Point only the active instrument at a markerless final row. Existing
				// programmes and free append capacity remain intact for New sound.
				song.instrumentTable[ins + 7 * 48] = 0xff;
				song.waveTable[255] = 0;
				song.waveTable[511] = 0;
			} else if(val == "full") {
				song.waveTable[254] = 1;
				song.waveTable[510] = 0;
				song.waveTable[255] = 1;
				song.waveTable[511] = 0;
			} else if(val == "shared-delay") {
				// Authorization tests address player frames directly. Remove the
				// instrument-level Wave delay so only the authored row delay below
				// determines which row owns each frame.
				song.instrumentTable[ins + 2 * 48] &= 0xf0;
				song.waveTable[start] = 0xcf;
				song.waveTable[start + 256] = 0x04;
			} else if(val == "shared-two") {
				// Two adjacent player frames must be two adjacent authored rows;
				// otherwise a fixture instrument with Wave speed > 0 makes a drag
				// revisit the first row and cannot exercise multi-row painting.
				song.instrumentTable[ins + 2 * 48] &= 0xf0;
				song.waveTable[start] = 0xcf;
				song.waveTable[start + 256] = 0x81;
				song.waveTable[start + 1] = 0x00;
				song.waveTable[start + 257] = 0x41;
				song.waveTable[start + 2] = 0x7f;
				song.waveTable[start + 258] = cast(ubyte)start;
			} else if(val == "timing-a") {
				ubyte[6] w1 = [0xb0, 0x00, 0x02, 0x01, 0x00, 0x7e];
				ubyte[6] w2 = [0x81, 0x04, 0x41, 0x41, 0x41, 0x00];
				song.waveTable[start .. start + 6] = w1[];
				song.waveTable[start + 256 .. start + 262] = w2[];
				song.instrumentTable[ins + 2 * 48] &= 0xf0;
			} else if(val == "timing-b" || val == "timing-b1") {
				ubyte[7] w1 = [0xc0, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x7f];
				ubyte[7] w2 = [0x81, 0x02, 0x41, 0x0c, 0x41, 0x0c,
					cast(ubyte)(start + 2)];
				song.waveTable[start .. start + 7] = w1[];
				song.waveTable[start + 256 .. start + 263] = w2[];
				song.instrumentTable[ins + 2 * 48] = cast(ubyte)(
					(song.instrumentTable[ins + 2 * 48] & 0xf0)
					| (val == "timing-b1" ? 1 : 0));
			} else throw new Exception("unknown wavefixture state");
			mainui.update();
			stderr.writefln("wave fixture: %s start=%02x", val, start);
			break;
		}
		case "shortcutstate": {
			stderr.writefln("shortcut: context=%s id=%s enabled=%s keys=%s",
				mainui.sm.getActiveContext(), val, mainui.sm.isActionEnabled(val),
				formatShortcuts(mainui.sm.getShortcuts(val)));
			break;
		}
		case "controlstate": {
			stderr.write("controls:");
			if(mainui.toplevel.soundEditorActive)
				foreach(control; mainui.toplevel.soundEditor.debugControls())
					stderr.writef(" %s@%d..%d,%d:%s", control.actionId,
						control.x0, control.x1, control.row, control.enabled ? "on" : "off");
			stderr.writeln();
			break;
		}
		case "cellstate": {
			auto parts = val.split(",");
			if(parts.length != 2) throw new Exception("cellstate expects x,y");
			int x = to!int(parts[0]), y = to!int(parts[1]);
			Uint32 cell = screen.getChar(x, y);
			stderr.writefln("cell: x=%d y=%d ch=%d fg=%d bg=%d raw=%08x",
				x, y, cell & 0xff, (cell >> 8) & 0xff, (cell >> 16) & 0xff, cell);
			break;
		}
		case "regstate": {
			int x0 = screen.width - 42;
			stderr.write("regs:");
			foreach(y; 1 .. 4) {
				stderr.writef(" row%d=", y);
				foreach(x; x0 .. screen.width) stderr.writef("%08x", screen.getChar(x, y));
			}
			stderr.writeln();
			break;
		}
		case "status": {
			UI.statusline.display(val);
			mainui.update();
			stderr.writefln("status: %s", val);
			break;
		}
		case "envpreview": {
			int ticks = val.length ? to!int(val) : 64;
			if(!mainui.toplevel.soundEditorActive) {
				stderr.writeln("env preview: inactive");
				break;
			}
			auto preview = mainui.toplevel.soundEditor.debugEnvelopePreview(ticks);
			stderr.writefln("env preview: source=resid-estimate note=%d pcm=0 remote=0 render=%d",
				preview.note, preview.generation);
			stderr.writef("env preview env:");
			foreach(value; preview.envelope) stderr.writef(" %02X", value);
			stderr.writeln();
			break;
		}
		case "filtershape": {
			if(!mainui.toplevel.soundEditorActive) {
				stderr.writeln("filter shapes: inactive");
				break;
			}
			if(val.length) {
				auto parts = val.split(",");
				if(parts.length != 2) throw new Exception("filtershape expects mode,cutoff");
				int mode = to!int(parts[0]), cutoff = to!int(parts[1]);
				auto r = mainui.toplevel.soundEditor.debugFilterShape(mode, cutoff);
				stderr.writefln("filter shape: mode=%d cutoff=%d axis=%d..%d y=%d lp=%d:%d..%d bp=%d:%d..%d hp=%d:%d..%d",
					r.mode, r.cutoff, r.top, r.bottom, r.y,
					r.lp ? 1 : 0, r.lpTop, r.lpBottom,
					r.bp ? 1 : 0, r.bpTop, r.bpBottom,
					r.hp ? 1 : 0, r.hpTop, r.hpBottom);
				break;
			}
			foreach(item; mainui.toplevel.soundEditor.debugFilterShapes())
				stderr.writefln("filter step: row=%d mode=%d frames=%d..%d x=%d..%d cutoff=%d..%d y=%d..%d handles=%d",
					item.row, item.mode, item.frame0, item.frame1,
					item.x0, item.x1, item.cutoff0, item.cutoff1,
					item.y0, item.y1, item.handles);
			break;
		}
		case "screendump": {
			// Text is the durable oracle; pixel graphs are covered through their semantic
			// SoundEditor state and real SID recordings rather than fragile PNG goldens.
			mainui.update();
			foreach(y; 0 .. screen.height) {
				char[] line;
				line.length = screen.width;
				foreach(x; 0 .. screen.width) {
					int ch = screen.getChar(x, y) & 0xff;
					line[x] = (ch >= 0x20 && ch <= 0x7e) ? cast(char)ch : ' ';
				}
				stderr.writefln("screen%02d:%s", y, line);
			}
			break;
		}
		case "wavedump": {
			// wavedump:<startRow> — print 24 wave-table rows (w1/w2) from startRow, a
			// read-only oracle for verifying the Sound Editor's wave loop simulation.
			int r0 = val.length ? (val.startsWith("0x") ? to!int(val[2..$],16) : to!int(val)) : 0;
			stderr.writef("wave rows from %02X:", r0);
			foreach(k; 0 .. 24) {
				int r = (r0 + k) & 0xff;
				stderr.writef(" %02X:%02x/%02x", r, song.waveTable[r], song.waveTable[r+256]);
			}
			stderr.writeln();
			break;
		}
		case "wavepreview": {
			// Read-only independent wave-program timing oracle. This deliberately does
			// not call SoundEditor's simulator: a one-row-per-tick UI implementation must
			// disagree with this output when a $01..$0f delay is present and fail the
			// usage test. Semantics mirror player_v4: the NEXT selected row's low control
			// byte overrides the countdown, so delay N holds the current row for N+1 ticks.
			int ticks = val.length ? to!int(val) : 40;
			if(ticks < 1) ticks = 1;
			if(ticks > 256) ticks = 256;
			int ins = state.activeInstrument;
			int startRow = song.instrumentTable[ins + 7 * 48];
			int waveTime = song.instrumentTable[ins + 2 * 48] & 0x0f;
			int nextRow = startRow, currentRow = startRow;
			int waveCnt = 0, currentW1 = 0, currentCtrl = 0;
			int[] rows, wave1, controls;
			foreach(tick; 0 .. ticks) {
				if(--waveCnt < 0) {
					waveCnt = waveTime;
					// A valid pointer lands on an authored row, never a marker. Be robust
					// to malformed input without mutating or walking forever.
					int guard = 0;
					while(song.waveTable[nextRow] == 0x7f && guard++ < 256)
						nextRow = song.waveTable[nextRow + 256];
					currentRow = nextRow;
					currentW1 = song.waveTable[currentRow];
					int w2 = song.waveTable[currentRow + 256];
					if(w2 >= 0x10)
						currentCtrl = (w2 >= 0xe0 && w2 <= 0xef) ? (w2 & 0x0f) : w2;

					int candidate = (currentRow + 1) & 0xff;
					int marker = song.waveTable[candidate];
					if(marker == 0x7e) candidate = currentRow;
					else if(marker == 0x7f) candidate = song.waveTable[candidate + 256];
					int delay = song.waveTable[candidate + 256];
					if(delay >= 1 && delay <= 0x0f) waveCnt = delay;
					nextRow = candidate;
				}
				rows ~= currentRow;
				wave1 ~= currentW1;
				controls ~= currentCtrl;
			}
			stderr.writefln("wave preview: ins=%02X start=%02X speed=%X ticks=%d",
				ins, startRow, waveTime, ticks);
			stderr.writef("wave preview rows:");
			foreach(x; rows) stderr.writef(" %02X", x);
			stderr.writeln();
			stderr.writef("wave preview w1:");
			foreach(x; wave1) stderr.writef(" %02X", x);
			stderr.writeln();
			stderr.writef("wave preview ctrl:");
			foreach(x; controls) stderr.writef(" %02X", x);
			stderr.writeln();
			break;
		}
		case "uipreview": {
			// Read-only semantic state produced by the Sound Editor's own graph simulator.
			// Tests compare this with wavepreview's independent player-order oracle.
			int ticks = val.length ? to!int(val) : 40;
			if(ticks < 1) ticks = 1;
			if(ticks > 256) ticks = 256;
			auto rows = mainui.toplevel.soundEditor.debugWaveRows(ticks);
			auto wave1 = mainui.toplevel.soundEditor.debugWaveTranspose(ticks);
			auto controls = mainui.toplevel.soundEditor.debugWaveControls(ticks);
			auto loop = mainui.toplevel.soundEditor.debugWaveLoop();
			stderr.writef("ui preview rows:");
			foreach(x; rows) stderr.writef(" %02X", x);
			stderr.writeln();
			stderr.writef("ui preview w1:");
			foreach(x; wave1) stderr.writef(" %02X", x);
			stderr.writeln();
			stderr.writef("ui preview ctrl:");
			foreach(x; controls) stderr.writef(" %02X", x);
			stderr.writeln();
			stderr.writefln("ui preview loop: %d/%d", loop[0], loop[1]);
			break;
		}
		case "voices": {
			// voices — per-voice visualizer state: the instrument each voice last
			// triggered, its brightness, and whether it has a per-frame recording +
			// how many frames (a read-only oracle for the Sound Editor recording view).
			static import audio.visualizer;
			foreach(v; 0 .. 3)
				stderr.writefln("voice%d: ins=%d bright=%.3f hasRec=%s recLen=%d", v,
					audio.visualizer.getVoiceInstrument(v),
					audio.visualizer.getVoiceBrightness(v),
					audio.visualizer.voiceHasRecording(v),
					audio.visualizer.getRecordingLength(v));
			break;
		}
		case "recdump": {
			// recdump:<voice> — print the recorded per-frame CONTROL, FREQ and PULSE
			// arrays for a voice. A read-only oracle for verifying that the Sound
			// Editor's §14.2 loop lines land on the frame where the recorded value
			// pattern actually repeats (value[L] == value[L+P]).
			static import audio.visualizer;
			int v = val.length ? to!int(val) : 0;
			auto ctrl = audio.visualizer.getRecordedControl(v);
			auto freq = audio.visualizer.getRecordedFreq(v);
			auto pw   = audio.visualizer.getRecordedPulse(v);
			auto amp  = audio.visualizer.getRecordedAmp(v);
			auto env  = audio.visualizer.getRecordedEnvelope(v);
			auto cut  = audio.visualizer.getRecordedCutoff(v);
			auto mode = audio.visualizer.getRecordedMode(v);
			auto res  = audio.visualizer.getRecordedResonance(v);
			auto route = audio.visualizer.getRecordedRouting(v);
			stderr.writef("rec v%d ctrl:", v);
			foreach(x; ctrl) stderr.writef(" %02X", x & 0xff);
			stderr.writeln();
			stderr.writef("rec v%d freq:", v);
			foreach(x; freq) stderr.writef(" %d", x);
			stderr.writeln();
			stderr.writef("rec v%d pulse:", v);
			foreach(x; pw) stderr.writef(" %d", x);
			stderr.writeln();
			stderr.writef("rec v%d amp:", v);
			foreach(x; amp) stderr.writef(" %.4f", x);
			stderr.writeln();
			stderr.writef("rec v%d env:", v);
			foreach(x; env) stderr.writef(" %02X", x);
			stderr.writeln();
			stderr.writef("rec v%d cutoff:", v);
			foreach(x; cut) stderr.writef(" %d", x);
			stderr.writeln();
			stderr.writef("rec v%d mode:", v);
			foreach(x; mode) stderr.writef(" %02X", x & 0x70);
			stderr.writeln();
			stderr.writef("rec v%d resonance:", v);
			foreach(x; res) stderr.writef(" %X", x & 0x0f);
			stderr.writeln();
			stderr.writef("rec v%d route:", v);
			foreach(x; route) stderr.writef(" %X", x & 0x0f);
			stderr.writeln();
			break;
		}
		case "insdump": {
			// insdump — print every instrument's AD/SR bytes with the decoded release
			// nibble. A read-only oracle for picking fast-R vs slow-R instruments when
			// verifying the Sound Editor's §12 auto-fit X-axis zoom.
			stderr.writeln("ins: AD SR (R nibble)");
			foreach(i; 0 .. 48) {
				ubyte ad = song.instrumentTable[i];
				ubyte sr = song.instrumentTable[i + 48];
				ubyte rst = song.instrumentTable[i + 2 * 48];
				string rstkind = (rst & 0xc0) == 0x80 ? "HARD"
					: (rst & 0xc0) == 0x40 ? "soft" : "3fr";
				stderr.writefln("ins%02X: AD=%02x SR=%02x R=%X rst=%02x(%s)",
					i, ad, sr, sr & 0x0f, rst, rstkind);
			}
			break;
		}
		case "seqdump": {
			// seqdump:<n> — dump sequence n's rows as hex (4 bytes/row). A
			// read-only oracle for verifying block copy/paste/merge/cut edits.
			int n = val.startsWith("0x") || val.startsWith("0X")
				? to!int(val[2..$], 16) : to!int(val);
			Sequence s = song.seqs[n];
			stderr.writef("seq %02X rows=%d:", n, s.rows);
			foreach(r; 0 .. s.rows)
				stderr.writef(" %02x%02x%02x%02x", s.data.raw[r*4], s.data.raw[r*4+1],
							  s.data.raw[r*4+2], s.data.raw[r*4+3]);
			stderr.writeln();
			break;
		}
		case "tracks": {
			// dump each voice's tracklist entries (trans,number) up to the end
			// mark — for verifying paste-new track insertion.
			foreach(v; 0 .. 3) {
				auto tl = song.tracks[v];
				stderr.writef("trk v%d:", v);
				for(int i = 0; i < tl.trackLength; i++)
					stderr.writef(" %02x%02x", tl[i].trans, tl[i].number);
				stderr.writeln();
			}
			break;
		}
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
	// Grid size. Default is the 160x50 MINIMUM; the real app autoscales to ~90% of the
	// desktop, so band heights (and anything derived from them) are much larger there.
	// `screen:COLSxROWS` reproduces a real window's geometry — pass it when a bug might
	// depend on band height rather than on the layout's minimum.
	int cols = 160, rows = 50;
	foreach(arg; args[1 .. $]) {
		if(!arg.startsWith("screen:")) continue;
		auto dims = arg["screen:".length .. $].split("x");
		if(dims.length == 2) { cols = to!int(dims[0]); rows = to!int(dims[1]); }
	}
	if(cols < 160) cols = 160;
	if(rows < 50) rows = 50;
	screen = new Screen(cols, rows);
	video = new VideoStandard(cols * FONT_X, rows * FONT_Y, screen, 0);
	seq.sequencer.initialHeight = rows - 10 > 64 ? 64 : rows - 10;
	// `wide` (anywhere in argv) selects the wide UI layout (com.fb.mode>0, the
	// app's autoscale default) — must be set before the UI/layout is built.
	foreach(arg; args[1 .. $]) {
		if(arg == "wide") com.fb.mode = 1;
		// `trace` mirrors the app's --verbose pitch-drag trace (com.fb.traceMouseDrag).
		if(arg == "trace") com.fb.traceMouseDrag = true;
	}
	initSession();
	mainui = new UI();
	mainui.update();

	// Batch: run argv commands in order. `serve`/`-` (anywhere) switches to a
	// persistent stdin loop afterwards, so the editor + Song stay alive across
	// many commands (a true stateful session, no per-step replay/rebuild).
	bool serve = false;
	foreach(arg; args[1 .. $]) {
		if(arg == "serve" || arg == "-") { serve = true; continue; }
		if(arg == "wide" || arg == "trace") continue;   // handled before UI construction
		if(arg.startsWith("screen:")) continue;        // ditto

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
