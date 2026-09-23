/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Registers all editor shortcuts and context bindings into com.shortcuts and applies derived menu labels.
*/

module ui.keymap;
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
import ui.window;
import ui.statusbar;
import ui.toplevel;
import ui.ui;
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

// Platform-specific primary keys; callbacks still dispatch the original editor keys.
version(OSX) {
	private enum homeKey = SDLK_UP;
	private enum endKey = SDLK_DOWN;
	private enum homeEndMods = KMOD_GUI;
	private enum voiceMods = KMOD_GUI;
	private enum fullscreenKey = SDLK_f;
	private enum fullscreenMods = KMOD_CTRL | KMOD_GUI;
	private enum insertKey = SDLK_RETURN;
	private enum insertMods = KMOD_ALT;
	private enum expandKey = SDLK_RETURN;
} else {
	private enum homeKey = SDLK_HOME;
	private enum endKey = SDLK_END;
	private enum homeEndMods = 0;
	private enum voiceMods = KMOD_CTRL;
	private enum fullscreenKey = SDLK_RETURN;
	private enum fullscreenMods = KMOD_ALT;
	private enum insertKey = SDLK_INSERT;
	private enum insertMods = 0;
	private enum expandKey = SDLK_INSERT;
}

/**
 * Register all keyboard shortcut actions, their bindings and metadata.
 * This is the single source of truth for global command shortcuts; help
 * text and doc/KEYBOARD.md are generated from these registrations.
 */
void registerShortcuts(UI ui) {
	with(ui) {
	// Application Control. Ctrl-Q is the standard-editor Quit shortcut; the same
	// item is File ▸ Quit. Its own "Application" category places it in a trailing
	// group of the File menu (separated from the load/save items, Quit last). A
	// confirmation dialog guards against an accidental Ctrl-Q.
	sm.register("exit_app", Ctx.global, "Application",
				"Quit program", SDLK_q, KMOD_CTRL, {
		requestExit();
	}, "Quit");

	sm.register("toggle_fullscreen", Ctx.global, "Display",
				"Toggle fullscreen", fullscreenKey, fullscreenMods, {
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

	// No key binding of its own: pressing Esc focuses the menu bar, and typing
	// any printable character there opens the palette seeded with it.
	sm.register("open_palette", Ctx.global, "Help",
				"Open the command palette: search commands and songs by name or shortcut (also Esc, then type)",
				SDLK_p, KMOD_CTRL, {
		menubar.close();
		palette.open("");
	}, "Command palette");

	sm.register("screenshot", Ctx.global, "Display",
				"Save screenshot", SDLK_F12, KMOD_CTRL, {
		// Handled in main.d before translation
		// This action registered for consistency but won't be triggered here
	});

	// File Operations
	sm.register("new_song", Ctx.global, "File",
				"Clear the song and start a new project", SDLK_n, KMOD_CTRL, {
		if(state.songModified)
			activateDialog(new ConfirmationDialog(
				"Discard unsaved changes and start new (y/n)? ", (int param) {
					if(param != 0) return;
					newSong();
				}));
		else newSong();
	}, "New");

	sm.register("load_file", Ctx.global, "File",
				"Open the Load song dialog", SDLK_F9, 0, {
		activateDialog(loaddialog);
	});
	sm.bindAlias("load_file", SDLK_o, KMOD_CTRL);   // standard Open

	sm.register("save_file", Ctx.global, "File",
				"Open the Save song dialog", SDLK_F10, 0, {
		activateDialog(savedialog);
	});

	sm.register("quick_save", Ctx.global, "File",
				"Quick save song (doesn't ask a filename)", SDLK_F10, KMOD_CTRL, {
		string s = savedialog.filename;
		if(s == "")
			activateDialog(savedialog);   // no name yet: prompt (standard Save behaviour)
		else {
			saveCallback(s);
			statusline.display(format("Saved \"%s\".",s));
		}
	});
	sm.bindAlias("quick_save", SDLK_s, KMOD_CTRL);   // standard Save

	sm.register("import_mod", Ctx.global, "File",
				"Import a ProTracker module (.mod): pick the file, then choose channels and which effects to translate", SDLK_F9, KMOD_SHIFT, {
		activateDialog(modimportdialog);   // keeps its own last directory (separate from .ct)
	}, "Import .mod...");

	sm.register("export_song", Ctx.global, "File",
				"Export song: Full player .prg / Optimized .prg / PSID (options dialog)", SDLK_F10, KMOD_SHIFT, {
		activateDialog(exportDialog);
	});

	sm.register("render_audio", Ctx.global, "File",
				"Render audio: .wav / .flac (duration, normalize, bit depth, rate)", SDLK_F10, KMOD_CTRL | KMOD_SHIFT, {
		activateDialog(renderDialog);
	});

	// Its own "Properties" category isolates it in a divider-separated group
	// between the file commands above and the trailing Quit group.
	sm.registerMenuOnly("properties", Ctx.global, "Properties",
				"Properties: playback backend, reSID SID model & filter preset, Ultimate IP/port, x64sc path, audio driver", {
		activateDialog(propertiesDialog);
	}, "Properties");

	// Undo/Redo
	sm.register("undo", Ctx.global, "Edit", "Undo", SDLK_z, KMOD_CTRL, {
		com.session.executeUndo();
	});

	sm.register("redo", Ctx.global, "Edit", "Redo", SDLK_r, KMOD_CTRL, {
		com.session.executeRedo();
		refresh();
	});
	sm.bindAlias("redo", SDLK_y, KMOD_CTRL);              // standard Redo
	sm.bindAlias("redo", SDLK_z, KMOD_CTRL | KMOD_SHIFT); // standard Redo (Ctrl-Shift-Z)

	// Playback Controls
	sm.register("play_from_mark", Ctx.global, "Playback",
				"Play from playback mark (loops the selected block if one is active)", SDLK_F1, 0, {
		if(!preparePlaybackAudio()) return;
		F1orF2(Keyinfo(0, 0, 0), false);
	});

	sm.register("play_from_mark_follow", Ctx.global, "Playback",
				"Play / resume from mark with tracking", SDLK_F1, KMOD_SHIFT, {
		if(!preparePlaybackAudio()) return;
		F1orF2(Keyinfo(0, KMOD_SHIFT, 0), false);
	});

	sm.register("play_from_beginning", Ctx.global, "Playback",
				"Play from the start (loops the selected block if one is active)", SDLK_F2, 0, {
		if(!preparePlaybackAudio()) return;
		F1orF2(Keyinfo(0, 0, 0), true);
	});

	sm.register("play_from_beginning_follow", Ctx.global, "Playback",
				"Play / resume from the start with tracking", SDLK_F2, KMOD_SHIFT, {
		if(!preparePlaybackAudio()) return;
		F1orF2(Keyinfo(0, KMOD_SHIFT, 0), true);
	});

	sm.register("play_from_cursor", Ctx.global, "Playback",
				"Play from cursor position (loops the selected block if one is active)", SDLK_F3, 0, {
		if(!preparePlaybackAudio()) return;
		if(!toplevel.playSelectionLoop(false))
			toplevel.playFromCursor();
	});

	sm.register("play_from_cursor_follow", Ctx.global, "Playback",
				"Play / resume from cursor with tracking", SDLK_F3, KMOD_SHIFT, {
		if(!preparePlaybackAudio()) return;
		playFromCursorFollow();
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
	});

	sm.register("dump_frame", Ctx.global, "Playback options",
				"Dump current SID register frame", SDLK_F12, KMOD_ALT, {
		audio.player.dumpFrame();
	});

	// Voice Control
	sm.register("toggle_voice_1", Ctx.global, "Voice control",
				"Toggle voice 1 on/off", SDLK_1, voiceMods, {
		audio.player.toggleVoice(0);
	});

	sm.register("toggle_voice_2", Ctx.global, "Voice control",
				"Toggle voice 2 on/off", SDLK_2, voiceMods, {
		audio.player.toggleVoice(1);
	});

	sm.register("toggle_voice_3", Ctx.global, "Voice control",
				"Toggle voice 3 on/off", SDLK_3, voiceMods, {
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

	// The Sequencer's three column/view switches. Registered GLOBALLY (not under
	// Ctx.sequencer) so they show up in the command palette and the Navigate menu
	// from any focus, and work from any window: they focus the Sequencer first,
	// then re-dispatch the F-key so the Sequencer's own handler performs the view
	// change (its F5 track/note toggle behaviour is unchanged when already there).
	sm.register("seq_enter_track_col", Ctx.global, "Window navigation",
				"Enter the sequencer track column (focuses the Sequencer)", SDLK_F5, 0, {
		toplevel.activateWindow(0);
		invokeKey(ui, SDLK_F5, 0);
	});
	sm.register("seq_enter_note_col", Ctx.global, "Window navigation",
				"Enter the sequencer note column (focuses the Sequencer)", SDLK_F6, 0, {
		toplevel.activateWindow(0);
		invokeKey(ui, SDLK_F6, 0);
	});
	sm.register("seq_overview", Ctx.global, "Window navigation",
				"Toggle the sequencer tracklist overview (focuses the Sequencer)", SDLK_F7, 0, {
		toplevel.activateWindow(0);
		invokeKey(ui, SDLK_F7, 0);
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
						   ~ " Press Ctrl-Space or Ctrl-K to toggle.");
	});
	// macOS reserves Ctrl-Space (Input Sources switching), so the OS eats it
	// before the app sees it — Ctrl-K is a portable alternate for the same toggle.
	sm.bindAlias("toggle_keyjam", SDLK_k, KMOD_CTRL);

	// Song Management
	sm.register("clear_sequences", Ctx.global, "Song management",
				"Clear all sequences", SDLK_KP_0, KMOD_ALT, {
		activateDialog(new ConfirmationDialog("Clear all sequence data? (y/N) ",
			(int param) { if(param == 0) toplevel.clearSeqs(); }));
	});
	sm.bindAlias("clear_sequences", SDLK_c, KMOD_CTRL | KMOD_ALT);

	sm.register("optimize_song", Ctx.global, "Song management",
				"Optimize song (clear unused sequences & data)", SDLK_KP_PERIOD, KMOD_ALT, {
		activateDialog(new ConfirmationDialog("Optimize song, removing unused data? (y/N) ",
			(int param) { if(param == 0) toplevel.optimizeSong(); }));
	});
	sm.bindAlias("optimize_song", SDLK_o, KMOD_CTRL | KMOD_ALT);

	// Display
	sm.register("toggle_help_text", Ctx.global, "Display",
				"Toggle help texts", SDLK_h, KMOD_ALT, {
		state.displayHelp ^= 1;
		UI.statusline.display("Help texts " ~ (state.displayHelp ? "enabled." : "disabled."));
	});

	sm.register("toggle_filter_track", Ctx.global, "Display",
				"Toggle the read-only filter track column", SDLK_f, KMOD_CTRL | KMOD_SHIFT, {
		showFilterTrack = !showFilterTrack;
		UI.statusline.display("Filter track " ~ (showFilterTrack ? "shown." : "hidden."));
	});

	sm.register("toggle_oscilloscope", Ctx.global, "Display",
				"Toggle the oscilloscope overlay (combined synthesized audio waveform, live during playback and keyjam)", SDLK_F12, KMOD_SHIFT, {
		toggleScope();
		UI.statusline.display("Oscilloscope " ~ (scopeVisible ? "shown." : "hidden."));
	});
	// Oscilloscope keyjam timebase zoom (only meaningful for a held keyjam note;
	// the live playback mix isn't zoomable). Alt-Up/Down are layout-stable, unlike
	// bracket keys. Alt-Up zooms in (shorter timespan), Alt-Down zooms out (longer).
	void scopeZoom(int dir) {
		if(!scopeVisible) return;
		if(!audio.player.keyjamEnabled()) {
			UI.statusline.display("Oscilloscope zoom applies to a held keyjam note.");
			return;
		}
		scopeWindow.zoom(dir);
		int f = scopeWindow.zoomFactor();
		UI.statusline.display(f <= 1 ? "Keyjam waveform: whole note."
									 : format("Keyjam waveform zoom: %dx.", f));
	}
	sm.register("scope_zoom_in", Ctx.global, "Display",
				"Oscilloscope: zoom in on the recorded keyjam note (shorter window)", SDLK_UP, KMOD_ALT, {
		scopeZoom(+1);
	});
	sm.register("scope_zoom_out", Ctx.global, "Display",
				"Oscilloscope: zoom out toward the whole recorded keyjam note", SDLK_DOWN, KMOD_ALT, {
		scopeZoom(-1);
	});

	// Visual Sound Editor: a full-screen, keyjam-on view of the selected
	// instrument (P1: chrome + keyjam + live output scope). Ctrl-E toggles
	// in/out; the same key resolves here before toplevel.keypress, so it still
	// leaves the screen even while its keyjam is on.
	sm.register("toggle_sound_editor", Ctx.global, "Display",
				"Toggle the visual Sound Editor (live instrument view with keyjam)", SDLK_e, KMOD_CTRL, {
		toplevel.toggleSoundEditor();
		statusline.display("Sound Editor " ~ (toplevel.soundEditorActive ? "opened." : "closed."));
	});

	sm.registerMenuOnly("toggle_note_spelling", Ctx.global, "Display",
				"Display note names with flats (b) instead of sharps (#)", {
		noteSpellingFlats = !noteSpellingFlats;
		UI.statusline.display("Note names: " ~ (noteSpellingFlats ? "flats (b)." : "sharps (#)."));
	}, "Flat note names");

	// Dialogs
	sm.register("about_dialog", Ctx.global, "Help",
				"Show the splash / about screen", SDLK_F11, 0, {
		aboutdialog.withScroller = true; // user-opened About shows the scroller
		activateDialog(aboutdialog);
	});
	// macOS reserves bare F11 (Show Desktop); Alt-S is a Mac-safe alias
	// (Option+letter isn't intercepted, matching the window-nav aliases).
	sm.bindAlias("about_dialog", SDLK_s, KMOD_ALT);

	// Boolean toggles: report current on/off state so menus draw an [x]/[ ]
	// checkbox. (SID model and visualization are A/B / multi-state, not here.)
	sm.setChecked("toggle_voice_1", () => audio.player.muted[0] == 0);
	sm.setChecked("toggle_voice_2", () => audio.player.muted[1] == 0);
	sm.setChecked("toggle_voice_3", () => audio.player.muted[2] == 0);
	sm.setChecked("toggle_interpolation", () => audio.player.interpolate != 0);
	sm.setChecked("toggle_keyjam", () => state.keyjamStatus);
	sm.setChecked("toggle_help_text", () => state.displayHelp);
	sm.setChecked("toggle_fullscreen", () => video.isFullscreen());
	sm.setChecked("toggle_follow_mode", () => toplevel.fplayEnabled());
	sm.setChecked("toggle_filter_track", () => showFilterTrack);
	sm.setChecked("toggle_oscilloscope", () => scopeVisible);
	sm.setChecked("toggle_note_spelling", () => noteSpellingFlats);

	// Context-specific command shortcuts (sequencer, tables, ...)
	registerContextShortcuts(ui);

	// Concise menu labels. The verbose `description` stays for F12 help and
	// KEYBOARD.md; menus use these via ActionDef.label() — still one source.
	// Set after all actions (incl. context) are registered.
	applyMenuLabels(ui);
	}
}

/**
 * Re-dispatches a synthetic keypress through the normal window path
 * (bypassing the shortcut manager, so no recursion). Context-command
 * callbacks use this so the proven per-widget keypress logic remains the
 * single implementation, while the registry is the single place that knows
 * about every command (for help generation and future menus).
 */
private void invokeKey(UI ui, int key, int mods, int unicode = 0) {
	ui.toplevel.keypress(Keyinfo(key, mods, unicode));
}

private ActionCallback invokeKeyAction(UI ui, int key, int mods) {
	return { invokeKey(ui, key, mods); };
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
void registerContextShortcuts(UI ui) {
	alias C = Ctx;
	auto sm = ui.sm;

	void invokeKey(int key, int mods, int unicode = 0) {
		.invokeKey(ui, key, mods, unicode);
	}

	// --- Visual Sound Editor controls (R59) ---
	// Context bindings win over similarly-shaped sequencer/global commands and
	// redispatch straight to SoundEditor.keypress, the same implementation used by
	// the labelled mouse buttons.
	void se(string id, string description, int key, int mods = 0) {
		string actionId = id.dup;
		sm.register(id, C.soundEditor, "Sound Editor controls", description, key, mods,
			invokeKeyAction(ui, key, mods), "", {
				return ui.toplevel.soundEditorActive
					&& ui.toplevel.soundEditor.commandEnabled(actionId);
			});
	}
	se("se_zoom_out", "Zoom out", SDLK_o, KMOD_CTRL | KMOD_SHIFT);
	se("se_zoom_in", "Zoom in", SDLK_i, KMOD_CTRL | KMOD_SHIFT);
	se("se_fit", "Fit the full sound", SDLK_a, KMOD_CTRL | KMOD_SHIFT);
	se("se_selection", "Zoom to the time selection", SDLK_g, KMOD_CTRL | KMOD_SHIFT);
	se("se_add", "Insert the selected programme row", SDLK_j, KMOD_CTRL | KMOD_SHIFT);
	se("se_delete", "Delete the selected programme row", SDLK_d, KMOD_CTRL | KMOD_SHIFT);
	se("se_stop", "Stop the selected programme", SDLK_s, KMOD_CTRL | KMOD_SHIFT);
	se("se_type", "Toggle Filter sweep/config row type", SDLK_t, KMOD_CTRL);
	se("se_carry", "Toggle selected sweep carry value", SDLK_i, KMOD_CTRL);
	se("se_new", "Create a new private sound", SDLK_n, KMOD_CTRL | KMOD_SHIFT);
	se("se_wave_prev", "Select the previous wave row", SDLK_PAGEUP, KMOD_SHIFT);
	se("se_wave_next", "Select the next wave row", SDLK_PAGEDOWN, KMOD_SHIFT);
	se("se_wave_1", "Edit selected wave byte 1", SDLK_1, KMOD_CTRL | KMOD_SHIFT);
	se("se_wave_2", "Edit selected wave byte 2", SDLK_2, KMOD_CTRL | KMOD_SHIFT);
	se("se_wave_loop", "Set the wave loop target", SDLK_l, KMOD_CTRL);
	se("se_res_down", "Decrease Filter resonance", SDLK_3, KMOD_CTRL | KMOD_SHIFT);
	se("se_res_up", "Increase Filter resonance", SDLK_4, KMOD_CTRL | KMOD_SHIFT);
	se("se_lp", "Toggle Filter low-pass", SDLK_l, KMOD_CTRL | KMOD_SHIFT);
	se("se_bp", "Toggle Filter band-pass", SDLK_b, KMOD_CTRL | KMOD_SHIFT);
	se("se_hp", "Toggle Filter high-pass", SDLK_h, KMOD_CTRL | KMOD_SHIFT);
	se("se_route", "Cycle Filter channel route", SDLK_r, KMOD_CTRL | KMOD_SHIFT);
	se("se_linked", "Toggle linked programme edits", SDLK_e, KMOD_CTRL | KMOD_SHIFT);
	se("se_start_down", "Decrease selected sweep start value", SDLK_5, KMOD_CTRL | KMOD_SHIFT);
	se("se_start_up", "Increase selected sweep start value", SDLK_6, KMOD_CTRL | KMOD_SHIFT);
	se("se_end_down", "Decrease selected sweep end value", SDLK_7, KMOD_CTRL | KMOD_SHIFT);
	se("se_end_up", "Increase selected sweep end value", SDLK_8, KMOD_CTRL | KMOD_SHIFT);
	se("se_duration_down", "Decrease selected sweep duration", SDLK_9, KMOD_CTRL | KMOD_SHIFT);
	se("se_duration_up", "Increase selected sweep duration", SDLK_0, KMOD_CTRL | KMOD_SHIFT);
	se("se_octave_down", "Decrease keyjam octave", SDLK_PAGEDOWN, KMOD_CTRL | KMOD_SHIFT);
	se("se_octave_up", "Increase keyjam octave", SDLK_PAGEUP, KMOD_CTRL | KMOD_SHIFT);
	se("se_instrument_prev", "Select previous instrument", SDLK_PAGEUP, KMOD_CTRL);
	se("se_instrument_next", "Select next instrument", SDLK_PAGEDOWN, KMOD_CTRL);
	// Allowed legacy aliases follow the portable primary in generated docs.
	sm.bindAlias("se_fit", homeKey, homeEndMods);
	sm.bindAlias("se_selection", endKey, homeEndMods);
	sm.bindAlias("se_add", SDLK_INSERT, 0);
	sm.bindAlias("se_delete", SDLK_DELETE, 0);
	sm.bindAlias("se_octave_down", SDLK_KP_DIVIDE, 0);
	sm.bindAlias("se_octave_up", SDLK_KP_MULTIPLY, 0);
	sm.bindAlias("se_instrument_prev", SDLK_KP_MINUS, 0);
	sm.bindAlias("se_instrument_next", SDLK_KP_PLUS, 0);
	sm.setCategory("se_new", "Sound");
	sm.setCategory("se_wave_1", "Sound");
	sm.setCategory("se_wave_2", "Sound");
	sm.setMenuLabel("se_new", "New sound");
	sm.setMenuLabel("se_wave_1", "Edit wave byte 1...");
	sm.setMenuLabel("se_wave_2", "Edit wave byte 2...");

	// --- Sequencer (common to note/track/overview columns) ---
	sm.register("seq_song_start", C.sequencer, "Navigation",
				"Move cursor to song start", homeKey, homeEndMods | KMOD_SHIFT,
				{ invokeKey(SDLK_HOME, KMOD_SHIFT); });
	sm.register("seq_song_end", C.sequencer, "Navigation",
				"Move cursor to song end", endKey, homeEndMods | KMOD_SHIFT,
				{ invokeKey(SDLK_END, KMOD_SHIFT); });
	sm.register("seq_jump_mark", C.sequencer, "Navigation",
				"Jump to playback mark (realigns the voices)", homeKey, homeEndMods | KMOD_CTRL,
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
				"Increase row highlight value", SDLK_PERIOD, KMOD_ALT,
				{ invokeKey(SDLK_PERIOD, KMOD_ALT); });
	sm.register("seq_highlight_dec", C.sequencer, "Display",
				"Decrease row highlight value", SDLK_COMMA, KMOD_ALT,
				{ invokeKey(SDLK_COMMA, KMOD_ALT); });
	sm.register("seq_highlight_reset", C.sequencer, "Display",
				"Reset highlighting to current row", SDLK_0, KMOD_ALT,
				{ invokeKey(SDLK_0, KMOD_ALT); });
	sm.register("seq_rowcounter", C.sequencer, "Display",
				"Show/hide row counters for sequences", SDLK_e, KMOD_ALT,
				{ invokeKey(SDLK_e, KMOD_ALT); });
	sm.register("seq_relative_notes", C.sequencer, "Display",
				"Toggle notes relative to current transpose", SDLK_t, KMOD_ALT,
				{ invokeKey(SDLK_t, KMOD_ALT); });

	sm.register("seq_copy", C.sequencer, "Sequence operations",
				"Ask for a sequence number and copy contents over current sequence", SDLK_c, KMOD_ALT,
				{ invokeKey(SDLK_c, KMOD_ALT); });
	sm.register("seq_append", C.sequencer, "Sequence operations",
				"Ask for a sequence number and insert contents to cursor pos", SDLK_n, KMOD_ALT,
				{ invokeKey(SDLK_n, KMOD_ALT); });
	sm.register("seq_prev_subtune", C.sequencer, "Sequence operations",
				"Activate previous subtune", SDLK_LEFT, KMOD_ALT,
				{ invokeKey(SDLK_LEFT, KMOD_ALT); });
	sm.register("seq_next_subtune", C.sequencer, "Sequence operations",
				"Activate next subtune", SDLK_RIGHT, KMOD_ALT,
				{ invokeKey(SDLK_RIGHT, KMOD_ALT); });

	// --- Block selection (note + track columns; resolved via the shared
	// sequencer context). Also drivable by left-drag with the mouse. ---
	sm.register("sel_mark_begin", C.sequencer, "Selection",
				"Mark block selection start at the cursor", SDLK_b, KMOD_CTRL,
				{ invokeKey(SDLK_b, KMOD_CTRL); });
	sm.register("sel_mark_end", C.sequencer, "Selection",
				"Mark block selection end at the cursor", SDLK_b, KMOD_CTRL | KMOD_SHIFT,
				{ invokeKey(SDLK_b, KMOD_CTRL | KMOD_SHIFT); });
	sm.register("sel_clear", C.sequencer, "Selection",
				"Clear the block selection", SDLK_d, KMOD_CTRL,
				{ invokeKey(SDLK_d, KMOD_CTRL); });
	sm.register("sel_copy", C.sequencer, "Selection",
				"Copy the selected block to the clipboard", SDLK_c, KMOD_CTRL,
				{ invokeKey(SDLK_c, KMOD_CTRL); });
	sm.register("sel_cut", C.sequencer, "Selection",
				"Cut the selected block (blank rows, keep length)", SDLK_x, KMOD_CTRL,
				{ invokeKey(SDLK_x, KMOD_CTRL); });
	sm.register("sel_paste", C.sequencer, "Selection",
				"Paste the block over rows from the cursor (overflow dropped)", SDLK_v, KMOD_CTRL,
				{ invokeKey(SDLK_v, KMOD_CTRL); });
	sm.register("sel_merge", C.sequencer, "Selection",
				"Merge the block into empty rows only from the cursor", SDLK_v, KMOD_CTRL | KMOD_SHIFT,
				{ invokeKey(SDLK_v, KMOD_CTRL | KMOD_SHIFT); });
	sm.register("sel_paste_new", C.sequencer, "Selection",
				"Paste the block as new track(s)/sequence(s) at the cursor", SDLK_n, KMOD_CTRL | KMOD_SHIFT,
				{ invokeKey(SDLK_n, KMOD_CTRL | KMOD_SHIFT); });

	// --- Note column (F6) ---
	sm.register("note_play_row", C.noteColumn, "Note column",
				"Play notes for all voices in current row", SDLK_KP_0, 0,
				{ invokeKey(SDLK_KP_0, 0); });
	// Keypad-free alias for keyboards without a numpad.
	sm.bindAlias("note_play_row", SDLK_p, KMOD_CTRL | KMOD_SHIFT);
	sm.register("note_split", C.noteColumn, "Note column",
				"Split current sequence into two from cursor pos", SDLK_p, KMOD_ALT,
				{ invokeKey(SDLK_p, KMOD_ALT); });
	sm.register("note_seq_start", C.noteColumn, "Note column",
				"Move cursor to sequence start (or screen top)", homeKey, homeEndMods,
				{ invokeKey(SDLK_HOME, 0); });
	sm.register("note_seq_end", C.noteColumn, "Note column",
				"Move cursor to sequence end (or screen bottom)", endKey, homeEndMods,
				{ invokeKey(SDLK_END, 0); });
	sm.register("note_expand_quick", C.noteColumn, "Note column",
				"Quick expand sequence (by highlight value * 4)", SDLK_RETURN, KMOD_SHIFT,
				{ invokeKey(SDLK_RETURN, KMOD_SHIFT); });
	sm.register("note_insert_row", C.noteColumn, "Note column",
				"Insert a row (with sequence expand)", insertKey, insertMods | KMOD_SHIFT,
				{ invokeKey(SDLK_INSERT, KMOD_SHIFT); });
	sm.register("note_delete_row", C.noteColumn, "Note column",
				"Delete a row (with sequence shrink)", SDLK_DELETE, KMOD_SHIFT,
				{ invokeKey(SDLK_DELETE, KMOD_SHIFT); });
	sm.register("note_expand", C.noteColumn, "Note column",
				"Expand the sequence", expandKey, KMOD_CTRL,
				{ invokeKey(SDLK_INSERT, KMOD_CTRL); });
	sm.register("note_shrink", C.noteColumn, "Note column",
				"Shrink the sequence", SDLK_DELETE, KMOD_CTRL,
				{ invokeKey(SDLK_DELETE, KMOD_CTRL); });
	sm.register("note_trans_semi_up", C.noteColumn, "Note column",
				"Transpose semitone up", SDLK_q, KMOD_ALT,
				{ invokeKey(SDLK_q, KMOD_ALT); });
	sm.register("note_trans_semi_down", C.noteColumn, "Note column",
				"Transpose semitone down", SDLK_a, KMOD_ALT,
				{ invokeKey(SDLK_a, KMOD_ALT); });
	sm.register("note_trans_oct_up", C.noteColumn, "Note column",
				"Transpose octave up", SDLK_w, KMOD_ALT,
				{ invokeKey(SDLK_w, KMOD_ALT); });
	sm.register("note_trans_oct_down", C.noteColumn, "Note column",
				"Transpose octave down", SDLK_s, KMOD_ALT,
				{ invokeKey(SDLK_s, KMOD_ALT); });
	sm.register("note_grab_instr", C.noteColumn, "Note column",
				"Grab the current row's instrument as the active instrument", SDLK_RETURN, 0,
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

	// --- Track column (F5) and bottom Tracks table ---
	sm.register("trk_make_unique", C.trackColumn, "Track column",
				"Copy selected tracks to the first empty sequences (excluding 00)", SDLK_u, KMOD_CTRL,
				{ invokeKey(SDLK_u, KMOD_CTRL); });
	sm.register("trk_insert", C.trackColumn, "Track column",
				"Insert a track at cursor", insertKey, insertMods,
				{ invokeKey(SDLK_INSERT, 0); });
	sm.register("trk_delete", C.trackColumn, "Track column",
				"Delete track at cursor", SDLK_DELETE, 0,
				{ invokeKey(SDLK_DELETE, 0); });
	sm.register("trk_insert_end", C.trackColumn, "Track column",
				"Insert a track to end of voice and move there", expandKey, KMOD_CTRL,
				{ invokeKey(SDLK_INSERT, KMOD_CTRL); });
	sm.register("trk_delete_end", C.trackColumn, "Track column",
				"Delete track to end of voice and move there", SDLK_DELETE, KMOD_CTRL,
				{ invokeKey(SDLK_DELETE, KMOD_CTRL); });
	sm.register("trk_insert_all", C.trackColumn, "Track column",
				"Insert a track for all voices", expandKey, KMOD_CTRL | KMOD_SHIFT,
				{ invokeKey(SDLK_INSERT, KMOD_CTRL | KMOD_SHIFT); });
	sm.register("trk_delete_all", C.trackColumn, "Track column",
				"Delete a track for all voices", SDLK_DELETE, KMOD_CTRL | KMOD_SHIFT,
				{ invokeKey(SDLK_DELETE, KMOD_CTRL | KMOD_SHIFT); });
	sm.register("trk_trans_up", C.trackColumn, "Track column",
				"Transpose tracks up from cursor down", SDLK_q, KMOD_ALT,
				{ invokeKey(SDLK_q, KMOD_ALT); });
	sm.register("trk_trans_down", C.trackColumn, "Track column",
				"Transpose tracks down from cursor down", SDLK_a, KMOD_ALT,
				{ invokeKey(SDLK_a, KMOD_ALT); });
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

	sm.register("ins_cut_selection", C.instrumentTable, "Selection",
				"Cut selected instrument data rows (blank bytes; keep descriptions)", SDLK_x, KMOD_CTRL,
				{ invokeKey(SDLK_x, KMOD_CTRL); }, "Cut selected rows");

	foreach(verb; ["cut", "copy", "paste"]) {
		int key = verb == "cut" ? SDLK_x : verb == "copy" ? SDLK_c : SDLK_v;
		string description = verb == "cut" ? "Cut selected table rows (blank without shifting)"
			: verb == "copy" ? "Copy selected table rows"
			: "Paste table rows (overwrite selection or from cursor; same table type)";
		sm.register("table_" ~ verb, C.subtable, "Selection", description,
				key, KMOD_CTRL, invokeKeyAction(ui, key, KMOD_CTRL));
	}

	// --- Sub-tables (wave / pulse / filter) ---
	// Reachable via the Navigate menu and the G key on the instrument and player
	// tables (the tables handle G directly; this entry gives it a menu home).
	sm.registerMenuOnly("wave_goto_instr", Ctx.global, "Window navigation",
				"Jump to the active instrument's wave-table row",
				{ ui.toplevel.gotoInstrumentWave(); }, "Go to instr wave");
	sm.register("wave_clear_row", C.subtable, "Tables",
				"Clear current wave row", SDLK_PERIOD, 0,
				{ invokeKey(SDLK_PERIOD, 0, '.'); });
	sm.register("table_row_top", C.subtable, "Tables",
				"Jump to first row", homeKey, homeEndMods | KMOD_SHIFT,
				{ invokeKey(SDLK_HOME, KMOD_SHIFT); });
	sm.register("table_row_bottom", C.subtable, "Tables",
				"Jump to last used row", endKey, homeEndMods | KMOD_SHIFT,
				{ invokeKey(SDLK_END, KMOD_SHIFT); });
	sm.register("table_insert_row", C.subtable, "Tables",
				"Insert a row", insertKey, insertMods,
				{ invokeKey(SDLK_INSERT, 0); });
	sm.register("table_delete_row", C.subtable, "Tables",
				"Delete a row", SDLK_DELETE, 0,
				{ invokeKey(SDLK_DELETE, 0); });

	version(OSX) {
		// Keep physical Home/End keys as aliases to the Mac primary chords.
		sm.bindAlias("seq_song_start", SDLK_HOME, KMOD_SHIFT);
		sm.bindAlias("seq_song_end", SDLK_END, KMOD_SHIFT);
		sm.bindAlias("seq_jump_mark", SDLK_HOME, KMOD_CTRL);
		sm.bindAlias("note_seq_start", SDLK_HOME, 0);
		sm.bindAlias("note_seq_end", SDLK_END, 0);
		sm.bindAlias("table_row_top", SDLK_HOME, KMOD_SHIFT);
		sm.bindAlias("table_row_bottom", SDLK_END, KMOD_SHIFT);
		sm.bindAlias("se_fit", SDLK_HOME, 0);
		sm.bindAlias("se_selection", SDLK_END, 0);
		// Other editor views previously handled bare Home/End only in widgets.
		foreach(ctx; [C.sequencer, C.instrumentTable, C.subtable]) {
			sm.register(ctx ~ "_home", ctx, "Navigation", "Move to beginning",
					homeKey, homeEndMods, invokeKeyAction(ui, SDLK_HOME, 0));
			sm.register(ctx ~ "_end", ctx, "Navigation", "Move to end",
					endKey, homeEndMods, invokeKeyAction(ui, SDLK_END, 0));
		}
		// Plain note-column Insert was previously handled only by the widget.
		sm.register("note_insert_fixed", C.noteColumn, "Note column",
				"Insert a row without expanding the sequence", insertKey, insertMods,
				{ invokeKey(SDLK_INSERT, 0); }, "Insert row (fixed length)");
		sm.bindAlias("note_insert_fixed", SDLK_INSERT, 0);
		sm.bindAlias("note_insert_row", SDLK_INSERT, KMOD_SHIFT);
		sm.bindAlias("note_expand", SDLK_INSERT, KMOD_CTRL);
		sm.bindAlias("trk_insert", SDLK_INSERT, 0);
		sm.bindAlias("trk_insert_end", SDLK_INSERT, KMOD_CTRL);
		sm.bindAlias("trk_insert_all", SDLK_INSERT, KMOD_CTRL | KMOD_SHIFT);
		sm.bindAlias("table_insert_row", SDLK_INSERT, 0);
		sm.bindAlias("se_add", insertKey, insertMods);
		foreach(i; 1 .. 4)
			sm.bindAlias("toggle_voice_" ~ to!string(i), SDLK_1 + i - 1, KMOD_CTRL);
	}
}

/**
 * Apply concise menu labels and note/sequence category grouping. Set after
 * all actions (incl. context) are registered. (ASCII only: the editor font is
 * a CP437-style 8-bit charset.)
 */
void applyMenuLabels(UI ui) {
	with(ui.sm) {
		// File / Edit / View / Help
		setMenuLabel("load_file", "Load song...");
		setMenuLabel("save_file", "Save song...");
		setMenuLabel("export_song", "Export song...");
		setMenuLabel("render_audio", "Render audio...");
		setMenuLabel("quick_save", "Quick save");
		setMenuLabel("optimize_song", "Optimize song");
		setMenuLabel("clear_sequences", "Clear sequences");
		setMenuLabel("increase_speed", "Speed +");
		setMenuLabel("decrease_speed", "Speed -");
		setMenuLabel("increase_multiplier_alt", "Multiplier +");
		setMenuLabel("decrease_multiplier_alt", "Multiplier -");
		setMenuLabel("toggle_fullscreen", "Fullscreen");
		setMenuLabel("toggle_help_text", "Help texts");
		setMenuLabel("toggle_filter_track", "Filter track");
		setMenuLabel("toggle_oscilloscope", "Oscilloscope");
		setMenuLabel("toggle_sound_editor", "Sound Editor");
		setMenuLabel("scope_zoom_in", "Oscilloscope zoom in");
		setMenuLabel("scope_zoom_out", "Oscilloscope zoom out");
		setMenuLabel("screenshot", "Screenshot");
		setMenuLabel("cycle_visualization", "Visualization");
		setMenuLabel("dump_frame", "Dump SID frame");
		setMenuLabel("help_dialog", "Keyboard help");
		setMenuLabel("about_dialog", "About...");
		// Playback
		setMenuLabel("play_from_mark", "Play from mark");
		setMenuLabel("play_from_mark_follow", "Play from mark (track)");
		setMenuLabel("play_from_beginning", "Play from start");
		setMenuLabel("play_from_beginning_follow", "Play from start (track)");
		setMenuLabel("play_from_cursor", "Play from cursor");
		setMenuLabel("play_from_cursor_follow", "Play from cursor (track)");
		setMenuLabel("stop_playback", "Stop");
		setMenuLabel("toggle_follow_mode", "Tracking");
		setMenuLabel("fast_forward_5", "Fast forward");
		setMenuLabel("fast_forward_25", "Fast forward (more)");
		setMenuLabel("next_filter_preset", "Next filter preset");
		setMenuLabel("prev_filter_preset", "Prev filter preset");
		setMenuLabel("toggle_interpolation", "Interpolation");
		setMenuLabel("toggle_sid_model", "SID model");
		setMenuLabel("toggle_voice_1", "Voice 1");
		setMenuLabel("toggle_voice_2", "Voice 2");
		setMenuLabel("toggle_voice_3", "Voice 3");
		setMenuLabel("toggle_keyjam", "Keyjam");
		// Window
		setMenuLabel("next_window", "Next sub-window");
		setMenuLabel("prev_window", "Previous sub-window");
		setMenuLabel("cycle_window", "Next window");
		setMenuLabel("cycle_window_reverse", "Previous window");
		setMenuLabel("window_voice1", "Voice 1");
		setMenuLabel("window_voice2", "Voice 2");
		setMenuLabel("window_voice3", "Voice 3");
		setMenuLabel("window_sequence", "Sequencer");
		setMenuLabel("window_instrument", "Instrument table");
		setMenuLabel("window_wave", "Wave table");
		setMenuLabel("window_pulse", "Pulse table");
		setMenuLabel("window_filter", "Filter table");
		setMenuLabel("window_command", "Command table");
		setMenuLabel("window_chord", "Chord table");
		setMenuLabel("window_song_info", "Song info");
		setMenuLabel("seq_enter_track_col", "Track column");
		setMenuLabel("seq_enter_note_col", "Note column");
		setMenuLabel("seq_overview", "Overview mode");
		// Sequencer context
		setMenuLabel("seq_song_start", "To song start");
		setMenuLabel("seq_song_end", "To song end");
		setMenuLabel("seq_jump_mark", "Jump to mark");
		setMenuLabel("seq_centralize", "Center cursor");
		setMenuLabel("seq_set_mark", "Set play mark");
		setMenuLabel("seq_wrap_mark", "Set loop mark");
		setMenuLabel("seq_highlight_inc", "Highlight +");
		setMenuLabel("seq_highlight_dec", "Highlight -");
		setMenuLabel("seq_highlight_reset", "Reset highlight");
		setMenuLabel("seq_rowcounter", "Row counters");
		setMenuLabel("seq_relative_notes", "Relative notes");
		setMenuLabel("seq_copy", "Copy over sequence...");
		setMenuLabel("seq_append", "Insert sequence...");
		setMenuLabel("seq_prev_subtune", "Previous subtune");
		setMenuLabel("seq_next_subtune", "Next subtune");
		// Note column
		setMenuLabel("note_play_row", "Play row");
		setMenuLabel("note_split", "Split sequence");
		setMenuLabel("note_seq_start", "To sequence start");
		setMenuLabel("note_seq_end", "To sequence end");
		setMenuLabel("note_expand_quick", "Quick expand");
		setMenuLabel("note_insert_row", "Insert row");
		setMenuLabel("note_delete_row", "Delete row");
		setMenuLabel("note_expand", "Expand sequence");
		setMenuLabel("note_shrink", "Shrink sequence");
		setMenuLabel("note_trans_semi_up", "Semitone up");
		setMenuLabel("note_trans_semi_down", "Semitone down");
		setMenuLabel("note_trans_oct_up", "Octave up");
		setMenuLabel("note_trans_oct_down", "Octave down");
		setMenuLabel("note_grab_instr", "Grab instrument");
		setMenuLabel("note_tie", "Tie note");
		setMenuLabel("note_autoinsert", "Auto instrument");
		setMenuLabel("note_octave_dec", "Base octave -");
		setMenuLabel("note_octave_inc", "Base octave +");
		// Track column
		setMenuLabel("trk_make_unique", "Make unique");
		setMenuLabel("trk_insert", "Insert track");
		setMenuLabel("trk_delete", "Delete track");
		setMenuLabel("trk_insert_end", "Insert track at end");
		setMenuLabel("trk_delete_end", "Delete track to end");
		setMenuLabel("trk_insert_all", "Insert track (all voices)");
		setMenuLabel("trk_delete_all", "Delete track (all voices)");
		setMenuLabel("trk_trans_up", "Transpose up");
		setMenuLabel("trk_trans_down", "Transpose down");
		setMenuLabel("trk_copy", "Copy tracks...");
		setMenuLabel("trk_paste", "Paste tracks");
		setMenuLabel("trk_paste_insert", "Paste as insert");
		setMenuLabel("trk_paste_overwrite", "Paste as overwrite");
		setMenuLabel("trk_swap_v1", "Swap with voice 1");
		setMenuLabel("trk_swap_v2", "Swap with voice 2");
		setMenuLabel("trk_swap_v3", "Swap with voice 3");
		setMenuLabel("trk_find_unused", "Find unused seq");
		setMenuLabel("trk_prev_seq", "Previous sequence");
		setMenuLabel("trk_next_seq", "Next sequence");
		// Instrument table
		setMenuLabel("ins_load", "Load instrument...");
		setMenuLabel("ins_save", "Save instrument...");
		setMenuLabel("ins_delete", "Delete instrument");
		setMenuLabel("ins_copy", "Copy instrument");
		setMenuLabel("ins_paste", "Paste instrument");
		// Sub-tables
		setMenuLabel("wave_goto_instr", "Go to instr wave");
		setMenuLabel("wave_clear_row", "Clear row");
		setMenuLabel("table_row_top", "To first row");
		setMenuLabel("table_row_bottom", "To last row");
		setMenuLabel("table_insert_row", "Insert row");
		setMenuLabel("table_delete_row", "Delete row");

		// Split the F6 note-column commands into note-level ("Note") and
		// sequence-level ("Sequence") groups, so the menu bar can show a
		// focused Note menu and a Sequence menu (which also gathers the
		// shared sequencer commands). "sequence" is CC's term for the note
		// pattern; a note is an individual pitch like C-4.
		setCategory("note_trans_semi_up", "Note");
		setCategory("note_trans_semi_down", "Note");
		setCategory("note_trans_oct_up", "Note");
		setCategory("note_trans_oct_down", "Note");
		setCategory("note_tie", "Note");
		setCategory("note_grab_instr", "Note");
		setCategory("note_autoinsert", "Note");
		setCategory("note_octave_dec", "Note");
		setCategory("note_octave_inc", "Note");
		setCategory("note_play_row", "Sequence");
		setCategory("note_split", "Sequence");
		setCategory("note_seq_start", "Sequence");
		setCategory("note_seq_end", "Sequence");
		setCategory("note_expand_quick", "Sequence");
		setCategory("note_insert_row", "Sequence");
		setCategory("note_delete_row", "Sequence");
		setCategory("note_expand", "Sequence");
		setCategory("note_shrink", "Sequence");
	}
}
