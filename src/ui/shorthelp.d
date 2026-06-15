/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Generates user-facing help (the F12 ContextHelp pages) and a Markdown keyboard
reference from the single shortcut registry in com.shortcuts. Keeping this in a
ui-level module avoids a com -> ui dependency cycle: com.shortcuts stays free of
ui.help, while this module bridges the registry to ContextHelp / Markdown.
*/

module ui.shorthelp;

import std.array : replicate, appender;
import std.string : format;
import std.algorithm : max;
import com.shortcuts;
import ui.help : ContextHelp;

// Fixed context order + human titles for documentation output.
private struct CtxTitle { string ctx; string title; }
private immutable CtxTitle[] CONTEXT_ORDER = [
	CtxTitle(Ctx.global,          "Global"),
	CtxTitle(Ctx.sequencer,       "Sequencer (all columns)"),
	CtxTitle(Ctx.noteColumn,      "Sequencer: note column (F6)"),
	CtxTitle(Ctx.trackColumn,     "Sequencer: track column (F5)"),
	CtxTitle(Ctx.instrumentTable, "Instrument table"),
	CtxTitle(Ctx.subtable,        "Wave / pulse / filter tables"),
	CtxTitle(Ctx.songInfo,        "Song info"),
];

private enum LEADER_WIDTH = 24;   // column where the description starts
private enum PAGE_ROWS = 30;      // lines per help page (HelpDialog ~36 tall)

/// Formats one "Ctrl-F1.........Description" help line with a dotted leader.
/// `keys` may list several shortcuts (e.g. "Alt-4 / Alt-I").
private string helpLine(string keys, string desc) {
	int pad = max(2, LEADER_WIDTH - cast(int)keys.length);
	return keys ~ replicate(".", pad) ~ desc;
}

/// Markdown rendering of a shortcut list: each in its own code span, joined
/// by " / " (e.g. `Alt-B` / `Ctrl-I`).
private string mdShortcuts(Shortcut[] scs) {
	import std.array : join;
	string[] parts;
	foreach(sc; scs)
		if(sc.isValid) parts ~= "`" ~ formatShortcut(sc) ~ "`";
	return parts.join(" / ");
}

/// Platform-specific input notes (from the key translation in com/kbd.d).
string[] platformNotes() {
	return [
		"macOS: the Cmd key acts as Ctrl+Shift for any shortcut.",
		"macOS: Cmd+1..9 act as the numeric keypad 1..9.",
		"macOS: Cmd+Up / Cmd+Down act as Shift+Home / Shift+End.",
		"macOS: F11 may be intercepted by the system (Show Desktop).",
	];
}

/**
 * Builds a ContextHelp (possibly multi-page) for the given contexts, grouping
 * by category. When isContextHelp is true the first page is prefixed with the
 * "press F12 again" hint, matching the previous hand-written sequencer help.
 */
ContextHelp genContextHelp(ShortcutManager sm, string title, string[] contexts,
						   bool isContextHelp = false, bool withPlatformNotes = false) {
	string[] pages;
	auto page = appender!string();
	int rows = 0;

	void flushPage() {
		if(page.data.length) {
			pages ~= page.data.idup;
			page = appender!string();
			rows = 0;
		}
	}
	void emit(string line, int cost = 1) {
		if(rows + cost > PAGE_ROWS) flushPage();
		page.put(line);
		page.put("\n");
		rows += cost;
	}

	if(isContextHelp) {
		page.put("`+1Press F12 again to see the global help.\n\n");
		rows += 2;
	}

	bool any = false;
	foreach(ctx; contexts) {
		foreach(cat; sm.categoriesForContext(ctx)) {
			emit(format("`+d%s", cat), 2);
			foreach(def; sm.actionsForContext(ctx)) {
				if(def.category != cat) continue;
				any = true;
				emit("`0f" ~ helpLine(formatShortcuts(sm.getShortcuts(def.actionId)),
									  def.description));
			}
			emit("");
		}
	}
	if(!any)
		emit("(no shortcuts registered)");

	if(withPlatformNotes) {
		emit("`+dPlatform notes", 2);
		foreach(n; platformNotes())
			emit("`0f" ~ n);
	}
	flushPage();

	return ContextHelp(title, pages);
}

/// Convenience builders for the two primary help screens.
ContextHelp genMainHelp(ShortcutManager sm) {
	return genContextHelp(sm, "Main help", [cast(string)Ctx.global], false, true);
}

ContextHelp genSequencerHelp(ShortcutManager sm) {
	return genContextHelp(sm, "Sequencer help",
		[cast(string)Ctx.sequencer, cast(string)Ctx.noteColumn,
		 cast(string)Ctx.trackColumn], true);
}

/**
 * Renders the full keyboard reference as Markdown, one section per context.
 * Intended for `ccutter --dump-keys > doc/KEYBOARD.md`.
 */
string exportMarkdown(ShortcutManager sm) {
	auto md = appender!string();
	md.put("# CheeseCutter keyboard reference\n\n");
	md.put("_Generated from the shortcut registry (com.shortcuts)._\n\n");
	foreach(ct; CONTEXT_ORDER) {
		auto defs = sm.actionsForContext(ct.ctx);
		if(defs.length == 0) continue;
		md.put(format("## %s\n\n", ct.title));
		foreach(cat; sm.categoriesForContext(ct.ctx)) {
			if(cat.length)
				md.put(format("### %s\n\n", cat));
			md.put("| Shortcut | Action |\n|---|---|\n");
			foreach(def; defs) {
				if(def.category != cat) continue;
				md.put(format("| %s | %s |\n",
							  mdShortcuts(sm.getShortcuts(def.actionId)),
							  def.description));
			}
			md.put("\n");
		}
	}
	md.put("## Platform notes\n\n");
	foreach(n; platformNotes())
		md.put(format("- %s\n", n));
	md.put("\n");
	return md.data;
}
