/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
Configurable keyboard shortcut binding system.
*/


module com.shortcuts;
import std.stdio;
import derelict.sdl2.sdl;
import ui.input : Keyinfo;
import std.typecons : Tuple;

/**
 * Represents a keyboard shortcut: a key code and modifier flags.
 * This struct can be used as a hash key in associative arrays.
 */
struct Shortcut {
	int key;   // SDLK_* constant
	int mods;  // Modifier flags (KMOD_CTRL, KMOD_SHIFT, etc.)

	/**
	 * Creates a Shortcut from a Keyinfo.
	 */
	this(Keyinfo keyinfo) {
		this.key = keyinfo.key;
		this.mods = keyinfo.mods;
	}

	/**
	 * Creates a Shortcut from explicit key and mods.
	 */
	this(int key, int mods) {
		this.key = key;
		this.mods = mods;
	}

	/**
	 * Hash function for use as AA key.
	 * Combines key and mods into a single hash value.
	 */
	size_t toHash() const {
		return cast(size_t)(key ^ (mods << 16));
	}

	/**
	 * Equality comparison for hash table lookups.
	 */
	bool opEquals(const ref Shortcut rhs) const {
		return key == rhs.key && mods == rhs.mods;
	}
}

/**
 * Action delegate type for shortcut callbacks.
 */
alias ActionCallback = void delegate();

/**
 * Manages keyboard shortcut bindings and dispatches keypress events.
 * 
 * Shortcuts are registered by action identifier (string), allowing
 * the same action to be bound to different shortcuts or the same
 * shortcut to be rebound. The system supports default bindings
 * loaded from code and will support JSON configuration loading
 * in the future.
 */
class ShortcutManager {
	private {
		// Map from action identifier to callback function
		void delegate()[string] actions;
		
		// Map from Shortcut to action identifier
		// Multiple shortcuts can map to the same action (rebinding)
		string[Shortcut] bindings;
		
		// Map from action identifier to default Shortcut (for reference/JSON export)
		Shortcut[string] defaultBindings;
	}

	/**
	 * Registers an action callback with the given identifier.
	 * The same action can be registered multiple times (last one wins).
	 * 
	 * Params:
	 *   actionId = Unique string identifier for the action (e.g., "play_from_mark")
	 *   callback = Delegate function to call when the action is triggered
	 */
	void registerAction(string actionId, ActionCallback callback) {
		actions[actionId] = callback;
	}

	/**
	 * Binds a keyboard shortcut to an action.
	 * If the shortcut was previously bound to a different action, it is rebound.
	 * 
	 * Params:
	 *   actionId = Action identifier (must be registered first)
	 *   key = SDLK_* key code
	 *   mods = Modifier flags (KMOD_CTRL, KMOD_SHIFT, etc.), can be 0
	 */
	void bindShortcut(string actionId, int key, int mods = 0) {
		auto shortcut = Shortcut(key, mods);
		bindings[shortcut] = actionId;
	}

	/**
	 * Binds a keyboard shortcut from a Keyinfo.
	 * Convenience method for binding from keyboard events.
	 */
	void bindShortcutFromKeyinfo(string actionId, Keyinfo keyinfo) {
		bindShortcut(actionId, keyinfo.key, keyinfo.mods);
	}

	/**
	 * Handles a keypress event and dispatches to bound actions.
	 * Returns true if a shortcut was found and handled, false otherwise.
	 * 
	 * Params:
	 *   key = Keyinfo from keyboard event
	 * 
	 * Returns:
	 *   true if shortcut was handled, false if no binding exists
	 */
	bool handleKeypress(Keyinfo key) {
		Shortcut shortcut = Shortcut(key);
		stderr.writefln("DEBUG: Handling keypress");// %d", key);

		// Look up the shortcut in bindings
		if(shortcut in bindings) {
			string actionId = bindings[shortcut];
			// Execute the action if registered
			if(actionId in actions) {
				actions[actionId]();
				return true;
			}
		}
		
		return false;
	}

	/**
	 * Updates the default bindings map for reference.
	 * Called internally after loading defaults.
	 */
	private void updateDefaultBindings() {
		defaultBindings.clear();
		foreach(shortcut, actionId; bindings) {
			defaultBindings[actionId] = shortcut;
		}
	}

	/**
	 * Loads default keyboard bindings based on current CheeseCutter shortcuts.
	 * This function contains all the hardcoded default mappings.
	 */
	void loadDefaultBindings() {
		// Global Application Control
		bindShortcut("exit_app", SDLK_ESCAPE, 0);
		bindShortcut("toggle_fullscreen", SDLK_RETURN, KMOD_ALT);
		bindShortcut("help_dialog", SDLK_F12, 0);
		bindShortcut("screenshot", SDLK_F12, KMOD_CTRL);
		bindShortcut("about_dialog", SDLK_F11, 0);  // XXX Mac has F11 preserved

		// File Operations
		bindShortcut("load_file", SDLK_F9, 0);
		bindShortcut("save_file", SDLK_F10, 0);
		bindShortcut("quick_save", SDLK_F11, KMOD_CTRL);

		// Undo/Redo
		bindShortcut("undo", SDLK_z, KMOD_CTRL);
		bindShortcut("redo", SDLK_r, KMOD_CTRL);

		// Playback Controls - Starting/Stopping
		bindShortcut("play_from_mark", SDLK_F1, 0);
		bindShortcut("play_from_mark_follow", SDLK_F1, KMOD_SHIFT);
		bindShortcut("play_from_beginning", SDLK_F2, 0);
		bindShortcut("play_from_beginning_follow", SDLK_F2, KMOD_SHIFT);
		bindShortcut("play_from_cursor", SDLK_F3, 0);
		bindShortcut("stop_playback", SDLK_F4, 0);
		bindShortcut("toggle_follow_mode", SDLK_SCROLLLOCK, 0);

		// Playback Options
		bindShortcut("fast_forward_5", SDLK_F8, 0);
		bindShortcut("fast_forward_25", SDLK_F8, KMOD_SHIFT);
		bindShortcut("next_filter_preset", SDLK_F8, KMOD_CTRL);
		bindShortcut("prev_filter_preset", SDLK_F8, KMOD_CTRL | KMOD_SHIFT);
		bindShortcut("toggle_interpolation", SDLK_F2, KMOD_CTRL);
		bindShortcut("toggle_sid_model", SDLK_F3, KMOD_CTRL);

		// Voice Control (During Playback)
		bindShortcut("toggle_voice_1", SDLK_1, KMOD_CTRL);
		bindShortcut("toggle_voice_2", SDLK_2, KMOD_CTRL);
		bindShortcut("toggle_voice_3", SDLK_3, KMOD_CTRL);

		// Window Navigation - Tab is handled in Toplevel, but register for consistency
		bindShortcut("next_window", SDLK_TAB, 0);
		bindShortcut("prev_window", SDLK_TAB, KMOD_SHIFT);
		bindShortcut("cycle_window", SDLK_TAB, KMOD_CTRL);
		bindShortcut("cycle_window_reverse", SDLK_TAB, KMOD_CTRL | KMOD_SHIFT);
		
		// Direct Window Access
		bindShortcut("window_voice1", SDLK_1, KMOD_ALT);
		bindShortcut("window_voice2", SDLK_2, KMOD_ALT);
		bindShortcut("window_voice3", SDLK_3, KMOD_ALT);
		bindShortcut("window_sequence", SDLK_v, KMOD_ALT);
		bindShortcut("window_instrument", SDLK_4, KMOD_ALT);
		bindShortcut("window_instrument_alt", SDLK_i, KMOD_ALT);
		bindShortcut("window_wave", SDLK_5, KMOD_ALT);
		bindShortcut("window_wave_alt", SDLK_w, KMOD_ALT);
		bindShortcut("window_pulse", SDLK_6, KMOD_ALT);
		bindShortcut("window_pulse_alt", SDLK_p, KMOD_ALT);
		bindShortcut("window_filter", SDLK_7, KMOD_ALT);
		bindShortcut("window_filter_alt", SDLK_f, KMOD_ALT);
		bindShortcut("window_command", SDLK_8, KMOD_ALT);
		bindShortcut("window_command_alt", SDLK_m, KMOD_ALT);
		bindShortcut("window_chord", SDLK_9, KMOD_ALT);
		bindShortcut("window_chord_alt", SDLK_d, KMOD_ALT);
		bindShortcut("window_song_info", SDLK_t, KMOD_ALT);

		// Song Settings
		bindShortcut("increase_speed", SDLK_PLUS, KMOD_CTRL);
		bindShortcut("increase_speed_kp", SDLK_KP_PLUS, KMOD_CTRL);
		bindShortcut("decrease_speed", SDLK_MINUS, KMOD_CTRL);
		bindShortcut("decrease_speed_kp", SDLK_KP_MINUS, KMOD_CTRL);
		bindShortcut("increase_multiplier_alt", SDLK_KP_PLUS, KMOD_ALT);
		bindShortcut("decrease_multiplier_alt", SDLK_KP_MINUS, KMOD_ALT);

		// Visualization
		bindShortcut("cycle_visualization", SDLK_F9, KMOD_CTRL);
		bindShortcut("dump_frame", SDLK_F12, KMOD_ALT);

		// Keyjam Mode
		bindShortcut("toggle_keyjam", SDLK_SPACE, KMOD_CTRL);

		// Song Management
		bindShortcut("clear_sequences", SDLK_KP_0, KMOD_ALT);
		bindShortcut("clear_sequences_ctrl", SDLK_c, KMOD_CTRL);
		bindShortcut("optimize_song", SDLK_KP_PERIOD, KMOD_ALT);
		bindShortcut("optimize_song_ctrl", SDLK_o, KMOD_CTRL);
		bindShortcut("toggle_help_text", SDLK_h, KMOD_ALT);

		// Store defaults for reference
		updateDefaultBindings();
	}

	/**
	 * Loads shortcut bindings from a JSON configuration file.
	 * 
	 * This is a stub implementation for future JSON support.
	 * Currently does nothing - will be implemented when a JSON
	 * library is added to the project.
	 * 
	 * Params:
	 *   filename = Path to JSON configuration file
	 * 
	 * Returns:
	 *   true if loading succeeded, false otherwise
	 */
	bool loadFromJSON(string filename) {
		// TODO: Implement JSON parsing when JSON library is available
		// Expected format: { "action": "shortcut_string", ... }
		// Example: { "play_from_mark": "F1", "toggle_fullscreen": "Alt+Return" }
		return false;
	}

	/**
	 * Saves current shortcut bindings to a JSON configuration file.
	 * 
	 * This is a stub implementation for future JSON support.
	 * Currently does nothing - will be implemented when a JSON
	 * library is added to the project.
	 * 
	 * Params:
	 *   filename = Path to JSON configuration file to create
	 * 
	 * Returns:
	 *   true if saving succeeded, false otherwise
	 */
	bool saveToJSON(string filename) {
		// TODO: Implement JSON serialization when JSON library is available
		return false;
	}

	/**
	 * Gets the shortcut currently bound to an action.
	 * 
	 * Params:
	 *   actionId = Action identifier
	 * 
	 * Returns:
	 *   The Shortcut bound to this action, or Shortcut(0,0) if not bound
	 */
	Shortcut getShortcut(string actionId) {
		// Search through bindings to find one matching this actionId
		foreach(shortcut, boundActionId; bindings) {
			if(boundActionId == actionId) {
				return shortcut;
			}
		}
		// Return invalid shortcut if not found
		return Shortcut(0, 0);
	}

	/**
	 * Checks if an action is registered.
	 * 
	 * Params:
	 *   actionId = Action identifier to check
	 * 
	 * Returns:
	 *   true if action is registered, false otherwise
	 */
	bool isActionRegistered(string actionId) {
		if (actionId in actions) {
			return true;
		}
		return false;
	}

	/**
	 * Clears all shortcut bindings.
	 * Actions remain registered but are no longer bound.
	 */
	void clearBindings() {
		bindings.clear();
	}

	/**
	 * Resets all bindings to defaults.
	 */
	void resetToDefaults() {
		clearBindings();
		loadDefaultBindings();
	}
}

// Global shortcut manager instance
private ShortcutManager _globalShortcutManager;

/**
 * Gets the global ShortcutManager instance.
 * Creates it on first access if it doesn't exist.
 * 
 * Returns:
 *   The global ShortcutManager instance
 */
ShortcutManager getShortcutManager() {
	if(_globalShortcutManager is null) {
		_globalShortcutManager = new ShortcutManager();
		_globalShortcutManager.loadDefaultBindings();
	}
	return _globalShortcutManager;
}
