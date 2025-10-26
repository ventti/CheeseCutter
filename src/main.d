/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
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

version(Win32) {
	const DIR_SEPARATOR = '\\';
}

// Default compact mode dimensions
enum DEFAULT_COLUMNS = 100;  // 800px / 8px per char
enum DEFAULT_ROWS = 42;      // ~32 sequencer + 10 overhead

void initVideo(bool useFullscreen, bool useyuv, int seqHeight = 0, int uiWidthCols = 0, bool useAutoscale = false, out int actualSeqHeight) {
    int mx, my;
    int logicalCols, logicalRows;

	if( SDL_Init(SDL_INIT_VIDEO) < 0) {
		throw new DisplayError("Couldn't initialize framebuffer.");
	}

    // Autoscale mode: auto-scale to screen size
    if(useAutoscale) {
        SDL_DisplayMode dm;
        if(SDL_GetDesktopDisplayMode(0, &dm) == 0) {
            // Use 90% of screen dimensions for comfortable windowed mode
            mx = cast(int)(dm.w * 0.9);
            my = cast(int)(dm.h * 0.9);
            logicalCols = mx / FONT_X;
            logicalRows = my / FONT_Y;
        } else {
            // Fallback if query fails
            mx = 1600;
            my = 900;
            logicalCols = mx / FONT_X;
            logicalRows = my / FONT_Y;
        }
        // Calculate sequencer height from total rows (subtract overhead)
        actualSeqHeight = logicalRows - 10;
        // Clamp to valid range
        if(actualSeqHeight < 32) actualSeqHeight = 32;
        if(actualSeqHeight > 64) actualSeqHeight = 64;
    }
    // Compact mode or explicit dimensions
    else {
        // Determine logical rows (height in character rows)
        if(seqHeight > 0) {
            logicalRows = seqHeight + 10; // sequencer + overhead
            actualSeqHeight = seqHeight;
        } else {
            logicalRows = DEFAULT_ROWS;
            actualSeqHeight = DEFAULT_ROWS - 10; // 32 rows for sequencer
        }

        // Determine logical columns (width in character columns)
        if(uiWidthCols > 0) {
            logicalCols = uiWidthCols;
        } else {
            logicalCols = DEFAULT_COLUMNS;
        }

        // Convert to pixels
        mx = logicalCols * FONT_X;
        my = logicalRows * FONT_Y;
    }

    screen = new Screen(logicalCols, logicalRows);
    video = new VideoStandard(mx, my, screen, useFullscreen ? 1 : 0);

	// SDL_EnableKeyRepeat(200, 10);
	// SDL_EnableUNICODE(1);
	// SDL_WM_SetCaption("CheeseCutter".toStringz(),"CheeseCutter".toStringz());
}

void mainloop(bool verbose) {
	int mods, key, unicode;
	bool quit = false;
	SDL_Event evt;
	while(!quit) {
		int ticks = audio.timer.readTick();
		mainui.timerEvent(ticks);
		while(SDL_PollEvent(&evt)) {
			switch(evt.type) {
			case SDL_QUIT:
				quit = true;
				break;
			case SDL_KEYDOWN:
				if(mainui.activeInput !is null) {
					Cursor cursor = mainui.activeInput.cursor;
					if(cursor !is null) cursor.reset();
				}
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
					int cx = (x + 4) / 8, cy = y / 14;
					mainui.clickedAt(cx, cy, evt.button.button);
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
			case SDL_MOUSEMOTION:
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
			if(cursor !is null) cursor.blink();
		}
		SDL_Delay(40);
		video.updateFrame();
	}
}

void printheader() {
	stderr.writefln("CheeseCutter (C) 2009-15 Abaddon");
	stderr.writefln("Released under GNU GPL.");
	stderr.writef("\n");
	stderr.writefln("Usage: ccutter [OPTION]... [FILE]");
	stderr.writef("\n");
	stderr.writefln("Options:");
	stderr.writefln("  -b [value]       Set playback buffer size (def=%d)", audio.audio.bufferSize);
	stderr.writefln("  -f               Start in fullscreen mode");
	stderr.writefln("  -nofp            Do not use resid-fp emulation");
	stderr.writefln("  -fpr [x]         Specify filter preset. x = 0..16 for 6581 and 0..1 for 8580");
	stderr.writefln("  -i               Disable resid interpolation (use fast mode instead)");
	stderr.writefln("  -m [0|1]         Specify SID model for reSID (6581/8580) (def=0)");
	stderr.writefln("  -n               Enable NTSC mode");
	stderr.writefln("  -r [value]       Set playback frequency (def=48000)");
	stderr.writefln("  -y               Use YUV video overlay");
	stderr.writefln("  --height [rows]  Set sequencer height in rows (def=32, min=32, max=64)");
	stderr.writefln("  --width [cols]   Set UI width in columns (def=%d, min=%d, max=200)", DEFAULT_COLUMNS, DEFAULT_COLUMNS);
	stderr.writefln("  --autoscale      Auto-scale UI to screen size");
	stderr.writef("\n");
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
	bool useAutoscale = false;
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
			sequencerHeight = to!int(args[i+1]);
			if(sequencerHeight < 32)
				throw new UserException("Sequencer height must be at least 32 rows");
			if(sequencerHeight > 64)
				throw new UserException("Sequencer height cannot exceed 64 rows");
			i++;
			break;
		case "--width":
			{
				int wcols = to!int(args[i+1]);
				const int minCols = DEFAULT_COLUMNS;
				const int maxCols = 200;
				if(wcols < minCols)
					throw new UserException(format("Window width must be at least %d columns", minCols));
				if(wcols > maxCols)
					throw new UserException(format("Window width cannot exceed %d columns", maxCols));
				requestedUiWidth = wcols;
				i++;
			}
			break;
		case "--autoscale":
			useAutoscale = true;
			break;
		case "--verbose":
			verbose = true;
			break;
		default:
				version (OSX) {
					if (args[i].length > 3 && args[i][0..4] == "-psn"){
						break;
					}
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

	audio.player.init();

	// Initialize video and get the actual sequencer height
	int actualSeqHeight;
	initVideo(fs, yuvOverlay, sequencerHeight, requestedUiWidth, useAutoscale, actualSeqHeight);

	// Set sequencer initial height based on what initVideo calculated
	seq.sequencer.initialHeight = actualSeqHeight;

	initSession();
	mainui = new UI();
	loadFile(filename);
	video.updateFrame();

	SDL_PauseAudio(0);
	log("Started");
	mainloop(verbose);
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
		mainui.loadCallback(fn);
		mainui.update();
	}
}

