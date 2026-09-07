/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Top-level editor screen composing the sequencer, editor tables and bars (Toplevel).
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
import ui.soundedit;
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
	// Visual Sound Editor screen (P1). It swaps in over the whole editor like
	// startFp() swaps the sequencer for fplay; `windows` and the active-window
	// index are saved on entry and restored on exit.
	SoundEditor soundEditor;
	bool soundEditorActive;
	private Window[] savedWindows;
	private int savedActiveWindowNum;
	private bool prevKeyjamStatus;

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
			screen.width >= sequencerContentWidth + filterTrackWidth + com.fb.border +
							minInsWidth + adjacentFixedWidth;

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
			// Reserve a read-only filter-track column to the right of voice 3,
			// inside the sequencer area; the instrument table starts after it.
			int seqContentX = sequencerContentWidth + filterTrackWidth;
			int tableX = seqContentX + com.fb.border;
			insWidth = screen.width - tableX - adjacentFixedWidth;
			if(insWidth > preferredInsWidth) insWidth = preferredInsWidth;
			sequencer = new Sequencer(Rectangle(zone1x, zone1y, screen.height - 10,
												seqContentX - zone1x));
			fplay = new Fplay(Rectangle(zone1x, zone1y, screen.height - 10,
										seqContentX - zone1x));

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
			// In wide mode the bottom tables (incl. chord) all sit below the
			// instrument table, so the top-right is free: give the description
			// column the full remaining width (capped at the 32-char label)
			// instead of a fixed 12 chars. In compact mode the chord table is
			// placed at the top-right, so leave insWidth at its default there.
			if(com.fb.mode > 0) {
				int insAvail = screen.width - zone2x - com.fb.border;
				insWidth = insAvail < preferredInsWidth ? insAvail : preferredInsWidth;
				if(insWidth < 3 + 8 * 3 + 12) insWidth = 3 + 8 * 3 + 12;
			}
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
		// Full-screen Sound Editor, sized to the editor content area (below the
		// menu/status rows, above the info/status footer). Constructed here so
		// `screen` is already available (the classic tables use it above).
		soundEditor = new SoundEditor(Rectangle(1, zone1y,
										  screen.height - zone1y - 5,
										  screen.width - 3));
		refresh();
	}

	override void clickedAt(int x, int y, int b, int clicks = 1) {
		foreach(idx, win; windows) {
			if(win.area.overlaps(x, y)) {
				activateWindow(idx);
				activeWindow.clickedAt(x, y, b, clicks);
			}
		}
		// While the Sound Editor owns the screen it is the ONLY window in `windows`;
		// the classic tracker's bottom tables (bottomTabSwitcher, a direct field NOT
		// in `windows`) and the header hotspots are hidden behind it. They must not
		// receive clicks — otherwise a click over a hidden hex table's saved area
		// still hits it (its full-screen area overlaps), firing showByteDescription
		// ("Byte N: ...") and hotspot actions over the Sound Editor. Same root cause
		// as the §13.1 refresh() leak: these targets weren't gated on soundEditorActive.
		if(soundEditorActive) return;
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
		// The Sound Editor runs its own keyjam AND panel navigation, so when it
		// is the active screen every key goes straight to it instead of the
		// global inputKeyjam (which would swallow navigation while keyjam is on).
		// The song-play/toggle shortcuts (F1..F4, Ctrl-E, ...) never reach here:
		// UI.keypress resolves them via the shortcut registry first.
		if(soundEditorActive) {
			activeWindow.keypress(key);
			return OK;
		}
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
		if(soundEditorActive) {
			return activeWindow.keyrelease(key);
		}
		if(state.keyjamStatus == true) {
			inputKeyjam.keyrelease(key);
		}
		return activeWindow.keyrelease(key);
	}

	override void refresh() {
		// §13.1: while the Sound Editor owns the screen, refresh ONLY it. Do NOT
		// repaint the classic tables (bottomTabSwitcher, a direct field not in
		// `windows`) or any savedWindows — otherwise activateDialog() -> refresh()
		// (e.g. opening F12 help) paints them over the Sound Editor and they bleed
		// through behind the dialog.
		if(soundEditorActive) {
			foreach(t; windows) {
				t.refresh();
				t.update();
			}
			// needed because 'input' might be messed by a subdialog
			activeWindow.activate();
			return;
		}
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

	// Focus the wave table and scroll it to the active instrument's wave-table
	// row. Reachable from the instrument table and player tables (the G key) and
	// the Navigate menu.
	void gotoInstrumentWave() {
		gotoInstrumentTable(7);
	}

	// Bring the sub-table an instrument-pointer column points into to the front
	// (7 = wave, 5 = pulse, 4 = filter) with the cursor on the pointed row /
	// program. The tables are already seeked to the active instrument's pointers
	// by activateInstrument(); this focuses the right one. Used by the wave-jump
	// command and by double-clicking a pointer byte in the instrument table.
	void gotoInstrumentTable(int ptrColumn) {
		activateWindow(2);
		// Alt modifier so the bottom tab-switcher treats this as a tab hotkey.
		int tabKey = ptrColumn == 5 ? SDLK_p : (ptrColumn == 4 ? SDLK_f : SDLK_w);
		activeWindow.keypress(Keyinfo(tabKey, KMOD_ALT, 0));
		if(ptrColumn == 7) wavetable.seekCurWave();
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

	// If a block is selected, play just that block and loop over it: start at the
	// block's top row and jump back there whenever the play head passes the
	// bottom. Returns true if it engaged (a selection was active); false lets the
	// caller fall through to normal playback. `follow` mirrors the Shift-modifier
	// (turn on view tracking).
	bool playSelectionLoop(bool follow) {
		if(!sequencer.hasSelection()) {
			fplay.clearLoop();
			return false;
		}
		Voice[] v = sequencer.getVoices();
		if(v.length < 3) { fplay.clearLoop(); return false; }
		int lo, len;
		sequencer.selectionRegion(lo, len);
		int[3] trk, seq;
		foreach(i; 0 .. 3) {
			RowData rd = v[i].getRowData(0, lo);
			trk[i] = rd.trkOffset;
			seq[i] = rd.seqOffset;
		}
		audio.player.stop();
		audio.player.start(trk.dup, seq.dup);
		if(follow) startFp();
		fplay.setLoop(trk, seq, lo, len);
		return true;
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

	// Enter/leave the visual Sound Editor. Like startFp()/stopFp() this swaps the
	// window set: the whole `windows` array is replaced by the single full-screen
	// SoundEditor and restored on exit. Entering forces keyjam ON so notes play
	// immediately; leaving restores the caller's prior keyjam state and screen.
	void toggleSoundEditor() {
		soundEditorActive ? stopSoundEditor() : startSoundEditor();
	}

	void startSoundEditor() {
		if(soundEditorActive) return;
		soundEditor.beginSession();
		savedWindows = windows;
		savedActiveWindowNum = activeWindowNum;
		prevKeyjamStatus = state.keyjamStatus;
		// v3: treat the Sound Editor as a separate full-screen VIEW. Wipe the whole
		// text grid first so no tracker cells peek through the gaps between the
		// Sound Editor's frame/param column/bands (its content region isn't a solid
		// fill). activateWindow()/refresh() below repaints the Sound Editor clean.
		screen.clrscr();
		windows = [cast(Window)soundEditor];
		soundEditorActive = true;
		activateWindow(0);
		// This window-set swap is not a normal WindowSwitcher tab change.  Push the
		// explicit context as well so Sound Editor command bindings win immediately
		// over the previously active sequencer/subtable shortcuts.
		if(mainui !is null && mainui.sm !is null)
			mainui.sm.setActiveContext(Ctx.soundEditor);
		// Force keyjam ON so the piano keys sound the moment the screen opens, but
		// v2 layout drops the whole-screen dark-blue keyjam tint: keep note routing
		// (keyjamStatus) while forcing the cosmetic background off. The SoundEditor
		// also re-asserts keyjamBackground=false every frame (see its update()).
		state.keyjamStatus = true;
		ui.enableKeyjamMode(true);
		com.fb.keyjamBackground = false;   // v2: no keyjam tint in the Sound Editor
		refresh();                          // repaint without the tint
	}

	void stopSoundEditor() {
		if(!soundEditorActive) return;
		soundEditorActive = false;
		// Drop the Sound Editor's overlay draw-list so its graphs don't linger over
		// the classic editor (overlayActive would otherwise force stale re-renders).
		video.olClear();
		// v3: wipe the text grid so no Sound Editor text (frame/params/raw strip)
		// lingers where the restored tracker doesn't repaint. activateWindow() below
		// calls refresh(), repainting the classic editor over the cleared screen.
		screen.clrscr();
		windows = savedWindows;
		int n = savedActiveWindowNum;
		if(n < 0 || n >= cast(int)windows.length) n = 0;
		// Restore the caller's prior keyjam state and the classic screen.
		// enableKeyjamMode refuses user toggles during playback, but leaving this
		// view must restore routing and tint even while a song/note is playing.
		state.keyjamStatus = prevKeyjamStatus;
		com.fb.keyjamBackground = prevKeyjamStatus;
		ui.enableKeyjamMode(prevKeyjamStatus);
		activateWindow(n);
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
