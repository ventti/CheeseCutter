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

// Default window width in pixels and corresponding default column count
enum DEFAULT_WINDOW_WIDTH_PX = 800;
enum DEFAULT_COLUMNS = DEFAULT_WINDOW_WIDTH_PX / FONT_X;

void initVideo(bool useFullscreen, bool useyuv, int seqHeight = 32, int windowWidthPx = 0) {
    int mx, my;

	if( SDL_Init(SDL_INIT_VIDEO) < 0) {
		throw new DisplayError("Couldn't initialize framebuffer.");
	}
    // Determine window (pixel) width. Default is current implementation (800px),
    // optionally overridden by --width (capped elsewhere to max 2x default).
    mx = windowWidthPx > 0 ? windowWidthPx : DEFAULT_WINDOW_WIDTH_PX;
	// Calculate height based on sequencer height plus overhead
	// Sequencer needs seqHeight rows, plus ~10 rows for header/status
	int totalRows = seqHeight + 10;
	my = totalRows * FONT_Y;

    // Keep logical UI width at the default character width so existing UI stays on the left.
    // Extra window width becomes free space on the right for optional future elements.
    int width = DEFAULT_WINDOW_WIDTH_PX / FONT_X;
	int height = my / FONT_Y;
	screen = new Screen(width, height);
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
    stderr.writefln("  --width [cols]   Set window width in columns (def=%d, max=%d)", DEFAULT_COLUMNS, DEFAULT_COLUMNS * 2);
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
    int requestedWindowWidth = 0; // pixels; 0 means use default
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
                int minCols = DEFAULT_COLUMNS;
                int maxCols = DEFAULT_COLUMNS * 2;
                if(wcols < minCols)
                    throw new UserException(format("Window width must be at least %d columns", minCols));
                if(wcols > maxCols)
                    throw new UserException(format("Window width cannot exceed %d columns", maxCols));
                requestedWindowWidth = wcols * FONT_X; // convert columns to pixels
                i++;
            }
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
	
	audio.player.init();
	// Use command-line height if specified, otherwise default to 32
	int effectiveHeight = sequencerHeight > 0 ? sequencerHeight : 32;
	if(sequencerHeight > 0) {
		seq.sequencer.initialHeight = sequencerHeight;
	}
    initVideo(fs, yuvOverlay, effectiveHeight, requestedWindowWidth);
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

