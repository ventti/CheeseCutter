/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Editor entry point — parses the CLI, initialises SDL/audio/framebuffer and the UI, then runs the main loop.
*/

module main;
import derelict.sdl2.sdl;
import com.fb;
import com.session;
import com.kbd;
import com.util;
import ct.base;
import ui.ui;
import ui.input;
import audio.player;
import audio.resid.filter;
import audio.audio, audio.callback, audio.timer;
static import audio.remote;
static import audio.ultimate;
static import audio.vice;
static import com.config;
static import com.palette;
import manpage;
import std.stdio;
import std.string;
import std.conv;
import std.file;
import std.experimental.logger;
import seq.sequencer;

version(linux) {
	const DIR_SEPARATOR = '/';
}

version(FreeBSD) {
	const DIR_SEPARATOR = '/';
}

version(OSX) {
	const DIR_SEPARATOR = '/';
}

version(Windows) {
	const DIR_SEPARATOR = '\\';
}

// Minimum / fixed-size-mode dimensions in characters. This is also the floor
// applied to autoscale, so the window is never smaller than 160x50 chars
// (1280x700 px at the 8x14 font).
enum DEFAULT_COLUMNS = 160;  // minimum UI width in characters
enum DEFAULT_ROWS = 50;      // minimum UI height in characters (40 seq + 10 overhead)

void initVideo(bool useFullscreen, bool useyuv, int seqHeight = 0, int uiWidthCols = 0, bool useAutoscale = false, out int actualSeqHeight) {
    int mx, my;
    int logicalCols, logicalRows;

	if( SDL_Init(SDL_INIT_VIDEO) < 0) {
		throw new DisplayError("Couldn't initialize framebuffer.");
	}

    // Autoscale mode (the default): size to ~90% of the screen.
    if(useAutoscale) {
        SDL_DisplayMode dm;
        if(SDL_GetDesktopDisplayMode(0, &dm) == 0) {
            // Use 90% of screen dimensions for comfortable windowed mode
            logicalCols = cast(int)(dm.w * 0.9) / FONT_X;
            logicalRows = cast(int)(dm.h * 0.9) / FONT_Y;
        } else {
            // Fallback if the display query fails: use the minimum size.
            logicalCols = DEFAULT_COLUMNS;
            logicalRows = DEFAULT_ROWS;
        }
    }
    // Fixed-size mode: explicit --width / --height (autoscale disabled).
    else {
        logicalCols = uiWidthCols > 0 ? uiWidthCols : DEFAULT_COLUMNS;
        logicalRows = seqHeight > 0 ? seqHeight + 10 : DEFAULT_ROWS;
    }

    // Enforce the 160x50 character minimum window in every mode.
    if(logicalCols < DEFAULT_COLUMNS) logicalCols = DEFAULT_COLUMNS;
    if(logicalRows < DEFAULT_ROWS) logicalRows = DEFAULT_ROWS;

    // Sequencer height follows the window height, capped to its valid range.
    actualSeqHeight = logicalRows - 10;
    if(actualSeqHeight > 64) {
        actualSeqHeight = 64;
        logicalRows = actualSeqHeight + 10;
    }

    // Convert to pixels (aligned to the character grid).
    mx = logicalCols * FONT_X;
    my = logicalRows * FONT_Y;

    screen = new Screen(logicalCols, logicalRows);
    video = new VideoStandard(mx, my, screen, useFullscreen ? 1 : 0);

	// Deliver layout/Shift/AltGr-aware composed characters as SDL_TEXTINPUT events
	// (so text fields can type e.g. '$' regardless of keyboard layout). Keydown
	// still drives shortcuts/navigation; see the SDL_TEXTINPUT case in mainloop().
	SDL_StartTextInput();

	// SDL_EnableKeyRepeat(200, 10);
	// SDL_EnableUNICODE(1);
	// SDL_WM_SetCaption("CheeseCutter".toStringz(),"CheeseCutter".toStringz());
}

// Publish the letterbox-corrected mouse position in grid pixels for widgets that need
// sub-cell precision (see com.fb.mousePixelX/Y). The UI itself keeps receiving character
// cells; this is strictly extra resolution alongside it, never a replacement.
private void publishMousePixel(int x, int y) {
	com.fb.mousePixelX = x;
	com.fb.mousePixelY = y;
}

void mainloop(bool verbose) {
	int mods, key, unicode;
	bool quit = false;
	SDL_Event evt;
	uint lastTimer = SDL_GetTicks() - 40;
	while(!quit) {
		uint frameStart = SDL_GetTicks();
		// Preserve the legacy timer cadence: status timeouts and cursor blink
		// count ticks. Input/presentation can run faster without shortening them.
		bool timerDue = frameStart - lastTimer >= 40;
		if(timerDue) {
			lastTimer += ((frameStart - lastTimer) / 40) * 40;
			int ticks = audio.timer.readTick();
			mainui.timerEvent(ticks);
		}
		while(SDL_PollEvent(&evt)) {
			switch(evt.type) {
			case SDL_QUIT:
				// Window close / macOS Cmd-Q: don't force-quit — show the same
				// confirmation Ctrl-Q does. The dialog's "y" sets exitRequested,
				// which ends the loop (checked after keydown, below).
				mainui.requestExit();
				break;
			case SDL_KEYDOWN:
				// Erase the focused field's cursor highlight before handling the
				// key, so a move never leaves an inverse-video "shadow" at the old
				// position (clear() repaints that cell to its original colors). The
				// cursor is re-established at the new position by the field on
				// keypress and by the per-frame activeInput.update(). Mirrors the
				// mouse path (UI.clickedAt clears the cursor up front).
				if(mainui.activeInput !is null && mainui.activeInput.cursor !is null)
					mainui.activeInput.cursor.clear();
				mods = evt.key.keysym.mod;
				key = evt.key.keysym.sym;

				// Global screenshot shortcut (Ctrl+F12)
				if(key == SDLK_F12 && (mods & KMOD_CTRL)) {
					video.saveScreenshot("");
					break;
				}

				// In SDL2, unicode field is not populated - use sym instead for ASCII range
				unicode = (key >= 0 && key <= 127) ? key : evt.key.keysym.unicode;
				mods &= 0xffffff - KMOD_NUM;
				if (verbose) {
					stderr.writefln("DEBUG: Key event - sym=%d mods=%04x unicode=%d", key, mods, unicode);
				}
				auto keyinfo = Keyinfo(key, mods, unicode);
				com.kbd.translate(keyinfo);
                // FIXME
				version(OSX) {
					if (key == SDLK_q && evt.key.keysym.mod & KMOD_GUI)
						quit=true;
				}

				mainui.keypress(keyinfo);
				if(mainui.exitRequested)
					quit = true;

				mainui.update();
				break;
			case SDL_TEXTINPUT:
				// Layout/Shift/AltGr-aware composed characters for text fields
				// (e.g. '$' = AltGr-4 on a Swedish/Finnish layout). Routed only to
				// the focused text field; ignored elsewhere. Keydown still drives
				// shortcuts, navigation and the sequencer/table grids.
				mainui.textInput(std.string.fromStringz(&evt.text.text[0]).idup);
				mainui.update();
				break;
			case SDL_KEYUP:
				mods = evt.key.keysym.mod;
				key = evt.key.keysym.sym;
				unicode = evt.key.keysym.unicode;
				mods &= 0xffff - KMOD_NUM;
				Keyinfo keyinfo = Keyinfo(key, mods, unicode);
//				com.kbd.translate(keyinfo);
				mainui.keyrelease(keyinfo);
				break;
			case SDL_MOUSEBUTTONDOWN:
				switch(evt.button.button) {
				case 1, 3:
					int x, y;
					SDL_GetMouseState(&x, &y);
					video.scalePosition(x, y);
					publishMousePixel(x, y);
					int cx = x / FONT_X, cy = y / FONT_Y;
					mainui.clickedAt(cx, cy, evt.button.button, evt.button.clicks);
					break;
				case 5:
					//rootwin.windowByCoord(cx, cy).mousewheelDown();
					mainui.keypress(Keyinfo(SDLK_DOWN, 0, 0));
					break;
				case 4:
					mainui.keypress(Keyinfo(SDLK_UP, 0, 0));
					break;
				default:
					break;
				}
				mainui.update();
				break;
			case SDL_MOUSEWHEEL:
				{
					// SDL2 wheel event: positive y typically means scroll up.
					int stepsY = evt.wheel.y;
					if (evt.wheel.direction == SDL_MouseWheelDirection.SDL_MOUSEWHEEL_FLIPPED) {
						stepsY = -stepsY;
					}
					if (stepsY != 0) {
						int count = stepsY > 0 ? stepsY : -stepsY;
						int keycode = stepsY > 0 ? SDLK_UP : SDLK_DOWN;
						foreach (s; 0 .. count) {
							mainui.keypress(Keyinfo(keycode, 0, 0));
						}
						mainui.update();
					}
				}
				break;
			case SDL_MOUSEBUTTONUP:
				if(evt.button.button == 1) {
					int x, y;
					SDL_GetMouseState(&x, &y);
					video.scalePosition(x, y);
					publishMousePixel(x, y);
					mainui.releasedAt(x / FONT_X, y / FONT_Y);
					mainui.update();
				}
				break;
			case SDL_MOUSEMOTION:
				{
					int x = evt.motion.x, y = evt.motion.y;
					video.scalePosition(x, y);
					publishMousePixel(x, y);
					if(evt.motion.state & SDL_BUTTON_LMASK) {
						// Drag = motion with the left button held.
						bool menuDrag = mainui.menubar.active;
						mainui.draggedTo(x / FONT_X, y / FONT_Y);
						if(menuDrag) mainui.updateMenu();
						else mainui.update();
					}
					// Plain hover: only the focused menu bar reacts; redraw on change.
					else if(mainui.hoverAt(x / FONT_X, y / FONT_Y)) {
						if(mainui.menubar.active) mainui.updateMenu();
						else mainui.update();
					}
				}
				break;
        //			case SDL_ACTIVEEVENT:
				//break;
        //case SDL_VIDEORESIZE:
				//video.resizeEvent(evt.resize.w, evt.resize.h);
				//break;
        //case SDL_VIDEOEXPOSE:
				//mainui.update();
				//break;
			default:
				//writeln("Unknown SDL event ",evt.type);
				break;
			}
		}
		if(mainui.activeInput !is null) {
			mainui.activeInput.update();
			Cursor cursor = mainui.activeInput.cursor;
			if(cursor !is null && timerDue) cursor.blink();
		}
		video.updateFrame();

		// Mirror any edited song data to the remote backend (no-op when
		// nothing changed). Re-injects the image if a new song was loaded.
		if(audio.remote.isActive()) {
			audio.remote.ensureLoaded(song);   // also drives the post-inject SID readback
			audio.remote.syncDeltas(song);
		}
		// Present input feedback immediately, then pace the whole frame (~60 Hz).
		// Rendering/backend work counts toward the budget instead of adding to it.
		uint elapsed = SDL_GetTicks() - frameStart;
		if(elapsed < 16) SDL_Delay(16 - elapsed);
	}
}

// Single source of truth for the command-line options. Both --help
// (printheader) and the localized man pages (--dump-man, see module manpage)
// are generated from this list, so they can never drift out of sync. Keep new
// CLI flags here only. (CliOpt is defined in module manpage.)
CliOpt[] cliOptions() {
	return [
		CliOpt("-b", "[value]", format("Set playback buffer size (def=%d)", audio.audio.bufferSize)),
		CliOpt("-f, --full", "", "Start in fullscreen mode"),
		CliOpt("-nofp", "", "Do not use resid-fp emulation"),
		CliOpt("-fpr", "[x]", "Specify filter preset. x = 0..16 for 6581 and 0..1 for 8580"),
		CliOpt("-i", "", "Disable resid interpolation (use fast mode instead)"),
		CliOpt("-l", "", "Enable VIC-II badline timing emulation"),
		CliOpt("-m", "[0|1]", "Specify SID model for reSID (6581/8580) (def=0)"),
		CliOpt("-n", "", "Enable NTSC mode"),
		CliOpt("-r", "[value]", "Set playback frequency (def=48000)"),
		CliOpt("-y", "", "Use YUV video overlay"),
		CliOpt("-h, --help", "", "Show this help and exit"),
		CliOpt("--height", "[rows]", format("Set sequencer height in rows (min=%d, max=64); disables autoscale", DEFAULT_ROWS - 10)),
		CliOpt("--width", "[cols]", format("Set UI width in columns (min=%d, max=200); disables autoscale", DEFAULT_COLUMNS)),
		CliOpt("--dump-keys", "", "Print the keyboard reference as Markdown and exit"),
		CliOpt("--dump-man", "", "Print the man page (roff) to stdout and exit"),
		CliOpt("--ultimate", "[IP]", "Play on a C64 Ultimate (1541U/Ultimate64) at IP over its REST API"),
		CliOpt("--ultimate-port", "[n]", "REST API port for --ultimate (def=80)"),
		CliOpt("--vice", "", "Play on a VICE x64sc (launches x64sc from PATH). --vice=host:port attaches to a running -binarymonitor; --vice=/path/x64sc launches that binary"),
		CliOpt("--vice-port", "[n]", "Binary-monitor port for --vice (def=6502)"),
		CliOpt("--palette", "[file]", "Load a JSON color palette (default: palette.json in the config dir)"),
		CliOpt("--verbose", "", "Enable verbose logging"),
	];
}

void printheader() {
	stderr.writefln("%s %s", com.util.APP_NAME, com.util.APP_VERSION);
	stderr.writefln("Based on %s %s.", com.util.UPSTREAM_NAME, com.util.UPSTREAM_VERSION);
	stderr.writefln("CheeseCutter (C) 2009-15 Abaddon");
	stderr.writefln("Released under GNU GPL.");
	stderr.writef("\n");
	stderr.writefln("Usage: ccutter [OPTION]... [FILE]");
	stderr.writef("\n");
	stderr.writefln("Options:");
	foreach(o; cliOptions()) {
		string left = o.arg.length ? o.flags ~ " " ~ o.arg : o.flags;
		stderr.writefln("  %-18s %s", left, o.help);
	}
	stderr.writefln("  The UI auto-scales to the screen by default (minimum %dx%d chars);", DEFAULT_COLUMNS, DEFAULT_ROWS);
	stderr.writefln("  pass --width and/or --height for a fixed size. Set");
	stderr.writefln("  CHEESECUTTER_ULTIMATE_PASSWORD for the C64 Ultimate X-Password header.");
	stderr.writef("\n");
}

// Parse a numeric command-line option without crashing on bad input. Reports a
// friendly error via UserException (caught in main) for a missing or
// non-numeric value.
int intOption(char[][] args, int i, string name) {
	if(i + 1 >= args.length)
		throw new UserException(format("Option %s requires a numeric value.", name));
	try
		return to!int(args[i + 1]);
	catch(std.conv.ConvException)
		throw new UserException(format("Option %s expects a number, got \"%s\".",
									   name, args[i + 1]));
}

int main(char[][] args) {
	int i;
	bool fs = false;
	bool yuvOverlay;
	string filename;
	bool fnDefined = false;
	int sequencerHeight = 0; // 0 means use default
	bool verbose = false;
	int requestedUiWidth = 0; // columns; 0 means use default
	bool useAutoscale = true; // autoscale by default; --width/--height disables it
	bool dumpKeys = false;
	bool ultimateOn = false;
	string ultimateHost;
	int ultimatePort = 80;
	bool viceOn = false;
	string viceTarget;
	int vicePort = 0; // 0 => transport default (6502)
	string paletteFile = null; // null => load the per-user default path (if any)

	// Read persisted user preferences (creates the file with defaults if absent).
	// These seed the backend/driver below; explicit CLI flags still take priority.
	com.config.load();
	// Seed the reSID model + filter presets from saved prefs (an explicit CLI
	// -m / -fpr below still overrides; both take effect once audio inits).
	audio.player.sidtype = com.config.prefs.sidModel ? 1 : 0;
	if(FP6581.length) audio.player.curfp6581 = com.config.prefs.filter6581 % cast(int)FP6581.length;
	if(FP8580.length) audio.player.curfp8580 = com.config.prefs.filter8580 % cast(int)FP8580.length;
  // DerelictSDL2.load();

	scope(exit) {
		destroy(mainui);
		destroy(video);
		SDL_Quit();
	}

	scope(failure) {
		if(song !is null) {
			stderr.writefln("Crashed! Saving backup...");
			song.save("_backup.ct");
		}
	}

	try {
		i = 1;
		while(i < args.length) {
			switch(args[i])
			{
			case "-h", "-help", "--help", "-?":
				printheader();
				return 0;
			case "--dump-man":
				{
					// optional language code: --dump-man [en|fr|de|sv|fi]
					string lang = "";
					if(i + 1 < args.length && args[i+1].length && args[i+1][0] != '-') {
						lang = cast(string)args[i+1].dup;
						i++;
					}
					std.stdio.write(dumpManPage(cliOptions(), lang));
					return 0;
				}
			case "-m":
				sidtype = to!int(args[i+1]);
				if(sidtype != 0 && sidtype != 1 && sidtype != 6581 && sidtype != 8580)
					throw new UserException("Incorrect SID type; specify 0 for 6581 or 1 for 8580");
				i++;
				break;
        	case "-fpr":
				int fprarg = to!int(args[i+1]);

				sidtype ? (audio.player.curfp8580 = cast(int)(fprarg % FP8580.length)) :
					(audio.player.curfp6581 = cast(int)(fprarg % FP6581.length));
				i++;
				break;
			case "-i":
				audio.player.interpolate = 0;
				break;
			case "-l":
				audio.player.badline = 1;
				break;
			case "-n":
				audio.player.ntsc = 1;
				break;
			case "-r":
				audio.audio.freq = to!int(args[i+1]);
				i++;
				break;
			case "-b":
				audio.audio.bufferSize = to!int(args[i+1]);
				i++;
				break;
			case "-f","--full":
				fs = true;
				break;
			case "-nofp":
				audio.player.usefp = 0;
				break;
		case "-y", "-ya", "-yuv":
			yuvOverlay = true;
			break;
		case "--height":
			{
				// Window minimum is 160x50 chars, i.e. >= 40 sequencer rows.
				const int minRows = DEFAULT_ROWS - 10;
				const int maxRows = 64;
				int h = intOption(args, i, "--height");
				if(h < minRows)
					throw new UserException(format("Sequencer height must be at least %d rows", minRows));
				if(h > maxRows)
					throw new UserException(format("Sequencer height cannot exceed %d rows", maxRows));
				sequencerHeight = h;
				useAutoscale = false; // explicit size disables autoscale
				i++;
			}
			break;
		case "--width":
			{
				const int minCols = DEFAULT_COLUMNS;
				const int maxCols = 200;
				int wcols = intOption(args, i, "--width");
				if(wcols < minCols)
					throw new UserException(format("Window width must be at least %d columns", minCols));
				if(wcols > maxCols)
					throw new UserException(format("Window width cannot exceed %d columns", maxCols));
				requestedUiWidth = wcols;
				useAutoscale = false; // explicit size disables autoscale
				i++;
			}
			break;
		case "--dump-keys":
			dumpKeys = true;
			break;
		case "--ultimate":
			if(i + 1 >= args.length || args[i+1][0] == '-')
				throw new UserException("Option --ultimate requires an IP address.");
			ultimateHost = cast(string)args[i+1].dup;
			ultimateOn = true;
			i++;
			break;
		case "--ultimate-port":
			ultimatePort = intOption(args, i, "--ultimate-port");
			i++;
			break;
		case "--vice":
			// Bare: launch x64sc from PATH. Explicit target via --vice=<target>
			// (handled in the default case below).
			viceOn = true;
			break;
		case "--vice-port":
			vicePort = intOption(args, i, "--vice-port");
			i++;
			break;
		case "--palette":
			if(i + 1 >= args.length)
				throw new UserException("Option --palette requires a file path.");
			paletteFile = cast(string)args[i + 1].dup;
			i++;
			break;
		case "--verbose":
			verbose = true;
			com.fb.traceMouseDrag = true;   // per-tick pitch-drag mouse/geometry trace
			break;
		default:
				version (OSX) {
					if (args[i].length > 3 && args[i][0..4] == "-psn"){
						break;
					}
				}
				if(args[i].length >= 7 && args[i][0..7] == "--vice=") {
					viceTarget = cast(string)args[i][7..$].dup;
					viceOn = true;
					break;
				}
				if(args[i][0] == '-')
					throw new UserException(format("Unrecognized option %s", args[i]));
				if(fnDefined)
					throw new UserException("Filename already defined.");
				filename = cast(string)args[i].dup;
				if(std.file.exists(filename) == 0 || std.file.isDir(filename)) {
					throw new UserException("File not found!");
				}
				fnDefined = true;

				break;
			}
			i++;
		}
	}
	catch(UserException e) {
		std.stdio.stderr.writeln(e);
		return -1;
	}

	// Apply UI mode selection before initializing UI layout
	if(useAutoscale) {
		com.fb.mode = 1;
	}

	if(ultimateOn && viceOn) {
		std.stdio.stderr.writeln("Error: --ultimate and --vice are mutually exclusive.");
		return -1;
	}
	// No backend on the command line: fall back to the saved preference.
	if(!ultimateOn && !viceOn) {
		if(com.config.prefs.backend == "ultimate") {
			ultimateOn = true;
			ultimateHost = com.config.prefs.ultimateHost;
			ultimatePort = com.config.prefs.ultimatePort;
		}
		else if(com.config.prefs.backend == "vice") {
			viceOn = true;
			viceTarget = com.config.prefs.x64scPath;
		}
	}
	if(ultimateOn)
		audio.ultimate.configure(ultimateHost, ultimatePort, audio.player.ntsc != 0);
	if(viceOn)
		audio.vice.configure(viceTarget, vicePort, audio.player.ntsc != 0);

	audio.player.init();

	// Apply the saved SDL audio driver (empty = SDL default). Done after the
	// device is open; setAudioDriver re-opens it with the chosen driver.
	if(com.config.prefs.audioDriver.length)
		audio.audio.setAudioDriver(com.config.prefs.audioDriver);

	// Load the color palette (JSON) before any rendering. An explicit --palette
	// path wins; otherwise the per-user default is used if present; any error
	// falls back to the built-in C64 defaults.
	com.palette.initPalette(paletteFile);

	// Initialize video and get the actual sequencer height
	int actualSeqHeight;
	initVideo(fs, yuvOverlay, sequencerHeight, requestedUiWidth, useAutoscale, actualSeqHeight);

	// Set sequencer initial height based on what initVideo calculated
	seq.sequencer.initialHeight = actualSeqHeight;

	initSession();
	mainui = new UI();
	if(dumpKeys) {
		import ui.shorthelp : exportMarkdown;
		std.stdio.write(exportMarkdown(mainui.sm));
		return 0;
	}
	loadFile(filename);
	video.updateFrame();

	// Bring up the remote backend and inject the player + current song image.
	if(audio.remote.isActive())
		audio.remote.ensureLoaded(song);

	SDL_PauseAudio(0);
	log("Started");
	mainloop(verbose);
	if(audio.remote.isActive())
		audio.remote.shutdown();
	audio.audio.audio_close();
	return 0;
}

void openFile(char* filename){
	string str = to!(string)(filename);
	loadFile(str);

}

void loadFile(string filename){
	if(filename && mainui) {
		string dir, fn;
		int sep = cast(int) filename.lastIndexOf(DIR_SEPARATOR);
		fn = filename[sep + 1..$];
		if(sep >= 0)
			dir = filename[0 .. sep];
		else dir = ".";
		chdir(dir);
		mainui.openFile(fn);
		mainui.update();
	}
}
