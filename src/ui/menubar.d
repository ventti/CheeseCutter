/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Top-bar dropdown menu system.

The menu bar lives on screen row 0 and is opened with Esc. It is driven entirely
by the shortcut registry (com.shortcuts): every menu item's label, shortcut text
and enabled state are derived from the one ActionDef registered in
UI.registerShortcuts(). The menu layer holds NO key bindings, descriptions or
labels of its own — only the presentation grouping that maps registry categories
to conventional top-level menus (File / Edit / View / Playback / Window / Help),
plus a dynamic context menu that follows the active editor context.

This guarantees the single-source-of-truth property: the mechanism (dispatch),
help (F12 / KEYBOARD.md, see ui.shorthelp) and the menus all consume the same
registry; none of them redefine a shortcut.
*/

module ui.menubar;

import derelict.sdl2.sdl;
import std.algorithm : max;
import com.session;      // screen, mainui, state
import com.shortcuts;
import com.util;         // APP_VERSION, versionInfo
import ui.input : Keyinfo;
import ui.ui : UI;

final class MenuBar {
	private:
	ShortcutManager sm;
	bool _active;                  // bar has keyboard focus (Esc pressed)
	int menuIndex;                 // remembered last top-level menu (latest focus)
	int itemIndex;                 // remembered last highlighted item (latest focus)

	struct Item {
		string actionId;
		bool sep;
		string label;
		string keys;
		bool enabled;
	}
	struct DMenu {
		string title;
		Item[] items;
	}
	DMenu[] menus;
	int[] titleX;                  // x of each top-level title, set by drawBar

	// Geometry of the currently drawn dropdown box (for mouse hit-testing).
	int boxX, boxY, boxW, boxH;

	public:

	this(ShortcutManager mgr) {
		sm = mgr;
		menuIndex = 0;
		itemIndex = 0;
		// Validate the layout once: every global category must be claimed by
		// exactly one menu, so no registered command is ever unreachable.
		assertCategoryCoverage();
	}

	@property bool active() const { return _active; }

	/// Esc entry point: focus the bar, restoring the last menu + item.
	void openMenu() {
		rebuild();
		_active = true;
		clampIndices();
		// Clean slate so the dropdown overlays a freshly painted screen.
		if(mainui !is null) mainui.refresh();
	}

	void close() {
		if(!_active) return;
		_active = false;
		// Repaint everything underneath so the dropdown leaves no artifacts.
		if(mainui !is null) mainui.refresh();
	}

	// --- Drawing -------------------------------------------------------------

	/// Row 0: top-level titles on the left, a program/version/date tag on the right.
	void drawBar() {
		rebuild();
		int bg = state.keyjamStatus ? 14 : 12;
		screen.clrtoeol(0, bg);
		titleX.length = menus.length;
		int x = 2;
		foreach(i, ref m; menus) {
			titleX[i] = x;
			bool selected = _active && cast(int)i == menuIndex;
			int fg = selected ? 0 : 1;
			int tbg = selected ? 15 : bg;
			screen.cprint(x, 0, fg, tbg, m.title);
			x += cast(int)m.title.length + 2;
		}
		// Right-aligned program/version tag: use the fullest name that still
		// clears the menu titles, shrinking the prefix as space runs out.
		string ver = APP_VERSION ~ versionInfo();
		foreach(tag; ["CheeseCutter Extended " ~ ver, "CC Ext " ~ ver, "CC " ~ ver]) {
			int tx = screen.width - cast(int)tag.length - 1;
			if(tx > x) { screen.cprint(tx, 0, 1, bg, tag); break; }
		}
	}

	/// The condensed dropdown box under the active title.
	void drawDropdown() {
		boxW = 0;
		if(!_active || menuIndex >= cast(int)menus.length) return;
		auto m = menus[menuIndex];
		if(m.items.length == 0) return;

		int labelW = 0, keyW = 0;
		foreach(it; m.items) {
			if(it.sep) continue;
			labelW = max(labelW, cast(int)it.label.length);
			keyW = max(keyW, cast(int)it.keys.length);
		}
		int inner = labelW + (keyW > 0 ? 2 + keyW : 0);
		int w = inner + 2;                      // + left/right border
		if(w < cast(int)m.title.length + 2) w = cast(int)m.title.length + 2;
		int h = cast(int)m.items.length + 2;    // + top/bottom border
		int bx = (menuIndex < cast(int)titleX.length) ? titleX[menuIndex] : 2;
		if(bx + w > screen.width) bx = screen.width - w;
		if(bx < 1) bx = 1;
		int by = 1;
		boxX = bx; boxY = by; boxW = w; boxH = h;

		frame(bx, by, h, w);
		foreach(i, it; m.items) {
			int ry = by + 1 + cast(int)i;
			if(it.sep) {
				foreach(cx; bx + 1 .. bx + w - 1)
					screen.setChar(cx, ry, 0x0500 | 192);
				continue;
			}
			bool hl = cast(int)i == itemIndex;
			int rbg = hl ? 11 : 0;
			int lfg = it.enabled ? (hl ? 1 : 15) : 8;
			foreach(cx; bx + 1 .. bx + w - 1)
				screen.setChar(cx, ry, cast(Uint32)(0x20 | (rbg << 16)));
			screen.cprint(bx + 1, ry, lfg, rbg, it.label);
			if(it.keys.length)
				screen.cprint(bx + w - 1 - cast(int)it.keys.length, ry,
							  it.enabled ? (hl ? 15 : 12) : 8, rbg, it.keys);
		}
	}

	// --- Input ---------------------------------------------------------------

	int keypress(Keyinfo key) {
		rebuild();
		switch(key.raw) {
		case SDLK_ESCAPE:
			close();
			break;
		case SDLK_LEFT:
			moveMenu(-1);
			break;
		case SDLK_RIGHT:
			moveMenu(1);
			break;
		case SDLK_UP:
			moveItem(-1);
			break;
		case SDLK_DOWN:
			moveItem(1);
			break;
		case SDLK_HOME:
			itemIndex = -1;
			moveItem(1);
			break;
		case SDLK_END:
			itemIndex = cast(int)menus[menuIndex].items.length;
			moveItem(-1);
			break;
		case SDLK_RETURN, SDLK_KP_ENTER:
			invokeCurrent();
			break;
		default:
			break;
		}
		return 0;
	}

	void clickedAt(int x, int y, int button, int clicks) {
		rebuild();
		if(y == 0) {
			foreach(i, m; menus) {
				if(i < titleX.length && x >= titleX[i]
				   && x < titleX[i] + cast(int)m.title.length) {
					menuIndex = cast(int)i;
					_active = true;
					itemIndex = firstSelectable(menuIndex);
					return;
				}
			}
			if(_active) close();
			return;
		}
		if(!_active) return;
		if(boxW > 0 && x > boxX && x < boxX + boxW - 1
		   && y > boxY && y < boxY + boxH - 1) {
			int idx = y - (boxY + 1);
			auto items = menus[menuIndex].items;
			if(idx >= 0 && idx < cast(int)items.length
			   && !items[idx].sep && items[idx].enabled) {
				itemIndex = idx;
				invokeCurrent();
			}
			return;
		}
		close();
	}

	// --- Menu building (from the registry) -----------------------------------

	private:

	void rebuild() {
		menus.length = 0;
		addGlobalMenu("File", ["File", "Application"]);   // Application = Quit (last group)
		addGlobalMenu("Edit", ["Edit", "Song management", "Song variables"]);
		addGlobalMenu("View", ["Display"]);
		addGlobalMenu("Playback", ["Playback", "Playback options",
								   "Voice control", "Keyjam"]);
		addGlobalMenu("Window", ["Window navigation"]);
		addContextMenu();
		addGlobalMenu("Help", ["Help"]);
		clampIndices();
	}

	Item makeItem(ActionDef def) {
		bool en = def.enabled is null || def.enabled();
		return Item(def.actionId, false, def.label(),
					formatShortcuts(sm.getShortcuts(def.actionId)), en);
	}

	// Append the items of `categories` (in order) from one context, separating
	// non-empty groups with a ruler. Returns the gathered items.
	Item[] gather(string context, string[] categories, bool leadSep) {
		Item[] items;
		bool first = !leadSep;
		foreach(cat; categories) {
			Item[] group;
			foreach(def; sm.actionsForContext(context))
				if(def.category == cat)
					group ~= makeItem(def);
			if(group.length) {
				if(!first) items ~= Item("", true, "", "", false);
				items ~= group;
				first = false;
			}
		}
		return items;
	}

	void addGlobalMenu(string title, string[] categories) {
		menus ~= DMenu(title, gather(cast(string)Ctx.global, categories, false));
	}

	void addContextMenu() {
		string ctx = sm.getActiveContext();
		string title;
		string[] contexts;
		if(ctx == Ctx.sequencer)            { title = "Sequence";   contexts = [cast(string)Ctx.sequencer]; }
		else if(ctx == Ctx.noteColumn)      { title = "Note";       contexts = [cast(string)Ctx.noteColumn, cast(string)Ctx.sequencer]; }
		else if(ctx == Ctx.trackColumn)     { title = "Track";      contexts = [cast(string)Ctx.trackColumn, cast(string)Ctx.sequencer]; }
		else if(ctx == Ctx.instrumentTable) { title = "Instrument"; contexts = [cast(string)Ctx.instrumentTable]; }
		else if(ctx == Ctx.subtable)        { title = "Tables";     contexts = [cast(string)Ctx.subtable]; }
		else if(ctx == Ctx.songInfo)        { title = "Song";       contexts = [cast(string)Ctx.songInfo]; }
		else return;   // global -> no context menu

		Item[] items;
		foreach(c; contexts)
			items ~= gather(c, sm.categoriesForContext(c), items.length > 0);
		if(items.length)
			menus ~= DMenu(title, items);
	}

	// --- Navigation helpers --------------------------------------------------

	int firstSelectable(int mi) {
		if(mi < 0 || mi >= cast(int)menus.length) return 0;
		auto items = menus[mi].items;
		foreach(i, it; items)
			if(!it.sep && it.enabled) return cast(int)i;
		return 0;
	}

	void moveMenu(int dir) {
		int n = cast(int)menus.length;
		if(n == 0) return;
		menuIndex = ((menuIndex + dir) % n + n) % n;
		itemIndex = firstSelectable(menuIndex);
		// The dropdown moves/resizes; repaint underneath to clear the old box.
		if(mainui !is null) mainui.refresh();
	}

	void moveItem(int dir) {
		if(menuIndex >= cast(int)menus.length) return;
		auto items = menus[menuIndex].items;
		int n = cast(int)items.length;
		if(n == 0) return;
		int i = itemIndex;
		foreach(_; 0 .. n) {
			i = ((i + dir) % n + n) % n;
			if(!items[i].sep && items[i].enabled) {
				itemIndex = i;
				return;
			}
		}
	}

	void invokeCurrent() {
		if(menuIndex >= cast(int)menus.length) return;
		auto items = menus[menuIndex].items;
		if(itemIndex < 0 || itemIndex >= cast(int)items.length) return;
		auto it = items[itemIndex];
		if(it.sep || !it.enabled) return;
		auto def = sm.getAction(it.actionId);
		// Close the bar BEFORE invoking: the callback may itself open a dialog
		// (e.g. File > Load), and the bar must not be the active modal then.
		close();
		if(def !is null && (def.enabled is null || def.enabled()))
			def.callback();
	}

	void clampIndices() {
		int n = cast(int)menus.length;
		if(n == 0) { menuIndex = 0; itemIndex = 0; return; }
		if(menuIndex >= n) menuIndex = n - 1;
		if(menuIndex < 0) menuIndex = 0;
		auto items = menus[menuIndex].items;
		if(itemIndex >= cast(int)items.length || itemIndex < 0
		   || items[itemIndex].sep || !items[itemIndex].enabled)
			itemIndex = firstSelectable(menuIndex);
	}

	// --- Rendering helper ----------------------------------------------------

	// A condensed pop-up frame (same box-drawing chars / colour as the dialogs,
	// without the drop shadow), drawn directly so MenuBar stays self-contained.
	void frame(int ax, int ay, int h, int w) {
		enum Uint32 fc = 0x0500;   // fg colour 5, bg 0 — matches Window.drawFrame
		for(int y = ay; y < ay + h; y++) {
			screen.setChar(ax, y, fc | 216);
			screen.setChar(ax + w - 1, y, fc | 216);
		}
		for(int x = ax; x < ax + w; x++) {
			screen.setChar(x, ay, fc | 192);
			screen.setChar(x, ay + h - 1, fc | 192);
		}
		screen.setChar(ax, ay, fc | 201);
		screen.setChar(ax + w - 1, ay, fc | 215);
		screen.setChar(ax, ay + h - 1, fc | 195);
		screen.setChar(ax + w - 1, ay + h - 1, fc | 212);
	}

	// --- Completeness assertion ----------------------------------------------

	void assertCategoryCoverage() {
		string[] mapped = ["File", "Application", "Edit", "Song management",
						   "Song variables", "Display", "Playback",
						   "Playback options", "Voice control", "Keyjam",
						   "Window navigation", "Help"];
		foreach(cat; sm.categoriesForContext(cast(string)Ctx.global)) {
			bool found = false;
			foreach(m; mapped) if(m == cat) { found = true; break; }
			assert(found, "MenuBar: unmapped global category '" ~ cat ~
				   "' — add it to a menu in ui.menubar so the command stays reachable.");
		}
	}
}
