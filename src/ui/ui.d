/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
*/

module ui.ui;
import derelict.sdl2.sdl;
import std.conv;
import main;
import ct.base;
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
import seq.sequencer;
import audio.audio;
import std.string;
import std.file;
import std.stdio;
import audio.audio, audio.timer, audio.callback;

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

	this(Rectangle a) {
		this(a, ui.help.HELPMAIN);
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

protected:

	@property void contextHelp(ContextHelp h) { help = h; }
	@property ContextHelp contextHelp() { return help; }

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

	override void clickedAt(int scrx, int scry, int button, int clicks = 1) {
		//	activateAt(scrx - activeWindow.area.x, scry - activeWindow.area.y);
	}
}

class Infobar : Window, Undoable {
	private {
		const int x1, x2;
		int idx;
	}
	InputString inputTitle, inputAuthor, inputReleased;

	this(Rectangle a) {
		super(a);
		x1 = area.x;
		x2 = x1 + (com.fb.mode > 0 ? 64 : 48);
	}

	override void update() {
		int headerColor = state.keyjamStatus ? 14 : 12;
		if(escapecounter) headerColor = 7;

		screen.clrtoeol(0, headerColor);

		enum hdr = "CheeseCutter 2.9" ~ com.util.versionInfo;
		screen.cprint(4, 0, 1, headerColor, hdr);
		screen.cprint(screen.width - 14, 0, 1, headerColor, "F12 = Help");
		int c1 = audio.player.isPlaying ? 13 : 12;
		screen.fprint(x1,area.y,format("`05Time: `0%x%02d:%02d / $%02x",
									   c1,audio.timer.min, audio.timer.sec,
									   audio.callback.linesPerFrame & 255));

		screen.fprint(x1 + 19,area.y,
				   format("`05Oct: `0d%d  `05Spd: `0d%X  `05St: `0d%d ",
						  state.octave, song.speed, seq.sequencer.stepValue));
		screen.fprint(x2+3, area.y+1,
				   format("`05Rate: `0d%-1d*%dhz  `05SID: `0d%s%s    ",
						  song.multiplier, audio.player.ntsc ? 60 : 50,
						  audio.player.usefp ? audio.player.curfp.id : audio.player.sidtype ? "8580" : "6581",
						  audio.player.badline ? "&0fb" : " "));
		screen.fprint(x1,area.y+1,format("`05Filename: `0d%s", state.filename.leftJustify(38)));
		//screen.fprint(x2,area.y,format("`05  `b1T`01itle: `0d%-32s", std.string.toString(cast(char *)song.title)));
		screen.fprint(x2,area.y,
					  format("`05%s `0d%-32s", (["  `b1T`01itle:", " `01Author:", "`01Release:" ])[idx],
							 song.title));
		screen.fprint(x2,area.y+2,format("`05 Player: `0d%s", ztos(song.playerID)));
	}

	override void refresh() {
		inputTitle = new InputString(cast(string)(song.title), cast(int)(song.title.length));
		inputReleased = new InputString(cast(string)(song.release), cast(int)( song.release.length));
		inputAuthor = new InputString(cast(string)(song.author), cast(int)(song.author.length));
		input = ([ inputTitle, inputAuthor, inputReleased ])[idx];
		input.setCoord(x2 + 9,area.y);
	}

	override void activate() {
		idx = 0;
		refresh();
	}

	override void deactivate() {
		outputStrings();
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
			if(com.fb.mode == 0) {
				ca = Rectangle(tx - 6, zone1y, zone1h, 6);
			}
			else ca = Rectangle(tx, zone2y, zone2h, 6);
			chordtable = new ChordTable(ca);
			bottomSwitcherW = tx + com.fb.border + 10;
			bottomWindows = [cast(Window)wavetable, pulsetable, filtertable,
							 cmdtable, chordtable];
			bottomHotkeys = "wpfmd";
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
			int x2 = x1 + (com.fb.mode > 0 ? 64 : 48);
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
				Hotspot(Rectangle(x2 + 3, y1, 1, 30), (int b){
						ui.activateDialog(UI.infobar);
					}),
				Hotspot(Rectangle(x2 + 18, y1 + 1, 1, 10), (int b){
						b > 1 ? audio.player.toggleSIDModel() : audio.player.nextFP();
					}),
				Hotspot(Rectangle(x2 + 3, y1 + 1, 1, 14), (int b) {
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

		if(key.mods & KMOD_ALT) {
			switch(key.raw)
			{
			case SDLK_v:
				activateWindow(0);
				break;
			case SDLK_1:
				if(!(key.mods & KMOD_CTRL)) {
					activateWindow(0);
					sequencer.activateVoice(0);
				}
				break;
			case SDLK_2:
				if(!(key.mods & KMOD_CTRL)) {
					activateWindow(0);
					sequencer.activateVoice(1);
				}
				break;
			case SDLK_3:
				if(!(key.mods & KMOD_CTRL)) {
					activateWindow(0);
					sequencer.activateVoice(2);
				}
				break;
			case SDLK_4:
			case SDLK_i:
				activateWindow(1);
				break;
			case SDLK_5, SDLK_w:
				activateWindow(2);
				key.key = SDLK_w;
				activeWindow.keypress(key);
				return OK;
			case SDLK_6, SDLK_p:
				activateWindow(2);
				key.key = SDLK_p;
				activeWindow.keypress(key);
				return OK;
			case SDLK_7, SDLK_f:
				activateWindow(2);
				key.key = SDLK_f;
				activeWindow.keypress(key);
				return OK;
			case SDLK_8, SDLK_m:
				activateWindow(2);
				key.key = SDLK_m;
				activeWindow.keypress(key);
				return OK;
			case SDLK_9, SDLK_d:
				activateWindow(2);
				key.key = SDLK_d;
				activeWindow.keypress(key);
				return OK;
			case SDLK_t:
				ui.activateDialog(UI.infobar);
				return OK;
			case SDLK_KP_0:
				clearSeqs();
				return OK;
			case SDLK_KP_PERIOD:
				optimizeSong();
				return OK;
			case SDLK_o:
				if(key.mods & KMOD_CTRL) {
					optimizeSong();
					return OK;
				}
				break;
			case SDLK_n:
				if(key.mods & KMOD_CTRL) {
					return OK;
				}
				break;
			case SDLK_c:
				if(key.mods & KMOD_CTRL) {
					clearSeqs();
					return OK;
				}
				break;
			case SDLK_h:
				state.displayHelp ^= 1;
				UI.statusline.display("Help texts " ~ (state.displayHelp ? "enabled." : "disabled."));
				break;
			default:
				break;
			}
		}
		else if(key.mods & KMOD_CTRL) {
			switch(key.raw)
			{
			 case SDLK_PLUS:
			 case SDLK_KP_PLUS:
				 song.speed = clamp(song.speed + 1, 0, 31);
				 break;
			 case SDLK_MINUS:
			 case SDLK_KP_MINUS:
				 song.speed = clamp(song.speed - 1, 0, 31);
				 break;
			case SDLK_TAB:
				key.mods & KMOD_SHIFT ? activeWindowNum-- : activeWindowNum++ ;
				if(activeWindowNum < 0) activeWindowNum = cast(int)( windows.length - 1);
				if(activeWindowNum >= windows.length)
					activeWindowNum %= windows.length;
				activateWindow();
				return OK;
			case SDLK_z:
				com.session.executeUndo();
				return OK;
			case SDLK_r:
				com.session.executeRedo();
				refresh();
				return OK;
			default:
				break;
			}
		}
		else if(!key.mods & KMOD_SHIFT) {
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
		int vismode;
		AboutDialog aboutdialog;
		FileSelectorDialog loaddialog, savedialog;
	}
	static Statusline statusline;
	static Infobar infobar;
	static Toplevel toplevel;
	bool exitRequested = false;
	ShortcutManager sm = new ShortcutManager();
	
	this() {
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

		int aboutdlg_width = screen.width - 18;
		int aboutdlg_height = 12;
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
		activateDialog(aboutdialog);
		
		// Initialize and register keyboard shortcuts
		registerShortcuts();
		
		update();
	}
	
	/**
	 * Register all keyboard shortcut actions and load default bindings
	 */
	private void registerShortcuts() {		
		// Application Control
		sm.registerAction("exit_app", {
			if(dialog || activeWindow == infobar)
				return;
			if(++escapecounter > 1) {
				activateDialog(new ConfirmationDialog("Really exit (y/n)? ", (int param) {
					if(param != 0) return;
					audio.player.stop();
					exitRequested = true;
				}));
			}
			tickcounter3 = 0;
		});
		
		sm.registerAction("toggle_fullscreen", {
			video.toggleFullscreen();
		});
		
		sm.registerAction("help_dialog", {
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
		
		sm.registerAction("screenshot", {
			// Handled in main.d before translation
			// This action registered for consistency but won't be triggered here
		});
		
		// File Operations
		sm.registerAction("load_file", {
			activateDialog(loaddialog);
		});
		
		sm.registerAction("save_file", {
			activateDialog(savedialog);
		});
		
		sm.registerAction("quick_save", {
			string s = savedialog.filename;
			if(s == "")
				statusline.display("Cannot Quicksave; give filename first by doing a regular save.");
			else {
				saveCallback(s);
				statusline.display(format("Saved \"%s\".",s));
			}
		});
		
		// Undo/Redo
		sm.registerAction("undo", {
			com.session.executeUndo();
		});
		
		sm.registerAction("redo", {
			com.session.executeRedo();
			refresh();
		});
		
		// Playback Controls
		sm.registerAction("play_from_mark", {
			F1orF2(Keyinfo(0, 0, 0), false);
		});
		
		sm.registerAction("play_from_mark_follow", {
			F1orF2(Keyinfo(0, KMOD_SHIFT, 0), false);
		});
		
		sm.registerAction("play_from_beginning", {
			F1orF2(Keyinfo(0, 0, 0), true);
		});
		
		sm.registerAction("play_from_beginning_follow", {
			F1orF2(Keyinfo(0, KMOD_SHIFT, 0), true);
		});
		
		sm.registerAction("play_from_cursor", {
			toplevel.playFromCursor();
		});
		
		sm.registerAction("stop_playback", {
			if(toplevel.fplayEnabled())
				seqPos.copyFrom(fplayPos);
			stop();
			if(toplevel.fplayEnabled())
				toplevel.stopFp();
		});

		sm.registerAction("toggle_follow_mode", {
			toggleFollowMode();
		});

		sm.registerAction("toggle_follow_mode_alt", {
			toggleFollowMode();
		});
		
		sm.registerAction("fast_forward_5", {
			audio.player.fastForward(5);
		});
		
		sm.registerAction("fast_forward_25", {
			audio.player.fastForward(25);
		});
		
		// Playback Options
		sm.registerAction("next_filter_preset", {
			audio.player.nextFP();
		});
		
		sm.registerAction("prev_filter_preset", {
			audio.player.prevFP();
		});
		
		sm.registerAction("toggle_interpolation", {
			audio.player.interpolate ^= 1;
			audio.player.init();
		});
		
		sm.registerAction("toggle_sid_model", {
			song.sidModel ^= 1;
			audio.player.setSidModel(song.sidModel);
		});
		
		sm.registerAction("cycle_visualization", {
			vismode = umod(vismode + 1, 0, VisMode.max);
			screen.clrtoeol(55, 1, 0);
			screen.clrtoeol(55, 2, 0);
			screen.clrtoeol(55, 3, 0);
			video.clearVisualizer();
		});
		
		sm.registerAction("dump_frame", {
			audio.player.dumpFrame();
		});
		
		// Voice Control
		sm.registerAction("toggle_voice_1", {
			audio.player.toggleVoice(0);
		});
		
		sm.registerAction("toggle_voice_2", {
			audio.player.toggleVoice(1);
		});
		
		sm.registerAction("toggle_voice_3", {
			audio.player.toggleVoice(2);
		});
		
		// Window Navigation
		sm.registerAction("next_window", {
			// This is handled in Toplevel, will need special handling
		});
		
		sm.registerAction("prev_window", {
			// This is handled in Toplevel, will need special handling
		});
		
		sm.registerAction("cycle_window", {
			toplevel.activeWindowNum++;
			if(toplevel.activeWindowNum >= toplevel.windows.length)
				toplevel.activeWindowNum %= toplevel.windows.length;
			toplevel.activateWindow();
		});
		
		sm.registerAction("cycle_window_reverse", {
			toplevel.activeWindowNum--;
			if(toplevel.activeWindowNum < 0) toplevel.activeWindowNum = cast(int)(toplevel.windows.length - 1);
			toplevel.activateWindow();
		});
		
		// Direct Window Access
		sm.registerAction("window_voice1", {
			toplevel.activateWindow(0);
			toplevel.sequencer.activateVoice(0);
		});
		
		sm.registerAction("window_voice2", {
			toplevel.activateWindow(0);
			toplevel.sequencer.activateVoice(1);
		});
		
		sm.registerAction("window_voice3", {
			toplevel.activateWindow(0);
			toplevel.sequencer.activateVoice(2);
		});
		
		sm.registerAction("window_sequence", {
			toplevel.activateWindow(0);
		});
		
		sm.registerAction("window_instrument", {
			toplevel.activateWindow(1);
		});
		
		sm.registerAction("window_instrument_alt", {
			toplevel.activateWindow(1);
		});
		
		sm.registerAction("window_wave", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_w, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_wave_alt", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_w, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_pulse", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_p, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_pulse_alt", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_p, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_filter", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_f, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_filter_alt", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_f, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_command", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_m, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_command_alt", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_m, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_chord", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_d, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_chord_alt", {
			toplevel.activateWindow(2);
			auto key = Keyinfo(SDLK_d, 0, 0);
			toplevel.activeWindow.keypress(key);
		});
		
		sm.registerAction("window_song_info", {
			toplevel.activateInfobar();
		});
		
		// Song Settings
		sm.registerAction("increase_speed", {
			song.speed = clamp(song.speed + 1, 0, 31);
		});
		
		sm.registerAction("increase_speed_kp", {
			song.speed = clamp(song.speed + 1, 0, 31);
		});
		
		sm.registerAction("decrease_speed", {
			song.speed = clamp(song.speed - 1, 0, 31);
		});
		
		sm.registerAction("decrease_speed_kp", {
			song.speed = clamp(song.speed - 1, 0, 31);
		});
		
		sm.registerAction("increase_multiplier_alt", {
			audio.player.setMultiplier(song.multiplier + 1);
		});
		
		sm.registerAction("decrease_multiplier_alt", {
			audio.player.setMultiplier(song.multiplier - 1);
		});
		
		// Keyjam Mode
		sm.registerAction("toggle_keyjam", {
			if(song.ver < 7) return;
			state.keyjamStatus ^= 1;
			enableKeyjamMode(state.keyjamStatus);
			statusline.display("Keyjam " ~ (state.keyjamStatus ? "enabled." : "disabled.")
							   ~ " Press Ctrl-Space to toggle.");
		});
		
		// Song Management
		sm.registerAction("clear_sequences", {
			toplevel.clearSeqs();
		});
		
		sm.registerAction("clear_sequences_ctrl", {
			toplevel.clearSeqs();
		});
		
		sm.registerAction("optimize_song", {
			toplevel.optimizeSong();
		});
		
		sm.registerAction("optimize_song_ctrl", {
			toplevel.optimizeSong();
		});
		
		// Help
		sm.registerAction("toggle_help_text", {
			state.displayHelp ^= 1;
			UI.statusline.display("Help texts " ~ (state.displayHelp ? "enabled." : "disabled."));
		});
		
		// Dialogs
		sm.registerAction("about_dialog", {
			activateDialog(aboutdialog);
		});
		
		// Load default bindings
		sm.loadDefaultBindings();
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
		Exception e = audio.callback.getException();
		if(e !is null) {
			writeln("error" ~ e.toString());
			audio.player.stop();
			statusline.display(e.toString());
		}
		if((tickcounter3 >= 0) && ++tickcounter3 > 20) {
			clearcounter = optimizecounter = escapecounter = restartcounter = 0;
			infobar.update();
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
		if(dialog)
			dialog.update();
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

		refresh();
		// all voices ON
		audio.player.setVoicon(0,0,0);

		string fn = s.strip();
		auto ind = 1 + fn.lastIndexOf(DIR_SEPARATOR);
		fn = fn[ind .. $];
		state.filename = fn;
		infobar.refresh();

		// sync save filesel to load filesel in case dir was changed
		foreach(d; [loaddialog, savedialog]) {
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
