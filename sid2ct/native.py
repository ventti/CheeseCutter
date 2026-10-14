"""Map observed sound trajectories into native CC wave/pulse/filter programs.

The CC2 image layout is the same public offset-table format used by Song and
its import tests. A fresh player image supplies pointers; no source player code
is installed in the reconstructed song.
"""
from collections import Counter
from functools import lru_cache
import math
import re
import struct
import zlib

from . import budget
from .coupling import dependency_masks, trajectory_distance


def dmc_tuning(raw):
    """Narrow DMC4 anchor; read source tuning from confirmed code operands.

    Format reference: https://github.com/anarkiwi/pydmcsid/docs/format.md
    Other DMC generations intentionally fall back to generic pitch estimation.
    """
    offset, load = struct.unpack_from('>HH', raw, 6)
    payload = raw[offset:]
    if not load:
        load, payload = int.from_bytes(payload[:2], 'little'), payload[2:]
    def word(i):
        return int.from_bytes(payload[i:i+2], 'little')
    if len(payload) < 0x900 or payload[0] != 0x4C or payload[3] != 0x4C:
        return None
    play = word(4)-load
    if not 0 <= play < len(payload)-3 or payload[play] != 0xCE or word(play+1) != load+0x718:
        return None
    for match in re.finditer(rb'\xb9(..)\x9d..\xb9(..)\x9d..', payload[:0x647], re.S):
        lo, hi = (int.from_bytes(x,'little')-load for x in match.groups())
        if hi-lo != 96 or not 0 <= lo < hi <= len(payload)-96:
            continue
        values = [payload[lo+i] | payload[hi+i]<<8 for i in range(96)]
        if 200 <= values[0] <= 350 and all(a < b for a,b in zip(values[:72],values[1:73])):
            return values
    return None


def indexed_tuning(raw, frames):
    """Recover an indexed 96-note table only with code and trace corroboration.

    Multiple paired LDA abs,X/Y sites must reference its low/high halves.
    Reject ambiguous tables and require observed tonal pitches to support it.
    This identifies tuning data, not a particular source-player format.
    """
    offset, load = struct.unpack_from('>HH', raw, 6)
    payload = raw[offset:]
    if not load:
        load, payload = int.from_bytes(payload[:2], 'little'), payload[2:]
    sites = Counter()
    for i in range(len(payload)-3):
        opcode = payload[i]
        if opcode not in (0xB9, 0xBD):
            continue
        a = int.from_bytes(payload[i+1:i+3], 'little')
        for j in range(i+3, min(i+13, len(payload)-2)):
            if payload[j] != opcode:
                continue
            b = int.from_bytes(payload[j+1:j+3], 'little')
            if abs(a-b) == 96:
                sites[min(a,b)-load] += 1
    observed = Counter(f[b] | f[b+1]<<8 for f in frames for b in (0,7,14)
                       if f[b+4]&0x70 and f[b+4]&1 and not f[b+4]&8)
    candidates = []
    for lo, count in sites.items():
        if count < 2 or not 0 <= lo <= len(payload)-192:
            continue
        values = [payload[lo+i] | payload[lo+96+i]<<8 for i in range(96)]
        if not 200 <= values[0] <= 350 or not all(a < b for a,b in zip(values,values[1:])):
            continue
        if any(abs(12*math.log2(b/a)-1) > .15 for a,b in zip(values[:71],values[1:72])):
            continue
        matches = set(values) & observed.keys()
        if len(matches) < 6 or sum(observed[v] for v in matches) < sum(observed.values())/2:
            continue
        candidates.append(values)
    return candidates[0] if len(candidates) == 1 else None


def sound_distance(left, right):
    """Compare observed timbre when editable instrument capacity is exhausted.

    Absolute note identity is deliberately excluded; envelopes, waveform shape,
    duty cycle and filter routing determine the closest available sound.
    """
    ad, sr, wave, pulse, filt = left
    other_ad, other_sr, other_wave, other_pulse, other_filter = right
    envelope = sum(abs(a-b) for a,b in zip(
        (ad>>4, ad&15, sr>>4, sr&15),
        (other_ad>>4, other_ad&15, other_sr>>4, other_sr&15)))
    def controls(program):
        return [control & 0xFE for _,control in program if control >= 16]
    a, b = controls(wave), controls(other_wave)
    shape = sum((x^y).bit_count() for x,y in zip(a,b)) + 4*abs(len(a)-len(b))
    def width(program):
        preset = program[0][2] if program else 0
        return ((preset&15)<<8) | (preset&0xF0)
    duty = abs(width(pulse)-width(other_pulse))/64
    filtering = 0
    if bool(filt) != bool(other_filter):
        filtering = 100
    elif filt:
        filtering = ((filt[0][0]^other_filter[0][0])&0x70).bit_count()*40
        filtering += (filt[0][1]^other_filter[0][1]).bit_count()*10
        filtering += abs(filt[0][2]-other_filter[0][2])/4
    return envelope*20 + shape*30 + duty + filtering + abs(len(wave)-len(other_wave))/4


def _solve_allocation(frames, events, stops, plans, usage, weighted, eff, data, offset, output_multiplier, multiplier,
                      coupled_signatures, protected, hints, hint_scale, time_limit, report, params=None):
    """CP-SAT allocation (sid2ct.solve); None means: use the greedy budget allocation instead."""
    from .allocation import select_with_budgets, program_cost
    from . import solve
    limits = (47, 254, 63, 63)
    allocation = report.setdefault('allocation', {})
    if len(weighted) <= 47 and all(c <= b for c, b in zip(program_cost(list(weighted)), limits)):
        allocation.update(status='trivial', objective=0.0)
        return list(weighted), {}, 0
    try:
        warm = select_with_budgets(weighted, instrument_limit=47, wave_limit=254, pulse_limit=63,
                                   filter_limit=63, coupled=coupled_signatures, protected=protected)
    except ValueError:
        warm = None
    make_image = solve.ImageMaker(data, {i: offset(i) for i in (14, 15, 16, 17)}, output_multiplier)
    from .effectmap import COMMAND_ROWS
    try:
        selected, assignment, solved = solve.allocate(
            events, stops, plans, frames=frames, usage=usage, step=max(1, multiplier // output_multiplier),
            effects=eff is not None, make_image=make_image, output_multiplier=output_multiplier,
            limits=limits, coupled_signatures=coupled_signatures, protected=protected,
            warm_selection=warm, hints=hints, hint_scale=hint_scale, time_limit=time_limit,
            free_commands=frozenset(eff.commands) if eff is not None else frozenset(),
            command_limit=COMMAND_ROWS - eff.reserved - len(eff.commands) if eff is not None else 0,
            workers=int(__import__('os').environ.get('SID2CT_WORKERS') or __import__('os').cpu_count() or 1), params=params,
            compare_warm=bool(__import__('os').environ.get('SID2CT_SOLVE_DEBUG')),
            evaluate={'legacy': [sig for sig, _ in usage.most_common(47)]} if __import__('os').environ.get('SID2CT_SOLVE_DEBUG') else None)
    except budget.BudgetExpired:
        raise
    except Exception as error:  # the greedy allocation still works; keep the reason in the report
        allocation.update(status='error', error=f'{type(error).__name__}: {error}')
        return None
    allocation.update(solved)
    if hints is not None:
        allocation['hint_player'] = hints.player
    if selected is None:
        return None
    allocation['tables'] = dict(zip(('instruments', 'wave_rows', 'pulse_rows', 'filter_rows'),
                                    program_cost(selected)))
    allocation['repaired_variants'] = sum(1 for v in assignment.values() if v[2])
    return selected, assignment, 0


def _native_song(template, frames, multiplier, row_frames, metadata, frequencies=None, output_multiplier=1, loop_start=None, pitch_programs="attack", modulation_programs="legacy", coupled_programs="legacy", instrument_allocation="legacy", change_points=False, pattern_mining=False, joint_modeling=False, layout="chunks", effect_programs="off", filter_mode="instrument", solve_time_limit=20.0, structure_hints=None, hint_scale=1.0, effect_tolerance=12.0, solve_params=None):
    if effect_programs not in ("off", "on"):
        raise ValueError("Effect programmes must be off or on.")
    if layout not in ("chunks", "compact"):
        raise ValueError("Layout must be chunks or compact.")
    if instrument_allocation not in ("legacy", "trajectory", "budget", "solve"):
        raise ValueError("Instrument allocation must be legacy, trajectory, budget or solve.")
    if joint_modeling and coupled_programs != "preserve":
        raise ValueError("Joint modeling requires preserved physical oscillator dependencies.")
    if coupled_programs not in ("legacy", "preserve"):
        raise ValueError("Coupled programmes must be legacy or preserve.")
    if modulation_programs not in ("legacy", "compact"):
        raise ValueError("Modulation programmes must be legacy or compact.")
    if pitch_programs not in ("attack", "compact", "full"):
        raise ValueError("Pitch programmes must be attack, compact or full.")
    if output_multiplier not in (1, multiplier):
        raise ValueError('Native sound rate must be base rate or source rate.')
    data = bytearray(zlib.decompress(template[3:]))
    if template[:3] != b'CC2' or len(data) < 167832:
        raise ValueError('Invalid CC2 template.')
    def offset(index):
        addr = struct.unpack_from('<H', data, 0xFA0+index*2)[0]
        if not 0 < addr < 65536:
            raise ValueError('Invalid native table pointer.')
        return addr
    def put(index, values):
        addr = offset(index)
        if addr+len(values) > 65536:
            raise ValueError('Native table exceeds image.')
        data[addr:addr+len(values)] = bytes(values)
    # Older player images point both frequency slots to the one-byte dummy
    # immediately before the actual table. Upgrade this image's pointer.
    freq_addr=offset(12)+(1 if offset(12)==offset(13) else 0)
    struct.pack_into('<H',data,0xFA0+12*2,freq_addr)
    default_tuning = [data[freq_addr+i] | data[freq_addr+96+i]<<8 for i in range(96)]
    tuning = frequencies or default_tuning
    tuning_offset = 0.0
    if frequencies:
        put(12, [v & 255 for v in tuning]+[v>>8 for v in tuning])
    elif effect_programs == 'on':
        # A uniformly detuned source cannot fit any effect; shift the table to it.
        from .ir import estimate_tuning
        step = max(1, multiplier // output_multiplier)
        tuning, tuning_offset = estimate_tuning(frames[::step], default_tuning)
        tuning = [min(65535, v) for v in tuning]
        if tuning_offset:
            put(12, [v & 255 for v in tuning]+[v>>8 for v in tuning])
    @lru_cache(maxsize=65536)
    def note(freq):
        return min(range(96), key=lambda n: abs(tuning[n]-freq)) if freq else 36
    required = dependency_masks(frames) if coupled_programs == "preserve" else [0]*len(frames)
    participating = 0
    for mask in required:
        participating |= mask
    if participating:
        # Relative lookup never uses notes 0..2. Reserve zero for a stopped
        # oscillator; absolute wave rows can select it without a note event.
        tuning = list(tuning)
        tuning[0] = 0
        put(12, [v & 255 for v in tuning]+[v>>8 for v in tuning])
    quantum = multiplier*row_frames
    count = (len(frames)+quantum-1)//quantum
    rows = [[[0xF0,0xF0,0x60,0] for _ in range(count)] for _ in range(3)]
    metrics = Counter()
    eff = None
    if effect_programs == 'on':
        from .effectmap import EffectPlanner
        eff = EffectPlanner(frames, multiplier, output_multiplier, tuning, row_frames,
                            full_pitch=pitch_programs == 'full',
                            reserved_commands=1 if participating else 0, tolerance=effect_tolerance)
    global_filter = None
    helper_report = {}
    if change_points:
        from .segmentation import detect_boundaries
        boundaries = detect_boundaries(frames, sustain=3*multiplier)
        helper_report['change_points'] = dict(mode='advisory', count=len(boundaries),
            reasons=dict(Counter(reason for boundary in boundaries for reason in boundary.reasons)),
            limitations='Boundaries do not retrigger envelopes; behavioral segmentation remains experimental.')
    groups = ()
    if joint_modeling:
        from .joint_voice import temporal_dependency_groups, group_trajectory
        groups = temporal_dependency_groups(frames)
        helper_report['joint_modeling'] = dict(groups=len(groups),
            sampled_ticks=sum(len(group_trajectory(frames[g.start:g.stop],
                type(g)(0,g.stop-g.start,g.voices,g.roots)).samples) for g in groups),
            mode='time-local coupled allocation weighting',
            limitations='Preserves topology and weights joint use; does not fit oscillator phase.')
    instruments = {}
    wave = [0, 0x7E]
    control = [0x11,0]
    pulses = [[0,0,255,127]]
    filters = [[0,0,255,127]]
    pulse_map, filter_map, wave_map = {}, {}, {}
    definitions = []
    events = []
    def make_wave(samples, base, coupled=False, flat=False):
        # Keep the attack/control trajectory and explicit release timing, but
        # compress runs using CC delay rows. Pitch changes use relative offsets
        # when possible so the instrument remains transposable.
        program = []
        for index,(f,b) in enumerate(samples):
            freq = f[b]|f[b+1]<<8
            n, c = note(freq), f[b+4]
            if freq > max(tuning):
                metrics['tuning_clamped_source_samples'] += 1
            # A fitted effect owns the pitch after the first row; that row keeps the
            # source's attack pitch (a noise hit starts high), as the plain program does.
            trans = 0 if flat and index else n-base if 0 <= n-base < 96 else 0x80+n
            if coupled and not freq:
                trans = 0x80
            if c < 16: c |= 0xE0
            program.append((trans,c))
        # Preserve six PAL frames at the selected sound rate. Later pitch
        # movement awaits slide/vibrato inference; control transitions remain.
        if pitch_programs != "full" and not coupled:
            for i in range(6*output_multiplier,len(program)):
                program[i] = (program[6*output_multiplier-1][0],program[i][1])
        # The end marker freezes the final waveform/pitch indefinitely. Final
        # hold duration has no effect and must not create distinct instruments.
        while (pitch_programs != "attack" or coupled) and len(program) > 1 and program[-1] == program[-2]:
            program.pop()
        out = []
        i = 0
        while i < len(program):
            pair = program[i]
            end=i+1
            while end<len(program) and program[end]==pair: end+=1
            duration=end-i
            # Counting the waveform and delay rows, delay D holds D+2 ticks.
            while duration:
                if duration <= 2:
                    out.extend([pair]*duration)
                    duration=0
                else:
                    held=min(17,duration)
                    out.extend([pair,(pair[0],held-2)])
                    duration-=held
            i=end
        out.append((0x7E,0))
        return tuple(out)
    def runs(values, maximum=8, wrap=None):
        """Piecewise linear sweep with signed slope; bounded programme size."""
        result=[]
        i=0
        while i+1<len(values) and len(result)<maximum:
            delta=values[i+1]-values[i]
            if wrap:
                delta=(delta+wrap//2)%wrap-wrap//2
            delta=max(-255,min(255,delta))
            end=i+1
            while end+1<len(values) and end-i<127:
                d=values[end+1]-values[end]
                if wrap: d=(d+wrap//2)%wrap-wrap//2
                if d!=delta: break
                end+=1
            result.append((end-i,delta))
            i=end
        return result
    def pulse_program(values):
        initial=values[0]//16*16
        result=[[0,0,(initial&0xF0)|(initial>>8),0]]
        for duration,delta in runs(values,maximum=4,wrap=4096):
            result.append([(duration-1)|(128 if delta<0 else 0),abs(delta),255,0])
        result[-1][3]=127
        return tuple(tuple(r) for r in result)
    def compact_pulse_program(values):
        # Stop freezes the final width. Trailing flat ticks are therefore
        # independent of note duration and must not fragment instruments.
        values = list(values)
        while len(values) > 1 and values[-1] == values[-2]:
            values.pop()
        def preset(value):
            value = value // 16 * 16
            # $ff means keep the current width, not a $ff0 preset.
            return min(value, 0xFE0)
        initial = preset(values[0])
        result = [[0, values[0]-initial,
                   (initial&0xF0)|(initial>>8), 0]]
        i = 1
        while i < len(values) and len(result) < 5:
            delta = (values[i]-values[i-1]+2048)%4096-2048
            if abs(delta) > 255:
                # A discontinuity is a reset, not a saturated sweep. The
                # pulse player applies the add on the preset tick as well.
                initial = preset(values[i])
                result.append([0, values[i]-initial,
                               (initial&0xF0)|(initial>>8), 0])
                i += 1
                continue
            end = i
            while end+1 < len(values) and end-i < 127:
                following = (values[end+1]-values[end]+2048)%4096-2048
                if following != delta:
                    break
                end += 1
            result.append([(end-i)|(128 if delta < 0 else 0), abs(delta), 255, 0])
            i = end+1
        result[-1][3] = 127
        return tuple(tuple(r) for r in result)

    def filter_program(samples):
        # CC keeps the eight high cutoff bits; small low-bit differences cannot
        # be represented by its editable filter presets.
        first=samples[0]
        initial=first[22]
        result=[[0x80|(first[24]&0x70),first[23],min(254,initial),0]]
        values=[f[22] for f in samples]
        i=1
        # A filter row's first tick sets its preset without adding the slope.
        # Reset at each boundary so discontinuities do not become clipped ramps.
        while i<len(values) and len(result)<4:
            delta=values[i+1]-values[i] if i+1<len(values) else 0
            end=i
            if -32<=delta<=31:
                while end+1<len(values) and end-i<127 and values[end+1]-values[end]==delta:
                    end+=1
            else:
                delta=0
            result.append([end-i,(delta*4)&255,min(254,values[i]),0])
            i=end+1
        result[-1][3]=127
        return tuple(tuple(r) for r in result)
    def attack_starts(v):
        b=v*7
        # TEST+GATE ($09) is a real envelope attack even without a waveform.
        starts=[i for i,f in enumerate(frames) if f[b+4]&1 and
                (i==0 or not frames[i-1][b+4]&1)]
        if participating & (1<<v) and (not starts or starts[0] != 0):
            # Seed even a waveform/gate-off modulator before the first attack.
            starts.insert(0, 0)
        return starts
    plans = {}
    wanted_adsr = {}
    stops = {}
    if eff is not None:
        requests = []
        for v in range(3):
            starts = attack_starts(v)
            for j,start in enumerate(starts):
                stop = starts[j+1] if j+1 < len(starts) else len(frames)
                if not any(mask & (1<<v) for mask in required[start:stop]):
                    requests.append((v,start,stop))
        plans = eff.plan(requests)
        if filter_mode == 'global':
            global_filter = eff.filter_plan()
            if global_filter is not None and not global_filter.ok:
                global_filter = None
    for v in range(3):
        b=v*7
        starts=attack_starts(v)
        for j,start in enumerate(starts):
            budget.check()
            stop=starts[j+1] if j+1<len(starts) else len(frames)
            segment=frames[start:stop:multiplier//output_multiplier]
            coupled = any(mask & (1<<v) for mask in required[start:stop])
            if not any(f[b+4]&0xF0 for f in segment) and not coupled:
                continue
            # Reject noise/TEST transients as the melodic fundamental.
            pitches=[f[b]|f[b+1]<<8 for f in segment[3:] if f[b+4]&0x70 and not f[b+4]&8]
            if not pitches: pitches=[f[b]|f[b+1]<<8 for f in segment if f[b]|f[b+1]<<8]
            base=note((min(pitches) if pitch_programs == "full" or coupled else
                       Counter(pitches).most_common(1)[0][0])) if pitches else 36
            # Sequence bytes reserve notes 0..2 and 95 for controls. Wave
            # rows can still select every table entry, including note 95.
            plan = plans.get((v,start)) if not coupled else None
            if plan is not None:
                base = plan.base
            base = max(3, min(94, base))
            ad,sr=segment[0][b+5:b+7]
            # A waveform programme owns short gates, avoiding a row-level
            # keyoff overwriting a note that lands on the same coarse row.
            cutoff=next((i for i,f in enumerate(segment) if i>0 and not f[b+4]&1),len(segment))
            length=(len(segment) if pitch_programs == "full" or coupled else
                    min(len(segment), max(8*output_multiplier,cutoff+1),64*output_multiplier))
            if plan is not None and plan.arpeggio():
                from .effectmap import arpeggio_program
                wp=arpeggio_program(plan)
            else:
                wp=make_wave([(f,b) for f in segment[:length]],base,coupled,flat=plan is not None)
            pp=(compact_pulse_program if modulation_programs == "compact" else pulse_program)([(f[b+2]|f[b+3]<<8)&4095 for f in segment[:min(64*output_multiplier,len(segment))]]) if any(f[b+4]&0x40 for f in segment) else ()
            fp=filter_program(segment[:min(64*output_multiplier,len(segment))]) if segment[0][23]&(1<<v) and (eff is None or filter_mode != 'global') else ()
            # Programme signatures cluster musical sounds independently of pitch.
            # Legacy widths are quantized; compact programs retain low bits.
            signature=(ad,sr,wp,pp,fp)
            events.append((v,start,base,signature,coupled))
            stops[(v,start)] = stop
            wanted_adsr[(v,start)] = (ad,sr)
            if coupled:
                metrics['coupled_oscillator_events'] += 1
                if not any(f[b+4]&0xF0 for f in segment):
                    metrics['waveform_off_modulator_events'] += 1
    if not events:
        raise ValueError('No playable attacks found for native reconstruction.')
    adsr_supers = {}
    if eff is not None and instrument_allocation != 'solve' and len({e[3] for e in events}) > 47:
        # Capacity pressure: sounds that differ only in AD/SR share the shape's
        # most used envelope; the difference becomes a nibble super or command 4.
        shapes = {}
        for e in events:
            if not e[4]:
                shapes.setdefault(e[3][2:], Counter())[e[3][:2]] += 1
        common = {shape: counts.most_common(1)[0][0] for shape,counts in shapes.items()}
        for index,(v,start,base,signature,coupled) in enumerate(events):
            representative = common.get(signature[2:])
            if coupled or representative is None or signature[:2] == representative:
                continue
            plan = plans.get((v,start))
            if plan is not None and (plan.command or plan.chord):
                continue
            sup = eff.adsr_super(signature[:2], representative)
            if sup:
                adsr_supers[(v,start)] = sup
                events[index] = (v,start,base,representative+signature[2:],coupled)
    # Allocate frequently-used sounds first. Rare variants reuse an existing
    # sound when an instrument/programme table reaches editable capacity.
    usage=Counter(e[3] for e in events)
    silent_fallback = None
    def waveform_off(signature):
        return all(not (c & 0xF0) if c < 0xE0 else True
                   for _,c in signature[2] if c >= 16)
    if participating and any(e[4] and waveform_off(e[3]) for e in events):
        # A long hidden oscillator can exceed the wave table. Reserve a silent
        # approximation so capacity fallback never turns it into a new voice.
        silent_fallback = (0,0,((0,0xE0),(0x7E,0)),(),())
    allocation = usage.most_common()
    if instrument_allocation != 'legacy':
        from .allocation import select_representatives, select_with_budgets
        weighted = Counter(usage)
        if joint_modeling:
            for v,start,base,signature,coupled in events:
                # Weight only the local event onset, never retroactive song-wide membership.
                if any(g.start <= start < g.stop and v in g.voices for g in groups):
                    weighted[signature] += 1
        protected = ()
        if silent_fallback is not None:
            weighted.setdefault(silent_fallback, 1)
            protected = (silent_fallback,)
        coupled_signatures = {e[3] for e in events if e[4]}
        solved = None
        if instrument_allocation == 'solve':
            solved = _solve_allocation(frames, events, stops, plans, usage, weighted, eff, data, offset, output_multiplier,
                                       multiplier, coupled_signatures, protected, structure_hints, hint_scale,
                                       solve_time_limit, helper_report, solve_params)
        if solved is not None:
            selected, forced, repaired = solved
            for index,(v,start,base,signature,coupled) in enumerate(events):
                target = forced.get(signature)
                if target is None or target[0] == signature or not target[2]:
                    continue
                wanted = (v,start)
                sup = eff.adsr_super(signature[:2], target[0][:2])
                plan = plans.get(wanted)
                if coupled or sup is None or (plan is not None and (plan.command or plan.chord)):
                    continue
                if sup:
                    adsr_supers[wanted] = sup
                events[index] = (v,start,base,target[0],coupled)
            selected.sort(key=lambda signature: (-len(signature[2]), signature))
            allocation = [(signature,usage.get(signature,0)) for signature in selected]
        elif instrument_allocation in ('budget','solve'):
            selected = select_with_budgets(weighted, instrument_limit=47,
                wave_limit=254, pulse_limit=63, filter_limit=63,
                coupled=coupled_signatures, protected=protected)
            # Store longer programs first so exact suffix costs match admission.
            selected.sort(key=lambda signature: (-len(signature[2]), signature))
            allocation = [(signature,usage[signature]) for signature in selected]
        else:
            selected = select_representatives(weighted, limit=47,
                coupled=coupled_signatures, protected=protected)
            allocation = [(signature,usage[signature]) for signature in selected]
            allocation += [(signature,weight) for signature,weight in usage.most_common()
                           if signature not in selected]
        helper_report.setdefault('allocation', {}).update(mode=instrument_allocation, selected=len(selected))
        if instrument_allocation == 'solve' and solved is None:
            helper_report['allocation']['fallback'] = 'budget'
    if silent_fallback is not None and silent_fallback not in dict(allocation):
        allocation.insert(0,(silent_fallback,0))
    for signature,_ in allocation:
        ad,sr,wp,pp,fp=signature
        if len(definitions)>=47: continue
        wi=wave_map.get(wp)
        if wi is None:
            # A complete programme may already be the exact suffix of another
            # one. Reuse its native start pointer without changing playback.
            for start in range(2, len(wave)-len(wp)+1):
                if tuple(zip(wave[start:start+len(wp)], control[start:start+len(wp)])) == wp:
                    wi = start
                    wave_map[wp] = wi
                    metrics['shared_wave_programs'] += 1
                    break
        if wi is None:
            if len(wave)+len(wp)>256: continue
            wi=len(wave); wave_map[wp]=wi
            wave.extend(x for x,_ in wp); control.extend(y for _,y in wp)
        pi=pulse_map.get(pp,0)
        if pp and not pi:
            if len(pulses)+len(pp)<=64:
                pi=len(pulses); pulse_map[pp]=pi
                for i,r in enumerate(pp):
                    rr=list(r)
                    rr[3]=pi+i+1 if i+1<len(pp) else 127
                    pulses.append(rr)
            else: metrics['pulse_programs_omitted']+=1
        fi=filter_map.get(fp,0)
        if fp and not fi:
            if len(filters)+len(fp)<=64:
                fi=len(filters); filter_map[fp]=fi
                for i,r in enumerate(fp):
                    rr=list(r)
                    rr[3]=fi+i+1 if i+1<len(fp) else 127
                    filters.append(rr)
            else: metrics['filter_programs_omitted']+=1
        idx=len(definitions)+1
        # An arpeggio program's end row carries the chord step as the wave time.
        definitions.append([ad,sr,wp[-1][1] if wp[-1][0] == 0x7E else 0,0,fi,pi,0,wi])
        instruments[signature]=idx
    if not definitions:
        raise ValueError('Sound programmes exceed native capacity.')
    # Only waveform rows perform lookups; delay and end rows are controls.
    relative_limits = {
        index: max((n for n, c in signature[2] if c >= 16 and n < 128), default=0)
        for signature, index in instruments.items()
    }
    fallbacks = {}
    placed = {}
    forced = forced if instrument_allocation == 'solve' and solved is not None else {}
    for v,start,base,signature,coupled in events:
        ins=instruments.get(signature)
        exact = ins is not None
        if ins is None:
            context = (signature,coupled,base)
            ins = fallbacks.get(context)
            target = forced.get(signature)
            if ins is None and target is not None and target[0] in instruments and base + relative_limits[instruments[target[0]]] <= 95:
                ins = fallbacks[context] = instruments[target[0]]
            if ins is None:
                # Favor envelope/control likeness before trajectory length.
                def distance(other):
                    if instrument_allocation != 'legacy':
                        from .allocation import trajectory_distance as allocation_distance
                        return allocation_distance(signature, other, coupled=coupled)
                    if coupled:
                        return sound_distance(signature, other) + trajectory_distance(signature[2], other[2])
                    if pitch_programs == 'full':
                        return sound_distance(signature, other)
                    a,s,w,p,f = other
                    return ((a!=signature[0])+(s!=signature[1]))*100 + abs(len(w)-len(signature[2])) + (w[0][1]^signature[2][0][1]).bit_count()*20
                choices = instruments
                if coupled and waveform_off(signature):
                    choices = {key:value for key,value in instruments.items() if waveform_off(key)}
                if instrument_allocation != 'legacy':
                    choices = {key:value for key,value in choices.items()
                               if waveform_off(key) == waveform_off(signature)}
                safe_choices = {key: value for key, value in choices.items()
                                if base + relative_limits[value] <= 95}
                if safe_choices:
                    if len(safe_choices) < len(choices):
                        metrics['tuning_safe_fallback_selections'] += 1
                    choices = safe_choices
                if not choices:
                    raise ValueError('No compatible packed instrument for oscillator waveform class.')
                ins=instruments[min(choices,key=lambda key:(distance(key), instruments[key]))]
                fallbacks[context] = ins
            if coupled and waveform_off(signature):
                metrics['waveform_off_modulator_approximations'] += 1
            metrics['approximated_instrument_attacks']+=1
            if coupled:
                metrics['approximated_coupled_events'] += 1
        maximum_base = 95 - relative_limits[ins]
        if base > maximum_base:
            metrics['tuning_clamped_events'] += 1
            base = maximum_base
        row=min(count-1,(start+quantum//2)//quantum)
        if rows[v][row][2]!=0x60: metrics['row_collisions']+=1
        if start!=row*quantum: metrics['quantized_events']+=1
        rows[v][row]=[0xC0+ins,0xF0,0x60+base,1 if coupled else 0]
        placed[(v,row)] = (start,exact,coupled)
    if eff is not None:
        occupied = {v: {r for r,row in enumerate(rows[v]) if row[3] or row[2] == 0x61} for v in range(3)}
        blank = [0xF0,0xF0,0x60,0]
        effect_stats = Counter()
        for (v,row),(start,exact,coupled) in sorted(placed.items()):
            plan = plans.get((v,start))
            if coupled or rows[v][row][3]:
                continue
            sup = adsr_supers.get((v,start), 0)
            if plan is not None and plan.arpeggio():
                if not exact:
                    effect_stats['arpeggio_on_approximated_instrument'] += 1
                    continue
                keyoff = row + plan.keyoff_rows if plan.keyoff_rows else None
                if keyoff is not None and (keyoff >= count or rows[v][keyoff] != blank):
                    effect_stats['arpeggio_keyoff_unavailable'] += 1
                    continue
                sup = eff.chord_super(plan)
                if keyoff is not None:
                    rows[v][keyoff] = [0xF0,0xF0,0x61,0]
                    occupied[v].add(keyoff)
                effect_stats['arpeggio_rows'] += 1
            elif plan is not None and plan.command:
                target = row + plan.delay_rows
                if target >= count or any(rows[v][k][2] != 0x60 for k in range(row+1, target+1)):
                    effect_stats['effect_delay_rows_unavailable'] += 1
                    continue
                if plan.delay_rows:
                    if rows[v][target][3]:
                        effect_stats['effect_delay_rows_unavailable'] += 1
                        continue
                    rows[v][target][3] = eff.command_super(plan)
                    occupied[v].add(target)
                    effect_stats['delayed_command_rows'] += 1
                    continue
                sup = eff.command_super(plan)
                effect_stats['command_rows'] += 1
            if sup:
                rows[v][row][3] = sup
                occupied[v].add(row)
                if (v,start) in adsr_supers:
                    effect_stats['adsr_supers'] += 1
        if global_filter is not None:
            for hosted in eff.host(global_filter.starts, occupied, frame_of=lambda e: e.frame):
                if hosted.voice is None or hosted.row >= count:
                    effect_stats['filter_starts_unhosted'] += 1
                    continue
                rows[hosted.voice][hosted.row][3] = 0x60 + hosted.event.row
                effect_stats['filter_starts'] += 1
            filters = [list(r) for r in global_filter.table]
        for hosted in eff.host(eff.volume_events(), occupied, frame_of=lambda e: e.frame):
            if hosted.voice is None or hosted.row >= count:
                effect_stats['volume_events_unhosted'] += 1
                continue
            rows[hosted.voice][hosted.row][3] = hosted.event.super_byte
            effect_stats['volume_events'] += 1
    put(14,wave+[0]*(256-len(wave)))
    put(15,control+[0]*(256-len(control)))
    put(17,[x for r in pulses for x in r]+[0]*(256-4*len(pulses)))
    put(16,[x for r in filters for x in r]+[0]*(256-4*len(filters)))
    inst=[0]*384
    for i,d in enumerate(definitions,1):
        for col,x in enumerate(d): inst[col*48+i]=x
    put(18,inst)
    commands = [0]*256
    if participating:
        # CMD_SET_OFFSET(0) removes CC's legacy per-voice frequency seed.
        # This prevents a one/two-unit error in coupled oscillator ratios.
        commands[1] = 3
    chord_table = [0]*128
    if eff is not None:
        for (op,hi,lo),index in eff.commands.items():
            commands[index], commands[64+index], commands[128+index] = op, hi, lo
        chord_table[:len(eff.chord_table)] = eff.chord_table
    put(24,commands)
    put(30,chord_table)
    # Clear sequence slots and install deduplicated 64-row chunks.
    seqlo,seqhi=offset(22),offset(23)
    sequence_map={}
    next_seq=1
    from .loops import pattern_spans
    spans, restart = pattern_spans(count, quantum, loop_start)
    plans = None
    if pattern_mining:
        from .patterns import mine_patterns
        original = tuple(tuple(tuple(row) for row in voice) for voice in rows)
        boundary = spans[restart][0]
        try:
            plan = mine_patterns(original, loop_start=boundary)
            if plan.expand() != original:
                raise ValueError('Pattern expansion changed physical voice rows.')
            fixed_patterns = {tuple(tuple(row) for row in voice[a:b])
                              for voice in rows for a,b in spans}
            if (len(plan.patterns) <= len(fixed_patterns) and
                all(len(order)*2+2 <= 1024 for order in plan.orders) and
                all(index <= 255 for index in plan.restarts)):
                plans = [( [plan.patterns[index] for index in order], restart_index)
                         for order,restart_index in zip(plan.orders,plan.restarts)]
            helper_report['patterns'] = dict(lossless=True, applied=plans is not None,
                mined_patterns=len(plan.patterns), fixed_patterns=len(fixed_patterns),
                search_rows=plan.search_rows, search_exhausted=plan.search_exhausted)
        except ValueError as error:
            helper_report['patterns'] = dict(applied=False, retained='fixed chunks', reason=str(error))
    if plans is None:
        plans = [([voice[a:b] for a,b in spans], restart) for voice in rows]
    compact_plan = None
    if layout == "compact":
        from .layout import (Row, compress, expand, comparison, verify_player,
                             without_repeated_instruments, row_statistics, chunk_layout, verify_export)
        original = tuple(tuple(Row.from_native(row) for row in voice) for voice in rows)
        boundary = spans[restart][0]
        statistics = row_statistics(original)
        try:
            # Build the model's complete sound context before installing rows.
            model_image = bytearray(data)
            model_image[65538] = output_multiplier
            model_image[65541:65573] = bytes([row_frames-1])*32
            # First prove that the original has defined tuning accesses. Even
            # untransposed reuse changes adjacent memory in packed exports.
            fixed = chunk_layout(original, loop_start=boundary)
            verify_player(model_image, original, fixed, loop_start=boundary)
            compact_plan = compress(original, loop_start=boundary)
            if expand(compact_plan) != original:
                raise ValueError('Layout expansion changed rows.')
            verified_calls = verify_player(model_image, original, compact_plan,
                                           loop_start=boundary)
            # A repeated instrument byte can reset effects or shadow ADSR.
            # Accept its omission only after full player comparison.
            reduced = without_repeated_instruments(original)
            try:
                smaller = compress(reduced, loop_start=boundary)
                from .layout import layout_cost
                if layout_cost(smaller) < layout_cost(compact_plan):
                    verified_calls = verify_player(model_image, original, smaller,
                                                   loop_start=boundary)
                    compact_plan = smaller
            except ValueError:
                pass
            export_calls = verify_export(model_image, original, compact_plan,
                                         loop_start=boundary, calls=max(15000, verified_calls))
            helper_report['layout'] = dict(applied=True, verified_calls=verified_calls,
                verified_export_calls=export_calls,
                **statistics, **comparison(original, compact_plan, loop_start=boundary))
            plans = [([tuple(row.native() for row in compact_plan.sequences[seq-1])
                       for trans, seq in order], voice_restart)
                     for order, voice_restart in zip(compact_plan.orders, compact_plan.restarts)]
        except Exception as error:
            compact_plan = None
            helper_report['layout'] = dict(applied=False, retained='fixed chunks', reason=str(error),
                **statistics, **comparison(original, chunk_layout(original, loop_start=boundary),
                                           loop_start=boundary))
            plans = [([voice[a:b] for a,b in spans], restart) for voice in rows]
    orders=[]
    for vid, (chunks, voice_restart) in enumerate(plans):
        order=[]
        for chunk_index, chunk in enumerate(chunks):
            raw=bytes(x for r in chunk for x in r)
            if len(chunk)<64: raw+=bytes([0xBF])
            raw=raw.ljust(256,b'\0')
            if raw not in sequence_map:
                if next_seq>=128: raise ValueError('Native reconstruction exceeds 127 sequences.')
                sequence_map[raw]=next_seq
                addr=data[seqlo+next_seq]|data[seqhi+next_seq]<<8
                data[addr:addr+256]=raw
                next_seq+=1
            trans = compact_plan.orders[vid][chunk_index][0] if compact_plan else 0
            order.extend([0xA0+trans,sequence_map[raw]])
        order.extend([0xF0 | ((voice_restart*2)>>8), (voice_restart*2)&255])
        if len(order)>1024: raise ValueError('Native reconstruction exceeds order capacity.')
        orders.append(bytes(order).ljust(1024,b'\0'))
    if restart > 255: raise ValueError("Loop restart exceeds native order capacity.")
    tracks=65536+256+5+160+2048
    data[tracks:tracks+32*3*1024]=(bytes([0xA0,0])+bytes([0xF0,0])*511)*(32*3)
    for v,order in enumerate(orders):
        data[tracks+v*1024:tracks+(v+1)*1024]=order
        put(19+v,order)
    # Disable unused bundled demo material in remaining sequence slots.
    for i in [0,*range(next_seq,128)]:
        addr=data[seqlo+i]|data[seqhi+i]<<8
        data[addr:addr+256]=bytes([0xF0,0xF0,0x60,0,0xBF])+bytes(251)
    data[65538]=output_multiplier
    data[65541:65573]=bytes([row_frames-1])*32
    data[offset(4)]=row_frames-1
    data[offset(26)]=row_frames-1
    data[offset(3)+6]=row_frames-1
    title=65536+256+5
    for i,s in enumerate(metadata):
        data[title+i*32:title+(i+1)*32]=s.encode('latin1',errors='replace')[:32].ljust(32,b' ')
    names=title+160
    data[names:names+48*32]=b' '*(48*32)
    for i in range(1,len(definitions)+1):
        data[names+i*32:names+(i+1)*32]=f'Inferred {i:02X}'.encode().ljust(32,b' ')
    # Check the final installed order transpose, instrument and wave state,
    # including loop-boundary carry, with the exact exported player model.
    from .ctplayer import CTPlayer
    player = CTPlayer(data)
    frequency = player._frequency
    metrics['tuning_range_violations'] = 0
    def checked_frequency(index):
        if not 0 <= (index & 255) <= 95:
            metrics['tuning_range_violations'] += 1
            raise ValueError(f'Native player tuning index {index & 255} outside 0..95')
        return frequency(index)
    player._frequency = checked_frequency
    validation_calls = (count + 2*(count-spans[restart][0]) + 64)*max(3, row_frames)*output_multiplier + 8
    for _ in range(validation_calls):
        player.frames(1)
    metrics['tuning_range_verified_calls'] = validation_calls
    metrics.setdefault('tuning_safe_fallback_selections', 0)
    metrics.setdefault('tuning_clamped_events', 0)
    metrics.setdefault('tuning_clamped_source_samples', 0)
    report=dict(mode='trace-reconstruction',sound_programs='dynamic',source_calls=len(frames),
                source_calls_per_second=50*multiplier,source_multiplier=multiplier,
                output_multiplier=output_multiplier,pitch_programs=pitch_programs,modulation_programs=modulation_programs,coupled_programs=coupled_programs,coupled_voices=[v+1 for v in range(3) if participating&(1<<v)],row_frames=row_frames,captured_seconds=len(frames)/(50*multiplier),
                instruments=len(definitions),observed_instrument_variants=len(usage),patterns=len(sequence_map),wave_rows=len(wave),
                pulse_rows=len(pulses),filter_rows=len(filters),events=len(events),**metrics)
    if eff is not None:
        report['effect_programs'] = effect_programs
        report['effects'] = dict(eff.metrics, **effect_stats, command_table_rows=len(eff.commands),
                                 tuning_offset_cents=round(tuning_offset, 2),
                                 chord_entries=len(eff.chords),
                                 filter='global' if global_filter is not None else 'instrument',
                                 filter_plan_rows=len(global_filter.table)-1 if global_filter is not None else 0)
    if helper_report:
        report['helpers'] = helper_report
        report['instrument_allocation'] = instrument_allocation
    for key in ['row_collisions','quantized_events','approximated_instrument_attacks','shared_wave_programs']:
        report.setdefault(key,0)
    report['warnings']=[
        'Observed attack/gate and piecewise-linear pulse/filter programmes are estimates, not original instrument source.',
        ('Wave-table pitch trajectories retain the first six PAL frames; later vibrato and slides are simplified.'
         if pitch_programs != 'full' else 'Pitch trajectories use nearest tuning-table notes; sub-semitone modulation remains approximate.'),
        'Events are rounded to the selected PAL row grid; collisions retain the later attack.',
        'Finite capture loops from its start; original loop boundaries are unknown.',
        'Low cutoff bits, intra-call writes and unsupported player behavior remain approximate.',
    ]
    if participating:
        report['warnings'].append('Coupled source/control trajectories are retained, including waveform-off oscillators; pitch still rounds to tuning notes and row/table limits can alter oscillator phase and ratios.')
    if frequencies: report['source_tuning']='Recovered 96-note source frequency table'
    return b'CC2'+zlib.compress(data),report


def native_song(template, frames, multiplier, row_frames, metadata, frequencies=None, output_multiplier=1, loop_start=None, pitch_programs="attack", modulation_programs="legacy", coupled_programs="legacy", instrument_allocation="legacy", change_points=False, pattern_mining=False, joint_modeling=False, layout="chunks", effect_programs="off", solve_time_limit=20.0, structure_hints=None, hint_scale=1.0, effect_tolerance=12.0, solve_params=None):
    """Build a native CC2 song; returns (bytes, report).

    effect_programs "off" is the original mapper. "on" fits slide, vibrato,
    detune and arpeggio effects into command/chord rows, merges AD/SR variants
    into row supers and hosts one global filter program, but keeps the global
    filter only when it plays the source's filter registers closer than the
    per-instrument filter programs (register distance on cutoff, resolution,
    mode and routing through the exact CT player model).
    """
    options = dict(frequencies=frequencies, output_multiplier=output_multiplier, loop_start=loop_start,
                   pitch_programs=pitch_programs, modulation_programs=modulation_programs,
                   coupled_programs=coupled_programs, instrument_allocation=instrument_allocation,
                   change_points=change_points, pattern_mining=pattern_mining, joint_modeling=joint_modeling,
                   layout=layout, effect_programs=effect_programs, solve_time_limit=solve_time_limit,
                   structure_hints=structure_hints, hint_scale=hint_scale, effect_tolerance=effect_tolerance,
                   solve_params=solve_params)
    if effect_programs != "on":
        return _native_song(template, frames, multiplier, row_frames, metadata, **options)
    try:
        import numpy  # noqa: F401
    except ImportError as error:
        raise ValueError('Effect programmes need numpy: python3 -m pip install -r tools/requirements-sid-search.txt') from error
    try:
        instrument_song, instrument_report = _native_song(template, frames, multiplier, row_frames, metadata,
                                                          filter_mode="instrument", **options)
    except (ArithmeticError, LookupError, TypeError) as error:
        # Searches and auto selection treat a ValueError as a failed candidate only.
        raise ValueError(f'Effect mapping failed: {type(error).__name__}: {error}') from error
    try:
        global_song, global_report = _native_song(template, frames, multiplier, row_frames, metadata,
                                                  filter_mode="global", **options)
    except (ValueError, ArithmeticError, LookupError, TypeError):
        global_song, global_report = None, None
    if global_report is None or global_report['effects']['filter'] != 'global':
        return instrument_song, instrument_report
    from .regdist import filter_distance
    step = max(1, multiplier // output_multiplier)
    source = [bytes(f) for f in frames[::step]]
    def distance(song):
        from .ctplayer import CTPlayer
        played = CTPlayer(zlib.decompress(song[3:])).frames(len(source))
        return filter_distance(source, played, output_multiplier)
    before, after = distance(instrument_song), distance(global_song)
    chosen, report = (global_song, global_report) if after < before else (instrument_song, instrument_report)
    report['effects']['filter_distance'] = dict(instrument=round(before, 6), global_plan=round(after, 6),
                                                chosen='global' if chosen is global_song else 'instrument')
    return chosen, report
