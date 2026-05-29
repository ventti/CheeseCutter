/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
Configurable keyboard shortcut binding system.

This is the single registry for all NAMED COMMAND keyboard shortcuts (both
global and context-specific). Each action carries metadata (context, category,
description, optional menu label) so that help text and doc/KEYBOARD.md can be
generated from the registry, and actions can later be enumerated into menus.

Raw data entry (hex-nibble typing, the QWERTY piano note entry, text fields,
plain cursor movement) is NOT registered here; it stays in the input widgets.
*/


module com.shortcuts;
import std.stdio;
import std.string : format, toUpper;
import std.algorithm : sort;
import derelict.sdl2.sdl;
import ui.input : Keyinfo;

private int normalizeShortcutMods(int mods) {
	int normalized = 0;
	if(mods & KMOD_SHIFT) normalized |= KMOD_SHIFT;
	if(mods & KMOD_CTRL) normalized |= KMOD_CTRL;
	if(mods & KMOD_ALT) normalized |= KMOD_ALT;
	if(mods & KMOD_GUI) normalized |= KMOD_GUI;
	return normalized;
}

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
		this.mods = normalizeShortcutMods(keyinfo.mods);
	}

	/**
	 * Creates a Shortcut from explicit key and mods.
	 */
	this(int key, int mods) {
		this.key = key;
		this.mods = normalizeShortcutMods(mods);
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

	bool isValid() const {
		return key != 0;
	}
}

/**
 * Action delegate type for shortcut callbacks.
 */
alias ActionCallback = void delegate();

/**
 * Optional predicate type used to grey-out / disable an action (e.g. in menus).
 */
alias EnabledPredicate = bool delegate();

/// Context identifiers. "global" is the fallback consulted for every keypress.
enum Ctx {
	global         = "global",
	sequencer      = "sequencer",       // sequencer overview ('F7' map)
	noteColumn     = "note_column",     // sequencer note/data column (F6)
	trackColumn    = "track_column",    // sequencer track column (F5)
	instrumentTable= "instrument_table",
	subtable       = "subtable",        // wave/pulse/filter/cmd/chord
	songInfo       = "song_info",
}

/**
 * Full definition of a registered action: callback + metadata for docs/menus.
 */
struct ActionDef {
	string actionId;
	string context;      // one of the Ctx values
	string category;     // group label, e.g. "Playback"
	string description;  // help sentence
	string menuLabel;    // optional; "" -> fall back to description
	ActionCallback callback;
	EnabledPredicate enabled;  // optional; null = always enabled

	string label() const {
		return menuLabel.length ? menuLabel : description;
	}
}

/**
 * Manages keyboard shortcut bindings and dispatches keypress events.
 *
 * Dispatch resolves the ACTIVE context first, then falls back to "global".
 * The same physical key can therefore mean different things in different
 * contexts (e.g. Ctrl-C copies an instrument in the instrument table but a
 * track in the track column).
 */
class ShortcutManager {
	private {
		// Map from action identifier to its full definition (callback + metadata)
		ActionDef[string] actions;

		// Global bindings: Shortcut -> action identifier
		string[Shortcut] bindings;

		// Per-context bindings: context -> (Shortcut -> action identifier)
		string[Shortcut][string] contextBindings;

		// The currently active context (pushed by the UI as windows change)
		string activeContext = Ctx.global;

		// Context fallback chain: child context -> parent context. Dispatch walks
		// this chain (then global) so e.g. a note-column keypress can resolve a
		// command registered on the shared "sequencer" context.
		string[string] contextParent;
	}

	this() {
		// The sequencer's note/track/overview columns share the common
		// "sequencer" commands; resolve through it, then to global.
		contextParent[Ctx.noteColumn] = Ctx.sequencer;
		contextParent[Ctx.trackColumn] = Ctx.sequencer;
	}

	/**
	 * Registers an action together with its binding and metadata.
	 * This is the primary registration API; one call fully defines an action.
	 *
	 * Params:
	 *   actionId    = unique identifier (e.g. "play_from_mark")
	 *   context     = context id (Ctx.global, Ctx.sequencer, ...)
	 *   category    = group label used for help/menu grouping
	 *   description = human-readable help sentence
	 *   key         = SDLK_* key code
	 *   mods        = modifier flags (KMOD_*), or 0
	 *   cb          = callback invoked when the shortcut fires
	 *   menuLabel   = optional short label for menus (defaults to description)
	 *   enabled     = optional predicate; when it returns false the action is skipped
	 */
	void register(string actionId, string context, string category,
				  string description, int key, int mods, ActionCallback cb,
				  string menuLabel = "", EnabledPredicate enabled = null) {
		actions[actionId] = ActionDef(actionId, context, category, description,
									  menuLabel, cb, enabled);
		auto sc = Shortcut(key, mods);
		if(context == Ctx.global)
			bindings[sc] = actionId;
		else
			contextBindings[context][sc] = actionId;
	}

	/**
	 * Registers a second key binding for an already-registered action.
	 * Useful for alternate keys (e.g. Alt-4 and Alt-I both jump to instruments).
	 */
	void bindAlias(string actionId, int key, int mods) {
		assert(actionId in actions, "bindAlias: unknown action " ~ actionId);
		auto sc = Shortcut(key, mods);
		string ctx = actions[actionId].context;
		if(ctx == Ctx.global)
			bindings[sc] = actionId;
		else
			contextBindings[ctx][sc] = actionId;
	}

	// --- Backward-compatible thin shims (kept for incremental migration) ---

	void registerAction(string actionId, ActionCallback callback) {
		if(auto def = actionId in actions)
			def.callback = callback;
		else
			actions[actionId] = ActionDef(actionId, Ctx.global, "", "", "",
										  callback, null);
	}

	void bindShortcut(string actionId, int key, int mods = 0) {
		auto sc = Shortcut(key, mods);
		bindings[sc] = actionId;
	}

	void bindShortcutFromKeyinfo(string actionId, Keyinfo keyinfo) {
		bindShortcut(actionId, keyinfo.key, keyinfo.mods);
	}

	// --- Dispatch ---

	/**
	 * Sets the active context. Called by the UI when the active window or
	 * sequencer column changes.
	 */
	void setActiveContext(string ctx) {
		activeContext = ctx;
	}

	string getActiveContext() {
		return activeContext;
	}

	/**
	 * Handles a keypress: resolves active-context binding first, then global.
	 * Returns true if a shortcut was found and invoked.
	 */
	bool handleKeypress(Keyinfo key) {
		Shortcut sc = Shortcut(key);
		// Walk the active context and its parents, then fall back to global.
		for(string ctx = activeContext; ctx.length; ) {
			if(auto m = ctx in contextBindings)
				if(auto id = sc in *m)
					return invoke(*id);
			auto p = ctx in contextParent;
			ctx = p is null ? null : *p;
		}
		if(auto id = sc in bindings)
			return invoke(*id);
		return false;
	}

	private bool invoke(string actionId) {
		if(auto def = actionId in actions) {
			if(def.enabled is null || def.enabled()) {
				def.callback();
				return true;
			}
		}
		return false;
	}

	// --- Queries (for docs/menus) ---

	/**
	 * Gets the shortcut currently bound to an action (searches global and
	 * context bindings). Returns Shortcut(0,0) if not bound.
	 */
	Shortcut getShortcut(string actionId) {
		foreach(sc, id; bindings)
			if(id == actionId) return sc;
		foreach(ctx, m; contextBindings)
			foreach(sc, id; m)
				if(id == actionId) return sc;
		return Shortcut(0, 0);
	}

	/**
	 * Returns every shortcut bound to an action (primary + aliases, across
	 * global and context bindings), sorted for stable output.
	 */
	Shortcut[] getShortcuts(string actionId) {
		Shortcut[] result;
		foreach(sc, id; bindings)
			if(id == actionId) result ~= sc;
		foreach(ctx, m; contextBindings)
			foreach(sc, id; m)
				if(id == actionId) result ~= sc;
		result.sort!((a, b) => formatShortcut(a) < formatShortcut(b));
		return result;
	}

	bool isActionRegistered(string actionId) {
		return (actionId in actions) !is null;
	}

	const(ActionDef)* getAction(string actionId) {
		return actionId in actions;
	}

	/**
	 * Returns all actions registered under a context, each paired with its
	 * (first) bound shortcut, sorted by category then description.
	 */
	ActionDef[] actionsForContext(string context) {
		ActionDef[] result;
		foreach(id, def; actions)
			if(def.context == context)
				result ~= def;
		result.sort!((a, b) => a.category < b.category ||
					 (a.category == b.category && a.description < b.description));
		return result;
	}

	/**
	 * Returns the distinct category labels present in a context, in first-seen
	 * (sorted) order.
	 */
	string[] categoriesForContext(string context) {
		string[] cats;
		bool[string] seen;
		foreach(def; actionsForContext(context)) {
			if(def.category !in seen) {
				seen[def.category] = true;
				cats ~= def.category;
			}
		}
		return cats;
	}

	void clearBindings() {
		bindings.clear();
		contextBindings.clear();
	}

	// --- JSON config (stubs; no JSON library linked yet) ---

	bool loadFromJSON(string filename) {
		// TODO: Implement JSON parsing when a JSON library is available.
		return false;
	}

	bool saveToJSON(string filename) {
		// TODO: Implement JSON serialization when a JSON library is available.
		return false;
	}
}

// Global shortcut manager instance
private ShortcutManager _globalShortcutManager;

/**
 * Gets the global ShortcutManager instance, creating it on first access.
 */
ShortcutManager getShortcutManager() {
	if(_globalShortcutManager is null)
		_globalShortcutManager = new ShortcutManager();
	return _globalShortcutManager;
}

// --- Key-name formatting helpers (pure; used by help/markdown generation) ---

/**
 * Returns a human-readable name for an SDLK_* key code.
 */
string keyName(int key) {
	switch(key) {
	case SDLK_RETURN, SDLK_KP_ENTER: return "Return";
	case SDLK_ESCAPE: return "Esc";
	case SDLK_TAB: return "Tab";
	case SDLK_SPACE: return "Space";
	case SDLK_BACKSPACE: return "Backspace";
	case SDLK_INSERT: return "Insert";
	case SDLK_DELETE: return "Delete";
	case SDLK_HOME: return "Home";
	case SDLK_END: return "End";
	case SDLK_PAGEUP: return "PageUp";
	case SDLK_PAGEDOWN: return "PageDown";
	case SDLK_UP: return "Up";
	case SDLK_DOWN: return "Down";
	case SDLK_LEFT: return "Left";
	case SDLK_RIGHT: return "Right";
	case SDLK_SCROLLLOCK: return "ScrollLock";
	case SDLK_PLUS: return "+";
	case SDLK_MINUS: return "-";
	case SDLK_EQUALS: return "=";
	case SDLK_LESS: return "<";
	case SDLK_GREATER: return ">";
	case SDLK_PERIOD: return ".";
	case SDLK_COMMA: return ",";
	case SDLK_SEMICOLON: return ";";
	case SDLK_KP_PLUS: return "Keypad +";
	case SDLK_KP_MINUS: return "Keypad -";
	case SDLK_KP_MULTIPLY: return "Keypad *";
	case SDLK_KP_DIVIDE: return "Keypad /";
	case SDLK_KP_PERIOD: return "Keypad .";
	case SDLK_F1: return "F1";
	case SDLK_F2: return "F2";
	case SDLK_F3: return "F3";
	case SDLK_F4: return "F4";
	case SDLK_F5: return "F5";
	case SDLK_F6: return "F6";
	case SDLK_F7: return "F7";
	case SDLK_F8: return "F8";
	case SDLK_F9: return "F9";
	case SDLK_F10: return "F10";
	case SDLK_F11: return "F11";
	case SDLK_F12: return "F12";
	default:
		if(key >= SDLK_KP_1 && key <= SDLK_KP_9)
			return format("Keypad %d", key - SDLK_KP_1 + 1);
		if(key == SDLK_KP_0)
			return "Keypad 0";
		if(key >= SDLK_a && key <= SDLK_z)
			return format("%c", cast(char)('A' + (key - SDLK_a)));
		if(key >= SDLK_0 && key <= SDLK_9)
			return format("%c", cast(char)('0' + (key - SDLK_0)));
		return format("Key(%d)", key);
	}
}

/**
 * Formats a complete shortcut (modifiers + key) as e.g. "Ctrl-F1".
 */
string formatShortcut(Shortcut sc) {
	if(!sc.isValid) return "";
	string s;
	if(sc.mods & KMOD_CTRL) s ~= "Ctrl-";
	if(sc.mods & KMOD_ALT) s ~= "Alt-";
	if(sc.mods & KMOD_SHIFT) s ~= "Shift-";
	if(sc.mods & KMOD_GUI) s ~= "Cmd-";
	s ~= keyName(sc.key);
	return s;
}

/**
 * Formats a list of shortcuts joined by " / " (e.g. "Alt-4 / Alt-I").
 */
string formatShortcuts(Shortcut[] scs) {
	import std.array : join;
	string[] parts;
	foreach(sc; scs)
		if(sc.isValid) parts ~= formatShortcut(sc);
	return parts.join(" / ");
}
