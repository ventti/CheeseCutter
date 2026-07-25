/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Ordinary clickable text button widget — a labelled char-cell button that draws itself in distinct hover / pressed / active / disabled styles from the semantic palette, and hit-tests a point against its cell span.

Historically the Sound Editor's zoom controls ([-] [+] [Fit] [Selection]) were
ad-hoc: a private struct laid them out, a drawer printed static text in two fixed
palette roles, and the click hit-test was inlined. This module promotes that into
a reusable widget so any screen can host buttons that give the user visual
feedback about what is going on:

  * normal   — the resting look (buttonLabel / buttonBg)
  * hover     — pointer is over it (buttonHover*)
  * pressed   — mouse button held down on it (buttonPress*), i.e. the "click" look
  * active    — a persistent "on"/current state the owner sets (buttonActive*)
  * disabled  — not clickable (buttonDisabledLabel on buttonBg)

The widget is deliberately state-in / draw-out: the owner positions it and sets
the flags each frame, then calls draw(). Precedence when several flags are set is
disabled > pressed > hovered > active > normal, so an in-progress interaction
always visibly wins over the persistent active state.
*/

module ui.button;

import com.session : screen;
import com.palette : idx, Role;

// A single labelled button occupying an inclusive-exclusive cell span [x0, x1)
// on a given text row. Value type: cheap to build fresh each frame from layout
// geometry, with the interaction/state flags set by the owner before draw().
struct Button {
	int x0, x1;        // inclusive-exclusive cell X span on `row`
	int row;           // text row (cells)
	string label;      // glyph label, e.g. "[Fit]"

	bool hovered;         // pointer is over the button
	bool pressed;         // mouse button is held down on it (the "click" look)
	bool active;          // persistent "on"/current-state indicator set by the owner
	bool enabled = true;  // false = greyed out and not clickable
	// Optional per-instance resting/on foreground overrides. Useful for compact bit
	// toggles that remain clickable while visually off (e.g. dark-gray -> yellow).
	int restingLabel = -1;
	int activeLabel = -1;
	int activeBackground = -1;

	// True if screen cell (cx, cy) lies on this button.
	bool contains(int cx, int cy) const {
		return cy == row && cx >= x0 && cx < x1;
	}

	// Foreground/background palette indices for the current state, following the
	// disabled > pressed > hovered > active > normal precedence.
	private void colors(out int fg, out int bg) const {
		if(!enabled)     { fg = idx(Role.buttonDisabledLabel); bg = idx(Role.buttonBg); }
		else if(pressed) { fg = idx(Role.buttonPressLabel);    bg = idx(Role.buttonPressBg); }
		else if(hovered) { fg = idx(Role.buttonHoverLabel);    bg = idx(Role.buttonHoverBg); }
		else if(active)  { fg = activeLabel >= 0 ? activeLabel : idx(Role.buttonActiveLabel);
		                    bg = activeBackground >= 0 ? activeBackground : idx(Role.buttonActiveBg); }
		else             { fg = restingLabel >= 0 ? restingLabel : idx(Role.buttonLabel);
		                    bg = idx(Role.buttonBg); }
	}

	// Render the label at [x0, row) in the current state's colors. All TEXT cells,
	// so it composites like the rest of the char-cell chrome.
	void draw() const {
		int fg, bg;
		colors(fg, bg);
		screen.cprint(x0, row, fg, bg, label);
	}
}
