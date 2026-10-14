"""Model the CheeseCutter 4.x player's SID registers in pure Python.

Input is the decompressed CC2 payload, including its subtune metadata.
Frames are play calls (50 * multiplier per PAL second), not video frames.
The order of the passes follows player_v4.acme, including delayed ties and
8-bit counters. No CPU emulator, external program, or third-party library
is used. Each instance owns its sound and shared filter state.

One assembly quirk is deliberately not reproduced: with portamento enabled,
updseq's signed CPY/BPL lets inline $c0..$ff index past the packed command
columns. Accidental opcode-7 matches depend on relocation and export pruning,
not the editable image. Such combinations can differ from exported playback.
Opcode 6 is a no-op, matching INCLUDE_CMD_SET_WAVE = FALSE in the source.
"""
from dataclasses import dataclass
import struct


# Indices in ct.base.Offsets, not addresses of a particular player build.
FREQ, WAVE, CONTROL, FILTER, PULSE, INST = 12, 14, 15, 16, 17, 18
SEQLO, SEQHI, COMMAND, CHORD, CHORDINDEX = 22, 23, 24, 30, 32
TRACKS = 65536 + 256 + 5 + 160 + 2048


def _dec(value):
    return (value - 1) & 255


def _negative(value):
    return bool(value & 128)


@dataclass
class _Voice:
    number: int
    track: bytes = b''
    trackpos: int = 0
    newseq: int = 1
    curseq: int = 0
    seqcnt: int = 0
    duration: int = 0
    durcnt: int = 0
    tsync: int = 254
    synccnt: int = 2
    tie: int = 0
    shnote: int = 0
    shinst: int = 0
    shsuper: int = 0
    shtrans: int = 0
    tracktrans: int = 0
    note: int = 0
    newins: int = 0
    newcmd: int = 0
    shad: int = 0
    shsr: int = 0
    ad: int = 0
    sr: int = 0
    offset: int = 0
    freq: int = 0
    gate: int = 0
    waveform: int = 0
    hardon: int = 0
    wavepos: int = 0
    wavecnt: int = 0
    wavetime: int = 0
    wavetrans: int = 0
    chordpos: int = 0
    chordvalue: int = 0
    pulse: int = 0
    pulsecur: int = 0
    pulsenxt: int = 0
    pulsecnt: int = 0
    effect: int = 0
    slide: int = 0
    porta: int = 0
    pitch: int = 0
    vibracnt: int = 0
    vibradir: int = 0
    vibraamp: int = 0
    vibrafrq: int = 0
    vibracor: int = 0
    vibrafeel: int = 0
    vibraphase: int = 0


class CTPlayer:
    """Advance a decompressed CT song and return 25 raw SID bytes per call."""

    def __init__(self, image: bytes, subtune=0):
        if len(image) < TRACKS + 32 * 3 * 1024:
            raise ValueError('Expected a decompressed CC2 payload with subtunes.')
        if not 0 <= subtune < 32:
            raise ValueError('Subtune must be in range 0..31.')
        self.image = bytes(image)
        self.pointers = struct.unpack_from('<39H', image, 0xFA0)
        for index in (FREQ, WAVE, CONTROL, FILTER, PULSE, INST,
                      SEQLO, SEQHI, COMMAND, CHORD, CHORDINDEX):
            if not 0 < self.pointers[index] < 65536:
                raise ValueError('Invalid native table pointer.')
        self.multiplier = max(1, image[65538])
        self.speed = image[65541 + subtune]
        self.speedcnt = 2
        self.speedsub = 0
        self.volume = 15
        self.bandpass = self.cutoff = self.filtlo = 0
        self.filtcnt = self.filtcur = self.filtnxt = 0
        self.filtadd = self.filtfraction = 0
        self.sync = 0
        self.sid = bytearray(25)
        self.calls = 0
        self.voices = []
        for number in range(3):
            start = TRACKS + (subtune * 3 + number) * 1024
            self.voices.append(_Voice(number, image[start:start + 1024]))
        # Export regenerates the chord index from delimiters, as Song does.
        self.chordindex = list(self._table(CHORDINDEX, 32))
        start = ordinal = 0
        for i, value in enumerate(self._table(CHORD, 128)):
            if value >= 128:
                if ordinal >= 31:
                    raise ValueError('Chord index overflow.')
                self.chordindex[ordinal] = start
                ordinal += 1
                start = i + 1
        self.chordindex[ordinal] = start
        # Export removes unreferenced wave chunks. Cleared voices therefore
        # start in the first retained chunk, which need not be image row 0.
        initial_wave = self._initial_wave()
        for v in self.voices:
            v.wavepos = initial_wave
        self.freqbase = self.pointers[FREQ]
        if self.freqbase == self.pointers[13]:
            self.freqbase += 1  # Legacy dummy pointer, also handled by native.py.
        self.chords_used = False
        self.filter_used = any(self._instrument(i)[4] for i in self.used_instruments)
        self.porta_used = False
        # Packed exports omit unused passes. In particular an unused chord
        # walker must not consume chord[0] from its cleared initial position.
        for seq in range(128):
            pos = 0
            while pos < 256:
                token = self._sequence(seq, pos)
                pos += 1
                if token == 191:
                    break
                if 96 <= token < 191:
                    command = self._sequence(seq, pos & 255)
                    pos += 1
                    self.chords_used |= 128 <= command < 160
                    self.filter_used |= 96 <= command < 128
                    self.porta_used |= (0 < command < 64 and
                                        self._read(COMMAND, command) == 7)

    def _initial_wave(self):
        sequences = set()
        for track in range(32 * 3):
            start = TRACKS + track * 1024
            for pos in range(0, 1024, 2):
                if self.image[start + pos] >= 240:
                    break
                sequences.add(self.image[start + pos + 1])
        instruments = set()
        for seq in sequences:
            for pos in range(0, 256, 4):
                token = self._sequence(seq, pos)
                if token == 191:
                    break
                if 192 <= token < 240:
                    instruments.add(token - 192)
        chunks = []
        start = 0
        for pos in range(256):
            if self._read(WAVE, pos) in (126, 127):
                chunks.append((start, pos))
                start = pos + 1
        pending = [self._instrument(i)[7] for i in instruments]
        used = set()
        while pending:
            pointer = pending.pop()
            for start, end in chunks:
                if start <= pointer <= end and start not in used:
                    used.add(start)
                    if self._read(WAVE, end) == 127:
                        pending.append(self._read(CONTROL, end))
                    break
        self.used_instruments = instruments
        return min(used, default=0)

    def _read(self, index, offset=0):
        return self.image[(self.pointers[index] + offset) & 65535]

    def _table(self, index, size):
        return bytes(self._read(index, i) for i in range(size))

    def _instrument(self, number):
        return tuple(self._read(INST, col * 48 + number) for col in range(8))

    def _frequency(self, note):
        note &= 255
        return (self.image[(self.freqbase + note) & 65535] |
                self.image[(self.freqbase + 96 + note) & 65535] << 8)

    def _sequence(self, sequence, pos):
        addr = self._read(SEQLO, sequence) | self._read(SEQHI, sequence) << 8
        return self.image[(addr + pos) & 65535]

    def _track(self, v):
        if not v.newseq:
            return
        v.seqcnt = _dec(v.newseq)
        v.newseq = 0
        pos = v.trackpos
        value = v.track[pos]
        if value >= 128:
            if value != 128:
                v.tracktrans = (value - 160) & 255
            pos += 1
            value = v.track[pos]
        v.curseq = value
        pos += 1
        value = v.track[pos]
        if value >= 240:
            v.trackpos = ((value & 7) << 8) + v.track[pos + 1]
        else:
            v.trackpos = pos

    def _row(self, v):
        v.durcnt = _dec(v.durcnt)
        if not _negative(v.durcnt):
            return
        v.tsync = 2
        pos = v.seqcnt
        # Invalid streams should fail promptly rather than hang a fitter.
        for _ in range(256):
            token = self._sequence(v.curseq, pos)
            pos = (pos + 1) & 255
            if token >= 240:
                v.duration = token & 15
            elif token >= 192:
                v.shinst = token - 192
                v.newins = (v.newins + 1) & 255
            elif token == 95:
                v.tie = (v.tie + 1) & 255
            else:
                if token >= 96:
                    token -= 96
                    command = self._sequence(v.curseq, pos)
                    pos = (pos + 1) & 255
                    if command:
                        v.shsuper = command
                        v.newcmd = (v.newcmd + 1) & 255
                self._latch(v, token)
                v.seqcnt = pos
                if pos == 0 or self._sequence(v.curseq, pos) == 191:
                    v.newseq = (v.newseq + 1) & 255
                v.durcnt = v.duration
                return
        raise ValueError('Sequence has no note in 256 bytes.')

    def _latch(self, v, note):
        v.shnote = note
        if note < 3:
            v.tie = (v.tie + 1) & 255
        else:
            v.shtrans = v.tracktrans
        if v.newcmd and v.shsuper < 64 and self._read(COMMAND, v.shsuper) == 7:
            v.porta = ((self._read(COMMAND, 64 + v.shsuper) & 15) << 8 |
                       self._read(COMMAND, 128 + v.shsuper))
            v.effect = 129
            v.newcmd = 0

    def _start(self, v):
        ad, sr, restart, hrwave, filt, pulse, hrsr, wave = self._instrument(v.shinst)
        if v.newins:
            v.shad, v.shsr = ad, sr
            if v.effect < 128:
                v.effect = 0
        v.note = (v.shnote + v.shtrans) & 255
        if v.effect < 128:
            v.pitch = self._frequency(v.note)
            v.offset = v.number
        v.wavepos = wave
        v.ad, v.sr = v.shad, v.shsr
        if pulse:
            if pulse >= 128:
                v.pulse = (pulse & 15) << 8
                v.pulsenxt = 0
            else:
                v.pulsenxt = (pulse << 2) & 255
            v.pulsecnt = 0
        if filt and self.filter_used:
            self.filtnxt = (filt << 2) & 255
            self.filtcnt = 0
        v.newins = 0
        v.chordvalue, v.chordpos = 0, 128
        v.wavetime, v.wavecnt = restart & 15, 0
        if restart & 192 != 64:
            v.waveform = hrwave | 1
            v.hardon = 1
        v.gate = 255
        v.synccnt = 0
        if v.effect < 128:
            v.effect = 0

    def _pulse(self, v):
        v.pulsecnt = _dec(v.pulsecnt)
        if _negative(v.pulsecnt):
            v.pulsecur = v.pulsenxt
            preset = self._read(PULSE, v.pulsecur + 2)
            if preset != 255:
                v.pulse = ((preset & 15) << 8) | (preset & 240)
            v.pulsecnt = self._read(PULSE, v.pulsecur) & 127
            nxt = self._read(PULSE, v.pulsecur + 3)
            v.pulsenxt = ((v.pulsenxt + 4) & 255 if not nxt else
                          0 if nxt == 127 else (nxt << 2) & 255)
        delta = self._read(PULSE, v.pulsecur + 1)
        if self._read(PULSE, v.pulsecur) & 128:
            delta = -delta
        v.pulse = (v.pulse + delta) & 65535

    def _effects(self, v):
        if v.effect in (1, 2):
            v.offset = (v.offset + (v.slide if v.effect == 1 else -v.slide)) & 65535
        elif v.effect in (3, 4):
            if v.effect == 4:
                delta = v.vibraamp << 2
            else:
                delta = (self._frequency(v.note + 1) - self._frequency(v.note)) & 65535
                shifts = (v.vibraamp + v.vibracor) & 255
                # DEY/BMI loop treats counts $81..$ff as zero shifts.
                if shifts <= 128:
                    delta >>= shifts
                v.vibracor = 0
                delta = (delta + v.vibraphase) & 65535
                v.vibraphase = (v.vibraphase + v.vibrafeel) & 65535
            v.offset = (v.offset + (-delta if v.vibradir & 1 else delta)) & 65535
            count = (v.vibracnt + 1) & 255
            if count >= v.vibrafrq:
                v.vibradir = (v.vibradir + 1) & 255
                count = 0
            v.vibracnt = count
            # Assembly falls through to CMP #$81 with the count in A.
            if count != 129 or not self.porta_used:
                return
            self._portamento(v)
        elif v.effect == 129:
            self._portamento(v)

    def _portamento(self, v):
        target = self._frequency(v.note)
        difference = (v.pitch - target) & 65535
        adjusted = (difference + (v.porta if difference & 32768 else -v.porta)) & 65535
        crossed = bool((difference ^ adjusted) & 32768)
        v.pitch = target if crossed else (target + adjusted) & 65535
        v.offset = (v.pitch - target) & 65535

    def _wave(self, v):
        if v.hardon:
            return
        v.wavecnt = _dec(v.wavecnt)
        if _negative(v.wavecnt):
            v.wavecnt = v.wavetime
            pos = v.wavepos
            v.wavetrans = self._read(WAVE, pos)
            control = self._read(CONTROL, pos)
            if control >= 16:
                v.waveform = control if control < 224 else control & 15
            following = self._read(WAVE, pos + 1)
            if following != 126:
                pos = (pos + 1) & 255
                if following == 127:
                    pos = self._read(CONTROL, pos)
                delay = self._read(CONTROL, pos)
                if 0 < delay < 16:
                    v.wavecnt = delay
            v.wavepos = pos
            if self.chords_used and v.chordpos < 128:
                value = self._read(CHORD, v.chordpos)
                v.chordvalue = value if value < 64 else value | 128
                nxt = self._read(CHORD, v.chordpos + 1)
                v.chordpos = nxt & 127 if nxt >= 128 else (v.chordpos + 1) & 255
        if v.wavetrans >= 128:
            v.freq = self._frequency(v.wavetrans & 127)
        else:
            note = v.wavetrans + v.note
            # ADC chordvalue reuses the carry from ADC notereal.
            if self.chords_used:
                note = (note & 255) + v.chordvalue + (note > 255)
            v.freq = (self._frequency(note) + v.offset) & 65535

    def _super(self, v):
        if v.tsync != 255 or not v.newcmd:
            return
        v.newcmd = 0
        command = v.shsuper
        if command < 64:
            op = self._read(COMMAND, command)
            hi = self._read(COMMAND, command + 64)
            lo = self._read(COMMAND, command + 128)
            if op in (0, 1):
                v.slide, v.effect = hi << 8 | lo, op + 1
            elif op == 2:
                v.effect = 3
                v.vibrafeel, v.vibraamp = hi & 15, lo & 15
                v.vibrafrq = (lo >> 4) + 1
                if v.vibrafrq & 1:
                    v.vibracor = (v.vibracor + 1) & 255
                v.vibracnt = v.vibrafrq >> 1
                v.vibradir = v.vibraphase = 0
            elif op == 3:
                v.offset = hi << 8 | lo
            elif op == 4:
                v.ad, v.sr = hi, lo
            elif op == 5:
                v.effect, v.vibrafrq, v.vibraamp = 4, hi, lo
                v.vibracnt, v.vibradir = hi >> 1, 0
            elif op == 8 and self.porta_used:
                v.effect = 0
            # 6 is disabled in player_v4.acme. 7 is consumed by _latch.
        elif command < 96:
            v.pulsenxt, v.pulsecnt = (command & 31) << 2, 0
        elif command < 128:
            self.filtnxt, self.filtcnt = (command & 31) << 2, 0
        elif command < 160:
            v.chordpos = self.chordindex[command & 31]
        elif command < 176:
            v.ad = (v.ad & 15) | (command & 15) << 4
        elif command < 192:
            v.ad = (v.ad & 240) | (command & 15)
        elif command < 208:
            v.sr = (v.sr & 15) | (command & 15) << 4
        elif command < 224:
            v.sr = (v.sr & 240) | (command & 15)
        elif command < 240:
            self.volume = command & 15
        elif command == 240:
            self.sync = (self.sync + 1) & 255
        else:
            self.speed = command & 15
            speed = self.speed
            if speed < 2:
                self.speedsub = 1
                speed = self._read(CHORD)
            self.speedcnt = _dec(speed)

    def _sound(self, v, extra=False):
        if not extra:
            v.hardon = 0
            if v.tsync < 128:
                v.tsync = _dec(v.tsync)
                if not v.tie:
                    if v.tsync == 1:
                        restart = self._instrument(v.shinst)
                        if (not _negative((v.synccnt - 2) & 255) and
                                restart[2] & 128):
                            if not restart[2] & 32:
                                v.ad = self._read(COMMAND, 64)
                            v.sr = restart[6]
                        v.gate = 254
                        self._wave(v)
                        self._super(v)
                        self._write(v, extra)
                        return
                    if v.tsync == 255:
                        self._start(v)
                        self._super(v)
                        self._write(v, extra)
                        return
        self._pulse(v)
        self._effects(v)
        self._wave(v)
        self._super(v)
        self._write(v, extra)

    def _write(self, v, extra):
        base = v.number * 7
        self.sid[base:base + 7] = bytes((v.freq & 255, v.freq >> 8,
            v.pulse & 255, v.pulse >> 8, v.waveform & v.gate, v.ad, v.sr))
        if extra or v.tsync != 255:
            return
        v.tsync = _dec(v.tsync)
        if not v.tie:
            return
        if v.shnote == 0:
            # A still holds the zero note at tiestore.
            v.tie = 0
        elif v.shnote < 3:
            v.gate = 254 if v.shnote == 1 else 255
            v.tie = 0
        else:
            v.note = (v.shnote + v.shtrans) & 255
            if v.effect < 128:
                v.offset = v.effect = 0
                v.tie = 0
            else:
                v.tie = 0

    def _filter(self):
        if self.filter_used:
            self.filtcnt = _dec(self.filtcnt)
            if _negative(self.filtcnt):
                self.filtcur = self.filtnxt
                duration = self._read(FILTER, self.filtcur)
                add = self._read(FILTER, self.filtcur + 1)
                if duration >= 128:
                    self.bandpass = duration & 112
                    self.sid[23] = add
                    duration = 0
                self.filtcnt = duration
                self.filtfraction = (add & 3) << 1
                self.filtadd = ((add - 256 if add & 128 else add) >> 2) & 255
                nxt = self._read(FILTER, self.filtcur + 3)
                self.filtnxt = ((self.filtnxt + 4) & 255 if not nxt else
                               0 if nxt == 127 else (nxt << 2) & 255)
                preset = self._read(FILTER, self.filtcur + 2)
                if preset != 255:
                    self.cutoff, self.filtlo = preset, 0
            else:
                fraction = self.filtlo + self.filtfraction
                self.filtlo = fraction & 7
                self.cutoff = (self.cutoff + self.filtadd + (fraction >= 8)) & 255
            self.sid[21:23] = bytes((self.filtlo, self.cutoff))
        self.sid[24] = self.volume | self.bandpass

    def frames(self, n):
        """Return the next n play-call snapshots; successive calls continue playback."""
        if n < 0:
            raise ValueError('Frame count cannot be negative.')
        result = []
        for _ in range(n):
            extra = self.calls % self.multiplier != 0
            if self.calls == 0:
                self.sid[23] = 240  # Cold start returns before sound/filter.
            else:
                if not extra:
                    self.speedcnt = _dec(self.speedcnt)
                    if _negative(self.speedcnt):
                        speed = self.speed
                        # CMP #2 / BPL, deliberately signed, in the source.
                        if _negative((speed - 2) & 255):
                            speed = self._read(CHORD, self.speedsub)
                            if speed >= 128:
                                self.speedsub = 0
                                speed = self._read(CHORD)
                            self.speedsub = (self.speedsub + 1) & 255
                            if _negative((speed - 2) & 255):
                                speed = 2
                        self.speedcnt = speed
                for v in reversed(self.voices):
                    if not extra:
                        v.synccnt = (v.synccnt + 1) & 255
                        if self.speedcnt == 1:
                            self._track(v)
                        elif self.speedcnt == 0:
                            self._row(v)
                    self._sound(v, extra)
                self._filter()
            result.append(bytes(self.sid))
            self.calls += 1
        return result


def simulate_voice(instrument, notes_events, frames, tables):
    """Run one sound program without order lists or sequence decoding.

    tables is a decompressed CC2 payload (or {'image': payload, 'voice': 0}).
    instrument is an index 0..47 or an eight-byte definition. Events are
    (call, note), (call, note, super), or (call, note, super, tie) tuples.
    A call marks the sequence-latch tick: normal notes open two base ticks
    later. Returns full 25-byte snapshots, including the shared filter.
    The selected voice retains its legacy frequency-offset seed.
    """
    image = tables['image'] if isinstance(tables, dict) else tables
    number = tables.get('voice', 0) if isinstance(tables, dict) else 0
    if number not in range(3):
        raise ValueError('Voice must be 0, 1 or 2.')
    if not isinstance(instrument, int):
        if len(instrument) != 8:
            raise ValueError('Instrument definition must contain eight bytes.')
        image = bytearray(image)
        addr = struct.unpack_from('<H', image, 0xFA0 + INST * 2)[0]
        for col, value in enumerate(instrument):
            image[addr + col * 48 + 1] = value
        instrument = 1
    if not 0 <= instrument < 48:
        raise ValueError('Instrument index must be 0..47.')
    player = CTPlayer(image)
    voice = player.voices[number]
    voice.shinst = instrument
    player.sid[23] = 240
    events = {}
    for event in notes_events:
        if len(event) not in (2, 3, 4) or event[0] in events:
            raise ValueError('Expected one (call, note[, super[, tie]]) event per call.')
        events[event[0]] = event[1:]
    result = []
    for call in range(frames):
        extra = call % player.multiplier != 0
        if call in events:
            if extra:
                raise ValueError('Note events must fall on base ticks.')
            note, *options = events[call]
            voice.tsync = 2
            voice.newins = 1
            voice.tie = int(bool(options[1])) if len(options) > 1 else 0
            if options and options[0]:
                voice.shsuper, voice.newcmd = options[0], 1
            player._latch(voice, note)
        if not extra:
            voice.synccnt = (voice.synccnt + 1) & 255
        player._sound(voice, extra)
        player._filter()
        result.append(bytes(player.sid))
    return result
