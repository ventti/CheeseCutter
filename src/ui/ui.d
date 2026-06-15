/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

UI facade — owns the main UI object and visualizer mode, and re-exports the window/bar modules.
*/

module ui.ui;

// Façade re-exports so the existing `import ui.ui;` users keep seeing the
// window / status-bar / toplevel types after the split.
public import ui.window;
public import ui.statusbar;
public import ui.toplevel;
import ui.keymap;

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
static import audio.render;
import ui.tables;
import ui.dialogs;
import seq.fplay;
import com.fb;
import com.util;
import com.shortcuts;
import ui.shorthelp;
import ui.menubar;
import ui.palette;
import seq.sequencer;
import audio.audio;
import std.string;
import std.file;
import std.stdio;
import audio.audio, audio.timer, audio.callback;
static import audio.remote;

package enum PAGESTEP = 16;
package enum CONFIRM_TIMEOUT = 90;
package enum UPDATE_RATE = 2; // 50 / n times per second

package int tickcounter1;

enum VisMode { None, Regs, Oscilloscope }

final class UI {
	private {
		Window dialog = null;
		//bool printSIDDump = false;
	}
	// Widened to package so the ui.keymap free functions (split out of UI) can
	// reach the dialogs / vismode the shortcut callbacks drive.
	package {
		int vismode = VisMode.Regs;
		AboutDialog aboutdialog;
		FileSelectorDialog loaddialog, savedialog, exportsavedialog;
		ExportOptionsDialog exportDialog, renderDialog;
		ExportOptions exportOpts;
	}
	enum SPLASH_DURATION_MS = 2500;
	static Statusline statusline;
	static Infobar infobar;
	static Toplevel toplevel;
	MenuBar menubar;
	CommandPalette palette;
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
		exportsavedialog = new SaveFileDialog(Rectangle(dialog_x, dialog_y, dialog_height,
												  dialog_width), &saveExportCallback, "Export song");
		exportDialog = new ExportOptionsDialog(&exportConfirm, false);
		renderDialog = new ExportOptionsDialog(&exportConfirm, true);

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

		// Initialize and register keyboard shortcuts (now free functions in
		// ui.keymap; registerShortcuts also runs the context and menu-label
		// passes, mirroring the previous in-class ordering).
		ui.keymap.registerShortcuts(this);
		// Seed the active context from the initially active window (mainui is not
		// assigned yet during construction, so the WindowSwitcher push is skipped).
		sm.setActiveContext(toplevel.contextId);
		// Generate the F12 help pages from the now-populated registry.
		ui.help.HELPMAIN = genMainHelp(sm);
		ui.help.HELPSEQUENCER = genSequencerHelp(sm);

		// Build the top-bar menu (also from the now-populated registry); its ctor
		// asserts every global command category is reachable from a menu.
		menubar = new MenuBar(sm);
		palette = new CommandPalette(this, sm);

		// Pop the splash on startup; it auto-dismisses after SPLASH_DURATION_MS
		// (see timerEvent) and any key also clears it.
		activateDialog(aboutdialog);
		splashDeadlineMs = SDL_GetTicks() + SPLASH_DURATION_MS;

		update();
	}
	
	package void toggleFollowMode() {
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

	// True while a free-text field (InputString) is focused — the song-info
	// Title/Author/Release bar and the instrument description. Every printable
	// key (including ones that share a keycode with a shortcut, e.g. '$' = Shift-4)
	// must reach the field, so global shortcuts are suppressed while it is active.
	// Numeric/hex/note inputs are NOT InputString, so shortcuts still work there.
	@property bool textInputActive() {
		return cast(InputString)activeInput !is null;
	}

	// OS-composed text (SDL_TEXTINPUT) routed to the focused text field. Ignored
	// unless a text field is active, so it never disturbs the sequencer/tables.
	void textInput(string s) {
		if(textInputActive)
			activeInput.textInput(s);
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
		statusline.timerEvent();
		// Draw the menu bar on EVERY timer event, not inside the tick-gated
		// block below: tickcounter1 only advances from player frame ticks
		// (audio.timer.readTick()), so while the editor sits idle the gated
		// block never runs. Gated, the dropdown was painted exactly once (by
		// the keypress update); when the statusline timeout then cleared row 2
		// it blacked out the dropdown's focused first row until the next
		// keypress, and the hover tooltip could never appear while idle.
		// Drawing here — right after statusline.timerEvent() and before the
		// frame is presented — repaints any statusline clear in the same
		// cycle and lets the tooltip dwell timer fire on wall clock.
		drawMenu();
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
		if(palette !is null) palette.draw();
	}

	package void F1orF2(Keyinfo key, bool fromStart) {
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

		bool skip_imm_keypress = false; //workaround for F11 - crapchars in savedialog

		// The command palette, when open, gets every key first (like the menu
		// bar, it is an overlay, not a dialog).
		if(palette !is null && palette.active) {
			palette.keypress(key);
			return OK;
		}
		// The top-bar menu, when focused, gets every key first (it is not a
		// dialog, so it never goes through the dialog/closeDialog path — a menu
		// item callback may itself open a dialog and must not be torn down).
		if(menubar.active) {
			// Typing a printable character morphs the menu into the command
			// palette, seeded with that character ("Esc, then type"). Space is
			// excluded: it toggles the focused menu checkbox.
			if(key.unicode > 0x20 && key.unicode < 0x7f
			   && !(key.mods & (KMOD_CTRL | KMOD_ALT | KMOD_GUI))) {
				menubar.close();
				palette.open("" ~ cast(char)key.unicode);
				return OK;
			}
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

		// Check if shortcut manager handles this keypress, but NOT while a free-text
		// field is being edited (the description / song-info fields) — there every
		// printable key must reach the field, not trigger a shortcut.
		if(!dialog && !textInputActive) {
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
		// The palette, while open, owns the whole screen (click outside closes).
		if(palette.active) {
			palette.clickedAt(x, y, b, clicks);
			return;
		}
		// The menu bar owns row 0, and the whole screen while it is focused.
		if(menubar.active || (!dialog && y == 0)) {
			menubar.clickedAt(x, y, b, clicks);
			return;
		}
		if(dialog)
			dialog.clickedAt(x, y, b, clicks);
		else toplevel.clickedAt(x, y, b, clicks);
	}

	// While the menu bar is focused it owns drag + release (the highlight follows
	// the drag; the action fires on release). Otherwise they route to the toplevel
	// (the active window owns the drag); never to a dialog.
	void draggedTo(int x, int y) {
		if(menubar.active) { menubar.draggedTo(x, y); return; }
		if(dialog || palette.active) return;
		toplevel.draggedTo(x, y);
	}

	void releasedAt(int x, int y) {
		if(menubar.active) { menubar.releasedAt(x, y); return; }
		if(dialog || palette.active) return;
		toplevel.releasedAt(x, y);
	}

	// Mouse moved with no button held. Only the focused menu bar reacts: its
	// highlight cursor follows the pointer. Returns true if a redraw is needed.
	bool hoverAt(int x, int y) {
		if(!menubar.active) return false;
		return menubar.hoverAt(x, y, false);
	}

	package void saveCallback(string s) {
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
		state.songModified = false;

		// sync load filesel to save filesel
		if(loaddialog.directory != savedialog.directory) {
			foreach(d; [loaddialog, savedialog]) {
				d.setFilename(fn);
				d.setDirectory(getcwd());
			}
			loaddialog.fsel.fpos.reset();
		}
	}

	// Propose an export filename from the current .ct(2) file (or a default).
	package string proposeExportName(string ext) {
		string fn = state.filename.strip();
		if(fn.length == 0) return "song" ~ ext;
		auto dot = fn.lastIndexOf('.');
		if(dot > 0) fn = fn[0 .. dot];
		return fn ~ ext;
	}

	// Step 1 of "Export song": the options dialog confirmed; stash the options and
	// open the save-file dialog (the same one used for saving a song), proposing
	// the right extension for the chosen format.
	private void exportConfirm(ExportOptions o) {
		exportOpts = o;
		string ext;
		final switch(o.format) {
		case ExportFormat.Psid:         ext = ".sid"; break;
		case ExportFormat.Wav:          ext = ".wav"; break;
		case ExportFormat.Flac:         ext = ".flac"; break;
		case ExportFormat.FullPrg:
		case ExportFormat.OptimizedPrg: ext = ".prg"; break;
		}
		exportsavedialog.setDirectory(getcwd());
		exportsavedialog.setFilename(proposeExportName(ext));
		activateDialog(exportsavedialog);
	}

	// Step 2: build and write the export using the stashed options + format. Data
	// formats go through ct.build; audio formats are rendered offline by the audio
	// engine (ct.build has no audio dependency) and written via audio.render.
	private void saveExportCallback(string s) {
		try {
			if(isAudioFormat(exportOpts.format)) {
				stop();   // the render takes over the audio engine
				statusline.display("Rendering audio...");
				short[] pcm = audio.player.renderPcm(exportOpts.singleSubtune,
													 exportOpts.durationSec, exportOpts.wavSampleRate);
				audio.render.writeAudioFile(s, pcm, exportOpts);
			}
			else {
				ubyte[] data = ct.build.exportSong(song, audio.player.ntsc != 0, exportOpts);
				std.file.write(s, data);
			}
		}
		catch(Exception e) {
			stderr.writeln(e.toString);
			statusline.display("Could not write export! " ~ e.msg);
			return;
		}
		string fn = s.strip();
		auto ind = 1 + fn.lastIndexOf(DIR_SEPARATOR);
		statusline.display(format("Exported \"%s\".", fn[ind .. $]));
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
		// (exportsavedialog too, so the export is offered in the loaded .ct's dir)
		foreach(d; [loaddialog, savedialog, exportsavedialog]) {
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
		// A plain load matches the file on disk; an import alters the current
		// song without touching its file.
		com.session.state.songModified = doImport;
	}

	// Start a fresh, empty project. Round-trips a blank Song through the normal
	// load path so every view and dialog rebinds exactly as for a file load
	// (replacing the global `song` reference would leave the voices bound to the
	// old data), then drops the temp file and presents it as an unnamed,
	// unmodified song.
	package void newSong() {
		import std.path : buildPath;
		string tmp = buildPath(tempDir(), "cc-new.ct");
		try {
			(new Song()).save(tmp);
		}
		catch(Exception e) {
			statusline.display("Could not start a new song: " ~ e.msg);
			return;
		}
		loadCallback(tmp);
		try { std.file.remove(tmp); } catch(Exception e) {}
		state.filename = "";
		foreach(d; [loaddialog, savedialog, exportsavedialog])
			d.setFilename("");
		statusline.display("New song.");
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
