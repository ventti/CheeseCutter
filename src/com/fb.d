/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
*/

module com.fb;
import derelict.sdl2.sdl;
import std.string : indexOf;
import com.util;

SDL_Color[] PALETTE = [
	{ 0x00, 0x00, 0x00 },       // 0
	{ 0xfe, 0xfe, 0xfe },       // 1
	{ 0x81, 0x33, 0x37 },       // 2
	{ 0x75, 0xce, 0xc8 },       // 3
	{ 0x8d, 0x3b, 0x97 },       // 4
	{ 0x55, 0xac, 0x4d },       // 5
	{ 0x2d, 0x2b, 0x9a },       // 6
	{ 0xed, 0xf0, 0x71 },       // 7
	{ 0x8d, 0x50, 0x29 },       // 8
	{ 0x54, 0x37, 0x00 },       // 9
	{ 0xc4, 0x6c, 0x71 },       // 10
	{ 0x49, 0x49, 0x49 },       // 11
	{ 0x7b, 0x7b, 0x7b },       // 12
	{ 0xa9, 0xfe, 0x9f },       // 13
	{ 0x6f, 0x6d, 0xeb },       // 14
	{ 0xb1, 0xb1, 0xb1 },       // 15

	// Brightness gradient colors (16-31): from mid-blue #303090 to black #000000
	// Used for ADSR envelope visualization
	{ 0x18, 0x18, 0x48 },  // 16: Brightest (step 15/15, halved)
	{ 0x16, 0x16, 0x42 },  // 17: step 14/15
	{ 0x14, 0x14, 0x3C },  // 18: step 13/15
	{ 0x12, 0x12, 0x36 },  // 19: step 12/15
	{ 0x10, 0x10, 0x30 },  // 20: step 11/15
	{ 0x0E, 0x0E, 0x2A },  // 21: step 10/15
	{ 0x0C, 0x0C, 0x24 },  // 22: step 9/15
	{ 0x0A, 0x0A, 0x1E },  // 23: step 8/15
	{ 0x08, 0x08, 0x18 },  // 24: step 7/15
	{ 0x06, 0x06, 0x12 },  // 25: step 6/15
	{ 0x04, 0x04, 0x0C },  // 26: step 5/15
	{ 0x03, 0x03, 0x09 },  // 27: step 4/15
	{ 0x02, 0x02, 0x06 },  // 28: step 3/15
	{ 0x01, 0x01, 0x04 },  // 29: step 2/15
	{ 0x01, 0x01, 0x03 },  // 30: step 1/15
	{ 0x00, 0x00, 0x00 }   // 31: Darkest (step 0/15) - black
];

immutable FONT_X = 8, FONT_Y = 14;
__gshared ubyte[] font;

// Splash artwork: raw 320x200 array of PALETTE indices (see tools/mk-splash.py),
// shown by Video.drawSplash() in place of the text grid while splashActive.
immutable SPLASH_W = 320, SPLASH_H = 200, SPLASH_SCALE = 2;
immutable ubyte[] splashData = cast(immutable(ubyte)[])import("splash.dat");

int mode; // 0 = compact (default), >0 = wide
immutable int border = 1;
private bool isDirty = false;

immutable CHECKX = "assert(x >= 0 && x < width);";
immutable CHECKY = "assert(y >= 0 && y < height);";
immutable CHECKS = "assert(x >= 0 && y >= 0 && x + y * width >= 0 && x + y * width < width*height);";

static this() {
	void[] arr;
	font.length = 256*16;
	// realign font data
	immutable rawfont = import("font.psf");
	for(int i=0;i<256;i++) {
		font[i*16..i*16+FONT_Y] = cast(ubyte[])rawfont[i*FONT_Y+4..i*FONT_Y+4+FONT_Y];
	}
}

abstract class Video {
	protected {
		//SDL_Surface* surface;
    SDL_Window* window;
    SDL_Renderer* renderer;
    SDL_Texture* texture;
		bool useFullscreen;
		Screen screen;
		Visualizer vis;
		const int requestedWidth, requestedHeight;
		int height, width; // resolution of window
		//int displayHeight, displayWidth; // resolution of the monitor
		SDL_Rect rect;
	}

	this(int wx, int wy, Screen scr, int fs) {
		//const SDL_VideoInfo* vidinfo = SDL_GetVideoInfo();
		screen = scr;
		//displayHeight = vidinfo.current_h;
		//displayWidth = vidinfo.current_w;
		requestedHeight = wy;
		requestedWidth = wx;

	}

	~this() {
    if(window !is null)
      SDL_DestroyWindow(window);
	}

	abstract void drawVisualizer(int);

	abstract void clearVisualizer();

	abstract protected void enableFullscreen(bool fs);

	void resizeEvent(int nw, int nh) {
	}

	void toggleFullscreen() {
		useFullscreen ^= 1;
		enableFullscreen(useFullscreen);
	}

	void scalePosition(ref int x, ref int y) {
		x -= rect.x;
		y -= rect.y;
    /+
		x *= cast(float)requestedWidth / width;
		y *= cast(float)requestedHeight / height;
    +/
	}

	void saveScreenshot(string filename) {
		import std.stdio : writefln;
		import std.datetime.systime : Clock;
		import std.format : format;
		import std.string : toStringz;

		// Generate filename if not provided
		if(filename == "") {
			auto now = Clock.currTime();
			filename = format("screenshot_%04d%02d%02d_%02d%02d%02d.bmp",
				now.year, now.month, now.day, now.hour, now.minute, now.second);
		}

		// Create a surface to capture the renderer content
		SDL_Surface* surface = SDL_CreateRGBSurface(0, width, height, 32,
			0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000);

		if(surface is null) {
			writefln("Error: Could not create surface for screenshot");
			return;
		}

		// Read pixels from renderer
		SDL_RenderReadPixels(renderer, null, SDL_PIXELFORMAT_ARGB8888, surface.pixels, surface.pitch);

		// Save to BMP file using SDL_SaveBMP_RW
		SDL_RWops* rw = SDL_RWFromFile(filename.toStringz(), "wb");
		if(rw !is null) {
			if(SDL_SaveBMP_RW(surface, rw, 1) == 0) {
				writefln("Screenshot saved: %s", filename);
			} else {
				writefln("Error saving screenshot: %s", SDL_GetError());
			}
		} else {
			writefln("Error opening file for screenshot: %s", SDL_GetError());
		}

		SDL_FreeSurface(surface);
	}

	// When set, updateFrame() blits the splash image instead of the text grid.
	// Toggled by AboutDialog (ui.dialogs). Declared as a trailing field and with
	// no new virtual method so the class layout/vtable stays compatible with
	// objects compiled before this change (the repo has no dep tracking).
	bool splashActive;

	abstract void updateFrame();
}

class VideoStandard : Video {
	this(int wx, int wy, Screen scr, int fs) {
		super(wx, wy, scr, fs);
		enableFullscreen(fs > 0);
	}

	override protected void enableFullscreen(bool fs) {
		width = requestedWidth;
		height = requestedHeight;
		useFullscreen = fs;

		// Create window with proper dimensions and fullscreen flag
		SDL_WindowFlags flags = cast(SDL_WindowFlags)0;
		if(fs) {
			flags = SDL_WINDOW_FULLSCREEN_DESKTOP;
		}

		SDL_CreateWindowAndRenderer(width, height, flags, &window, &renderer);
		if(window is null || renderer is null) {
			throw new DisplayError("Unable to initialize graphics mode.");
		}

		SDL_SetWindowTitle(window, com.util.APP_NAME);
		SDL_StartTextInput();
		SDL_RaiseWindow(window);

		screen.refresh();
	}

	override void drawVisualizer(int n) {
	}

	override void clearVisualizer() {
	}

	private SDL_Texture* splashTexture;

	// Not an override: kept off the base Video vtable so stale objects keep
	// calling updateFrame() at the right slot (no dep tracking in this repo).
	void drawSplash() {
		// Lazily upload the 320x200 indexed artwork into an ARGB texture, then
		// blit it centered at SPLASH_SCALE with a black margin.
		if(splashTexture is null) {
			splashTexture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
											  SDL_TEXTUREACCESS_STATIC, SPLASH_W, SPLASH_H);
			auto buf = new Uint32[SPLASH_W * SPLASH_H];
			foreach(i, idx; splashData) {
				auto col = PALETTE[idx];
				buf[i] = (0xff << 24) | (col.r << 16) | (col.g << 8) | col.b;
			}
			SDL_UpdateTexture(splashTexture, null, buf.ptr,
							  SPLASH_W * cast(int)Uint32.sizeof);
		}
		SDL_Rect dst;
		dst.w = SPLASH_W * SPLASH_SCALE;
		dst.h = SPLASH_H * SPLASH_SCALE;
		dst.x = (width - dst.w) / 2;
		dst.y = (height - dst.h) / 2;
		SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
		SDL_RenderClear(renderer);
		SDL_RenderCopy(renderer, splashTexture, null, &dst);
		SDL_RenderPresent(renderer);
	}

	override void updateFrame() {
		int x, y;
		int a,b,c;

		if(splashActive) { drawSplash(); return; }

		Uint32* bptr = &screen.data[0];
		Uint32* cptr = &screen.olddata[0];
		// Uint32* sptr = cast(Uint32 *)surface.pixels;
		Uint32* sp;
		Uint8* bp;
		Uint8 ubg, ufg;
		int outx, outy;

			if (!isDirty) return;
		isDirty = false;

        SDL_Rect rect;
        rect.x = 0;
        rect.y = 0;
        rect.w = width;
        rect.h = height;
        //SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        //SDL_RenderDrawRect(renderer, &rect);
		//SDL_LockSurface(surface);
        SDL_RenderClear(renderer);

			// Draw a unified header background across the full window width (top bar)
			{
				int headerBg = screen.getbg(screen.width - 1, 0);
				SDL_SetRenderDrawColor(renderer, PALETTE[headerBg].r,
							   PALETTE[headerBg].g,
							   PALETTE[headerBg].b, 255);
				SDL_Rect topbar;
				topbar.x = 0;
				topbar.y = 0;
				topbar.w = width;
				topbar.h = FONT_Y; // one text row height
				SDL_RenderFillRect(renderer, &topbar);
			}
		for(y = 0;y < screen.height; y++) {
			for(x = 0; x < screen.width; x++) {
				//if(*bptr != *cptr) {
                if(true) {
					*cptr = *bptr;
					//sp = sptr;
					a = *bptr & 255;
					bp = &font[a * 16];
					ufg = (*bptr >> 8) & 0xff;  // 8 bits for fg
					ubg = (*bptr >> 16) & 0xff; // 8 bits for bg
                    /+
                     auto fgcolor = getColor(surface, ufg),
                     bgcolor = getColor(surface, ubg);
                     +/
                    rect.x = x * 8;
                    rect.y = y * FONT_Y;
                    rect.h = FONT_Y;
                    rect.w = 8;
                    SDL_SetRenderDrawColor(renderer, PALETTE[ubg].r,
                                           PALETTE[ubg].g,
                                           PALETTE[ubg].b, 255);
                    SDL_RenderFillRect(renderer, &rect);

                    SDL_SetRenderDrawColor(renderer, PALETTE[ufg].r,
                                           PALETTE[ufg].g,
                                           PALETTE[ufg].b, 255);
                    int yy = y * FONT_Y;
					for(c = 4; c < 4 + FONT_Y; c++, bp++) {
                        int xx = x * 8;
						b = *bp;
						if(b & 0x80) {
                            SDL_RenderDrawPoint(renderer, xx, yy);
                        }
                        xx++;
						if(b & 0x40) {
                            SDL_RenderDrawPoint(renderer, xx, yy);
                        }
                        xx++;
						if(b & 0x20) {
                            SDL_RenderDrawPoint(renderer, xx, yy);
                        }
                        xx++;
						if(b & 0x10) {
                            SDL_RenderDrawPoint(renderer, xx, yy);
                        }
                        xx++;
						if(b & 0x08) {
                            SDL_RenderDrawPoint(renderer, xx, yy);
                        }
                        xx++;
						if(b & 0x04) {
                            SDL_RenderDrawPoint(renderer, xx, yy);
                        }
                        xx++;
						if(b & 0x02) {
                            SDL_RenderDrawPoint(renderer, xx, yy);
                        }
                        xx++;
						if(b & 0x01) {
                            SDL_RenderDrawPoint(renderer, xx, yy);
                        }
                        xx++;
						sp += width - 8;
                        yy++;
					}

				}
				//sptr += 8;
				bptr++;
				cptr++;
			}
			//sptr += width*13;
		}
			//SDL_UnlockSurface(surface);
			//SDL_Flip(surface);
    SDL_RenderPresent(renderer);
	}

}

class Screen {
	Uint32[] data;
	private Uint32[] olddata;
	immutable int width, height;
	alias width w;
	alias height h;

	this(int xchars, int ychars) {
		width = xchars;
		height = ychars;
		data.length = xchars * ychars;
		olddata.length = xchars * ychars;
		refresh();
	}

	Uint32 getChar(int x, int y) {
		mixin(CHECKS);
		return data[x + y * width];
	}

	void setChar(int x, int y, Uint32 c) {
		mixin(CHECKS);
		data[x + y * width] = c;
		isDirty = true;
	}

	void setColor(int x, int y, int fg, int bg) {
		mixin(CHECKS);
		Uint32* s = &data[x + y * width];
		*s &= 0xff;
		*s |= (fg << 8) | (bg << 16);  // bg now at bit 16 (8 bits available)
		isDirty = true;
	}

	int getbg(int x, int y) {
		return (getChar(x, y) >> 16) & 0xff;  // Extract 8 bits from position 16
	}

	void setbg(int x, int y, int bg) {
		Uint32* s = &data[x + y * width];
		*s &= 0xff00ff;  // Clear bg bits (16-23)
		*s |= (bg << 16);
		isDirty = true;
	}

	void clrtoeol(int y, int bg) {
		clrtoeol(0, y, bg);
	}

	void clrtoeol(int x, int y, int bg) {
		mixin(CHECKY);
		Uint32* s = &data[x + y * width];
		Uint32 v = cast(Uint32)(0x20 | (bg << 16));
		while(x++ < width) *s++ = v;
		isDirty = true;
	}

	void clrscr() {
		data[] = 0x20;
		isDirty = true;
	}

	void refresh() {
		olddata[] = 255;
		isDirty = true;
	}

	void cprint(int x, int y, int fg, int bg, string txt) {
		mixin(CHECKS);
		bool skipbg, skipfg;
		if(bg < 0) { skipbg = true; bg = 0; }
		if(fg < 0) { skipfg = true; fg = 0; }
		Uint32[] s = data[x + y * width .. x + y * width + txt.length];
		Uint32 col = cast(Uint32)((fg << 8) | (bg << 16));
		foreach(i, char c; txt) {
			if(skipbg)
				col = cast(Uint32)((fg << 8) | (s[i] & 0xff0000));
			if(skipfg)
				col = cast(Uint32)((bg << 16) | (s[i] & 0xff00));

			s[i] = cast(Uint32)(c | col);
		}
		isDirty = true;
	}

	void fprint(int x, int y, string str) {
		mixin(CHECKS);
		// Removed assertion - string length is arbitrary, buffer bounds are what matter
		Uint32[] outb = data[x + y * width .. $];
		if(outb.length == 0) return; // Nothing to write - at or past end of line
		
		int bg = 0, fg = 0;
		int idx;
		while(idx < str.length && outb.length > 0) {  // Check buffer bounds
			int getcol(char c) {
				return cast(int)(c == '+' ? -1 : "0123456789abcdef".indexOf(c));
			}
			if(str[idx] == '`') {
				// Safety check for color codes
				if(idx + 2 >= str.length) break;
				bg = getcol(str[idx + 1]);
				fg = getcol(str[idx + 2]);
				idx += 3;
				continue;
			}
		if(bg >= 0) {
			outb[0] &= 0xff00ff;  // Clear bg bits (16-23)
			outb[0] |= bg << 16;
		}
		if(fg >= 0) {
			outb[0] &= 0xff00ff;  // Clear fg bits (8-15)
			outb[0] |= fg << 8;
		}
		outb[0] &= 0xffffff00;  // Clear character bits
		outb[0] |= str[idx] & 255;
		outb = outb[1 .. $];
		idx++;
	}
	isDirty = true;
}
}

interface Visualizer {
	void clear();
	void draw(int);
}

private class Oscilloscope : Visualizer {
	private SDL_Surface* surface;
	private short* samples;
	private const short xconst, yconst;
	enum width = 960/4, height = 3*FONT_Y;

	this(SDL_Surface* surface, short xpos, short ypos) {
		this.surface = surface;
		this.xconst = xpos;
		this.yconst = ypos;
		import audio.audio;
		samples = audio.audio.mixbuf;
		assert(samples !is null);
	}

	void clear() {
		SDL_FillRect(surface, new SDL_Rect(xconst, yconst,
                                           width, height), 0);
	}

	void draw(int frames) {
		float smpofs;
		float n = frames * 50.0f;
		int count = cast(int)(48000 / n);

		auto colh = getColor(surface, 13),
			coll = getColor(surface, 5);

		clear();

		smpofs = 0.0f;
		import audio.audio;
		int oldposition = height / 2 + samples[cast(int)smpofs]  / 768;

		for(int i = 0; i < width; i++) {
			int sample = samples[cast(int)smpofs] / 768;
			int position = height / 2 + sample;
			position = com.util.umod(position, 0, height-1);
			int a = oldposition, b = position;

			if(a > b) {
				int temp = b;
				b = a;
				a = temp;
			}
			assert(a <= b);
			Uint32* pos = cast(Uint32 *)surface.pixels + xconst + i + (a + yconst) * surface.w;
			*pos = (i > 12 && i < width - 12) ? colh : coll;
			for(int k = a; k < b; k++) {
				*pos = (i > 12 && i < width - 12) ? colh : coll;
				pos += surface.w;
			}
			smpofs++;
			if(smpofs >= audio.audio.getbufsize())
				smpofs -= cast(int)audio.audio.getbufsize();
			oldposition = position;
		}
	}
}

class DisplayError : Error {
	this(string msg) {
		super("SDL Error: " ~ msg);
	}
}

void enableKeyRepeat() {
  //	SDL_EnableKeyRepeat(200, 10);
}

void disableKeyRepeat() {
	//SDL_EnableKeyRepeat(0, 0);
}

Uint16 readkey() {
	SDL_Event evt;
	bool loop = true;

	while(loop) {
		while(SDL_PollEvent(&evt)) {
			if(evt.type == SDL_QUIT) {
				SDL_Quit();
				return 0;
			}
			if(evt.type == SDL_KEYDOWN) {
				loop = false;
				break;
			}
		}
		SDL_Delay(50);
	}
	return cast(Uint16)evt.key.keysym.unicode;
}

private int getColor(SDL_Surface* s, int c) {
	return PALETTE[c].b << s.format.Bshift |
		(PALETTE[c].g << s.format.Gshift) |
		(PALETTE[c].r << s.format.Rshift);
}
