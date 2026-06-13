# 0003 — Single shortcut registry as source of truth

**Status:** Accepted

## Context

Keyboard shortcuts surface in several places: the live dispatch that runs the
command, the F12 context help, the generated `doc/KEYBOARD.md`, and the top
menu bar / command palette. Historically a shortcut could be defined in the
widget that handled it *and* described again in help text — so a binding and its
documentation could silently disagree.

## Decision

All **named-command** shortcuts live in one registry, `ShortcutManager`
(`src/com/shortcuts.d`), each registered with metadata (action id, context,
category, description, key, mods, callback). Everything else derives from it:

- **Dispatch:** `UI.keypress` (`src/ui/ui.d`) calls `handleKeypress` once,
  resolving active-context → parents → global. Bindings registered in
  `UI.registerShortcuts` / `registerContextShortcuts` (`src/ui/keymap.d`).
- **Help & docs:** `src/ui/shorthelp.d` builds the F12 `ContextHelp` pages and
  `exportMarkdown` powers `ccutter --dump-keys` → `doc/KEYBOARD.md`.
- **Menus / palette:** `src/ui/menubar.d` and `src/ui/palette.d` read labels,
  shortcut text and enabled state from the registry; they hold no bindings.

Raw data entry (hex nibbles, the QWERTY piano, text fields, plain cursor
movement) is intentionally **not** registered — it stays in the input widgets.
Context shortcuts use a behaviour-preserving re-dispatch (`invokeKey` →
`toplevel.keypress`) so the proven per-widget logic stays the single
implementation while the registry stays the single catalogue.

## Consequences

- A shortcut is defined exactly once; menus, help and the keyboard reference
  can't drift from it.
- Adding a shortcut = one `register(...)` entry, then `make docs` regenerates
  F12 help and `doc/KEYBOARD.md` (see CLAUDE.md "Keep docs in sync").
- The split (registry for named commands, widgets for raw entry) is a rule to
  uphold: don't register data-entry keys, don't bind named commands in widgets.
