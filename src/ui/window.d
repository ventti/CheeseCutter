/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Base windowing primitives — Window, WindowSwitcher, Rectangle, Hotspot.
*/

module ui.window;
import derelict.sdl2.sdl;
import std.conv;
import main;
import ct.base;
import com.session;
import ui.help;
import ui.input;
import com.fb;
import com.util;
import com.shortcuts;
import std.string;

struct Rectangle {
	int x, y;
	int height, width;
	alias height h;
	alias width w;

	string toString() {
		return format("%d %d %d %d",x, y, h, w);
	}

	bool overlaps(int cx, int cy) {
		return cx >= x && cx < x + width && cy >= y && cy < y + height;
	}

	Rectangle relativeTo(int scrx, int scry) {
		return Rectangle(scrx - x, scry - y);
	}
}

abstract class Window {
	Rectangle area;
	Input input;
	protected ContextHelp help;
	private bool hasCustomHelp;

	this(Rectangle a) {
		area = a;
	}

	this(Rectangle a, ContextHelp ctx) {
		contextHelp = ctx;
		area = a;
	}

	abstract void update();
	int keypress(Keyinfo key) { return 0; }
	int keyrelease(Keyinfo key) { return 0; }
	void refresh() {}
	void deactivate() {}
	void activate() { refresh(); }
	void clickedAt(int scrx, int scry, int button, int clicks = 1) {}
	/// Mouse moved with the left button held (drag), and left button released.
	/// Coords are screen char-cells, as for clickedAt. No-op by default.
	void draggedTo(int scrx, int scry) {}
	void releasedAt(int scrx, int scry) {}

	/// Identifies the keyboard-shortcut context this window provides. The active
	/// window's contextId is pushed into the ShortcutManager so context-specific
	/// command shortcuts resolve correctly. Defaults to global.
	@property string contextId() { return Ctx.global; }

	// Widened from protected to public (both accessors, to keep them one
	// @property overload set, and because the existing subclass overrides in
	// other modules are public): the ui.keymap free function (help_dialog
	// callback) reads contextHelp off a Window reference across module
	// boundaries now that keymap is split out of ui.ui. (`package` does not
	// work here: a package-visible base method is not visible to overrides in
	// other modules, breaking every contextHelp override.)
	public @property void contextHelp(ContextHelp h) { help = h; hasCustomHelp = true; }
	// Default windows show the (generated) global help live, so regenerating
	// ui.help.HELPMAIN after the registry is populated takes effect everywhere.
	public @property ContextHelp contextHelp() { return hasCustomHelp ? help : ui.help.HELPMAIN; }

protected:

	final void drawFrame() { drawFrame(area); }

	static void drawFrame(Rectangle a) {
		int x,y;
		for(y=a.y;y<a.y+a.height;y++) {
			screen.setChar(a.x-1,y,0);
			screen.setChar(a.x,y, 0x500|216);
			screen.setChar(a.x+a.width-1,y, 0x500|216);
			screen.setChar(a.x+a.width,y,0);
			screen.data[a.x+1 + y * screen.width .. a.x + a.width - 1 + y * screen.width] = 0x00;
			screen.setColor(a.x+a.width+1,y+1,11,0);
		}
		for(x=a.x;x<a.x+a.width;x++) {
			screen.setChar(x,a.y, 0x0500|192);
			screen.setChar(x,a.y+a.height-1, 0x0500|192);
			screen.setColor(x+2,a.y+a.height, 11, 0);
		}

		screen.setChar(a.x,a.y,0x500 | 201);
		screen.setChar(a.x+a.width-1,a.y,0x500 | 215);
		screen.setChar(a.x,a.y+a.height-1,0x500 | 195);
		screen.setChar(a.x+a.width-1,a.y+a.height-1,0x500 | 212);
	}

	final void drawRuler(int y) {
		for(int x = area.x;x < area.x + area.width; x++) {
			screen.setChar(x, area.y + y, 0x0500|192);
		}
	}

}

struct Hotspot {
	Rectangle area;
	void delegate(int) callback;
}

class WindowSwitcher : Window {
	Window[] windows;
	char[] hotkeys;
	Window activeWindow;
	int activeWindowNum;

	this(Rectangle s, Window[] w) {
		super(s);
		windows = w;
		activeWindowNum = 0;
		activateWindow();
	}

	this(Rectangle s, Window[] w, string h) {
		this(s, w);
		hotkeys = cast(char[])h;
	}

	this(Rectangle s, Window[] w, char[] h) {
		this(s, w);
		hotkeys = h;
	}

	this(Rectangle s, Window[] w, char[] h, int mk) {
		this(s, w);
		hotkeys = h;
	}

	void activateWindow() {
		activateWindow(activeWindowNum);
	}

	void activateWindow(ulong n){
		activateWindow(cast(int)n);
	}

	void activateWindow(int n) {
		if(activeWindow !is null) {
			if(activeWindow.input !is null && activeWindow.input.cursor !is null)
				activeWindow.input.cursor.clear();
			activeWindow.deactivate();
		}
		activeWindow = windows[n];
		activeWindow.activate();
		activeWindowNum = n;
		input = activeWindow.input;
		if(mainui !is null && mainui.sm !is null)
			mainui.sm.setActiveContext(activeWindow.contextId);
		refresh();
	}

	override void update() {
		activeWindow.update();
	}

	override void activate() {
		activeWindow.activate();
	}

	override void deactivate() {
		activeWindow.deactivate();
	}

	override void refresh() {
		foreach(w; windows) w.refresh();
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_ALT) {
			foreach(i, hk; hotkeys) {
				if(key.raw == hk) {
					activeWindowNum = cast(int)i;
					activateWindow();
					return OK;
				}
			}
		}
		switch(key.raw) {
		case SDLK_TAB:
			key.mods & KMOD_SHIFT ? activeWindowNum-- : activeWindowNum++ ;
			/+
			if(activeWindowNum < 0) activeWindowNum = cast(int)(windows.length - 1);
			if(activeWindowNum >= windows.length)
				activeWindowNum %= windows.length;
				+/
			activeWindowNum = umod(activeWindowNum, 0, cast(int)windows.length - 1);
			activateWindow();
			return OK;
		default:
			return activeWindow.keypress(key);
		}
		assert(0);
	}

	override ContextHelp contextHelp() {
		return activeWindow.contextHelp();
	}

	override @property string contextId() {
		return activeWindow.contextId;
	}

	override void clickedAt(int scrx, int scry, int button, int clicks = 1) {
		//	activateAt(scrx - activeWindow.area.x, scry - activeWindow.area.y);
	}
}
