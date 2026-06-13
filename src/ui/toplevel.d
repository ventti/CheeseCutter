/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
*/

module ui.toplevel;
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
import ui.window;
import ui.statusbar;
import ui.ui;
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

final package class Toplevel : WindowSwitcher, Undoable {
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

	// A drag belongs to the window where it began, i.e. the active window
	// (clickedAt activated it on button-down). Route there directly.
	override void draggedTo(int x, int y) {
		activeWindow.draggedTo(x, y);
	}

	override void releasedAt(int x, int y) {
		activeWindow.releasedAt(x, y);
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
		if(!(key.mods & KMOD_SHIFT)) {
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

	package void stopFp() {
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

	package void optimizeSong() {
		// TODO: VALIDATION HERE BEFORE PURGING... PurgeException should be useless if validate covers all errorcases
		try {
			saveSongState();
			(new Purge(song,true)).purgeAll();
		}
		catch(PurgeException e) {
			UI.statusline.display(e.toString);
			return;
		}
		refresh();
		UI.statusline.display("Song data optimized.");
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

	package void clearSeqs() {
		saveSongState();          // undo point (same snapshot optimize uses)
		song.clearSeqs();
		sequencer.reset();
		refresh();
		UI.statusline.display("Sequence data cleared.");
	}
}
