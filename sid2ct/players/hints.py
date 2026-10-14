"""Structure hints recovered from a recognised player's song data, used to guide trace-based reconstruction.

Hints never replace the register trace: sound is still fitted against what the
SID actually played, so a wrong or partial extractor can only cost score.
"""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class NoteHint:
    """One note event as the source player's data describes it."""
    call: int               # play-call index (0-based, after init) where the row starts
    note: int               # player note index as written in the pattern data
    instrument: int | None  # source instrument number, None when the row keeps the previous one
    tie: bool = False       # legato / no retrigger
    command: tuple | None = None  # raw (opcode, param...) as stored by the source player
    kind: str = 'note'      # 'note', 'rest', 'effect' (command-only row) or 'gate_off'


@dataclass(frozen=True)
class SequenceInfo:
    """Where one source pattern lives in C64 memory."""
    address: int
    length: int             # bytes


@dataclass
class VoiceHints:
    row_calls: list[int] = field(default_factory=list)       # call index of every row start
    pattern_calls: list[int] = field(default_factory=list)   # call index of every pattern start
    orderlist: list[tuple[int, int]] = field(default_factory=list)  # (pattern id, transpose)
    loop_index: int | None = None                            # orderlist index the voice loops to
    notes: list[NoteHint] = field(default_factory=list)
    row_durations: list[int] = field(default_factory=list)   # calls per row, parallel to row_calls
    sequences: dict[int, SequenceInfo] = field(default_factory=dict)  # by pattern id


@dataclass
class StructureHints:
    player: str             # family name as reported by sid2ct.players.identify
    version: str | None
    voices: tuple[VoiceHints, VoiceHints, VoiceHints]
    instruments: dict[int, dict] = field(default_factory=dict)  # raw source instrument fields
    tempo_calls: list[int] = field(default_factory=list)       # calls per row, in order of use
    loop_call: int | None = None                               # call index where the song loops
    tables: dict[str, dict] = field(default_factory=dict)      # raw source tables, e.g. {'wave': {...}}
    speed_commands: list[tuple[int, int]] = field(default_factory=list)  # (call, new speed)
    warnings: list[str] = field(default_factory=list)


def gate_rise_agreement(hints, frames, tolerance=1):
    """Share of hinted non-tie notes that coincide with a traced gate rise on the same voice.

    `frames` are 25-byte register frames as parsed by `convert.parse_trace`.
    """
    matched = total = 0
    for voice, vh in enumerate(hints.voices):
        control = 4 + voice * 7
        rises = {i for i in range(1, len(frames))
                 if frames[i][control] & 1 and not frames[i - 1][control] & 1}
        for note in vh.notes:
            if note.tie:
                continue
            total += 1
            if any(note.call + d in rises for d in range(-tolerance, tolerance + 1)):
                matched += 1
    return matched / total if total else 0.0
