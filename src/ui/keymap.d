/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
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

/**
 * Register all keyboard shortcut actions, their bindings and metadata.
 * This is the single source of truth for global command shortcuts; help
 * text and doc/KEYBOARD.md are generated from these registrations.
 */
void registerShortcuts(UI ui) {
	with(ui) {
	// Application Control. Quit has no hotkey anymore (Esc opens the menu
	// bar); it is reached via File > Quit, so it is registered menu-only.
	// Its own "Application" category places it in a trailing group of the
	// File menu (separated from the load/save items, Quit last).
	// Alt-F4 is the conventional close shortcut; the same item is File ▸ Quit.
	sm.register("exit_app", Ctx.global, "Application",
				"Quit program", SDLK_F4, KMOD_ALT, {
		string msg = state.songModified
			? "You have unsaved changes. Really exit (y/n)? "
			: "Really exit (y/n)? ";
		activateDialog(new ConfirmationDialog(msg, (int param) {
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
				"Ask for a sequence number and copy contents over current sequence", SDLK_c, KMOD_ALT,
				{ invokeKey(SDLK_c, KMOD_ALT); });
	sm.register("seq_append", C.sequencer, "Sequence operations",
				"Ask for a sequence number and insert contents to cursor pos", SDLK_a, KMOD_ALT,
				{ invokeKey(SDLK_a, KMOD_ALT); });
	sm.register("seq_prev_subtune", C.sequencer, "Sequence operations",
				"Activate previous subtune", SDLK_LEFT, KMOD_ALT,
				{ invokeKey(SDLK_LEFT, KMOD_ALT); });
	sm.register("seq_next_subtune", C.sequencer, "Sequence operations",
				"Activate next subtune", SDLK_RIGHT, KMOD_ALT,
				{ invokeKey(SDLK_RIGHT, KMOD_ALT); });
	sm.register("seq_enter_track_col", C.sequencer, "Sequence operations",
				"Enter the track column / toggle tracklist display", SDLK_F5, 0,
				{ invokeKey(SDLK_F5, 0); });
	sm.register("seq_enter_note_col", C.sequencer, "Sequence operations",
				"Enter the note column", SDLK_F6, 0,
				{ invokeKey(SDLK_F6, 0); });
	sm.register("seq_overview", C.sequencer, "Sequence operations",
				"Toggle tracklist overview mode", SDLK_F7, 0,
				{ invokeKey(SDLK_F7, 0); });

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
				"Split current sequence into two from cursor pos", SDLK_p, KMOD_CTRL,
				{ invokeKey(SDLK_p, KMOD_CTRL); });
	sm.register("note_seq_start", C.noteColumn, "Note column",
				"Move cursor to sequence start (or screen top)", SDLK_HOME, 0,
				{ invokeKey(SDLK_HOME, 0); });
	sm.register("note_seq_end", C.noteColumn, "Note column",
				"Move cursor to sequence end (or screen bottom)", SDLK_END, 0,
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
		setMenuLabel("save_prg", "Export .prg...");
		setMenuLabel("quick_save", "Quick save");
		setMenuLabel("optimize_song", "Optimize song");
		setMenuLabel("clear_sequences", "Clear sequences");
		setMenuLabel("increase_speed", "Speed +");
		setMenuLabel("decrease_speed", "Speed -");
		setMenuLabel("increase_multiplier_alt", "Multiplier +");
		setMenuLabel("decrease_multiplier_alt", "Multiplier -");
		setMenuLabel("toggle_fullscreen", "Fullscreen");
		setMenuLabel("toggle_help_text", "Help texts");
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
		setMenuLabel("seq_enter_track_col", "Track column");
		setMenuLabel("seq_enter_note_col", "Note column");
		setMenuLabel("seq_overview", "Overview mode");
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
