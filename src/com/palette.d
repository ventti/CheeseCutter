/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Semantic, JSON-configurable color palette — base C64 colors plus UI roles.

The renderer stores fg/bg as small integer indices into a 32-entry RGB table
(`PALETTE`): 0..15 are the base C64 colors, 16..31 a fixed brightness gradient
(mid-blue -> black) used for the ADSR/playback fade. Historically both the RGB
values and the "which index means what" choices were hardcoded all over the UI.

This module makes the palette data-driven without changing that index model:

  * `PALETTE` (moved here from com.fb) holds the runtime RGB values. It defaults
    to the classic C64 colors, so with no config file the editor looks exactly
    as before.
  * A two-tier JSON config redefines them. Tier 1 `colors` remaps the 16 named
    base colors to arbitrary hex; tier 2 `roles` points each semantic UI role
    (background, cursor, frame, playbackBar, ...) at a base color. Code refers to
    roles via `idx(Role.x)` instead of magic numbers.

Loading: `initPalette(explicitFile)` resolves the file (an explicit --palette
path wins, else the per-user default `~/.config/cheesecutter/palette.json`),
applies it over the built-in defaults, and degrades gracefully to the defaults
(with a stderr warning) on any error. See doc/palette.json for the schema.
*/

module com.palette;

import derelict.sdl2.sdl : SDL_Color;
import std.stdio : stderr;

enum int NUM_BASE = 16;    // C64 base colors, indices 0..15
enum int NUM_TOTAL = 32;   // + brightness gradient, indices 16..31

// The 16 base C64 colors, named neutrally by hue rather than by any UI purpose.
// The integer value is the palette index the name resolves to by default.
enum BaseColor : int {
	black = 0, white = 1, red = 2, cyan = 3, purple = 4, green = 5,
	blue = 6, yellow = 7, orange = 8, brown = 9, lightred = 10, darkgray = 11,
	gray = 12, lightgreen = 13, lightblue = 14, lightgray = 15
}

// JSON key <-> BaseColor. Kept explicit (not `to!BaseColor`) so the config
// vocabulary is stable and independent of the enum member spelling.
private immutable BaseColor[string] baseColorByName;

// Semantic UI roles. Each maps to a base color index (see `defaultRoleBase`),
// which JSON `roles` can override. Add a role here + a default + a name entry
// when you give a new UI element a configurable color.
enum Role : int {
	background,        // the editor backdrop / default cell bg
	text,              // default light text
	cursor,            // edit cursor / current-row highlight
	frame,             // window/box frame lines
	playbackBar,       // the row the player is on
	wrapBar,           // pattern wrap indicator bar
	selectionBar,      // block-selection highlight bar
	activeInstrument,  // instrument number of the playing voice
	filterStatic,      // filter value taken verbatim from the table
	filterCalc,        // filter cutoff being swept/calculated
	filterEmpty,       // in-song filter row with no active value
	filterHeader,      // filter table header
	keyjamBg,          // whole-screen background tint while keyjam mode is active
	keyjamTag,         // "KEYJAM" mode badge text in the top bar
	soundeditSelection, // Sound Editor time-range selection overlay (translucent)
	soundeditValue,       // Sound Editor parameter values (yellow)
	buttonLabel,          // clickable button label, resting state
	buttonBg,             // clickable button background, resting state
	buttonHoverLabel,     // button label while the pointer hovers it
	buttonHoverBg,        // button background while hovered
	buttonPressLabel,     // button label while pressed (the "click" look)
	buttonPressBg,        // button background while pressed
	buttonActiveLabel,    // button label in its persistent "on"/current state
	buttonActiveBg,       // button background in its "on"/current state
	buttonDisabledLabel,  // button label when greyed out / not clickable
	soundeditScrollTrack, // Sound Editor scrollbar track (darkgray, dotted)
	soundeditScrollThumb, // Sound Editor scrollbar thumb (mid-gray)
	soundeditSelEdge,     // Sound Editor selection edges (lightblue)
	soundeditDim,         // Sound Editor dimmed idle-preview / dim fills (darkgray)
}

// JSON key <-> Role. Same rationale as baseColorByName.
private immutable Role[string] roleByName;

// Default role -> base color index. This reproduces the historical hardcoded
// choices exactly, so the built-in palette renders identically to before.
private immutable int[Role.max + 1] defaultRoleBase = [
	Role.background:       BaseColor.black,
	Role.text:             BaseColor.lightgray,
	Role.cursor:           BaseColor.white,
	Role.frame:            BaseColor.green,
	Role.playbackBar:      BaseColor.blue,
	Role.wrapBar:          BaseColor.purple,
	Role.selectionBar:     BaseColor.green,
	Role.activeInstrument: BaseColor.cyan,
	Role.filterStatic:     BaseColor.lightgray,
	Role.filterCalc:       BaseColor.gray,
	Role.filterEmpty:      BaseColor.darkgray,
	Role.filterHeader:     BaseColor.darkgray,
	Role.keyjamBg:         BaseColor.blue,
	Role.keyjamTag:        BaseColor.yellow,
	Role.soundeditSelection: BaseColor.blue,
	Role.soundeditValue:       BaseColor.yellow,
	Role.buttonLabel:          BaseColor.lightgray,
	Role.buttonBg:             BaseColor.darkgray,
	Role.buttonHoverLabel:     BaseColor.white,
	Role.buttonHoverBg:        BaseColor.gray,
	Role.buttonPressLabel:     BaseColor.black,
	Role.buttonPressBg:        BaseColor.lightgray,
	Role.buttonActiveLabel:    BaseColor.white,
	Role.buttonActiveBg:       BaseColor.blue,
	Role.buttonDisabledLabel:  BaseColor.gray,
	Role.soundeditScrollTrack: BaseColor.darkgray,
	Role.soundeditScrollThumb: BaseColor.gray,
	Role.soundeditSelEdge:     BaseColor.lightblue,
	Role.soundeditDim:         BaseColor.darkgray,
];

// Built-in RGB values: 0..15 classic C64, 16..31 the mid-blue->black gradient
// used for the ADSR/playback fade. Copied verbatim from the old com.fb table.
private immutable ubyte[3][NUM_TOTAL] defaultRgb = [
	[0x00, 0x00, 0x00],  //  0 black
	[0xfe, 0xfe, 0xfe],  //  1 white
	[0x81, 0x33, 0x37],  //  2 red
	[0x75, 0xce, 0xc8],  //  3 cyan
	[0x8d, 0x3b, 0x97],  //  4 purple
	[0x55, 0xac, 0x4d],  //  5 green
	[0x2d, 0x2b, 0x9a],  //  6 blue
	[0xed, 0xf0, 0x71],  //  7 yellow
	[0x8d, 0x50, 0x29],  //  8 orange
	[0x54, 0x37, 0x00],  //  9 brown
	[0xc4, 0x6c, 0x71],  // 10 lightred
	[0x49, 0x49, 0x49],  // 11 darkgray
	[0x7b, 0x7b, 0x7b],  // 12 gray
	[0xa9, 0xfe, 0x9f],  // 13 lightgreen
	[0x6f, 0x6d, 0xeb],  // 14 lightblue
	[0xb1, 0xb1, 0xb1],  // 15 lightgray
	// 16..31 brightness gradient (step 15/15 halved down to black)
	[0x18, 0x18, 0x48], [0x16, 0x16, 0x42], [0x14, 0x14, 0x3C], [0x12, 0x12, 0x36],
	[0x10, 0x10, 0x30], [0x0E, 0x0E, 0x2A], [0x0C, 0x0C, 0x24], [0x0A, 0x0A, 0x1E],
	[0x08, 0x08, 0x18], [0x06, 0x06, 0x12], [0x04, 0x04, 0x0C], [0x03, 0x03, 0x09],
	[0x02, 0x02, 0x06], [0x01, 0x01, 0x04], [0x01, 0x01, 0x03], [0x00, 0x00, 0x00],
];

// Runtime RGB table the renderer reads. Populated by resetToDefaults() at
// module init (so it is never empty even if initPalette is never called) and
// re-populated by initPalette().
__gshared SDL_Color[] PALETTE;

// Runtime role -> palette index, indexed by Role. Read via idx().
__gshared int[Role.max + 1] roleToIndex;

/// Current palette index for a semantic role.
int idx(Role r) { return roleToIndex[r]; }

shared static this() {
	baseColorByName = [
		"black": BaseColor.black, "white": BaseColor.white, "red": BaseColor.red,
		"cyan": BaseColor.cyan, "purple": BaseColor.purple, "green": BaseColor.green,
		"blue": BaseColor.blue, "yellow": BaseColor.yellow, "orange": BaseColor.orange,
		"brown": BaseColor.brown, "lightred": BaseColor.lightred,
		"darkgray": BaseColor.darkgray, "gray": BaseColor.gray,
		"lightgreen": BaseColor.lightgreen, "lightblue": BaseColor.lightblue,
		"lightgray": BaseColor.lightgray,
	];
	roleByName = [
		"background": Role.background, "text": Role.text, "cursor": Role.cursor,
		"frame": Role.frame, "playbackBar": Role.playbackBar, "wrapBar": Role.wrapBar,
		"selectionBar": Role.selectionBar, "activeInstrument": Role.activeInstrument,
		"filterStatic": Role.filterStatic, "filterCalc": Role.filterCalc,
		"filterEmpty": Role.filterEmpty, "filterHeader": Role.filterHeader,
		"keyjamBg": Role.keyjamBg, "keyjamTag": Role.keyjamTag,
		"soundeditSelection": Role.soundeditSelection,
		"soundeditValue": Role.soundeditValue,
		"buttonLabel": Role.buttonLabel,
		"buttonBg": Role.buttonBg,
		"buttonHoverLabel": Role.buttonHoverLabel,
		"buttonHoverBg": Role.buttonHoverBg,
		"buttonPressLabel": Role.buttonPressLabel,
		"buttonPressBg": Role.buttonPressBg,
		"buttonActiveLabel": Role.buttonActiveLabel,
		"buttonActiveBg": Role.buttonActiveBg,
		"buttonDisabledLabel": Role.buttonDisabledLabel,
		"soundeditScrollTrack": Role.soundeditScrollTrack,
		"soundeditScrollThumb": Role.soundeditScrollThumb,
		"soundeditSelEdge": Role.soundeditSelEdge,
		"soundeditDim": Role.soundeditDim,
	];
	resetToDefaults();
}

private void resetToDefaults() {
	PALETTE.length = NUM_TOTAL;
	foreach(i; 0 .. NUM_TOTAL)
		PALETTE[i] = SDL_Color(defaultRgb[i][0], defaultRgb[i][1], defaultRgb[i][2], 0);
	foreach(r; 0 .. Role.max + 1)
		roleToIndex[r] = defaultRoleBase[r];
}

// Parse "#rrggbb" / "rrggbb" (case-insensitive). Throws on malformed input.
private SDL_Color parseHexColor(string s) {
	import std.string : strip, chompPrefix;
	import std.conv : to;
	string h = s.strip().chompPrefix("#");
	if(h.length != 6)
		throw new Exception("expected #rrggbb, got '" ~ s ~ "'");
	ubyte comp(size_t o) { return to!ubyte(h[o .. o + 2], 16); }
	return SDL_Color(comp(0), comp(2), comp(4), 0);
}

// Per-user default palette path: palette.json beside the editor's config.json
// (com.config.configDir() handles the platform convention).
string defaultPalettePath() {
	import std.path : buildPath;
	import com.config : configDir;
	return buildPath(configDir(), "palette.json");
}

// Resolve the palette file: explicit path wins; otherwise the per-user default
// if it exists. Returns "" if none should be loaded.
private string resolvePaletteFile(string explicitFile) {
	import std.file : exists;
	if(explicitFile.length) return explicitFile;   // --palette: caller reports if missing
	string p = defaultPalettePath();
	return exists(p) ? p : "";
}

/++
 + Initialise the runtime palette. Starts from the built-in defaults, then
 + overlays the JSON config if one is found. Any parse/IO error leaves the
 + already-applied defaults in place and prints a warning — the editor always
 + starts with a usable palette.
 +
 + `explicitFile`: the --palette argument, or null/"" to use the default path.
 +/
void initPalette(string explicitFile = null) {
	import std.file : readText, FileException;
	import std.json : parseJSON, JSONValue, JSONType;

	resetToDefaults();

	immutable file = resolvePaletteFile(explicitFile is null ? "" : explicitFile);
	if(file.length == 0) {
		if(explicitFile !is null && explicitFile.length)
			stderr.writefln("palette: --palette file resolved empty; using defaults");
		return;
	}

	string content;
	try {
		content = readText(file);
	} catch(Exception e) {
		stderr.writefln("palette: cannot read '%s' (%s); using defaults", file, e.msg);
		return;
	}

	try {
		JSONValue root = parseJSON(content);

		// Tier 1: redefine base colors by name.
		if(auto colors = "colors" in root.object) {
			foreach(string name, JSONValue v; colors.object) {
				auto bc = name in baseColorByName;
				if(bc is null) {
					stderr.writefln("palette: unknown color '%s' ignored", name);
					continue;
				}
				try PALETTE[cast(int)*bc] = parseHexColor(v.str);
				catch(Exception e)
					stderr.writefln("palette: bad value for color '%s': %s", name, e.msg);
			}
		}

		// Tier 2: point roles at a base color name.
		if(auto roles = "roles" in root.object) {
			foreach(string name, JSONValue v; roles.object) {
				auto role = name in roleByName;
				if(role is null) {
					stderr.writefln("palette: unknown role '%s' ignored", name);
					continue;
				}
				auto bc = v.str in baseColorByName;
				if(bc is null) {
					stderr.writefln("palette: role '%s' references unknown color '%s'",
						name, v.str);
					continue;
				}
				roleToIndex[cast(int)*role] = cast(int)*bc;
			}
		}
	} catch(Exception e) {
		stderr.writefln("palette: invalid JSON in '%s' (%s); using defaults", file, e.msg);
		resetToDefaults();
		return;
	}
}
