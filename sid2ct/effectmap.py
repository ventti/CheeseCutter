"""Choose CT 4.x effect supers for the native mapper from the whole-chip IR and effect fits.

EffectPlanner fits each attack's pitch with effects.fit_pitch (flat, detune,
slide, vibrato, portamento, arpeggio), packs the needed command-table rows
and chord entries under the player's capacity (clustering parameters and
refitting, else dropping the effect so the instrument's wave program keeps the
trajectory) and answers which row supers carry them. Global filter starts and
master-volume changes get hosts through effects.assign_hosts. native_song
owns the sequence rows and the tables; this module only plans.

Timing: a row's super acts on the row's tick 2 (the tick the note starts), so a
delay of k whole rows is a super on the k-th following blank row, and a global
event wanted at tick T is hosted on the row whose tick 2 is nearest T.
"""
from collections import Counter
from dataclasses import dataclass, replace
from types import SimpleNamespace

import numpy as np

from . import budget
from .effects import (assign_hosts, chord_table_bytes, fit_adsr, fit_pitch, fit_volume,  # noqa: F401
                      refit_command)
from .filterfit import fit_filter
from .ir import build_chip

COMMAND_ROWS = 63         # command rows 1..63 (row 0 means no command)
CHORD_ENTRIES = 31        # the player's chord index overflows at the 32nd delimiter
CHORD_BYTES = 128
ROW_TICKS_TO_START = 2    # a row's super (and its note) acts on tick 2 of the row
TOLERANCE_CENTS = 12.0
NO_DROP = ('flat',)


@dataclass
class NotePlan:
    primitive: str
    base: int
    note: object = None          # IR note view the fit was made on
    fit: object = None
    command: tuple = None        # (op, hi, lo) pitch command row
    delay_rows: int = 0
    chord: tuple = None
    chord_loop: int = 0
    step: int = 1
    control: int = 0             # arpeggio: waveform of its single wave row
    keyoff_rows: int = None      # arpeggio: gate-off row offset from the note's row

    def arpeggio(self):
        return self.primitive == 'arpeggio'


def arpeggio_program(plan):
    """One waveform row held; the end row's (unused) control byte carries the chord step."""
    return ((0, plan.control), (0x7E, plan.step - 1))


def restart_nibble(wave_program):
    """Instrument wave time: ticks between wave-row runs. Arpeggio programs ask for step - 1."""
    return wave_program[-1][1] if wave_program and wave_program[-1][0] == 0x7E else 0


class EffectPlanner:
    def __init__(self, frames, multiplier, output_multiplier, tuning, row_frames, *, full_pitch=False,
                 reserved_commands=0, tolerance=TOLERANCE_CENTS):
        self.tolerance = tolerance
        self.step = max(1, multiplier // output_multiplier)
        self.output_multiplier = output_multiplier
        self.tuning = list(tuning)
        self.quantum = row_frames * output_multiplier        # ticks per row on the decimated clock
        self.full_pitch = full_pitch
        self.reserved = reserved_commands
        self.frames = list(frames[::self.step])
        self.chip = build_chip(self.frames, multiplier=output_multiplier, tuning=self.tuning,
                               rate=50.0 * output_multiplier)
        self.notes = {}
        self.following = {}
        for track in self.chip.voices:
            for i, note in enumerate(track.notes):
                if note.kind in ('initial', 'gate'):
                    self.notes[(track.voice, note.start)] = note
                    nxt = track.notes[i + 1] if i + 1 < len(track.notes) else None
                    self.following[(track.voice, note.start)] = nxt
        self.commands = {}        # (op, hi, lo) -> row index
        self.chords = {}          # (values, loop) -> (index, table position)
        self.chord_table = []
        self.metrics = Counter()
        self._cache = {}

    # Pitch -----------------------------------------------------------------

    def tick(self, source_frame):
        return -(-source_frame // self.step)

    def _view(self, note):
        """The note up to its first gate-off tick: the release tail's pitch is not part of the effect."""
        if note.gate_off is None or note.gate_off + 1 >= note.length:
            return note
        m = max(2, note.gate_off + 1)
        return replace(note, stop=note.start + m, freq=note.freq[:m], pulse=note.pulse[:m],
                       control=note.control[:m], ad=note.ad[:m], sr=note.sr[:m])

    def _fit(self, note):
        key = (note.freq.tobytes(), note.control.tobytes(), note.voice, note.prev_freq)
        if key not in self._cache:
            budget.check()
            self._cache[key] = fit_pitch(note, self.tuning, tolerance=self.tolerance, quantum=self.quantum)
        return self._cache[key]

    def _covers(self, key, next_start, horizon=None):
        """True when no legato/test step splits the native attack segment this note starts.

        horizon limits the check to the first ticks (the wave program's pitch memory).
        """
        following = self.following.get(key)
        if following is None or following.kind not in ('legato', 'test'):
            return True
        limit = next_start if horizon is None else min(next_start, key[1] + horizon)
        return following.start >= limit

    def _row_of(self, tick):
        return (tick + self.quantum // 2) // self.quantum

    def plan(self, requests):
        """requests: [(voice, source start frame, source stop frame)] -> {(voice, start): NotePlan | None}."""
        plans = {}
        for voice, start, stop in requests:
            key = (voice, self.tick(start))
            note = self.notes.get(key)
            if note is None:
                self.metrics['notes_unmapped'] += 1
                plans[(voice, start)] = None
                continue
            plans[(voice, start)] = self._plan_note(key, note, self.tick(stop))
        self._pack_commands(plans)
        self._pack_chords(plans)
        for entry in plans.values():
            if entry is not None:
                self.metrics['plan_' + entry.primitive] += 1
        return plans

    def _plan_note(self, key, note, next_start):
        view = self._view(note)
        fit = self._fit(view)
        self.metrics['notes_fitted'] += 1
        if not fit.ok or fit.primitive == 'wave_abs':
            self.metrics['notes_kept_in_wave_program'] += 1
            return None
        plan = NotePlan(fit.primitive, fit.params['note'], view, fit)
        if fit.primitive in ('flat', 'detune'):
            # Held pitch: only what the instrument's wave program would remember matters.
            horizon = None if self.full_pitch else 6 * self.output_multiplier
            if not self._covers(key, next_start, horizon):
                self.metrics['notes_partial_coverage'] += 1
                return None
            plan.command = fit.command
            return plan
        if not self._covers(key, next_start):
            self.metrics['notes_partial_coverage'] += 1
            return None
        if fit.primitive == 'portamento':
            self.metrics['portamento_not_mapped'] += 1   # sticky state needs a reset row; see ADR in docs
            return None
        if fit.primitive == 'arpeggio':
            return self._plan_arpeggio(plan, view, note, next_start)
        plan.command = fit.command
        plan.delay_rows = fit.delay // self.quantum
        if fit.delay % self.quantum:
            self.metrics['delay_not_on_row'] += 1
            return None
        return plan

    def _plan_arpeggio(self, plan, view, note, next_start):
        fit = plan.fit
        controls = np.asarray(view.control[1:], int) & 0xFE
        if not len(controls) or (controls != controls[0]).any():
            self.metrics['arpeggio_control_changes'] += 1
            return None
        plan.chord, plan.chord_loop, plan.step = fit.chord, fit.params['loop'], fit.params['step']
        plan.control = int(view.control[1]) | 1
        if note.gate_off is not None and note.gate_off + 1 < note.length:
            offset = round(note.gate_off / self.quantum)
            start_row = self._row_of(note.start)
            if offset < 1 or start_row + offset >= self._row_of(next_start):
                self.metrics['arpeggio_no_keyoff_row'] += 1
                return None
            plan.keyoff_rows = offset
        return plan

    # Capacity --------------------------------------------------------------

    @staticmethod
    def _distance(a, b):
        if a[0] in (2, 5):
            return abs(a[1] - b[1]) * 16 + abs(a[2] - b[2])
        return abs((a[1] << 8 | a[2]) - (b[1] << 8 | b[2]))

    def _pack_commands(self, plans):
        capacity = COMMAND_ROWS - self.reserved
        users = Counter(p.command for p in plans.values() if p is not None and p.command)
        kept = [c for c, _ in users.most_common(capacity)]
        for key, entry in plans.items():
            if entry is None or not entry.command or entry.command in kept:
                continue
            near = sorted((c for c in kept if c[0] == entry.command[0]),
                          key=lambda c: self._distance(c, entry.command))[:3]
            for command in near:
                fit = refit_command(entry.note, self.tuning, entry.fit, command, tolerance=self.tolerance,
                                    quantum=self.quantum)
                if fit is not None and fit.ok:
                    entry.command, entry.fit = command, fit
                    self.metrics['command_rows_quantised'] += 1
                    break
            else:
                self.metrics['effects_dropped_for_capacity'] += 1
                plans[key] = None
        for command, _ in users.most_common(capacity):
            if any(p is not None and p.command == command for p in plans.values()):
                self.alloc_command(command)

    def alloc_command(self, command):
        """Command-table row index for (op, hi, lo); None when the table is full."""
        if command not in self.commands:
            if len(self.commands) >= COMMAND_ROWS - self.reserved:
                return None
            self.commands[command] = 1 + self.reserved + len(self.commands)
        return self.commands[command]

    def _pack_chords(self, plans):
        # Entry 0 is a neutral loop: a voice that has not played a note yet walks
        # the chord table from position 0 on a stale note, which must stay in range.
        users = Counter((p.chord, p.chord_loop) for p in plans.values() if p is not None and p.chord)
        position = 2
        for (values, loop), _ in users.most_common():
            if 1 + len(self.chords) >= CHORD_ENTRIES or position + len(values) + 1 > CHORD_BYTES:
                continue
            self.chords[(values, loop)] = (1 + len(self.chords), position)
            self.chord_table.extend(values)
            self.chord_table.append(0x80 | (position + loop))
            position += len(values) + 1
        if self.chords:
            self.chord_table[:0] = [0, 0x80]
        for key, entry in plans.items():
            if entry is not None and entry.chord and (entry.chord, entry.chord_loop) not in self.chords:
                self.metrics['effects_dropped_for_capacity'] += 1
                plans[key] = None

    def chord_super(self, plan):
        return 0x80 + self.chords[(plan.chord, plan.chord_loop)][0]

    def command_super(self, plan):
        return self.commands[plan.command]

    # ADSR ------------------------------------------------------------------

    def adsr_super(self, wanted, representative):
        """Row super that turns the representative's AD/SR into the wanted pair.

        0: identical, $a0..$df: one changed nibble, a command row index for command 4,
        None: command 4 is needed but the command table is full."""
        stand_in = SimpleNamespace(length=2, ad=np.array([wanted[0]] * 2), sr=np.array([wanted[1]] * 2))
        fit = fit_adsr(stand_in, *representative)
        if fit.kind == 'none':
            return 0
        if fit.kind == 'inline':
            return fit.super_byte
        return self.alloc_command(fit.command)

    # Global events ---------------------------------------------------------

    def filter_plan(self, tolerance=16):
        if not self.chip.filter.used():
            return None
        return fit_filter(self.chip.filter, tolerance=tolerance)

    def volume_events(self):
        """Master-volume events worth a super: none when constant, none for sample-like noise.

        The first ticks are player initialisation, and a super only acts from tick 2 anyway,
        so the series starts there.
        """
        series = np.asarray(self.chip.volume.volume)[ROW_TICKS_TO_START:]
        events = [replace(e, frame=e.frame + ROW_TICKS_TO_START)
                  for e in fit_volume(series, min_gap=self.quantum)]
        rows = max(1, len(self.frames) // self.quantum)
        events = [e for e in events if not (e.frame == ROW_TICKS_TO_START and e.value == 15)]
        if len(events) > rows // 2:
            self.metrics['volume_digi_skipped'] += 1
            return []
        return events

    def host(self, events, occupied, *, frame_of):
        """assign_hosts with each event wanted on the row whose tick 2 is nearest its frame."""
        return assign_hosts(events, self.quantum, occupied,
                            frame_of=lambda e: frame_of(e) - ROW_TICKS_TO_START)
