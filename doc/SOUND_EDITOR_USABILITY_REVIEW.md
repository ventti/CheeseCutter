# Sound Editor usability review

Reviewed 2026-07-16 against the completed implementation and master usage test.

## Verdict

The editor meets the practical modern soft-synth standard while retaining the
CheeseCutter text/palette aesthetic: direct envelope and programme manipulation,
predictable cursors and ownership, immediate auditioning, undo, exact numeric
feedback and one time-aligned view of modulation and output. Its strongest point
is honest SID presentation: vivid traces use actual reSID values instead of a
cosmetically smoothed approximation.

## Direct references

- [Ableton Wavetable manual](https://www.ableton.com/en/manual/live-instrument-reference/#wavetable):
  envelope time, slope, and value are edited directly in the envelope display;
  parameters can also be surfaced in an expanded all-controls view.
- [Ableton keyboard envelope editing](https://www.ableton.com/en/live-manual/12/accessibility-and-keyboard-navigation/#editing-automation-and-modulation-envelopes):
  the current envelope position and value are exposed while navigating, with
  keyboard creation and movement of breakpoints.
- [Surge XT manual — UI basics](https://surge-synthesizer.github.io/manual-xt/index.html#user-interface-basics):
  hover displays values, Shift-drag provides fine control, double-click resets,
  typed values are available, and Ctrl/Cmd-Z/Y provides undo/redo.
- [Surge XT manual — modulation routing](https://surge-synthesizer.github.io/manual-xt/index.html#modulation-routing):
  selected, used, and routed states are visually distinct; hovering a modulated
  target highlights its source.
- [Arturia Pigments manual](https://downloads.arturia.net/products/pigments/manual/pigments_Manual_3_5_0_EN.pdf):
  modulation sources use consistent color families and controls distinguish
  hover, selection, and editing states.
- [SDL2 key-symbol documentation](https://wiki.libsdl.org/SDL2/SDL_Keysym):
  command dispatch uses the virtual key plus explicit modifier state, while text
  composition belongs to the separate text-input path.
- [SDL2 modifier enumeration](https://wiki.libsdl.org/SDL2/SDL_Keymod): SDL exposes
  left/right Ctrl, Alt and GUI plus `KMOD_MODE`, allowing AltGr and GUI-origin
  events to be rejected deterministically in Sound context.
- [Microsoft PowerToys Keyboard Manager](https://learn.microsoft.com/en-us/windows/powertoys/keyboard-manager):
  documents that AltGr can present as left Ctrl plus right Alt and warns that
  Ctrl+Alt remapping can break it; Sound primaries therefore avoid Alt entirely.
- [Apple Mission Control shortcuts](https://support.apple.com/guide/mac-help/see-all-your-open-windows-on-mac-mchlb7beb9af/mac):
  Control-arrow chords belong to Mission Control and Spaces, so graph editing no
  longer relies on them.

The portable-shortcut denylist is reproducible from these platform owners:

- Microsoft: [keyboard interaction guidance](https://learn.microsoft.com/en-us/windows/win32/uxguide/inter-keyboard)
  and [Windows default shortcuts](https://support.microsoft.com/en-gb/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec).
- Apple: [macOS default shortcuts](https://support.apple.com/en-us/102650),
  [Mission Control](https://support.apple.com/en-gb/guide/mac-help/mh35798/mac),
  and [Spaces](https://support.apple.com/en-asia/guide/mac-help/-mh14112/mac).
- Ubuntu/GNOME: [custom shortcut rules](https://help.ubuntu.com/stable/ubuntu-help/keyboard-shortcuts-set.html),
  [the default terminal shortcut](https://ubuntu.com/desktop/docs/en/latest/how-to/change-the-default-terminal/),
  and [command-line lockdown](https://help.gnome.org/system-admin-guide/lockdown-command-line.html).
- KDE Plasma: [screen-lock shortcuts](https://docs.kde.org/stable_kf6/en/plasma-workspace/kcontrol/screenlocker/index.html)
  and [task-switcher shortcuts](https://docs.kde.org/stable_kf6/en/kwin/kcontrol/kwintabbox/kwintabbox.pdf).

Together these sources justify avoiding GUI/Super, Alt, Ctrl+Alt, Ctrl+Space and
Ctrl+Arrow as Sound primaries; the eight-layout whitelist then uses the same
semantic Ctrl/Shift plus letter, digit or Page key set on every target layout.

## Comparison

| Standard | Sound Editor | Assessment |
|---|---|---|
| Direct manipulation | ADSR handles; pulse/filter step handles | Meets |
| Immediate feedback | retriggers held notes and redraws live | Meets |
| Actual output view | per-note output scope and SID state | Exceeds |
| Time alignment | shared tick axis and playhead | Exceeds |
| Undo/redo | one undo step per key/drag gesture | Meets |
| Keyboard access | scalar and selected-step editing | Meets |
| Hover/selection feedback | numeric probe and highlighted handles | Meets after this pass |
| Safe shared-data editing | automatic copy-on-write; explicit visible `Linked edits` mode | Meets; complete ownership matrix and full regression pass |
| Fine/default/numeric gestures | graph drag plus exact fine/hex entry | Meets |
| Full visual wave editing | pitch, delay, control, rows and loops | Meets |

## Implemented improvements

- The hint below Parameters now predicts the action under the pointer: select a
  pulse/filter row, drag ADSR handles, toggle a wave bit, or drag-select time.
- A pulse/filter selection identifies its table row and advertises the keyboard
  controls; a range selection says that dragging edits joins.
- The raw-data footer now calls the hardware-wide filter `SID-global`, avoiding
  confusion with a program shared between instruments.
- Rows and Ticks are explicit, with a fixed keyjam gate and selectable SID voice.
- Wave, pulse and logical filter blocks support exact insertion, duration, slope,
  loop contraction, End state, resonance, modes and masks.
- Wave editing is row-aware: pitch moves vertically, delay moves horizontally,
  reserved rows stay protected, and a visible trailing `+` creates the next row from
  a cell distinct from stopped or looped END/LOOP triangles.
- Control-bit painting never substitutes a different SID meaning: unrepresentable
  `$E0..$FF` effective requests stay unchanged with a visible explanation, while valid
  direct/encoded-low crossings and shared multi-row paint remain one undo gesture.
- Empty-song sentinel rows have no live owner and are never treated as shared or used;
  the first Pulse/Filter drag creates and edits directly without a modal.
- Genuinely shared Wave/Pulse/Filter mutations automatically copy-on-write in one undo
  transaction; only visibly active persistent `Linked edits` mode may change shared bytes.
- Wave mutations use the same non-modal ownership transaction, while delay/speed-aware
  inward END/LOOP triangles target the block actually under the pointer.
- The fitted timeline includes the full authored Wave programme even when the latest
  reSID keyjam recording is shorter.
- Actual keyjam graphs use raw reSID ENV/register values; the pre-keyjam C-4
  estimate uses the same isolated core without audio or remote side effects.
- Authored programme geometry remains visible and draggable after a shorter keyjam
  capture, and filter gutter controls follow the selected logical block.
- Pulse and Filter duration edges now follow the shared timeline under the pointer;
  Fit cannot change resize velocity midway through a drag.
- Authored loops use one inward orange triangle pair, making loop start and end
  visually distinct from slope dots and duration boundaries.
- Bracket-free padded controls are grouped by the selected graph; New sound and
  wave-byte editing live in the context-specific Sound menu with the same shortcuts.
- Hover help reuses the existing status-line mechanism and is clipped immediately
  left of the live SID-register block, so help changes cannot blink register data.
- All Sound operations now have layout-stable compact-keyboard primaries; exact
  modifier matching consumes AltGr/GUI impostors and preserves other contexts.

## Portable primary map

There are 32 unique primaries: 22 named UI/menu actions and 10 raw graph, octave
or instrument actions. All use only physical Ctrl/Shift plus A-Z, 0-9, PageUp or
PageDown on US, UK, DE, IT, ES, FI-SE, DK and NO layouts.

| Actions | Primary shortcuts |
|---|---|
| Zoom out/in; Fit; Selection | `Ctrl-Shift-O/I/A/G` |
| Add; Delete; Stop; Type; Carry; New | `Ctrl-Shift-J/D/S`, `Ctrl-T`, `Ctrl-I`, `Ctrl-Shift-N` |
| Wave previous/next; W1/W2; Loop | `Shift-PageUp/PageDown`, `Ctrl-Shift-1/2`, `Ctrl-L` |
| Resonance -/+; LP/BP/HP/Route | `Ctrl-Shift-3/4/L/B/H/R` |
| Linked edits | `Ctrl-Shift-E` |
| Start -/+; End -/+; Duration -/+ | `Ctrl-Shift-5/6/7/8/9/0` |
| Octave -/+; Instrument previous/next | `Ctrl-Shift-PageDown/PageUp`, `Ctrl-PageUp/PageDown` |

The eight optional aliases are `Home`, `End`, `Insert`, `Delete`, keypad `/`,
keypad `*`, keypad `-` and keypad `+`; generated help always lists the portable
primary first.

## Recommended next increments

1. Add a deliberate reset gesture only after defining SID-safe defaults per
   control; do not copy generic synth defaults blindly.
2. Unify Shift as fine control where possible, then move viewport pan to a
   dedicated shortcut without breaking tracker muscle memory.
3. Continue human testing on each supported platform for cursor feel, density and
   discoverability; these are not fully replaceable by deterministic tests.
