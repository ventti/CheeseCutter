/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Text-mode framebuffer — Video/Screen abstraction, character-cell rendering and the pixel-sharp oscilloscope trace overlay.
*/

module com.fb;
import derelict.sdl2.sdl;
import std.algorithm : max, min;
import std.string : indexOf;
import com.util;
// The RGB table + semantic roles now live in com.palette (data-driven, loaded
// from JSON at startup). PALETTE keeps the same index model this renderer uses.
public import com.palette : PALETTE, Role, idx;

immutable FONT_X = 8, FONT_Y = 14;
__gshared ubyte[] font;

// Separate 8x8 PETSCII font used only by the About-splash scroller (see
// Video.drawSplash()). Glyphs are MSB-left bitmap rows like `font`, but 8 tall.
immutable SCROLL_FONT_Y = 8;
__gshared ubyte[] scrollfont;

// Splash artwork: raw 320x200 array of PALETTE indices (see tools/mk-splash.py),
// shown by Video.drawSplash() in place of the text grid while splashActive.
immutable SPLASH_W = 320, SPLASH_H = 200, SPLASH_SCALE = 2;
immutable ubyte[] splashData = cast(immutable(ubyte)[])import("splash.dat");

// Window icon: raw 96x96 RGBA (see tools/mk-icon.py), handed to
// SDL_SetWindowIcon() at window creation. SDL applies it to the title-bar /
// taskbar icon on Windows and Linux; macOS ignores it and uses the .app
// bundle's ct.icns for the Dock icon instead.
immutable ICON_W = 96, ICON_H = 96;
immutable ubyte[] iconData = cast(immutable(ubyte)[])import("icon.dat");

// About-splash scroller: a right-to-left PETSCII scroller drawn over the bottom
// of the artwork. Text is light gray (PALETTE 15) by default; an inline control
// byte 0x00..0x0f changes the colour to that C64 palette index for what follows.
immutable double SCROLL_SPEED = 50.0;    // 1 scaled px (1 font px) per 50Hz tick
immutable ubyte SCROLL_DEFAULT_COL = 1;
// Scroller row position: pixels below the bottom edge of the artwork (the image
// already has static credits baked into its own bottom rows, so the scroller
// sits in the black margin beneath it). Band height = SCROLL_FONT_Y*SPLASH_SCALE.
immutable int SCROLL_ROW_OFFSET = SPLASH_SCALE * 8;
immutable string scrollText =
	"   \x0dCHEESECUTTER EXTENDED " ~ APP_VERSION ~
	"   \x01 - A MODERNIZED FORK OF \x0dTHE POPULAR EDITOR" ~
	"               \x01(C) 2009-17 ABADDON - RELEASED UNDER THE GNU GPL" ~
	"               \x01(C) 2025-26 EXTENSIONS PRODUCED BY VENT" ~
	"               \x01RESID ENGINE BY DAG LEM & ANTTI LANKILA" ~
        "               \x01ORIGINAL MACOSX AND D2 PORT BY RUK 2013" ~
	"               \x01PARTS OF RESID INTERFACE BY CADAVER / COVERT BITOPS" ~
	"               \x01INCLUDES ACME ASSEMBLER 0.91 BY MARCO BAYE" ~
	"               \x01LIBSDL2 BY THE SDL TEAM" ~
	"               \x01VISIT \x0dhttps://github.com/ventti/CheeseCutter\x01 FOR MORE INFORMATION" ~
	"               \x0fPRESS ANY KEY TO RETURN TO CUT SOME CHEESE ...        ";

int mode; // 0 = compact (default), >0 = wide
immutable int border = 1;
private bool isDirty = false;
// When set, renderGrid draws the black (index 0) cell background as dark blue
// (index 6) instead — a whole-screen "keyjam active" tint. Set by the UI when
// keyjam mode toggles (com.fb has no com.session dependency, so it's a flag).
__gshared bool keyjamBackground = false;

// Last mouse position in GRID PIXELS: letterbox-corrected (Video.scalePosition) but NOT
// yet divided down to a character cell. The UI dispatches mouse events in cells, which is
// too coarse for a continuous vertical drag — a graph band can be under 5 cells tall, so
// cell granularity quantizes the whole band to 5 reachable values. Widgets that need
// sub-cell precision read this instead of reconstructing a cell centre. Published by the
// SDL event loop in main.mainloop (com.fb has no dependency on the UI, so it's a flag).
__gshared int mousePixelX = 0, mousePixelY = 0;

// --verbose: trace each pitch-drag tick (mouse pixel vs the pixel the block is drawn at)
// to stderr. For diagnosing "the object does not follow my mouse" on a real display,
// where the window/renderer geometry cannot be reproduced headlessly.
__gshared bool traceMouseDrag = false;

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
	// PSF1 8x8 PETSCII font for the splash scroller (4-byte header, 8 bytes/glyph).
	scrollfont.length = 256*SCROLL_FONT_Y;
	immutable rawpet = import("petscii.psf");
	for(int i=0;i<256;i++) {
		scrollfont[i*SCROLL_FONT_Y..i*SCROLL_FONT_Y+SCROLL_FONT_Y] =
			cast(ubyte[])rawpet[4+i*SCROLL_FONT_Y..4+i*SCROLL_FONT_Y+SCROLL_FONT_Y];
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

	// Overlay a pixel-resolution waveform trace on top of the composited text
	// grid (used by the oscilloscope). `ys` holds one screen-pixel y per
	// horizontal pixel, starting at x `x0`; consecutive points are joined so a
	// steep slope stays continuous. `col`/`edgeCol` are palette indices — the
	// first/last `edgeMargin` columns use `edgeCol` (a dim fade at the window
	// edges). Re-set every frame while the scope is open; clearScopeTrace()
	// removes it. Base no-ops; only the SDL renderer subclass draws.
	void setScopeTrace(int x0, int midY, int[] ys, int col, int edgeCol, int edgeMargin) {}
	// Overlay a recorded-waveform envelope (keyjam view): per column a min/max
	// vertical bar (`lo`/`hi` screen-pixel y), a pixel center line at `midY`, and
	// a thin gate on/off bar at `gateY` (`gate[i]` != 0 = gate on). Base no-op.
	void setScopeEnvelope(int x0, int midY, int gateY, int[] lo, int[] hi,
						   ubyte[] gate, int col, int axisCol, int gateCol) {}
	void clearScopeTrace() {}

	abstract protected void enableFullscreen(bool fs);

	void resizeEvent(int nw, int nh) {
	}

	void toggleFullscreen() {
		useFullscreen ^= 1;
		enableFullscreen(useFullscreen);
	}

	bool isFullscreen() { return useFullscreen; }

	// Convert an SDL mouse position into the coordinate space the UI is DRAWN in.
	//
	// SDL reports mouse coordinates in window POINTS, but every draw call here uses
	// renderer OUTPUT PIXELS. Those are not the same number whenever the drawing surface
	// is scaled — a HiDPI/Retina backing store makes the output 2x the window, and a
	// fullscreen-desktop or user-resized window stretches it by an arbitrary ratio. Left
	// unconverted (the scaling below used to be commented out), a drag moved the pointer
	// at a different rate than the graphics it was dragging: the classic symptom is a
	// grabbed object travelling a different distance than the mouse.
	//
	// Derive the factor from the live SDL sizes rather than the requested ones, so it
	// stays correct after a resize or a fullscreen toggle. Exactly 1:1 (and a no-op) when
	// the surface is unscaled, which is the case under the dummy video driver.
	void scalePosition(ref int x, ref int y) {
		int outW, outH, winW, winH;
		if(renderer !is null && window !is null) {
			SDL_GetRendererOutputSize(renderer, &outW, &outH);
			SDL_GetWindowSize(window, &winW, &winH);
			if(winW > 0 && winH > 0 && (outW != winW || outH != winH)) {
				if(!warnedMouseScale) {
					warnedMouseScale = true;
					import std.stdio : stderr;
					stderr.writefln("fb: scaled drawing surface — window %dx%d points, "
						~ "renderer %dx%d pixels (x%.3f/%.3f); mouse input converted.",
						winW, winH, outW, outH,
						cast(double)outW / winW, cast(double)outH / winH);
				}
				x = cast(int)(cast(long)x * outW / winW);
				y = cast(int)(cast(long)y * outH / winH);
			}
		}
		// Letterbox offset, in the same (pixel) space as the converted position above.
		x -= rect.x;
		y -= rect.y;
	}
	private bool warnedMouseScale = false;

	// Report the window(points) vs renderer(pixels) geometry once at startup. Silent when
	// they match; a mismatch means the drawing surface is scaled, which is exactly what
	// scalePosition has to compensate for, so make it visible rather than mysterious.
	protected void reportSurfaceScale() {
		if(renderer is null || window is null) return;
		int outW, outH, winW, winH;
		SDL_GetRendererOutputSize(renderer, &outW, &outH);
		SDL_GetWindowSize(window, &winW, &winH);
		if(winW <= 0 || winH <= 0) return;
		bool scaled = (outW != winW || outH != winH);
		import std.stdio : stderr;
		stderr.writefln("fb: window %dx%d points, renderer %dx%d pixels (x%.3f/%.3f), "
			~ "grid %dx%d px — surface %s.",
			winW, winH, outW, outH,
			cast(double)outW / winW, cast(double)outH / winH,
			requestedWidth, requestedHeight,
			scaled ? "SCALED (mouse input converted)" : "unscaled (1:1)");
	}

	// Capture the current frame to a PNG in the current working directory.
	// If filename is empty a timestamped name is generated. Implemented by the
	// concrete subclass, which owns the render helpers needed to redraw the
	// frame into the backbuffer before the pixel readback.
	abstract void saveScreenshot(string filename);

	// When set, updateFrame() blits the splash image instead of the text grid.
	// Toggled by AboutDialog (ui.dialogs). Declared as a trailing field and with
	// no new virtual method so the class layout/vtable stays compatible with
	// objects compiled before this change (the repo has no dep tracking).
	bool splashActive;
	// When set (only while the user-opened About dialog is active, not the
	// startup splash), drawSplash() also draws the scroller. Trailing data field,
	// no new virtual method, for the same vtable-compatibility reason as above.
	bool splashScroll;

	abstract void updateFrame();

	// --- Immediate-mode overlay draw-list (Sound Editor et al.) ---
	// A per-frame list of simple pixel ops in DEVICE-pixel coords with a palette
	// colour index `col`, flushed on top of the finished text grid in
	// renderGrid() right alongside the single-slot scope trace (so both
	// updateFrame() and saveScreenshot() composite it identically). The caller
	// rebuilds the list every frame: olClear() at the start of its draw, then any
	// number of ol* ops. Several independent graphs can coexist here at once, and
	// it lives beside — not instead of — setScopeTrace above. Declared as TRAILING
	// no-op virtuals on the base for vtable compatibility (this repo has no dep
	// tracking, so new virtuals must be appended); only the SDL subclass draws.
	void olClear() {}
	void olLine(int x0, int y0, int x1, int y1, int col) {}
	void olVLine(int x, int y0, int y1, int col) {}
	void olHLine(int x0, int x1, int y, int col) {}
	void olRect(int x, int y, int w, int h, int col) {}   // outline
	void olFillRect(int x, int y, int w, int h, int col) {}
	void olPoint(int x, int y, int col) {}
	// Alpha-blended filled rect (0=transparent..255=opaque): a real translucent
	// overlay, e.g. the Sound Editor's time-range selection wash. Trailing no-op
	// virtual for vtable compatibility; only the SDL subclass blends.
	void olFillRectA(int x, int y, int w, int h, int col, int alpha) {}
	// Repaint the finished text grid over this device-pixel rectangle after all
	// preceding overlay ops. Used by menus/dialogs so graphs remain visible around
	// them without bleeding through their foreground chrome.
	void olMaskRect(int x, int y, int w, int h) {}
	// Foreground chrome refreshes independently of the Sound Editor graphs.
	// Replace its masks each UI pass without discarding retained graph ops.
	void olClearMasks() {}
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

		SDL_WindowFlags flags = fs ? SDL_WINDOW_FULLSCREEN_DESKTOP
								   : cast(SDL_WindowFlags)0;

		if(window is null) {
			// First call: create the window + renderer.
			SDL_CreateWindowAndRenderer(width, height, flags, &window, &renderer);
			if(window is null || renderer is null) {
				throw new DisplayError("Unable to initialize graphics mode.");
			}
			SDL_SetWindowTitle(window, com.util.APP_NAME);
			setWindowIcon();
			SDL_StartTextInput();
			reportSurfaceScale();
		} else {
			// Subsequent toggles: switch the EXISTING window in place. Recreating
			// the window/renderer here leaked the old fullscreen window — it stayed
			// on screen behind the new one, showing the last fullscreen frame.
			SDL_SetWindowFullscreen(window, flags);
		}

		SDL_RaiseWindow(window);
		screen.refresh();
	}

	// Set the window icon from the embedded 96x96 RGBA blob. SDL copies the
	// pixels into its own storage, so the temporary surface (and our immutable
	// source data) can be freed/left untouched afterwards. No-op visually on
	// macOS, where the Dock icon comes from the .app bundle's ct.icns.
	private void setWindowIcon() {
		// Byte order in memory is R,G,B,A; masks below are the little-endian form.
		SDL_Surface* icon = SDL_CreateRGBSurfaceFrom(
			cast(void*)iconData.ptr, ICON_W, ICON_H, 32, ICON_W * 4,
			0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000);
		if(icon !is null) {
			SDL_SetWindowIcon(window, icon);
			SDL_FreeSurface(icon);
		}
	}

	// --- Pixel-resolution oscilloscope trace overlay ---
	// Set by the scope window each frame; drawn at the tail of renderGrid() so
	// both updateFrame() and saveScreenshot() composite it identically, on top
	// of the text grid. scopeActive also forces updateFrame() to re-render even
	// when the text grid itself hasn't changed (the trace moves every frame).
	private bool scopeActive, scopeIsEnvelope;
	private int scopeX0, scopeCol, scopeEdgeCol, scopeEdgeMargin;
	private int scopeMidY, scopeGateY, scopeGateCol;
	private int[] scopeYs;
	private int[] scopeLo, scopeHi;
	private ubyte[] scopeGate;

	override void setScopeTrace(int x0, int midY, int[] ys, int col, int edgeCol, int edgeMargin) {
		scopeX0 = x0; scopeMidY = midY; scopeCol = col; scopeEdgeCol = edgeCol; scopeEdgeMargin = edgeMargin;
		// Copy into our own buffer: the caller reuses its array next frame.
		scopeYs.length = ys.length;
		scopeYs[] = ys[];
		scopeIsEnvelope = false;
		scopeActive = true;
	}

	override void setScopeEnvelope(int x0, int midY, int gateY, int[] lo, int[] hi,
								   ubyte[] gate, int col, int axisCol, int gateCol) {
		scopeX0 = x0; scopeMidY = midY; scopeGateY = gateY;
		scopeCol = col; scopeEdgeCol = axisCol; scopeGateCol = gateCol;
		scopeLo.length = lo.length; scopeLo[] = lo[];
		scopeHi.length = hi.length; scopeHi[] = hi[];
		scopeGate.length = gate.length; scopeGate[] = gate[];
		scopeIsEnvelope = true;
		scopeActive = true;
	}

	override void clearScopeTrace() { scopeActive = false; }

	private void drawScopeTrace() {
		if(!scopeActive) return;
		if(scopeIsEnvelope) { drawScopeEnvelope(); return; }
		if(scopeYs.length < 2) return;
		immutable int n = cast(int)scopeYs.length;
		// Pixel center line (zero axis) under the trace.
		SDL_SetRenderDrawColor(renderer, PALETTE[scopeEdgeCol].r, PALETTE[scopeEdgeCol].g, PALETTE[scopeEdgeCol].b, 255);
		SDL_RenderDrawLine(renderer, scopeX0, scopeMidY, scopeX0 + n - 1, scopeMidY);
		foreach(i; 1 .. n) {
			int ci = (i < scopeEdgeMargin || i >= n - scopeEdgeMargin)
				? scopeEdgeCol : scopeCol;
			SDL_SetRenderDrawColor(renderer, PALETTE[ci].r, PALETTE[ci].g, PALETTE[ci].b, 255);
			SDL_RenderDrawLine(renderer, scopeX0 + i - 1, scopeYs[i-1], scopeX0 + i, scopeYs[i]);
		}
	}

	// Recorded-waveform (keyjam) draw: center line, per-column min/max bars, and
	// a gate on/off bar along the top.
	private void drawScopeEnvelope() {
		immutable int n = cast(int)scopeLo.length;
		if(n < 1) return;
		void setcol(int c) {
			SDL_SetRenderDrawColor(renderer, PALETTE[c].r, PALETTE[c].g, PALETTE[c].b, 255);
		}
		// Pixel center line (zero axis).
		setcol(scopeEdgeCol);
		SDL_RenderDrawLine(renderer, scopeX0, scopeMidY, scopeX0 + n - 1, scopeMidY);
		// Min/max envelope bars.
		setcol(scopeCol);
		foreach(i; 0 .. n)
			SDL_RenderDrawLine(renderer, scopeX0 + i, scopeLo[i], scopeX0 + i, scopeHi[i]);
		// Gate on/off indicator: a thin bar at the top, drawn only where gate on.
		setcol(scopeGateCol);
		immutable int gn = cast(int)scopeGate.length;
		foreach(i; 0 .. n) {
			if(i < gn && scopeGate[i])
				SDL_RenderDrawLine(renderer, scopeX0 + i, scopeGateY, scopeX0 + i, scopeGateY + 2);
		}
	}

	// --- Immediate-mode overlay draw-list (see base Video.ol*) ---
	// Rebuilt each frame by the caller (olClear + ol* ops). overlayActive forces
	// a per-frame re-render like scopeActive, and the list is kept between frames
	// so saveScreenshot() re-renders the same overlay. Device-pixel coords.
	private enum OlKind { line, vline, hline, rect, fillrect, point, maskrect }
	private struct OlOp { OlKind kind; int a, b, c, d, col; int alpha = 255; }
	private OlOp[] olOps;
	private bool overlayActive;

	override void olClear() { olOps.length = 0; overlayActive = false; }
	override void olLine(int x0, int y0, int x1, int y1, int col) {
		olOps ~= OlOp(OlKind.line, x0, y0, x1, y1, col); overlayActive = true;
	}
	override void olVLine(int x, int y0, int y1, int col) {
		olOps ~= OlOp(OlKind.vline, x, y0, y1, 0, col); overlayActive = true;
	}
	override void olHLine(int x0, int x1, int y, int col) {
		olOps ~= OlOp(OlKind.hline, x0, x1, y, 0, col); overlayActive = true;
	}
	override void olRect(int x, int y, int w, int h, int col) {
		olOps ~= OlOp(OlKind.rect, x, y, w, h, col); overlayActive = true;
	}
	override void olFillRect(int x, int y, int w, int h, int col) {
		olOps ~= OlOp(OlKind.fillrect, x, y, w, h, col); overlayActive = true;
	}
	override void olPoint(int x, int y, int col) {
		olOps ~= OlOp(OlKind.point, x, y, 0, 0, col); overlayActive = true;
	}
	override void olFillRectA(int x, int y, int w, int h, int col, int alpha) {
		olOps ~= OlOp(OlKind.fillrect, x, y, w, h, col, alpha); overlayActive = true;
	}
	override void olMaskRect(int x, int y, int w, int h) {
		olOps ~= OlOp(OlKind.maskrect, x, y, w, h, 0); overlayActive = true;
	}
	override void olClearMasks() {
		size_t kept;
		foreach(op; olOps) {
			if(op.kind != OlKind.maskrect) olOps[kept++] = op;
		}
		if(kept != olOps.length) isDirty = true;
		olOps.length = kept;
		overlayActive = kept != 0;
	}

	// Read-only diagnostics for the headless driver's overlay lifetime checks.
	final size_t overlayOperationCount() const { return olOps.length; }
	final size_t overlayMaskCount() const {
		size_t count;
		foreach(op; olOps) if(op.kind == OlKind.maskrect) count++;
		return count;
	}

	// Render one text cell exactly as renderGrid does. Kept as a helper so a mask op
	// can restore foreground chrome after the pixel overlay has been composited.
	private void drawGridCell(int x, int y) {
		if(x < 0 || y < 0 || x >= screen.width || y >= screen.height) return;
		Uint32 cell = screen.data[x + y * screen.width];
		int glyph = cell & 255;
		Uint8* bp = &font[glyph * 16];
		Uint8 ufg = (cell >> 8) & 0xff;
		Uint8 ubg = (cell >> 16) & 0xff;
		if(keyjamBackground && ubg == 0) ubg = cast(ubyte)idx(Role.keyjamBg);
		SDL_Rect cellRect = { x * FONT_X, y * FONT_Y, FONT_X, FONT_Y };
		SDL_SetRenderDrawColor(renderer, PALETTE[ubg].r, PALETTE[ubg].g, PALETTE[ubg].b, 255);
		SDL_RenderFillRect(renderer, &cellRect);
		SDL_SetRenderDrawColor(renderer, PALETTE[ufg].r, PALETTE[ufg].g, PALETTE[ufg].b, 255);
		int yy = y * FONT_Y;
		foreach(c; 4 .. 4 + FONT_Y) {
			int bits = bp[c - 4];
			int xx = x * FONT_X;
			foreach(bit; 0 .. FONT_X) {
				if(bits & (0x80 >> bit)) SDL_RenderDrawPoint(renderer, xx + bit, yy);
			}
			yy++;
		}
	}

	// Flush the overlay draw-list on top of the finished text grid.
	private void drawOverlay() {
		if(!overlayActive || olOps.length == 0) return;
		// Blend mode on so ops with alpha<255 (e.g. the selection wash) composite
		// translucently over the grid; alpha==255 stays fully opaque. Restored below.
		SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
		foreach(ref op; olOps) {
			auto c = PALETTE[op.col & 0xff];
			SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, cast(ubyte)op.alpha);
			final switch(op.kind) {
			case OlKind.line:
				SDL_RenderDrawLine(renderer, op.a, op.b, op.c, op.d);
				break;
			case OlKind.vline:
				SDL_RenderDrawLine(renderer, op.a, op.b, op.a, op.c);
				break;
			case OlKind.hline:
				// Single-pixel triangle tips are points: some SDL renderers drop
				// a line whose two endpoints coincide.
				if(op.a == op.b) SDL_RenderDrawPoint(renderer, op.a, op.c);
				else SDL_RenderDrawLine(renderer, op.a, op.c, op.b, op.c);
				break;
			case OlKind.rect:
				SDL_Rect ro = { op.a, op.b, op.c, op.d };
				SDL_RenderDrawRect(renderer, &ro);
				break;
			case OlKind.fillrect:
				SDL_Rect rf = { op.a, op.b, op.c, op.d };
				SDL_RenderFillRect(renderer, &rf);
				break;
			case OlKind.point:
				SDL_RenderDrawPoint(renderer, op.a, op.b);
				break;
			case OlKind.maskrect:
				int x0 = max(0, op.a / FONT_X);
				int y0 = max(0, op.b / FONT_Y);
				int x1 = min(screen.width,  (op.a + op.c + FONT_X - 1) / FONT_X);
				int y1 = min(screen.height, (op.b + op.d + FONT_Y - 1) / FONT_Y);
				foreach(y; y0 .. y1) foreach(x; x0 .. x1) drawGridCell(x, y);
				break;
			}
		}
		SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_NONE);
	}

	private SDL_Texture* splashTexture;

	// Scroller state. scrollCells is the message expanded into one entry per
	// drawn glyph (control bytes consumed into the active colour); built lazily.
	private struct SCell { ubyte g; ubyte col; }
	private SCell[] scrollCells;
	private int scrollTotalW;            // total scroller width in font-space px
	private double scrollX = 0;          // left edge offset, font-space px
	private uint scrollLastMs = 0;       // for frame-rate-independent advance

	private void buildScrollCells() {
		ubyte col = SCROLL_DEFAULT_COL;
		foreach(ubyte ch; cast(immutable(ubyte)[])scrollText) {
			if(ch < 0x10) { col = ch; continue; }
			scrollCells ~= SCell(ch, col);
		}
		scrollTotalW = cast(int)scrollCells.length * 8;
		scrollX = -SPLASH_W;             // start fully off the right edge
	}

	// Draw the right-to-left PETSCII scroller across the bottom of the splash
	// rect `splash`, scaled at SPLASH_SCALE and clipped to the splash width.
	private void drawScroller(SDL_Rect splash) {
		if(scrollCells.length == 0) {
			buildScrollCells();
			if(scrollCells.length == 0) return;
		}
		uint now = SDL_GetTicks();
		uint dt = now - scrollLastMs;
		// A long gap means a fresh open (or the first frame): restart from the
		// right edge and don't advance, so each About open scrolls from scratch.
		if(scrollLastMs == 0 || dt > 500) {
			scrollLastMs = now;
			scrollX = -SPLASH_W;
			return;
		}
		scrollX += SCROLL_SPEED * dt / 1000.0;
		scrollLastMs = now;
		if(scrollX >= scrollTotalW) scrollX = -SPLASH_W;

		immutable bandH = SCROLL_FONT_Y * SPLASH_SCALE;
		int bandY = splash.y + splash.h + SCROLL_ROW_OFFSET;
		SDL_Rect clip = { splash.x, bandY, splash.w, bandH };
		SDL_RenderSetClipRect(renderer, &clip);

		int rightEdge = splash.x + splash.w;
		int first = cast(int)(scrollX / 8);
		if(first < 0) first = 0;
		for(int ci = first; ci < cast(int)scrollCells.length; ci++) {
			int gx = splash.x + cast(int)((ci*8 - scrollX) * SPLASH_SCALE);
			if(gx >= rightEdge) break;
			SCell cell = scrollCells[ci];
			ubyte* bp = &scrollfont[cell.g * SCROLL_FONT_Y];
			SDL_SetRenderDrawColor(renderer, PALETTE[cell.col].r,
								   PALETTE[cell.col].g, PALETTE[cell.col].b, 255);
			for(int row = 0; row < SCROLL_FONT_Y; row++, bp++) {
				ubyte b = *bp;
				for(int colb = 0; colb < 8; colb++) {
					if(b & (0x80 >> colb)) {
						SDL_Rect px = { gx + colb*SPLASH_SCALE,
										bandY + row*SPLASH_SCALE,
										SPLASH_SCALE, SPLASH_SCALE };
						SDL_RenderFillRect(renderer, &px);
					}
				}
			}
		}
		SDL_RenderSetClipRect(renderer, null);
	}

	// Not an override: kept off the base Video vtable so stale objects keep
	// calling updateFrame() at the right slot (no dep tracking in this repo).
	void drawSplash() {
		drawSplashBody();
		SDL_RenderPresent(renderer);
	}

	// Splash draw without the final present, so saveScreenshot() can read the
	// backbuffer before it is swapped out.
	private void drawSplashBody() {
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
		if(splashScroll) drawScroller(dst);
	}

	override void updateFrame() {
		if(splashActive) { drawSplash(); return; }
		// The oscilloscope trace moves every frame, so re-render while it is
		// active even when the text grid itself is unchanged.
		if (!isDirty && !scopeActive && !overlayActive) return;
		isDirty = false;
		renderGrid();
		SDL_RenderPresent(renderer);
	}

	// Draw the text grid into the backbuffer without presenting. Split out of
	// updateFrame() so saveScreenshot() can render a fresh frame and read it
	// back before the present (reading after SDL_RenderPresent is undefined).
	private void renderGrid() {
		int x, y;
		int a,b,c;

		Uint32* bptr = &screen.data[0];
		Uint32* cptr = &screen.olddata[0];
		// Uint32* sptr = cast(Uint32 *)surface.pixels;
		Uint32* sp;
		Uint8* bp;
		Uint8 ubg, ufg;
		int outx, outy;

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
                    // Keyjam tint: paint the black background with the keyjam role.
                    if(keyjamBackground && ubg == 0) ubg = cast(ubyte)idx(Role.keyjamBg);
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
		// Composite the pixel-sharp oscilloscope trace over the finished grid,
		// then the immediate-mode overlay draw-list (both captured by screenshots).
		drawScopeTrace();
		drawOverlay();
	}

	// Capture the current frame to a PNG in the current working directory.
	// If filename is empty a timestamped name is generated.
	override void saveScreenshot(string filename) {
		import std.stdio : writefln;
		import std.datetime.systime : Clock;
		import std.format : format;

		// Generate filename if not provided
		if(filename == "") {
			auto now = Clock.currTime();
			filename = format("screenshot_%04d%02d%02d_%02d%02d%02d.png",
				now.year, now.month, now.day, now.hour, now.minute, now.second);
		}

		// Render a fresh frame into the backbuffer so the readback captures the
		// current screen: SDL_RenderReadPixels is only defined *before* the
		// present that swaps the buffer out (which the event loop already did).
		if(splashActive) drawSplashBody();
		else renderGrid();

		// Grab the freshly drawn backbuffer (ARGB8888) before presenting it.
		SDL_Surface* surface = SDL_CreateRGBSurface(0, width, height, 32,
			0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000);
		if(surface is null) {
			writefln("Error: could not create surface for screenshot: %s", SDL_GetError());
			return;
		}
		int rc = SDL_RenderReadPixels(renderer, null, SDL_PIXELFORMAT_ARGB8888,
									  surface.pixels, surface.pitch);

		// Present so the user still sees this frame (matches the old flow where
		// updateFrame() would have presented).
		SDL_RenderPresent(renderer);

		if(rc != 0) {
			writefln("Error reading pixels for screenshot: %s", SDL_GetError());
			SDL_FreeSurface(surface);
			return;
		}

		// Extract RGB from the ARGB surface (accounting for pitch) and write PNG.
		auto rgb = new ubyte[width * height * 3];
		foreach(y; 0 .. height) {
			auto row = cast(Uint32*)(cast(ubyte*)surface.pixels + y * surface.pitch);
			foreach(x; 0 .. width) {
				Uint32 p = row[x];
				size_t o = (y * width + x) * 3;
				rgb[o + 0] = cast(ubyte)((p >> 16) & 0xff); // R
				rgb[o + 1] = cast(ubyte)((p >> 8) & 0xff);  // G
				rgb[o + 2] = cast(ubyte)(p & 0xff);         // B
			}
		}
		SDL_FreeSurface(surface);

		try {
			writePng(filename, width, height, rgb);
			writefln("Screenshot saved: %s", filename);
		} catch(Exception e) {
			writefln("Error saving screenshot %s: %s", filename, e.msg);
		}
	}

}

// Minimal PNG writer (8-bit truecolor RGB, no interlace). Kept dependency-free
// on purpose: SDL2_image is not linked, so instead of pulling in IMG_SavePNG we
// build the chunks by hand and reuse Phobos' zlib (the deflate stream and the
// per-chunk CRC-32 are exactly what PNG's IDAT/chunk framing require).
private void writePng(string filename, int w, int h, const(ubyte)[] rgb) {
	import std.zlib : compress, crc32;
	import std.bitmanip : nativeToBigEndian;
	import std.stdio : File;

	// One filter byte (0 = None) per scanline, followed by the RGB triples.
	auto raw = new ubyte[(w * 3 + 1) * h];
	foreach(y; 0 .. h) {
		size_t dst = cast(size_t)y * (w * 3 + 1);
		raw[dst] = 0;
		raw[dst + 1 .. dst + 1 + w * 3] = rgb[cast(size_t)y * w * 3 .. cast(size_t)(y + 1) * w * 3];
	}
	auto idat = cast(ubyte[])compress(raw, 6);

	auto file = File(filename, "wb");
	ubyte[8] sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
	file.rawWrite(sig[]);

	void chunk(string type, const(ubyte)[] data) {
		file.rawWrite(nativeToBigEndian(cast(uint)data.length)[]);
		file.rawWrite(type);
		if(data.length) file.rawWrite(data);
		uint c = crc32(0, cast(const(ubyte)[])type);
		c = crc32(c, data);
		file.rawWrite(nativeToBigEndian(c)[]);
	}

	ubyte[13] ihdr;
	ihdr[0 .. 4] = nativeToBigEndian(w)[];
	ihdr[4 .. 8] = nativeToBigEndian(h)[];
	ihdr[8]  = 8;   // bit depth
	ihdr[9]  = 2;   // color type: truecolor RGB
	ihdr[10] = 0;   // compression: deflate
	ihdr[11] = 0;   // filter method
	ihdr[12] = 0;   // interlace: none
	chunk("IHDR", ihdr[]);
	chunk("IDAT", idat);
	chunk("IEND", []);
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
