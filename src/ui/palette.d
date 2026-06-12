/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Command palette: a VS-Code-style "> " prompt that searches every command
reachable from the current focus plus the .ct/.ct2 songs in the current
directory, case-insensitively, by name/description.

Opened by pressing Esc (which focuses the menu bar) and starting to type: the
first printable character closes the bar and seeds the query (Space excepted —
it toggles menu checkboxes). Also reachable as Help > Command palette.

Like the menu dropdown, the palette is an overlay with a save-under buffer, so
it can be erased without a full-screen clear (which would blink the SID
register readout on the right). It holds NO command definitions of its own:
candidates are enumerated from the shortcut registry (com.shortcuts) over the
active context's dispatch chain, and selecting one invokes the very same
ActionDef.callback() the keyboard shortcut and the menus use.
*/

module ui.palette;

import derelict.sdl2.sdl;
import std.algorithm : max, min, sort;
import std.file : dirEntries, getcwd, isDir, FileException, SpanMode;
import std.path : baseName, extension;
import std.string : indexOf, toLower, CaseSensitive;
import com.session;      // screen
import com.shortcuts;
import ui.input : Keyinfo;
import ui.menubar : MenuBar;
import ui.ui : UI;

final class CommandPalette {
	private:
	UI mainUi;
	ShortcutManager sm;
	bool _active;
	string query;
	int sel;                       // index into the shown slice of matches

	// A candidate: either a registered command or a loadable song file.
	struct Entry {
		bool isFile;
		string actionId;     // commands only
		string label;        // ActionDef.label() / file name
		string description;  // full help sentence ("" for files)
		string category;
		Shortcut primary;
		int order;           // registration order / directory order
		int rank;            // match quality, filled by refilter()
	}
	Entry[] candidates;            // rebuilt on open()
	Entry[] matches;               // refiltered on every keystroke

	enum MAX_SHOWN = 10;
	enum PAD = 1, GAP = 2;
	enum HINT = "type to search commands and songs";

	// Save-under buffer: the screen cells beneath the box (same discipline as
	// the menu dropdown), so closing never needs a full-screen clear.
	Uint32[] under;
	int uX, uY, uW, uH;
	bool hasUnder;
	int lastX, lastY, lastW, lastH;   // last drawn box (detect move/resize)
	bool drawn;

	// Geometry of the currently drawn box (for mouse hit-testing).
	int boxX, boxY, boxW, boxH;

	public:

	this(UI ui, ShortcutManager mgr) {
		mainUi = ui;
		sm = mgr;
	}

	@property bool active() const { return _active; }

	/// Open with an initial query (may be empty), e.g. the character typed
	/// while the menu bar was focused.
	void open(string seed) {
		buildCandidates();
		query = seed;
		sel = 0;
		refilter();
		_active = true;
	}

	void close() {
		if(!_active) return;
		_active = false;
		if(hasUnder) restoreUnder();
		drawn = false;
	}

	// --- Input ---------------------------------------------------------------

	int keypress(Keyinfo key) {
		switch(key.raw) {
		case SDLK_ESCAPE:
			close();
			break;
		case SDLK_BACKSPACE:
			if(query.length == 0) close();
			else { query = query[0 .. $ - 1]; refilter(); }
			break;
		case SDLK_UP:
			moveSel(-1);
			break;
		case SDLK_DOWN:
			moveSel(1);
			break;
		case SDLK_RETURN, SDLK_KP_ENTER:
			invokeCurrent();
			break;
		default:
			if(key.unicode >= 0x20 && key.unicode < 0x7f
			   && !(key.mods & (KMOD_CTRL | KMOD_ALT | KMOD_GUI))) {
				query ~= cast(char)key.unicode;
				refilter();
			}
			break;
		}
		return 0;
	}

	void clickedAt(int x, int y, int button, int clicks) {
		if(button != SDL_BUTTON_LEFT) return;
		// Suggestion rows start one below the query row (boxY+1 = query).
		if(boxW > 0 && x > boxX && x < boxX + boxW - 1
		   && y > boxY && y < boxY + boxH - 1) {
			int idx = y - (boxY + 2);
			if(idx >= 0 && idx < shownCount()) {
				sel = idx;
				invokeCurrent();
			}
			return;             // clicks on the query/hint rows are ignored
		}
		close();
	}

	// --- Drawing ---------------------------------------------------------------

	/// Repaint the whole box; called from UI.drawMenu on every timer event so
	/// the statusline timeout (row 2 runs through the box) never blanks it.
	void draw() {
		if(!_active) {
			if(hasUnder) restoreUnder();
			drawn = false;
			boxW = 0;
			return;
		}

		int shown = shownCount();
		// Width: fit the prompt and the widest "label + gap + shortcut" row,
		// clamped left of the SID register readout (rows 1-3, screen.width-42).
		int desired = cast(int)query.length + 3;     // "> " + query + cursor
		desired = max(desired, cast(int)HINT.length);
		foreach(i; 0 .. shown) {
			auto e = matches[i];
			int rw = cast(int)e.label.length + GAP + rightTagWidth(e);
			desired = max(desired, rw);
		}
		int bx = 2, by = 1;
		int w = desired + 2 * PAD + 2;               // padding + borders
		w = max(w, 40);
		w = min(w, min(70, screen.width - 44));
		int h = 2 + 1 + max(1, shown);               // frame + query row + rows
		boxX = bx; boxY = by; boxW = w; boxH = h;

		// Save-under: snapshot the covered cells on first show / resize.
		if(!drawn || bx != lastX || by != lastY || w != lastW || h != lastH) {
			if(hasUnder) restoreUnder();
			captureUnder(bx, by, w, h);
			lastX = bx; lastY = by; lastW = w; lastH = h;
			drawn = true;
		}

		frame(bx, by, h, w);
		int innerX = bx + 1 + PAD;
		int innerW = w - 2 - 2 * PAD;

		// Query row: "> query" + a block cursor; show the tail when too long.
		int qy = by + 1;
		foreach(cx; bx + 1 .. bx + w - 1)
			screen.setChar(cx, qy, cast(Uint32)0x20);
		string q = query;
		int qavail = innerW - 3;
		if(cast(int)q.length > qavail) q = q[$ - qavail .. $];
		screen.cprint(innerX, qy, 1, 0, "> " ~ q);
		screen.setChar(innerX + 2 + cast(int)q.length, qy,
					   cast(Uint32)(0x20 | (1 << 16)));

		if(shown == 0) {
			int ry = by + 2;
			foreach(cx; bx + 1 .. bx + w - 1)
				screen.setChar(cx, ry, cast(Uint32)0x20);
			string msg = query.length ? "no matches" : HINT;
			if(cast(int)msg.length > innerW) msg = msg[0 .. innerW];
			screen.cprint(innerX, ry, 8, 0, msg);
			return;
		}

		foreach(i; 0 .. shown) {
			auto e = matches[i];
			int ry = by + 2 + i;
			bool hl = i == sel;
			int rbg = hl ? 4 : 0;                    // purple selection bar
			foreach(cx; bx + 1 .. bx + w - 1)
				screen.setChar(cx, ry, cast(Uint32)(0x20 | (rbg << 16)));
			int tagW = rightTagWidth(e);
			int lavail = innerW - (tagW ? GAP + tagW : 0);
			string label = e.label;
			if(cast(int)label.length > lavail) label = label[0 .. lavail];
			screen.cprint(innerX, ry, hl ? 1 : (e.isFile ? 13 : 15), rbg, label);
			if(e.isFile) {
				screen.cprint(bx + w - 1 - PAD - tagW, ry,
							  hl ? 15 : 11, rbg, "load");
			}
			else if(e.primary.isValid) {
				mainUi.menubar.drawShortcut(bx + w - 1 - PAD - tagW, ry, e.primary,
										hl ? 1 : 12,      // key colour
										hl ? 15 : 11,     // separator colour
										rbg);
			}
		}
	}

	// --- Candidates & matching -------------------------------------------------

	private:

	void buildCandidates() {
		candidates.length = 0;
		// Every command dispatchable from the current focus: the active
		// context's fallback chain, then global. Disabled actions are hidden
		// ("executable right now" semantics); the palette itself and the no-op
		// screenshot action (handled in main.d before translation) are skipped.
		foreach(ctx; sm.contextChain()) {
			foreach(def; sm.actionsForContext(ctx)) {
				if(def.actionId == "open_palette" || def.actionId == "screenshot")
					continue;
				if(def.enabled !is null && !def.enabled())
					continue;
				candidates ~= Entry(false, def.actionId, def.label(),
									def.description, def.category, def.primary,
									def.order);
			}
		}
		// The .ct/.ct2 songs in the current directory (= the load/save
		// dialogs' directory); selecting one loads it.
		int forder = 0;
		try {
			foreach(entry; dirEntries(getcwd(), SpanMode.shallow)) {
				string name = baseName(entry.name);
				if(name.length == 0 || name[0] == '.' || name[0] == '#')
					continue;
				string ext = extension(name).toLower;
				if(ext != ".ct" && ext != ".ct2")
					continue;
				try {
					if(entry.name.isDir()) continue;
				}
				catch(FileException) { continue; }   // dangling symlink etc.
				candidates ~= Entry(true, "", name, "", "", Shortcut(0, 0),
									forder++);
			}
		}
		catch(FileException) {}
	}

	// True when the match at idx begins a word (start of string, or preceded
	// by a separator: space in prose, '-'/'_'/'.' in filenames).
	static bool wordStart(string s, ptrdiff_t idx) {
		import std.ascii : isAlphaNum;
		return idx == 0 || (idx > 0 && !isAlphaNum(s[idx - 1]));
	}

	// Match quality: 0 = label prefix, 1 = word start in label/description,
	// 2 = substring anywhere (incl. category), -1 = no match.
	static int rankEntry(ref Entry e, string q) {
		ptrdiff_t li = e.label.indexOf(q, CaseSensitive.no);
		if(li == 0) return 0;
		if(li > 0 && wordStart(e.label, li)) return 1;
		if(e.isFile) return li >= 0 ? 2 : -1;
		ptrdiff_t di = e.description.indexOf(q, CaseSensitive.no);
		if(di >= 0 && wordStart(e.description, di)) return 1;
		if(li >= 0 || di >= 0) return 2;
		if(e.category.indexOf(q, CaseSensitive.no) >= 0) return 2;
		return -1;
	}

	void refilter() {
		matches.length = 0;
		if(query.length) {
			foreach(e; candidates) {
				e.rank = rankEntry(e, query);
				if(e.rank >= 0) matches ~= e;
			}
			// Better rank first; commands before files; registration order.
			matches.sort!((a, b) =>
				a.rank != b.rank ? a.rank < b.rank :
				(a.isFile != b.isFile ? !a.isFile : a.order < b.order));
		}
		int n = shownCount();
		if(sel >= n) sel = n ? n - 1 : 0;
		if(sel < 0) sel = 0;
	}

	int shownCount() {
		return min(cast(int)matches.length, MAX_SHOWN);
	}

	static int rightTagWidth(ref Entry e) {
		if(e.isFile) return 4;                       // "load"
		return MenuBar.shortcutWidth(e.primary);
	}

	void moveSel(int dir) {
		int n = shownCount();
		if(n == 0) return;
		sel = ((sel + dir) % n + n) % n;
	}

	void invokeCurrent() {
		int n = shownCount();
		if(n == 0) { close(); return; }
		auto e = matches[sel];
		// Close BEFORE invoking: the callback may open a dialog or repaint,
		// and the save-under must be restored first (same as the menu).
		close();
		if(e.isFile) {
			mainUi.loadCallback(e.label);                // file is in getcwd()
		}
		else {
			auto def = sm.getAction(e.actionId);
			if(def !is null && (def.enabled is null || def.enabled()))
				def.callback();
		}
	}

	// --- Save-under & frame (same self-contained pattern as MenuBar) ----------

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
}
