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
import std.algorithm : max, sort;
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
		Shortcut primary;    // primary binding (rendered with dim separators)
		bool enabled;
		bool toggle;         // boolean toggle -> draw a checkbox
		bool on;             // toggle current state
		int order;           // registration order, for stable sorting
		string description;  // full help sentence, shown as a hover tooltip
	}
	struct DMenu {
		string title;
		Item[] items;
	}
	DMenu[] menus;
	int[] titleX;                  // x of each top-level title, set by drawBar

	// Geometry of the currently drawn dropdown box (for mouse hit-testing).
	int boxX, boxY, boxW, boxH;

	// Save-under buffer: the screen cells beneath the dropdown, so the menu can
	// be erased without a full screen clear (which would blink the SID register
	// readout on the right). Only ever covers the dropdown's own rectangle.
	Uint32[] under;
	int uX, uY, uW, uH;
	bool hasUnder;
	int lastX, lastY, lastW, lastH;   // last drawn box (detect move/resize)
	bool drawn;

	// Hover tooltip: after the selection has been steady for ~1s, the focused
	// item's full description is shown to the right of the menu, with its own
	// save-under buffer (disjoint from the dropdown's, so neither disturbs the
	// SID register readout on the right).
	enum uint TOOLTIP_DELAY_MS = 1000;
	uint tipDeadline;
	Uint32[] tipUnder;
	int tpX, tpY, tpW, tpH;
	bool hasTip;

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
		resetTip();
		// No screen clear: drawDropdown captures the cells it covers (save-under)
		// and restores them on move/close, so the rest of the screen — notably
		// the SID register readout on the right — is never touched.
	}

	void close() {
		if(!_active) return;
		_active = false;
		if(hasTip) restoreTip();
		if(hasUnder) restoreUnder();   // erase the dropdown, no full-screen clear
		drawn = false;
	}

	// Restart the hover timer and hide any visible tooltip (call on every
	// selection change so the tooltip only appears after ~1s of dwell).
	private void resetTip() {
		tipDeadline = SDL_GetTicks() + TOOLTIP_DELAY_MS;
		if(hasTip) restoreTip();
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

	static int shortcutWidth(Shortcut sc) {
		return sc.isValid ? cast(int)formatShortcut(sc).length : 0;
	}

	// Render a shortcut at (x,y): modifier/key names in keyFg, the joining
	// hyphens in a subtler sepFg (built from the Shortcut's mods+key, so the
	// literal '-' key is never confused with a separator). Layout matches
	// formatShortcut(), so its width == shortcutWidth(sc).
	void drawShortcut(int x, int y, Shortcut sc, int keyFg, int sepFg, int bg) {
		int cx = x;
		void seg(string s, int fg) { screen.cprint(cx, y, fg, bg, s); cx += cast(int)s.length; }
		bool need = false;
		if(sc.mods & KMOD_CTRL)  { seg("Ctrl", keyFg); need = true; }
		if(sc.mods & KMOD_ALT)   { if(need) seg("-", sepFg); seg("Alt", keyFg); need = true; }
		if(sc.mods & KMOD_SHIFT) { if(need) seg("-", sepFg); seg("Shift", keyFg); need = true; }
		if(sc.mods & KMOD_GUI)   { if(need) seg("-", sepFg); seg("Cmd", keyFg); need = true; }
		if(need) seg("-", sepFg);
		seg(keyName(sc.key), keyFg);
	}

	/// The condensed dropdown box under the active title. Uses a save-under
	/// buffer so it can be erased without clearing (and blinking) the rest of
	/// the screen — notably the SID register readout on the right.
	void drawDropdown() {
		if(!_active || menuIndex >= cast(int)menus.length
		   || menus[menuIndex].items.length == 0) {
			if(hasTip) restoreTip();
			if(hasUnder) restoreUnder();
			drawn = false;
			boxW = 0;
			return;
		}
		auto m = menus[menuIndex];

		// One space of padding inside each border; >=2 spaces between columns.
		// Toggles get their own aligned checkbox column.
		enum PAD = 1, GAP = 2, CB = 3;
		int labelW = 0, shortW = 0;
		bool hasToggle = false;
		foreach(it; m.items) {
			if(it.sep) continue;
			labelW = max(labelW, cast(int)it.label.length);
			shortW = max(shortW, shortcutWidth(it.primary));
			if(it.toggle) hasToggle = true;
		}
		int content = labelW;
		if(hasToggle) content += GAP + CB;
		if(shortW > 0) content += GAP + shortW;
		int w = content + 2 * PAD + 2;          // padding + left/right border
		if(w < cast(int)m.title.length + 2) w = cast(int)m.title.length + 2;
		int h = cast(int)m.items.length + 2;    // + top/bottom border
		int bx = (menuIndex < cast(int)titleX.length) ? titleX[menuIndex] : 2;
		if(bx + w > screen.width) bx = screen.width - w;
		if(bx < 1) bx = 1;
		int by = 1;
		boxX = bx; boxY = by; boxW = w; boxH = h;

		// Save-under: snapshot the covered cells on first show / move / resize.
		if(!drawn || bx != lastX || by != lastY || w != lastW || h != lastH) {
			if(hasTip) restoreTip();
			if(hasUnder) restoreUnder();
			captureUnder(bx, by, w, h);
			lastX = bx; lastY = by; lastW = w; lastH = h;
			drawn = true;
		}

		frame(bx, by, h, w);
		int labelX = bx + 1 + PAD;
		int cbX = labelX + labelW + GAP;        // fixed, aligned checkbox column
		foreach(i, it; m.items) {
			int ry = by + 1 + cast(int)i;
			if(it.sep) {
				// A faint inset rule, not the bright green frame colour.
				foreach(cx; bx + 1 .. bx + w - 1)
					screen.setChar(cx, ry, cast(Uint32)(0x20));        // clear pad
				foreach(cx; labelX .. bx + w - 1 - PAD)
					screen.setChar(cx, ry, 0x0b00 | 192);              // colour 11
				continue;
			}
			bool hl = cast(int)i == itemIndex;
			int rbg = hl ? 4 : 0;                                      // purple bar
			foreach(cx; bx + 1 .. bx + w - 1)
				screen.setChar(cx, ry, cast(Uint32)(0x20 | (rbg << 16)));
			int lfg = hl ? 1 : (it.enabled ? 15 : 8);
			screen.cprint(labelX, ry, lfg, rbg, it.label);
			if(it.toggle)
				screen.cprint(cbX, ry, hl ? 1 : (it.on ? 13 : 8), rbg,
							  it.on ? "[x]" : "[ ]");
			if(it.primary.isValid) {
				int sw = shortcutWidth(it.primary);
				int sx = bx + w - 1 - PAD - sw;       // right-aligned
				drawShortcut(sx, ry, it.primary,
							 hl ? 1 : (it.enabled ? 12 : 8),   // key colour
							 hl ? 15 : 11,                     // separator colour
							 rbg);
			}
		}

		drawTooltip(bx, by, w, m);
	}

	// After the selection has dwelt ~1s, show the focused item's full
	// description as a single-row tooltip to the right of the box. Own
	// save-under; clamped left of the SID register column on rows 1..3.
	void drawTooltip(int bx, int by, int w, DMenu m) {
		bool show = _active && SDL_GetTicks() >= tipDeadline
			&& itemIndex >= 0 && itemIndex < cast(int)m.items.length
			&& !m.items[itemIndex].sep && m.items[itemIndex].description.length > 0;
		if(!show) { if(hasTip) restoreTip(); return; }
		int ry = by + 1 + itemIndex;
		int regX = screen.width - 42;
		int limit = (ry >= 1 && ry <= 3) ? regX - 1 : screen.width - 1;
		int tipX = bx + w;                       // immediately right of the box
		string text = " " ~ m.items[itemIndex].description ~ " ";
		int avail = limit - tipX + 1;
		if(avail < 6) { if(hasTip) restoreTip(); return; }
		if(cast(int)text.length > avail) text = text[0 .. avail];
		int tw = cast(int)text.length;
		if(!hasTip || tpX != tipX || tpY != ry || tpW != tw) {
			if(hasTip) restoreTip();
			captureTip(tipX, ry, tw);
		}
		screen.cprint(tipX, ry, 0, 15, text);    // black on light grey
	}

	void captureTip(int x, int y, int w) {
		tipUnder.length = w;
		foreach(k; 0 .. w) tipUnder[k] = screen.getChar(x + k, y);
		tpX = x; tpY = y; tpW = w; tpH = 1;
		hasTip = true;
	}

	void restoreTip() {
		if(!hasTip) return;
		foreach(k; 0 .. tpW) screen.setChar(tpX + k, tpY, tipUnder[k]);
		hasTip = false;
	}

	// Save / restore the screen cells beneath the dropdown rectangle.
	void captureUnder(int x, int y, int w, int h) {
		under.length = w * h;
		int k = 0;
		foreach(yy; y .. y + h)
			foreach(xx; x .. x + w)
				under[k++] = screen.getChar(xx, yy);
		uX = x; uY = y; uW = w; uH = h;
		hasUnder = true;
	}

	void restoreUnder() {
		if(!hasUnder) return;
		int k = 0;
		foreach(yy; uY .. uY + uH)
			foreach(xx; uX .. uX + uW)
				screen.setChar(xx, yy, under[k++]);
		hasUnder = false;
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
		case SDLK_SPACE:
			toggleCurrent();
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
					resetTip();
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
		addGlobalMenu("Navigate", ["Window navigation"]);
		addContextMenus();
		addGlobalMenu("Help", ["Help"]);
		clampIndices();
	}

	Item makeItem(ActionDef def) {
		bool en = def.enabled is null || def.enabled();
		bool tog = def.checked !is null;
		bool on = tog && def.checked();
		return Item(def.actionId, false, def.label(), def.primary, en, tog, on,
					def.order, def.description);
	}

	// Append the items of `categories` (in order) from one context, separating
	// non-empty groups with a ruler. Items within a group are shown in
	// registration order (not alphabetical), e.g. Undo before Redo.
	Item[] gather(string context, string[] categories, bool leadSep) {
		Item[] items;
		bool first = !leadSep;
		foreach(cat; categories) {
			Item[] group;
			foreach(def; sm.actionsForContext(context))
				if(def.category == cat)
					group ~= makeItem(def);
			if(group.length) {
				group.sort!((a, b) => a.order < b.order);
				if(!first) items ~= Item("", true, "", Shortcut(0, 0), false,
										 false, false, 0, "");
				items ~= group;
				first = false;
			}
		}
		return items;
	}

	void addGlobalMenu(string title, string[] categories) {
		menus ~= DMenu(title, gather(cast(string)Ctx.global, categories, false));
	}

	// The shared sequencer commands (F5/F6/F7 columns) grouped as one "Sequence"
	// menu. Used by the note, track and overview contexts.
	private void addSequenceMenu() {
		auto items = gather(cast(string)Ctx.sequencer,
							sm.categoriesForContext(cast(string)Ctx.sequencer), false);
		if(items.length) menus ~= DMenu("Sequence", items);
	}

	// Emit the context-specific top-level menus (inserted before Help). The F6
	// note column splits into a note-level "Note" menu and a "Sequence" menu;
	// the F5 track column shows "Track" + "Sequence"; the F7 overview shows just
	// "Sequence"; the instrument list and sub-tables get their own single menu.
	void addContextMenus() {
		string ctx = sm.getActiveContext();
		if(ctx == Ctx.noteColumn) {
			auto note = gather(cast(string)Ctx.noteColumn, ["Note"], false);
			if(note.length) menus ~= DMenu("Note", note);
			// "Sequence" = the note column's sequence-level commands + the shared
			// sequencer commands.
			auto seq = gather(cast(string)Ctx.noteColumn, ["Sequence"], false);
			seq ~= gather(cast(string)Ctx.sequencer,
						  sm.categoriesForContext(cast(string)Ctx.sequencer),
						  seq.length > 0);
			if(seq.length) menus ~= DMenu("Sequence", seq);
		}
		else if(ctx == Ctx.trackColumn) {
			auto trk = gather(cast(string)Ctx.trackColumn,
							  sm.categoriesForContext(cast(string)Ctx.trackColumn), false);
			if(trk.length) menus ~= DMenu("Track", trk);
			addSequenceMenu();
		}
		else if(ctx == Ctx.sequencer) {
			addSequenceMenu();
		}
		else if(ctx == Ctx.instrumentTable) {
			auto ins = gather(cast(string)Ctx.instrumentTable,
							  sm.categoriesForContext(cast(string)Ctx.instrumentTable), false);
			if(ins.length) menus ~= DMenu("Instrument", ins);
		}
		else if(ctx == Ctx.subtable) {
			auto tbl = gather(cast(string)Ctx.subtable,
							  sm.categoriesForContext(cast(string)Ctx.subtable), false);
			if(tbl.length) menus ~= DMenu("Tables", tbl);
		}
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
		resetTip();
		// The box moves/resizes; drawDropdown notices and restores the old box's
		// save-under before drawing the new one (no full-screen clear).
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
				resetTip();
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

	// Space on a toggle item: flip it but KEEP the menu open (Enter-and-close
	// stays available for the same item). No-op on non-toggles.
	void toggleCurrent() {
		if(menuIndex >= cast(int)menus.length) return;
		auto items = menus[menuIndex].items;
		if(itemIndex < 0 || itemIndex >= cast(int)items.length) return;
		auto it = items[itemIndex];
		if(it.sep || !it.enabled || !it.toggle) return;
		auto def = sm.getAction(it.actionId);
		if(def is null || (def.enabled !is null && !def.enabled())) return;
		// Erase the menu (restore both save-unders) before the callback runs:
		// it may repaint the screen beneath the box (statusline message,
		// fullscreen re-init). The next drawDropdown then recaptures a fresh
		// save-under, so closing the menu later cannot restore stale content.
		if(hasTip) restoreTip();
		if(hasUnder) restoreUnder();
		drawn = false;
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
