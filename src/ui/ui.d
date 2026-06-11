/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
*/

module ui.ui;
import derelict.sdl2.sdl;
import std.conv;
import main;
import ct.base;
import ct.build;
import com.session;
import ct.purge;
import ui.help;
import ui.input;
import audio.player;
import ui.tables;
import ui.dialogs;
import seq.fplay;
import com.fb;
import com.util;
import com.shortcuts;
import ui.shorthelp;
import ui.menubar;
import seq.sequencer;
import audio.audio;
import std.string;
import std.file;
import std.stdio;
import audio.audio, audio.timer, audio.callback;
static import audio.remote;

enum PAGESTEP = 16;
enum CONFIRM_TIMEOUT = 90;
enum UPDATE_RATE = 2; // 50 / n times per second

private int tickcounter1, tickcounter3 = -1;
private int clearcounter, optimizecounter, escapecounter, restartcounter;

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

	/// Identifies the keyboard-shortcut context this window provides. The active
	/// window's contextId is pushed into the ShortcutManager so context-specific
	/// command shortcuts resolve correctly. Defaults to global.
	@property string contextId() { return Ctx.global; }

protected:

	@property void contextHelp(ContextHelp h) { help = h; hasCustomHelp = true; }
	// Default windows show the (generated) global help live, so regenerating
	// ui.help.HELPMAIN after the registry is populated takes effect everywhere.
	@property ContextHelp contextHelp() { return hasCustomHelp ? help : ui.help.HELPMAIN; }

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

class Infobar : Window, Undoable {
	private {
		const int x1, infoX, playerX;
		int idx;
		bool editing;
	}
	InputString inputTitle, inputAuthor, inputReleased;

	override @property string contextId() { return Ctx.songInfo; }
	override ContextHelp contextHelp() { return ui.help.HELPMAIN; }

	this(Rectangle a) {
		super(a);
		x1 = area.x;
		infoX = x1 + (com.fb.mode > 0 ? 64 : 48);
		playerX = infoX + 43;
	}

	override void update() {
		// Row 0 (the title/menu bar) is now owned by MenuBar (UI.drawMenu);
		// the Infobar only paints the song-info area at the bottom.
		int c1 = audio.player.isPlaying ? 13 : 12;
		screen.fprint(x1,area.y,format("`05Time: `0%x%02d:%02d / $%02x",
									   c1,audio.timer.min, audio.timer.sec,
									   audio.callback.linesPerFrame & 255));

		screen.fprint(x1 + 19,area.y,
				   format("`05Oct: `0d%d  `05Spd: `0d%X  `05St: `0d%d ",
						  state.octave, song.speed, seq.sequencer.stepValue));
		screen.fprint(x1,area.y+1,format("`05Filename: `0d%s", state.filename.leftJustify(38)));
		drawSongField(0, "  `b1T`01itle:", inputTitle, song.title);
		drawSongField(1, " `01Author:", inputAuthor, song.author);
		drawSongField(2, "`01Release:", inputReleased, song.release);
		screen.fprint(playerX, area.y,
				   format("`05Rate:   `0d%-1d*%dhz",
						  song.multiplier, audio.player.ntsc ? 60 : 50));
		screen.fprint(playerX, area.y+1,
				   format("`05SID:    `0d%s%s",
						  audio.player.usefp ? audio.player.curfp.id : audio.player.sidtype ? "8580" : "6581",
						  audio.player.badline ? "&0fb" : " "));
		screen.fprint(playerX, area.y+2,format("`05Player: `0d%s", ztos(song.playerID)));
	}

	override void refresh() {
		inputTitle = new InputString(cast(string)(song.title), cast(int)(song.title.length));
		inputReleased = new InputString(cast(string)(song.release), cast(int)( song.release.length));
		inputAuthor = new InputString(cast(string)(song.author), cast(int)(song.author.length));
		input = ([ inputTitle, inputAuthor, inputReleased ])[idx];
		input.setCoord(infoX + 9,area.y + idx);
	}

	override void activate() {
		editing = true;
		idx = 0;
		refresh();
	}

	override void deactivate() {
		outputStrings();
		editing = false;
	}

	private void outputStrings() {
		auto title = inputValue(inputTitle);
		auto release = inputValue(inputReleased);
		auto author = inputValue(inputAuthor);
		if(song.title == title && song.release == release && song.author == author)
			return;
		com.session.insertUndo(this, createState());
		song.title[] = title[];
		song.release[] = release[];
		song.author[] = author[];
	}

	override int keypress(Keyinfo key) {
		int r = input.keypress(key);
		if(r == RETURN) {
			idx++;
			if(idx > 2) {
				idx = 0;
				return RETURN;
			}
			outputStrings();
			refresh();
		}
		else if(r == CANCEL) {
			idx = 0; update();
			return RETURN;
		}
		return OK;
	}

	private:

	void drawSongField(int row, string label, InputString field, ref char[32] value) {
		screen.fprint(infoX, area.y + row, format("`05%s ", label));
		if(editing && field !is null && idx == row) {
			field.update();
		}
		else {
			screen.fprint(infoX + 9, area.y + row,
						  format("`0d%-32s", value));
		}
	}

	char[32] inputValue(InputString input) {
		return paddedString32(input.toString(false));
	}

	UndoValue createState() {
		UndoValue v;
		v.songTitle = song.title;
		v.songRelease = song.release;
		v.songAuthor = song.author;
		v.hasSongInfo = true;
		return v;
	}

public:

	override void undo(UndoValue v) {
		if(!v.hasSongInfo)
			return;
		song.title[] = v.songTitle[];
		song.release[] = v.songRelease[];
		song.author[] = v.songAuthor[];
		refresh();
		update();
	}

	override UndoValue createRedoState(UndoValue value) {
		return createState();
	}
}

class Statusline : Window {
	int counter;
	string message;

	this(Rectangle a) {
		super(a);
	}

	void display(string msg) {
		message = msg;
		counter = CONFIRM_TIMEOUT;
		screen.clrtoeol(2, 0);
		update();
	}

	override void deactivate() {
		counter = 0;
		update();
	}

	override void update() {
		if(counter)
			screen.fprint(4, 2, "`0f " ~ message);
		else screen.clrtoeol(2, 0);
	}

	void timerEvent() {
		if(counter > 0) {
			--counter;
			if(!counter) update();
		}
	}
}

final private class Toplevel : WindowSwitcher, Undoable {
	InputKeyjam inputKeyjam;
	InsTable instable;
	CmdTable cmdtable;
	WindowSwitcher bottomTabSwitcher;
	WaveTable wavetable;
	PulseTable pulsetable;
	FilterTable filtertable;
	ChordTable chordtable;
	TracksTable trackstable;
	Sequencer sequencer;
	Fplay fplay;
	UI ui;
	Hotspot[] hotspots;
	bool followplay;

 	this(UI ui) {
		this.ui = ui;
		int zone1x = 0;
		int zone2x = screen.width / 2 + zone1x - 1;
		int zone1y = 4;
		int zone1h = screen.height / 2 - 5;
		int zone2y = screen.height / 2;
		int zone2h = screen.height - zone2y - 5;
		int fullTableHeight = screen.height - zone1y - 5;
		enum sequencerContentWidth = 48;
		enum minInsWidth = 3 + 8 * 3 + 14;
		enum preferredInsWidth = 3 + 8 * 3 + 32;
		enum tracksWidth = 19;
		int insWidth = 3 + 8 * 3 + 12;
		int adjacentFixedWidth = 8 + 14 + 14 + 10 + 6 + tracksWidth + com.fb.border * 6;
		bool adjacentTableLayout = com.fb.mode > 0 &&
			screen.width >= sequencerContentWidth + minInsWidth + adjacentFixedWidth;

		int cappedHeight(int rows) {
			int h = rows + 1;
			return fullTableHeight < h ? fullTableHeight : h;
		}

		inputKeyjam = new InputKeyjam();

		int tx;
		int bottomSwitcherX;
		int bottomSwitcherY;
		int bottomSwitcherH;
		int bottomSwitcherW;
		Window[] bottomWindows;
		string bottomHotkeys;

		if(adjacentTableLayout) {
			int tableX = sequencerContentWidth;
			insWidth = screen.width - tableX - adjacentFixedWidth;
			if(insWidth > preferredInsWidth) insWidth = preferredInsWidth;
			sequencer = new Sequencer(Rectangle(zone1x, zone1y, screen.height - 10,
												tableX - zone1x));
			fplay = new Fplay(Rectangle(zone1x, zone1y, screen.height - 10,
										tableX - zone1x));

			tx = tableX;
			instable = new InsTable(Rectangle(tx, zone1y, cappedHeight(0x30), insWidth));
			tx += insWidth + com.fb.border;
			bottomSwitcherX = tx;
			bottomSwitcherY = zone1y;
			bottomSwitcherH = fullTableHeight;
			wavetable = new WaveTable(Rectangle(tx, zone1y, cappedHeight(0x100), 8));
			tx += 8 + com.fb.border;
			pulsetable = new PulseTable(Rectangle(tx, zone1y, cappedHeight(0x40), 14));
			tx += 14 + com.fb.border;
			filtertable = new FilterTable(Rectangle(tx, zone1y, cappedHeight(0x40), 14));
			tx += 14 + com.fb.border;
			cmdtable = new CmdTable(Rectangle(tx, zone1y, cappedHeight(0x40), 10));
			tx += 10 + com.fb.border;
			chordtable = new ChordTable(Rectangle(tx, zone1y, cappedHeight(0x80), 6));
			tx += 6 + com.fb.border;
			trackstable = new TracksTable(Rectangle(tx, zone1y, fullTableHeight, tracksWidth));
			tx += tracksWidth;
			bottomSwitcherW = tx - bottomSwitcherX;
			bottomWindows = [cast(Window)wavetable, pulsetable, filtertable,
							 cmdtable, chordtable, trackstable];
			bottomHotkeys = "wpfmdr";
		}
		else {
			sequencer = new Sequencer(Rectangle(zone1x, zone1y, screen.height - 10,
												zone2x - zone1x));
			fplay = new Fplay(Rectangle(zone1x, zone1y, screen.height - 10,
										zone2x - zone1x));
			instable = new InsTable(Rectangle(zone2x, zone1y, zone1h, insWidth));

			tx = zone2x;
			bottomSwitcherX = zone2x;
			bottomSwitcherY = zone2y;
			bottomSwitcherH = zone2h;
			wavetable = new WaveTable(Rectangle(tx, zone2y, zone2h, 8));
			tx += com.fb.border + 8;
			pulsetable = new PulseTable(Rectangle(tx, zone2y, zone2h, 14));
			tx += com.fb.border + 14;
			filtertable = new FilterTable(Rectangle(tx, zone2y, zone2h, 14));
			tx += com.fb.border + 14;
			cmdtable = new CmdTable(Rectangle(tx, zone2y, zone2h, 10));
			tx += com.fb.border + 10;

			Rectangle ca;
			int tracksX;
			if(com.fb.mode == 0) {
				ca = Rectangle(tx - 6, zone1y, zone1h, 6);
				tracksX = tx;
			}
			else {
				ca = Rectangle(tx, zone2y, zone2h, 6);
				tracksX = tx + 6 + com.fb.border;
			}
			chordtable = new ChordTable(ca);
			// Tracks table is always present; place it after the bottom tables.
			trackstable = new TracksTable(Rectangle(tracksX, zone2y, zone2h, tracksWidth));
			bottomSwitcherW = tracksX + tracksWidth - bottomSwitcherX;
			bottomWindows = [cast(Window)wavetable, pulsetable, filtertable,
							 cmdtable, chordtable, trackstable];
			bottomHotkeys = "wpfmdr";
		}

		bottomTabSwitcher = new WindowSwitcher(Rectangle(bottomSwitcherX, bottomSwitcherY,
														 bottomSwitcherH, bottomSwitcherW),
											   bottomWindows,
											   bottomHotkeys);

		/+
		super(Rectangle(), [cast(Window)sequencer, instable,
							wavetable, pulsetable, filtertable,
							cmdtable, chordtable], null);
		+/

		super(Rectangle(), [cast(Window)sequencer, instable,
					   bottomTabSwitcher]);
		{
			int x1 = 4;
			int infoX = x1 + (com.fb.mode > 0 ? 64 : 48);
			int playerX = infoX + 43;
			int y1 = screen.height - 4;
			int settingsX = x1 + 19;

			hotspots = [
				Hotspot(Rectangle(settingsX, y1, 1, 6), (int b) {
						if(b == 1)
							state.octave = clamp(state.octave + 1, 0, 6);
						else if(b == 3)
							state.octave = clamp(state.octave - 1, 0, 6);
					}),
				Hotspot(Rectangle(settingsX + 8, y1, 1, 7), (int b) {
						if(b == 1)
							song.speed = clamp(song.speed + 1, 0, 31);
						else if(b == 3)
							song.speed = clamp(song.speed - 1, 0, 31);
					}),
				Hotspot(Rectangle(settingsX + 17, y1, 1, 5), (int b) {
						if(b == 1)
							seq.sequencer.stepValue = clamp(seq.sequencer.stepValue + 1, 0, 9);
						else if(b == 3)
							seq.sequencer.stepValue = clamp(seq.sequencer.stepValue - 1, 0, 9);
					}),
				Hotspot(Rectangle(infoX, y1, 3, 41), (int b){
						ui.activateDialog(UI.infobar);
					}),
				Hotspot(Rectangle(playerX + 8, y1 + 1, 1, 10), (int b){
						b > 1 ? audio.player.toggleSIDModel() : audio.player.nextFP();
					}),
				Hotspot(Rectangle(playerX + 8, y1, 1, 14), (int b) {
						b == 1 ? audio.player.incMultiplier() : audio.player.decMultiplier();
					})
				];
		}
		refresh();
	}

	override void clickedAt(int x, int y, int b, int clicks = 1) {
		foreach(idx, win; windows) {
			if(win.area.overlaps(x, y)) {
				activateWindow(idx);
				activeWindow.clickedAt(x, y, b, clicks);
			}
		}
		foreach(idx, win; bottomTabSwitcher.windows) {
			if(win.area.overlaps(x, y)) {
				bottomTabSwitcher.activateWindow(idx);
				bottomTabSwitcher.activeWindow.clickedAt(x, y, b, clicks);
				if(win == trackstable && b == 1 && clicks >= 2) {
					int offset;
					if(trackstable.offsetAtCoord(x, y, offset))
						sequencer.seekPatternOffset(offset);
				}
				break;
			}
		}
		foreach(idx, spot; hotspots) {
			if(spot.area.overlaps(x, y))
				spot.callback(b);
		}
	}

	override int keypress(Keyinfo key) {
		switch(key.unicode) {
		case ']':
			if(song.speed < 32)
				song.speed = song.speed + 1;
			return OK;
		case '[':
			if(song.speed > 0)
				song.speed = song.speed - 1;
			return OK;
		case '{':
			audio.player.setMultiplier(song.multiplier - 1);
			return OK;
		case '}':
			audio.player.setMultiplier(song.multiplier + 1);
			return OK;
/+
		case '(':
			if(octave > 0)
				octave--;
			return OK;
	 	case ')':
			 if(octave < 6)
			 	octave++;
			return OK;+/
		default:
			break;
		}

		// Global Alt- and Ctrl- command shortcuts (window switching, undo/redo,
		// song speed, clear/optimize, etc.) are handled centrally by the
		// ShortcutManager in UI.keypress before reaching here, so their former
		// duplicate switch branches have been removed. The [ ] { } speed and
		// multiplier keys above stay because they are matched on key.unicode,
		// which the registry does not key on. The block below keeps the
		// data-entry / cursor keys that are intentionally not in the registry.
		if(!key.mods & KMOD_SHIFT) {
			switch(key.raw)
			 {
			 case SDLK_KP_DIVIDE:
				 if(state.octave > 0)
					 state.octave--;
				 break;
			 case SDLK_KP_MULTIPLY:
				 if(state.octave < 6)
					 state.octave++;
				 break;
			case SDLK_PLUS:
			case SDLK_KP_PLUS:
				if(state.allowInstabNavigation) {
					instable.stepRow(1);
					state.activeInstrument = instable.row;
				}
				break;
			case SDLK_MINUS:
			case SDLK_KP_MINUS:
				if(state.allowInstabNavigation) {
					instable.stepRow(-1);
					state.activeInstrument = instable.row;
				}
				break;
			 default:
				 break;
			 }
		}
		else if(key.mods & KMOD_SHIFT) {
			version(OSX) {
				if(key.raw == SDLK_EQUALS && state.allowInstabNavigation) {
					instable.stepRow(1);
					state.activeInstrument = instable.row;
				}
			}
		}
		if(state.keyjamStatus == true) {
			inputKeyjam.keypress(key);
		}
		else {
			int r = activeWindow.keypress(key);
			if(r == RETURN || r == CANCEL) {
				assert(0);
			}
			if(activeWindow == sequencer && trackstable !is null) {
				trackstable.refresh();
			}
		}
		return OK;
	}

	override int keyrelease(Keyinfo key) {
		if(state.keyjamStatus == true) {
			inputKeyjam.keyrelease(key);
		}
		return activeWindow.keyrelease(key);
	}

	override void refresh() {
		foreach(t; windows) {
			t.refresh();
			t.update();
		}
		bottomTabSwitcher.refresh();
		// needed because 'input' might be messed by a subdialog
		activeWindow.activate();
	}

	override void update() {
		foreach(t; windows) {
			if(t == bottomTabSwitcher) {
				foreach(bottomWindow; bottomTabSwitcher.windows) {
					bottomWindow.update();
				}
			}
			else {
				t.update();
			}
		}
	}

	void activateInstrument(int ins) {
		if(ins > 47) ins = 47;
		if(ins < 0) ins = 0;
		instable.seekRow(ins);
		state.activeInstrument = ins;
		wavetable.seekRowOnTopIfNeeded(song.instrumentTable[ins + 7 * 48]);
		pulsetable.seekProgram(song.instrumentTable[ins + 5 * 48]);
		filtertable.seekProgram(song.instrumentTable[ins + 4 * 48]);
		refresh();
	}

	void cycleBottomSubwindow(bool reverse) {
		if(activeWindow != bottomTabSwitcher) {
			activateWindow(2);
		}
		bottomTabSwitcher.activeWindowNum += reverse ? -1 : 1;
		bottomTabSwitcher.activeWindowNum = umod(bottomTabSwitcher.activeWindowNum, 0,
												 cast(int)bottomTabSwitcher.windows.length - 1);
		bottomTabSwitcher.activateWindow();
		input = bottomTabSwitcher.input;
	}

	bool fplayEnabled() { return followplay; }

	void activateByCoord(int x, int y) {
		foreach(idx, win; windows) {
			if(win.area.overlaps(x, y)) {
				activateWindow(idx);
			}
		}
		foreach(idx, win; bottomTabSwitcher.windows) {
			if(win.area.overlaps(x, y)) {
				bottomTabSwitcher.activateWindow(idx);
				break;
			}
		}
	}

	void activateInfobar() {
		ui.activateDialog(UI.infobar);
	}
	void timerEvent() {
		fplay.timerEvent();
	}

	Window windowByCoord(int x, int y) {
		foreach(idx, win; windows ~ bottomTabSwitcher.windows) {
			if(win.area.overlaps(x, y))
				return win;
		}
		return null;
	}

	void playFromCursor() {
		Voice[] v = sequencer.getVoices();
		auto d1 = v[0].activeRow;
		auto d2 = v[1].activeRow;
		auto d3 = v[2].activeRow;
		audio.player.start([d1.trkOffset,d2.trkOffset,d3.trkOffset],
					  [d1.seqOffset,d2.seqOffset,d3.seqOffset]);
		fplay.startFromCursor();
	}

	void reset() {
		sequencer.reset();
		sequencer.resetMark();
	}

	void startFp() {
		followplay = true;
		windows[0] = fplay;
		if(activeWindow == sequencer)
			activateWindow(0);
	}

	void startFp(int mode) {
		startFp();
		if(activeWindow == fplay)
			fplay.start(mode);
	}

	void startPlayback(int j) {
		fplay.start(j);
	}

	private void stopFp() {
		followplay = false;
		windows[0] = sequencer;
		activateWindow(activeWindowNum);
	}

	void stopPlayback() {
		fplay.stop();
		if(followplay) {
			stopFp();
			followplay = false;
			activate();
			sequencer.reset(false);
		}
	}

	private void optimizeSong() {
		if(++optimizecounter > 1) {
			refresh();
			// TODO: VALIDATION HERE BEFORE PURGING... PurgeExpception should be useless if validate covers all errorcases
			try {
				saveSongState();
				(new Purge(song,true)).purgeAll();
			}
			catch(PurgeException e) {
				UI.statusline.display(e.toString);
				optimizecounter = 0;
				return;

			}

			refresh();
			UI.statusline.display("Song data optimized.");
			optimizecounter = 0;
		}
		else {
			UI.statusline.display("Press again to confirm song data optimization...");
			tickcounter3 = 0;
		}
	}

	private void saveSongState() {
		com.session.insertUndo(this, createSongState());
	}

	private UndoValue createSongState() {
		UndoValue v;
		song.tableIterator((ct.base.Song.Table t) {
				v.tableData ~= t.data.dup;
			});
		v.insLabels = song.insLabels;
		v.hasInsLabels = true;
		v.songTitle = song.title;
		v.songRelease = song.release;
		v.songAuthor = song.author;
		v.hasSongInfo = true;
		for(int i = 0; i < 3; i++) {
			auto tl = song.tracks[i];
			v.trackLists ~= TracklistStore(tl.deepcopy, tl);
		}
		foreach(s; song.seqs) {
			v.seqSources ~= s;
			v.seqData ~= s.data.raw.dup;
		}
		return v;
	}

	override void undo(UndoValue v) {
		int idx;
		song.tableIterator((ct.base.Song.Table t) {
				t.data[0..$] = v.tableData[idx++][0..$];
			});
		if(v.hasInsLabels)
			song.insLabels[] = v.insLabels[];
		if(v.hasSongInfo) {
			song.title[] = v.songTitle[];
			song.release[] = v.songRelease[];
			song.author[] = v.songAuthor[];
		}
		foreach(t; v.trackLists) {
			t.source.overwriteFrom(t.store);
		}
		foreach(i, s; v.seqSources) {
			s.data.raw[] = v.seqData[i][];
			s.refresh();
		}
		refresh();
	}

	override UndoValue createRedoState(UndoValue value) {
		return createSongState();
	}

	private void clearSong() {
		if(++restartcounter > 1) {
			//song.open(cast(ubyte[])import("player.bin"));
			sequencer.reset();
			refresh();
			clearcounter = 0;
			//savedialog.setFilename("");
			state.filename = "";
			UI.statusline.display("Editor restarted.");
		}
		else {
			UI.statusline.display("Press again to confirm editor cold start...");
			tickcounter3 = 0;
		}
	}

	private void clearSeqs() {
		if(++clearcounter > 1) {
			song.clearSeqs();
			sequencer.reset();
			clearcounter = 0;
			UI.statusline.display("Sequence data cleared.");
		}
		else {
			UI.statusline.display("Press again to confirm sequence data clearing...");
			tickcounter3 = 0;
		}
	}
}

enum VisMode { None, Regs, Oscilloscope }

final class UI {
	private {
		Window dialog = null;
		//bool printSIDDump = false;
		int vismode = VisMode.Regs;
		AboutDialog aboutdialog;
		FileSelectorDialog loaddialog, savedialog, prgdialog;
	}
	enum SPLASH_DURATION_MS = 2500;
	static Statusline statusline;
	static Infobar infobar;
	static Toplevel toplevel;
	MenuBar menubar;
	bool exitRequested = false;
	// Constructed at runtime in the ctor (NOT via a field initializer): a
	// `= new` field initializer is evaluated with CTFE and baked into shared
	// .init memory, which corrupts the manager's associative arrays at runtime.
	ShortcutManager sm;
	// Wall-clock deadline (SDL ticks) for auto-dismissing the startup splash;
	// 0 once dismissed. Keeps the Esc-Esc-y quit chord usable. Declared as the
	// trailing instance field so earlier field offsets stay binary-compatible
	// with objects compiled before this change (no dep tracking in this repo).
	uint splashDeadlineMs;

	this() {
		sm = new ShortcutManager();
		statusline = new Statusline(Rectangle(0, 2, 1));
		toplevel = new Toplevel(this);

		infobar = new Infobar(Rectangle(4, screen.height - 4, 1, screen.width - 8));

		int dialog_width = screen.width - 32;
		int dialog_height = screen.height - 10;
		// Cap dialog dimensions to reasonable sizes
		if(dialog_width > 120) dialog_width = 120;
		if(dialog_height > 50) dialog_height = 50;
		int dialog_x = screen.width / 2 - dialog_width / 2;
		int dialog_y = screen.height / 2 - dialog_height / 2;

		loaddialog = new LoadFileDialog(Rectangle(dialog_x, dialog_y, dialog_height,
												  dialog_width), &loadCallback, &importCallback);
		savedialog = new SaveFileDialog(Rectangle(dialog_x, dialog_y, dialog_height,
												  dialog_width), &saveCallback);
		prgdialog = new SaveFileDialog(Rectangle(dialog_x, dialog_y, dialog_height,
												  dialog_width), &savePrgCallback, "Save playable .prg");

		int aboutdlg_width = screen.width - 18;
		int aboutdlg_height = 13;
		// Cap dialog width to reasonable size (prevent overflow in fprint)
		if(aboutdlg_width > 100) aboutdlg_width = 100;
		int aboutdlg_x = screen.width / 2 - aboutdlg_width / 2;
		int aboutdlg_y = screen.height / 2 - aboutdlg_height / 2;

		aboutdialog = new AboutDialog(Rectangle(aboutdlg_x, aboutdlg_y,
												aboutdlg_height,
												aboutdlg_width));

		audio.player.setMultiplier(song.multiplier);

		//if(com.fb.mode > 0)
		//	state.shortTitles = false;
		toplevel.activate();

		// Initialize and register keyboard shortcuts
		registerShortcuts();
		// Seed the active context from the initially active window (mainui is not
		// assigned yet during construction, so the WindowSwitcher push is skipped).
		sm.setActiveContext(toplevel.contextId);
		// Generate the F12 help pages from the now-populated registry.
		ui.help.HELPMAIN = genMainHelp(sm);
		ui.help.HELPSEQUENCER = genSequencerHelp(sm);

		// Build the top-bar menu (also from the now-populated registry); its ctor
		// asserts every global command category is reachable from a menu.
		menubar = new MenuBar(sm);

		// Pop the splash on startup; it auto-dismisses after SPLASH_DURATION_MS
		// (see timerEvent) and any key also clears it.
		activateDialog(aboutdialog);
		splashDeadlineMs = SDL_GetTicks() + SPLASH_DURATION_MS;

		update();
	}
	
	/**
	 * Register all keyboard shortcut actions, their bindings and metadata.
	 * This is the single source of truth for global command shortcuts; help
	 * text and doc/KEYBOARD.md are generated from these registrations.
	 */
	private void registerShortcuts() {
		// Application Control. Quit has no hotkey anymore (Esc opens the menu
		// bar); it is reached via File > Quit, so it is registered menu-only.
		// Its own "Application" category places it in a trailing group of the
		// File menu (separated from the load/save items, Quit last).
		sm.registerMenuOnly("exit_app", Ctx.global, "Application",
					"Quit program", {
			activateDialog(new ConfirmationDialog("Really exit (y/n)? ", (int param) {
				if(param != 0) return;
				audio.player.stop();
				exitRequested = true;
			}));
		}, "Quit");

		sm.register("toggle_fullscreen", Ctx.global, "Display",
					"Toggle fullscreen", SDLK_RETURN, KMOD_ALT, {
			video.toggleFullscreen();
		});

		sm.register("help_dialog", Ctx.global, "Help",
					"Open context help", SDLK_F12, 0, {
			int helpdlg_width = screen.width - 10;
			int helpdlg_height = 36;
			int helpdlg_x = screen.width / 2 - helpdlg_width / 2;
			int helpdlg_y = screen.height / 2 - helpdlg_height / 2;
			HelpDialog helpdialog =
				new HelpDialog(Rectangle(helpdlg_x, helpdlg_y,
										 helpdlg_height,
										 helpdlg_width), activeWindow.contextHelp);
			activateDialog(helpdialog);
		});

		sm.register("screenshot", Ctx.global, "Display",
					"Save screenshot", SDLK_F12, KMOD_CTRL, {
			// Handled in main.d before translation
			// This action registered for consistency but won't be triggered here
		});

		// File Operations
		sm.register("load_file", Ctx.global, "File",
					"Open the Load song dialog", SDLK_F9, 0, {
			activateDialog(loaddialog);
		});

		sm.register("save_file", Ctx.global, "File",
					"Open the Save song dialog", SDLK_F10, 0, {
			activateDialog(savedialog);
		});

		sm.register("save_prg", Ctx.global, "File",
					"Save current subtune as a playable .prg", SDLK_F10, KMOD_SHIFT, {
			prgdialog.setDirectory(getcwd());   // = the loaded .ct's dir
			prgdialog.setFilename(proposePrgName());
			activateDialog(prgdialog);
		});

		sm.register("quick_save", Ctx.global, "File",
					"Quick save song (doesn't ask a filename)", SDLK_F10, KMOD_CTRL, {
			string s = savedialog.filename;
			if(s == "")
				statusline.display("Cannot Quicksave; give filename first by doing a regular save.");
			else {
				saveCallback(s);
				statusline.display(format("Saved \"%s\".",s));
			}
		});

		// Undo/Redo
		sm.register("undo", Ctx.global, "Edit", "Undo", SDLK_z, KMOD_CTRL, {
			com.session.executeUndo();
		});

		sm.register("redo", Ctx.global, "Edit", "Redo", SDLK_r, KMOD_CTRL, {
			com.session.executeRedo();
			refresh();
		});

		// Playback Controls
		sm.register("play_from_mark", Ctx.global, "Playback",
					"Play from playback mark", SDLK_F1, 0, {
			F1orF2(Keyinfo(0, 0, 0), false);
		});

		sm.register("play_from_mark_follow", Ctx.global, "Playback",
					"Play / resume from mark with tracking", SDLK_F1, KMOD_SHIFT, {
			F1orF2(Keyinfo(0, KMOD_SHIFT, 0), false);
		});

		sm.register("play_from_beginning", Ctx.global, "Playback",
					"Play from the start", SDLK_F2, 0, {
			F1orF2(Keyinfo(0, 0, 0), true);
		});

		sm.register("play_from_beginning_follow", Ctx.global, "Playback",
					"Play / resume from the start with tracking", SDLK_F2, KMOD_SHIFT, {
			F1orF2(Keyinfo(0, KMOD_SHIFT, 0), true);
		});

		sm.register("play_from_cursor", Ctx.global, "Playback",
					"Play from cursor position", SDLK_F3, 0, {
			toplevel.playFromCursor();
		});

		sm.register("stop_playback", Ctx.global, "Playback",
					"Stop playback", SDLK_F4, 0, {
			if(toplevel.fplayEnabled())
				seqPos.copyFrom(fplayPos);
			stop();
			if(toplevel.fplayEnabled())
				toplevel.stopFp();
		});

		sm.register("toggle_follow_mode", Ctx.global, "Playback",
					"Start/stop tracking (works only when playing)", SDLK_SCROLLLOCK, 0, {
			toggleFollowMode();
		});
		sm.bindAlias("toggle_follow_mode", SDLK_F5, KMOD_CTRL);

		sm.register("fast_forward_5", Ctx.global, "Playback",
					"Fast forward", SDLK_F8, 0, {
			audio.player.fastForward(5);
		});

		sm.register("fast_forward_25", Ctx.global, "Playback",
					"Fast forward more", SDLK_F8, KMOD_SHIFT, {
			audio.player.fastForward(25);
		});

		// Playback Options
		sm.register("next_filter_preset", Ctx.global, "Playback options",
					"Select next SID filter preset", SDLK_F8, KMOD_CTRL, {
			audio.player.nextFP();
		});

		sm.register("prev_filter_preset", Ctx.global, "Playback options",
					"Select previous SID filter preset", SDLK_F8, KMOD_CTRL | KMOD_SHIFT, {
			audio.player.prevFP();
		});

		sm.register("toggle_interpolation", Ctx.global, "Playback options",
					"Toggle interpolation", SDLK_F2, KMOD_CTRL, {
			audio.player.interpolate ^= 1;
			audio.player.init();
		});

		sm.register("toggle_sid_model", Ctx.global, "Playback options",
					"Toggle SID type (6581/8580)", SDLK_F3, KMOD_CTRL, {
			song.sidModel ^= 1;
			audio.player.setSidModel(song.sidModel);
		});

		sm.register("cycle_visualization", Ctx.global, "Playback options",
					"Cycle playback visualization", SDLK_F9, KMOD_CTRL, {
			vismode = umod(vismode + 1, 0, VisMode.max);
			screen.clrtoeol(55, 1, 0);
			screen.clrtoeol(55, 2, 0);
			screen.clrtoeol(55, 3, 0);
			video.clearVisualizer();
		});

		sm.register("dump_frame", Ctx.global, "Playback options",
					"Dump current SID register frame", SDLK_F12, KMOD_ALT, {
			audio.player.dumpFrame();
		});

		// Voice Control
		sm.register("toggle_voice_1", Ctx.global, "Voice control",
					"Toggle voice 1 on/off", SDLK_1, KMOD_CTRL, {
			audio.player.toggleVoice(0);
		});

		sm.register("toggle_voice_2", Ctx.global, "Voice control",
					"Toggle voice 2 on/off", SDLK_2, KMOD_CTRL, {
			audio.player.toggleVoice(1);
		});

		sm.register("toggle_voice_3", Ctx.global, "Voice control",
					"Toggle voice 3 on/off", SDLK_3, KMOD_CTRL, {
			audio.player.toggleVoice(2);
		});

		// Window Navigation
		sm.register("next_window", Ctx.global, "Window navigation",
					"Move cursor between subwindows", SDLK_TAB, 0, {
			toplevel.cycleBottomSubwindow(false);
		});

		sm.register("prev_window", Ctx.global, "Window navigation",
					"Move cursor between subwindows (reverse)", SDLK_TAB, KMOD_SHIFT, {
			toplevel.cycleBottomSubwindow(true);
		});

		sm.register("cycle_window", Ctx.global, "Window navigation",
					"Move cursor between main windows", SDLK_TAB, KMOD_CTRL, {
			toplevel.activeWindowNum++;
			if(toplevel.activeWindowNum >= toplevel.windows.length)
				toplevel.activeWindowNum %= toplevel.windows.length;
			toplevel.activateWindow();
		});

		sm.register("cycle_window_reverse", Ctx.global, "Window navigation",
					"Move cursor between main windows (reverse)", SDLK_TAB, KMOD_CTRL | KMOD_SHIFT, {
			toplevel.activeWindowNum--;
			if(toplevel.activeWindowNum < 0) toplevel.activeWindowNum = cast(int)(toplevel.windows.length - 1);
			toplevel.activateWindow();
		});

		// Direct Window Access
		sm.register("window_voice1", Ctx.global, "Window navigation",
					"Jump to voice 1", SDLK_1, KMOD_ALT, {
			toplevel.activateWindow(0);
			toplevel.sequencer.activateVoice(0);
		});

		sm.register("window_voice2", Ctx.global, "Window navigation",
					"Jump to voice 2", SDLK_2, KMOD_ALT, {
			toplevel.activateWindow(0);
			toplevel.sequencer.activateVoice(1);
		});

		sm.register("window_voice3", Ctx.global, "Window navigation",
					"Jump to voice 3", SDLK_3, KMOD_ALT, {
			toplevel.activateWindow(0);
			toplevel.sequencer.activateVoice(2);
		});

		sm.register("window_sequence", Ctx.global, "Window navigation",
					"Jump to Sequencer", SDLK_v, KMOD_ALT, {
			toplevel.activateWindow(0);
		});

		sm.register("window_instrument", Ctx.global, "Window navigation",
					"Jump to Instrument table", SDLK_4, KMOD_ALT, {
			toplevel.activateWindow(1);
		});
		sm.bindAlias("window_instrument", SDLK_i, KMOD_ALT);

		sm.register("window_wave", Ctx.global, "Window navigation",
					"Jump to Wave table", SDLK_5, KMOD_ALT, {
			toplevel.activateWindow(2);
			// Alt modifier required so the bottom tab-switcher treats this as a
			// tab hotkey (Alt+letter) rather than data entry.
			auto key = Keyinfo(SDLK_w, KMOD_ALT, 0);
			toplevel.activeWindow.keypress(key);
		});
		sm.bindAlias("window_wave", SDLK_w, KMOD_ALT);

		sm.register("window_pulse", Ctx.global, "Window navigation",
					"Jump to Pulse table", SDLK_6, KMOD_ALT, {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_p, KMOD_ALT, 0);
			toplevel.activeWindow.keypress(key);
		});
		sm.bindAlias("window_pulse", SDLK_p, KMOD_ALT);

		sm.register("window_filter", Ctx.global, "Window navigation",
					"Jump to Filter table", SDLK_7, KMOD_ALT, {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_f, KMOD_ALT, 0);
			toplevel.activeWindow.keypress(key);
		});
		sm.bindAlias("window_filter", SDLK_f, KMOD_ALT);

		sm.register("window_command", Ctx.global, "Window navigation",
					"Jump to Cmd table", SDLK_8, KMOD_ALT, {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_m, KMOD_ALT, 0);
			toplevel.activeWindow.keypress(key);
		});
		sm.bindAlias("window_command", SDLK_m, KMOD_ALT);

		sm.register("window_chord", Ctx.global, "Window navigation",
					"Jump to Chord table", SDLK_9, KMOD_ALT, {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_d, KMOD_ALT, 0);
			toplevel.activeWindow.keypress(key);
		});
		sm.bindAlias("window_chord", SDLK_d, KMOD_ALT);

		sm.register("window_song_info", Ctx.global, "Window navigation",
					"Edit title / author / release info", SDLK_t, KMOD_ALT, {
			toplevel.activateInfobar();
		});

		// Song Settings
		sm.register("increase_speed", Ctx.global, "Song variables",
					"Increase default song speed", SDLK_PLUS, KMOD_CTRL, {
			song.speed = clamp(song.speed + 1, 0, 31);
		});
		sm.bindAlias("increase_speed", SDLK_KP_PLUS, KMOD_CTRL);

		sm.register("decrease_speed", Ctx.global, "Song variables",
					"Decrease default song speed", SDLK_MINUS, KMOD_CTRL, {
			song.speed = clamp(song.speed - 1, 0, 31);
		});
		sm.bindAlias("decrease_speed", SDLK_KP_MINUS, KMOD_CTRL);

		sm.register("increase_multiplier_alt", Ctx.global, "Song variables",
					"Increase multispeed framecall counter", SDLK_KP_PLUS, KMOD_ALT, {
			audio.player.setMultiplier(song.multiplier + 1);
		});

		sm.register("decrease_multiplier_alt", Ctx.global, "Song variables",
					"Decrease multispeed framecall counter", SDLK_KP_MINUS, KMOD_ALT, {
			audio.player.setMultiplier(song.multiplier - 1);
		});

		// Keyjam Mode
		sm.register("toggle_keyjam", Ctx.global, "Keyjam",
					"Toggle keyjam mode", SDLK_SPACE, KMOD_CTRL, {
			if(song.ver < 7) return;
			state.keyjamStatus ^= 1;
			enableKeyjamMode(state.keyjamStatus);
			statusline.display("Keyjam " ~ (state.keyjamStatus ? "enabled." : "disabled.")
							   ~ " Press Ctrl-Space to toggle.");
		});

		// Song Management
		sm.register("clear_sequences", Ctx.global, "Song management",
					"Clear sequences (press twice to activate)", SDLK_KP_0, KMOD_ALT, {
			toplevel.clearSeqs();
		});
		sm.bindAlias("clear_sequences", SDLK_c, KMOD_CTRL | KMOD_ALT);

		sm.register("optimize_song", Ctx.global, "Song management",
					"Optimize (clear unused sequences & data)", SDLK_KP_PERIOD, KMOD_ALT, {
			toplevel.optimizeSong();
		});
		sm.bindAlias("optimize_song", SDLK_o, KMOD_CTRL | KMOD_ALT);

		// Display
		sm.register("toggle_help_text", Ctx.global, "Display",
					"Toggle help texts", SDLK_h, KMOD_ALT, {
			state.displayHelp ^= 1;
			UI.statusline.display("Help texts " ~ (state.displayHelp ? "enabled." : "disabled."));
		});

		// Dialogs
		sm.register("about_dialog", Ctx.global, "Help",
					"Show the splash / about screen", SDLK_F11, 0, {
			activateDialog(aboutdialog);
		});
		// macOS reserves bare F11 (Show Desktop); Alt-S is a Mac-safe alias
		// (Option+letter isn't intercepted, matching the window-nav aliases).
		sm.bindAlias("about_dialog", SDLK_s, KMOD_ALT);

		// Context-specific command shortcuts (sequencer, tables, ...)
		registerContextShortcuts();
	}

	/**
	 * Re-dispatches a synthetic keypress through the normal window path
	 * (bypassing the shortcut manager, so no recursion). Context-command
	 * callbacks use this so the proven per-widget keypress logic remains the
	 * single implementation, while the registry is the single place that knows
	 * about every command (for help generation and future menus).
	 */
	private void invokeKey(int key, int mods, int unicode = 0) {
		toplevel.keypress(Keyinfo(key, mods, unicode));
	}

	/**
	 * Register context-specific command shortcuts. Each is registered under a
	 * non-global context; dispatch resolves the active context (pushed as the
	 * active window / sequencer column changes), walking note_column/
	 * track_column -> sequencer -> global. Callbacks re-dispatch the key to the
	 * active widget, so behaviour is identical to pressing the key directly,
	 * while every command is catalogued here for docs and menus. Raw data entry
	 * (hex nibbles, the QWERTY piano, text fields) is intentionally NOT listed.
	 */
	private void registerContextShortcuts() {
		alias C = Ctx;

		// --- Sequencer (common to note/track/overview columns) ---
		sm.register("seq_song_start", C.sequencer, "Navigation",
					"Move cursor to song start", SDLK_HOME, KMOD_SHIFT,
					{ invokeKey(SDLK_HOME, KMOD_SHIFT); });
		sm.register("seq_song_end", C.sequencer, "Navigation",
					"Move cursor to song end", SDLK_END, KMOD_SHIFT,
					{ invokeKey(SDLK_END, KMOD_SHIFT); });
		sm.register("seq_jump_mark", C.sequencer, "Navigation",
					"Jump to playback mark (realigns the voices)", SDLK_HOME, KMOD_CTRL,
					{ invokeKey(SDLK_HOME, KMOD_CTRL); });
		sm.bindAlias("seq_jump_mark", SDLK_h, KMOD_CTRL);
		sm.register("seq_centralize", C.sequencer, "Navigation",
					"Center the cursor on screen", SDLK_l, KMOD_CTRL,
					{ invokeKey(SDLK_l, KMOD_CTRL); });
		sm.register("seq_set_mark", C.sequencer, "Navigation",
					"Set playback start mark to current position", SDLK_BACKSPACE, 0,
					{ invokeKey(SDLK_BACKSPACE, 0); });
		sm.register("seq_wrap_mark", C.sequencer, "Navigation",
					"Set loop (wrap) mark to current position", SDLK_BACKSPACE, KMOD_CTRL,
					{ invokeKey(SDLK_BACKSPACE, KMOD_CTRL); });

		sm.register("seq_highlight_inc", C.sequencer, "Display",
					"Increase row highlight value", SDLK_m, KMOD_CTRL,
					{ invokeKey(SDLK_m, KMOD_CTRL); });
		sm.register("seq_highlight_dec", C.sequencer, "Display",
					"Decrease row highlight value", SDLK_n, KMOD_CTRL,
					{ invokeKey(SDLK_n, KMOD_CTRL); });
		sm.register("seq_highlight_reset", C.sequencer, "Display",
					"Reset highlighting to current row", SDLK_0, KMOD_CTRL,
					{ invokeKey(SDLK_0, KMOD_CTRL); });
		sm.register("seq_rowcounter", C.sequencer, "Display",
					"Show/hide row counters for sequences", SDLK_e, KMOD_CTRL,
					{ invokeKey(SDLK_e, KMOD_CTRL); });
		sm.register("seq_relative_notes", C.sequencer, "Display",
					"Toggle notes relative to current transpose", SDLK_t, KMOD_CTRL,
					{ invokeKey(SDLK_t, KMOD_CTRL); });

		sm.register("seq_copy", C.sequencer, "Sequence operations",
					"Ask for a SEQ number and copy contents over current SEQ", SDLK_c, KMOD_ALT,
					{ invokeKey(SDLK_c, KMOD_ALT); });
		sm.register("seq_append", C.sequencer, "Sequence operations",
					"Ask for a SEQ number and insert contents to cursor pos", SDLK_a, KMOD_ALT,
					{ invokeKey(SDLK_a, KMOD_ALT); });
		sm.register("seq_prev_subtune", C.sequencer, "Sequence operations",
					"Activate previous subtune", SDLK_LEFT, KMOD_ALT,
					{ invokeKey(SDLK_LEFT, KMOD_ALT); });
		sm.register("seq_next_subtune", C.sequencer, "Sequence operations",
					"Activate next subtune", SDLK_RIGHT, KMOD_ALT,
					{ invokeKey(SDLK_RIGHT, KMOD_ALT); });
		sm.register("seq_height_inc", C.sequencer, "Sequence operations",
					"Increase sequencer height", SDLK_EQUALS, KMOD_CTRL,
					{ invokeKey(SDLK_EQUALS, KMOD_CTRL); });
		sm.bindAlias("seq_height_inc", SDLK_KP_PLUS, KMOD_CTRL);
		sm.register("seq_height_dec", C.sequencer, "Sequence operations",
					"Decrease sequencer height", SDLK_MINUS, KMOD_CTRL,
					{ invokeKey(SDLK_MINUS, KMOD_CTRL); });
		sm.bindAlias("seq_height_dec", SDLK_KP_MINUS, KMOD_CTRL);
		sm.register("seq_enter_track_col", C.sequencer, "Sequence operations",
					"Enter the track column / toggle tracklist display", SDLK_F5, 0,
					{ invokeKey(SDLK_F5, 0); });
		sm.register("seq_enter_note_col", C.sequencer, "Sequence operations",
					"Enter the note column", SDLK_F6, 0,
					{ invokeKey(SDLK_F6, 0); });
		sm.register("seq_overview", C.sequencer, "Sequence operations",
					"Toggle tracklist overview mode", SDLK_F7, 0,
					{ invokeKey(SDLK_F7, 0); });

		// --- Note column (F6) ---
		sm.register("note_play_row", C.noteColumn, "Note column",
					"Play notes for all voices in current row", SDLK_KP_0, 0,
					{ invokeKey(SDLK_KP_0, 0); });
		// Keypad-free alias for keyboards without a numpad.
		sm.bindAlias("note_play_row", SDLK_p, KMOD_CTRL | KMOD_SHIFT);
		sm.register("note_split", C.noteColumn, "Note column",
					"Split current sequence into two from cursor pos", SDLK_p, KMOD_CTRL,
					{ invokeKey(SDLK_p, KMOD_CTRL); });
		sm.register("note_seq_start", C.noteColumn, "Note column",
					"Move cursor to SEQ start (or screen top)", SDLK_HOME, 0,
					{ invokeKey(SDLK_HOME, 0); });
		sm.register("note_seq_end", C.noteColumn, "Note column",
					"Move cursor to SEQ end (or screen bottom)", SDLK_END, 0,
					{ invokeKey(SDLK_END, 0); });
		sm.register("note_expand_quick", C.noteColumn, "Note column",
					"Quick expand sequence (by highlight value * 4)", SDLK_RETURN, KMOD_SHIFT,
					{ invokeKey(SDLK_RETURN, KMOD_SHIFT); });
		sm.register("note_insert_row", C.noteColumn, "Note column",
					"Insert a row (with sequence expand)", SDLK_INSERT, KMOD_SHIFT,
					{ invokeKey(SDLK_INSERT, KMOD_SHIFT); });
		sm.register("note_delete_row", C.noteColumn, "Note column",
					"Delete a row (with sequence shrink)", SDLK_DELETE, KMOD_SHIFT,
					{ invokeKey(SDLK_DELETE, KMOD_SHIFT); });
		sm.register("note_expand", C.noteColumn, "Note column",
					"Expand the sequence", SDLK_INSERT, KMOD_CTRL,
					{ invokeKey(SDLK_INSERT, KMOD_CTRL); });
		sm.register("note_shrink", C.noteColumn, "Note column",
					"Shrink the sequence", SDLK_DELETE, KMOD_CTRL,
					{ invokeKey(SDLK_DELETE, KMOD_CTRL); });
		sm.register("note_trans_semi_up", C.noteColumn, "Note column",
					"Transpose semitone up", SDLK_q, KMOD_CTRL,
					{ invokeKey(SDLK_q, KMOD_CTRL); });
		sm.register("note_trans_semi_down", C.noteColumn, "Note column",
					"Transpose semitone down", SDLK_a, KMOD_CTRL,
					{ invokeKey(SDLK_a, KMOD_CTRL); });
		sm.register("note_trans_oct_up", C.noteColumn, "Note column",
					"Transpose octave up", SDLK_w, KMOD_CTRL,
					{ invokeKey(SDLK_w, KMOD_CTRL); });
		sm.register("note_trans_oct_down", C.noteColumn, "Note column",
					"Transpose octave down", SDLK_s, KMOD_CTRL,
					{ invokeKey(SDLK_s, KMOD_CTRL); });
		sm.register("note_grab_instr", C.noteColumn, "Note column",
					"Grab the instrument value in the current row", SDLK_RETURN, 0,
					{ invokeKey(SDLK_RETURN, 0); });
		sm.register("note_tie", C.noteColumn, "Note column",
					"Change the note in current row to a tie note", SDLK_COMMA, 0,
					{ invokeKey(SDLK_COMMA, 0, ','); });
		sm.register("note_autoinsert", C.noteColumn, "Note column",
					"Toggle automatic instrument value insert", SDLK_SEMICOLON, 0,
					{ invokeKey(SDLK_SEMICOLON, 0, ';'); });
		sm.register("note_octave_dec", C.noteColumn, "Note column",
					"Decrease base octave", SDLK_LESS, 0,
					{ invokeKey(SDLK_LESS, 0, '<'); });
		sm.register("note_octave_inc", C.noteColumn, "Note column",
					"Increase base octave", SDLK_GREATER, 0,
					{ invokeKey(SDLK_GREATER, 0, '>'); });

		// --- Track column (F5) ---
		sm.register("trk_insert", C.trackColumn, "Track column",
					"Insert a track at cursor", SDLK_INSERT, 0,
					{ invokeKey(SDLK_INSERT, 0); });
		sm.register("trk_delete", C.trackColumn, "Track column",
					"Delete track at cursor", SDLK_DELETE, 0,
					{ invokeKey(SDLK_DELETE, 0); });
		sm.register("trk_insert_end", C.trackColumn, "Track column",
					"Insert a track to end of voice and move there", SDLK_INSERT, KMOD_CTRL,
					{ invokeKey(SDLK_INSERT, KMOD_CTRL); });
		sm.register("trk_delete_end", C.trackColumn, "Track column",
					"Delete track to end of voice and move there", SDLK_DELETE, KMOD_CTRL,
					{ invokeKey(SDLK_DELETE, KMOD_CTRL); });
		sm.register("trk_insert_all", C.trackColumn, "Track column",
					"Insert a track for all voices", SDLK_INSERT, KMOD_CTRL | KMOD_SHIFT,
					{ invokeKey(SDLK_INSERT, KMOD_CTRL | KMOD_SHIFT); });
		sm.register("trk_delete_all", C.trackColumn, "Track column",
					"Delete a track for all voices", SDLK_DELETE, KMOD_CTRL | KMOD_SHIFT,
					{ invokeKey(SDLK_DELETE, KMOD_CTRL | KMOD_SHIFT); });
		sm.register("trk_trans_up", C.trackColumn, "Track column",
					"Transpose tracks up from cursor down", SDLK_q, KMOD_CTRL,
					{ invokeKey(SDLK_q, KMOD_CTRL); });
		sm.register("trk_trans_down", C.trackColumn, "Track column",
					"Transpose tracks down from cursor down", SDLK_a, KMOD_CTRL,
					{ invokeKey(SDLK_a, KMOD_CTRL); });
		sm.register("trk_copy", C.trackColumn, "Track column",
					"Ask for a number and copy tracks into clipboard", SDLK_c, KMOD_CTRL,
					{ invokeKey(SDLK_c, KMOD_CTRL); });
		sm.bindAlias("trk_copy", SDLK_z, KMOD_ALT);
		sm.register("trk_paste", C.trackColumn, "Track column",
					"Paste copied tracks (ask insert or overwrite)", SDLK_v, KMOD_CTRL,
					{ invokeKey(SDLK_v, KMOD_CTRL); });
		sm.register("trk_paste_insert", C.trackColumn, "Track column",
					"Paste copied tracks as insert", SDLK_i, KMOD_CTRL,
					{ invokeKey(SDLK_i, KMOD_CTRL); });
		sm.bindAlias("trk_paste_insert", SDLK_b, KMOD_ALT);
		sm.register("trk_paste_overwrite", C.trackColumn, "Track column",
					"Paste copied tracks as overwrite", SDLK_o, KMOD_CTRL,
					{ invokeKey(SDLK_o, KMOD_CTRL); });
		sm.register("trk_swap_v1", C.trackColumn, "Track column",
					"Swap voice's tracks with voice 1's from cursor down", SDLK_1, KMOD_CTRL | KMOD_ALT,
					{ invokeKey(SDLK_1, KMOD_CTRL | KMOD_ALT); });
		sm.register("trk_swap_v2", C.trackColumn, "Track column",
					"Swap voice's tracks with voice 2's from cursor down", SDLK_2, KMOD_CTRL | KMOD_ALT,
					{ invokeKey(SDLK_2, KMOD_CTRL | KMOD_ALT); });
		sm.register("trk_swap_v3", C.trackColumn, "Track column",
					"Swap voice's tracks with voice 3's from cursor down", SDLK_3, KMOD_CTRL | KMOD_ALT,
					{ invokeKey(SDLK_3, KMOD_CTRL | KMOD_ALT); });
		sm.register("trk_find_unused", C.trackColumn, "Track column",
					"Find next unused sequence from current value", SDLK_f, KMOD_CTRL,
					{ invokeKey(SDLK_f, KMOD_CTRL, 6); });
		sm.register("trk_prev_seq", C.trackColumn, "Track column",
					"Select previous sequence", SDLK_LESS, 0,
					{ invokeKey(SDLK_LESS, 0, '<'); });
		sm.register("trk_next_seq", C.trackColumn, "Track column",
					"Select next sequence", SDLK_GREATER, 0,
					{ invokeKey(SDLK_GREATER, 0, '>'); });

		// --- Instrument table ---
		sm.register("ins_load", C.instrumentTable, "Instrument table",
					"Load current instrument from disk", SDLK_l, KMOD_CTRL,
					{ invokeKey(SDLK_l, KMOD_CTRL); });
		sm.register("ins_save", C.instrumentTable, "Instrument table",
					"Save current instrument to disk", SDLK_s, KMOD_CTRL,
					{ invokeKey(SDLK_s, KMOD_CTRL); });
		sm.register("ins_delete", C.instrumentTable, "Instrument table",
					"Delete current instrument", SDLK_d, KMOD_CTRL,
					{ invokeKey(SDLK_d, KMOD_CTRL); });
		sm.register("ins_copy", C.instrumentTable, "Instrument table",
					"Copy instrument to clipboard", SDLK_c, KMOD_CTRL,
					{ invokeKey(SDLK_c, KMOD_CTRL); });
		sm.register("ins_paste", C.instrumentTable, "Instrument table",
					"Paste instrument from clipboard", SDLK_v, KMOD_CTRL,
					{ invokeKey(SDLK_v, KMOD_CTRL); });

		// --- Sub-tables (wave / pulse / filter) ---
		sm.register("wave_goto_instr", C.subtable, "Tables",
					"Jump to current instrument's wave", SDLK_g, 0,
					{ invokeKey(SDLK_g, 0, 'g'); });
		sm.register("wave_clear_row", C.subtable, "Tables",
					"Clear current wave row", SDLK_PERIOD, 0,
					{ invokeKey(SDLK_PERIOD, 0, '.'); });
		sm.register("table_row_top", C.subtable, "Tables",
					"Jump to first row", SDLK_HOME, KMOD_SHIFT,
					{ invokeKey(SDLK_HOME, KMOD_SHIFT); });
		sm.register("table_row_bottom", C.subtable, "Tables",
					"Jump to last used row", SDLK_END, KMOD_SHIFT,
					{ invokeKey(SDLK_END, KMOD_SHIFT); });
		sm.register("table_insert_row", C.subtable, "Tables",
					"Insert a row", SDLK_INSERT, 0,
					{ invokeKey(SDLK_INSERT, 0); });
		sm.register("table_delete_row", C.subtable, "Tables",
					"Delete a row", SDLK_DELETE, 0,
					{ invokeKey(SDLK_DELETE, 0); });
	}

	private void toggleFollowMode() {
		if(!audio.player.isPlaying) return;
		if(toplevel.fplayEnabled()) {
			stop(false);
			seqPos.copyFrom(fplayPos);
			toplevel.stopFp();
			statusline.display("Tracking off.");
		}
		else {
			stop(false);
			toplevel.startFp();
			statusline.display("Tracking on.");
		}
	}

	@property Window activeWindow() {
		if(dialog) return dialog;
		return toplevel.activeWindow;
	}

	@property Input activeInput() {
		return activeWindow.input;
	}

	@property VisMode currentVisMode() {
		return cast(VisMode)vismode;
	}

	void timerEvent(int n) {
		// Auto-dismiss the startup splash once its deadline passes.
		if(splashDeadlineMs != 0 && SDL_GetTicks() >= splashDeadlineMs) {
			splashDeadlineMs = 0;
			if(dialog is aboutdialog) closeDialog();
		}
		Exception e = audio.callback.getException();
		if(e !is null) {
			writeln("error" ~ e.toString());
			audio.player.stop();
			statusline.display(e.toString());
		}
		if((tickcounter3 >= 0) && ++tickcounter3 > 20) {
			clearcounter = optimizecounter = escapecounter = restartcounter = 0;
			infobar.update();
			drawMenu();
			tickcounter3 = -1;
		}
		statusline.timerEvent();
		tickcounter1 += n;
		if(tickcounter1 >= UPDATE_RATE) {
			infobar.update();
			if(dialog) dialog.update();
			tickcounter1 = 0;
			toplevel.timerEvent();

			if(audio.player.isPlaying || audio.player.keyjamEnabled) {
				if(vismode == VisMode.Regs) {
					int x = screen.width - 42;
					screen.cprint(x, 1, 15, 0, "V1:");
					screen.cprint(x, 2, 15, 0, "V2:");
					screen.cprint(x, 3, 15, 0, "V3:");
					screen.cprint(x+26, 1, 15, 0, "$D415 16 17 18");

					for(int i = 0; i < 7; i++) {
						screen.cprint(x+3+i*3, 1, 5,0, format("%02X", audio.audio.sidreg[i]));
						screen.cprint(x+3+i*3, 2, 5,0, format("%02X", audio.audio.sidreg[i+7]));
						screen.cprint(x+3+i*3, 3, 5,0, format("%02X", audio.audio.sidreg[i+14]));
					}

					for(int i = 0; i < 4;i++) {
						screen.cprint(x+8+21+i*3, 2, 5,0, format("%02X", audio.audio.sidreg[i+0x15]));
					}
				}
				update();  // TESTME: just do video.updateFrame()

				// Apply playback row tinting only when no dialog is covering
				// the tables. Dialogs must remain visually authoritative.
				if(dialog is null) {
					if(toplevel.followplay && toplevel.fplay) {
						toplevel.fplay.renderVisualization();
					} else if(toplevel.sequencer) {
						toplevel.sequencer.renderVisualization();
					}
				}
			}
		}
		if(vismode == VisMode.Oscilloscope &&
		   (audio.player.isPlaying || audio.player.keyjamEnabled))
			video.drawVisualizer(n);
	}

	void update() {
		infobar.update();
		toplevel.update();
		drawMenu();
		if(dialog)
			dialog.update();
	}

	// Draws the top-bar menu (row 0) and, when focused, its dropdown. Called
	// after every header/content repaint so the periodic infobar refresh never
	// erases the bar. The dropdown is drawn last so it overlays the tables.
	private void drawMenu() {
		if(menubar is null) return;
		menubar.drawBar();
		menubar.drawDropdown();
	}

	private void F1orF2(Keyinfo key, bool fromStart) {
		if(audio.player.isPlaying) {
			if(!(key.mods & KMOD_SHIFT) && toplevel.fplayEnabled()) { // drop tracking
				stop(false);
				seqPos.copyFrom(fplayPos);
				toplevel.stopFp();
				return;
			}
			// song is playing but plain F1 pressed; restart
		}
		int m1, m2, m3;
		m1 = seqPos.pos[0].mark;
		m2 = seqPos.pos[1].mark;
		m3 = seqPos.pos[2].mark;
		stop();
		if(!fromStart) {
			audio.player.start([m1, m2, m3], [0, 0, 0]);
			if(key.mods & KMOD_SHIFT) {
				toplevel.startFp();
			}
			toplevel.startPlayback(Jump.toMark);
		}
		else {
			audio.player.start();
			if(key.mods & KMOD_SHIFT) {
				toplevel.startFp(Jump.toBeginning);
			}
			toplevel.startPlayback(Jump.toBeginning);
		}
	}

	int keypress(Keyinfo key) {

		/+ old buggy coldstart code
		if(key.mods & KMOD_ALT && key.mods & KMOD_CTRL && key.raw == SDLK_KP0) {
			if(++restartcounter > 1) {
				song = new Song();
				toplevel.sequencer.reset();
				refresh();
				clearcounter = 0;
				UI.statusline.display("Editor restarted.");
				savedialog.setFilename("");
				// TODO: find out why tracklist is not erased
				filename = "";
			}
			else {
				UI.statusline.display("Press again to confirm editor cold start...");
				tickcounter3 = 0;
			}
			return OK;
		}
		else+/
		bool skip_imm_keypress = false; //workaround for F11 - crapchars in savedialog

		// The top-bar menu, when focused, gets every key first (it is not a
		// dialog, so it never goes through the dialog/closeDialog path — a menu
		// item callback may itself open a dialog and must not be torn down).
		if(menubar.active) {
			menubar.keypress(key);
			return OK;
		}
		// Esc opens the menu bar (it no longer quits; quit is File > Quit). Not
		// while a dialog is up, and not while editing the song-info fields.
		if(!dialog && key.raw == SDLK_ESCAPE && key.mods == 0
		   && activeWindow != infobar) {
			menubar.openMenu();
			return OK;
		}

		// Check if shortcut manager handles this keypress
		// But only if there's no active input field or dialog that needs to handle it first
		if(!dialog) { // if(activeInput is null && !dialog) {
			//auto sm = getShortcutManager();
			if(sm.handleKeypress(key)) {

				// Shortcut was handled
				// Special case: F11 saves dialog needs skip_imm_keypress
				if(key.raw == SDLK_F11 && key.mods == 0) {
					skip_imm_keypress = true;
				}
				else {
					return OK;
				}
			}
		}
		
		// Handle Alt+key shortcuts that might not be in shortcut manager
		// (context-dependent or special cases)
		if(key.mods & KMOD_ALT && !(key.mods & KMOD_CTRL)) {
			// These are handled by shortcut manager or by toplevel
		}
		
		// Check for active input field or dialog - they get priority
		int r;
		if(dialog && !skip_imm_keypress) {
			if(key.mods & KMOD_ALT) return OK;
			r = dialog.keypress(key);
			if(r != OK) {
				closeDialog();
				return r;
			}
		}
		else {
			// Pass to toplevel which handles window-specific shortcuts
			toplevel.keypress(key);
		}
		return OK;
	}

	int keyrelease(Keyinfo key) {
		toplevel.keyrelease(key);
		return OK;
	}

	void clickedAt(int x, int y, int b, int clicks = 1) {
		if(activeInput !is null && activeInput.cursor !is null)
			activeInput.cursor.clear();
		// The menu bar owns row 0, and the whole screen while it is focused.
		if(menubar.active || (!dialog && y == 0)) {
			menubar.clickedAt(x, y, b, clicks);
			return;
		}
		if(dialog)
			dialog.clickedAt(x, y, b, clicks);
		else toplevel.clickedAt(x, y, b, clicks);
	}

	private void saveCallback(string s) {
		try {
			song.save(s);
		}
		catch(FileException e) {
			stderr.writeln(e.toString);
			statusline.display("Could not save file! Check your filename.");
			return;
		}

		string fn = s.strip();
		auto ind = 1 + fn.lastIndexOf(DIR_SEPARATOR);
		fn = fn[ind..$];
		state.filename = fn;

		// sync load filesel to save filesel
		if(loaddialog.directory != savedialog.directory) {
			foreach(d; [loaddialog, savedialog]) {
				d.setFilename(fn);
				d.setDirectory(getcwd());
			}
			loaddialog.fsel.fpos.reset();
		}
	}

	// Propose a .prg filename from the current .ct(2) file (or a default).
	private string proposePrgName() {
		string fn = state.filename.strip();
		if(fn.length == 0) return "song.prg";
		auto dot = fn.lastIndexOf('.');
		if(dot > 0) fn = fn[0 .. dot];
		return fn ~ ".prg";
	}

	private void savePrgCallback(string s) {
		try {
			ubyte[] prg = ct.build.buildResidentImage(song, audio.player.ntsc != 0, true); // standalone: auto-play
			std.file.write(s, prg);
		}
		catch(Exception e) {
			stderr.writeln(e.toString);
			statusline.display("Could not write .prg! " ~ e.msg);
			return;
		}
		string fn = s.strip();
		auto ind = 1 + fn.lastIndexOf(DIR_SEPARATOR);
		statusline.display(format("Saved playable \"%s\".", fn[ind .. $]));
	}

	void importCallback(string s) {
		loadCallback(s, true);
	}

	void loadCallback(string s) {
		loadCallback(s, false);
	}

	private void loadCallback(string s, bool doImport) {
		stop();

		if(std.file.exists(s) == 0 || std.file.isDir(s)) {
			statusline.display("File not found or not accessible: " ~ s);
			return;
		}
		try {
			if(!doImport)
				song.open(s);
			else {
				Song insong = new Song();
				insong.open(s);
				song.importData(insong);
			}
		}
		catch(Exception e) {
			statusline.display("Error: " ~ e.toString);
			return;
		}

		// A new song image means the resident remote-backend copy is stale.
		if(audio.remote.isActive())
			audio.remote.markReload();

		refresh();
		// all voices ON
		audio.player.setVoicon(0,0,0);

		string fn = s.strip();
		auto ind = 1 + fn.lastIndexOf(DIR_SEPARATOR);
		fn = fn[ind .. $];
		state.filename = fn;
		infobar.refresh();

		// sync save filesel to load filesel in case dir was changed
		// (prgdialog too, so the .prg is offered in the loaded .ct's dir)
		foreach(d; [loaddialog, savedialog, prgdialog]) {
			d.setFilename(fn);
			d.setDirectory(getcwd());
		}
		savedialog.fsel.fpos = loaddialog.fsel.fpos;

		// set variables
		audio.player.setSidModel(song.sidModel);
		audio.player.setFP(song.fppres);
		audio.player.setMultiplier(song.multiplier);

		enableKeyjamMode(false);

		toplevel.reset();

		if(doImport) {
			statusline.display("Song data imported.");
		}

		import com.session;
		com.session.state.undoQueue.clear();
		com.session.state.redoQueue.clear();
	}

	void activateDialog(Window d) {
		enableKeyjamMode(false);
		closeDialog();
		dialog = d;
		d.activate();
	}

	void closeDialog() {
		if(dialog) dialog.deactivate();
		dialog = null;
		refresh();
	}

	void enableKeyjamMode(bool doEnable) {
		if(audio.player.isPlaying) return;
/+		doEnable ? com.fb.disableKeyRepeat() :
			com.fb.enableKeyRepeat();+/
		state.keyjamStatus = doEnable;
	}

	void activateInstrumentTable(int ins) {
		UI.activateInstrument(ins);
		// just hacking away.....
		toplevel.activateWindow(2);
		toplevel.keypress(Keyinfo(SDLK_i, KMOD_ALT, 0));
	}

	static void stop() {
		stop(true);
	}

	static void stop(bool doStop) {
		if(doStop) {
			audio.player.stop();
		}
		infobar.update();
		toplevel.stopPlayback();
	}

	static void refresh() {
		screen.clrscr();
		toplevel.refresh();
		UI.statusline.update();
	}

	static void activateInstrument(int ins) {
		toplevel.activateInstrument(ins);
	}
}
