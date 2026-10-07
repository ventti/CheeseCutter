/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

GoatTracker 2 GTS5 import: parses songs and maps tables, effects and timing into editable CheeseCutter data.

Source semantics: GoatTracker readme sections 3 and 6.1, and gplay.c
(https://github.com/leafo/goattracker2). No player code is copied.
*/
module ct.goatimport;

import com.util : UserException;
import std.string : format, strip;
import std.algorithm : min, max, clamp, canFind;

struct GoatRow { ubyte note, instrument, command, parameter; }
struct GoatInstrument { ubyte[9] data; string name; }
struct GoatTable { ubyte[] left, right; }
struct GoatStep { int pattern; int transpose = int.max; }
struct GoatOrder { GoatStep[] steps; int restart; }
struct GoatSong {
    string title, author, copyright;
    GoatOrder[3][] orders;
    GoatInstrument[] instruments; // zero is the empty instrument
    GoatTable[4] tables;
    GoatRow[][] patterns;
}
struct GoatInfo { bool valid; string title, author, copyright; int subtunes; }

private string cleanName(const(ubyte)[] bytes) {
    char[] result;
    foreach(b; bytes) {
        if(!b) break;
        result ~= cast(char)(b >= 32 && b < 127 ? b : ' ');
    }
    return strip(cast(string)result.idup);
}

GoatInfo readGoatInfo(const(ubyte)[] data) {
    GoatInfo info;
    if(data.length < 101 || data[0 .. 4] != cast(const(ubyte)[])"GTS5") return info;
    info.title = cleanName(data[4 .. 36]);
    info.author = cleanName(data[36 .. 68]);
    info.copyright = cleanName(data[68 .. 100]);
    info.subtunes = data[100];
    info.valid = info.subtunes > 0 && info.subtunes <= 32;
    return info;
}

GoatSong parseGoatSong(const(ubyte)[] data) {
    size_t pos;
    const(ubyte)[] take(size_t count) {
        if(count > data.length - pos)
            throw new UserException(format("Truncated GoatTracker song at byte %d.", pos));
        auto bytes = data[pos .. pos + count]; pos += count; return bytes;
    }
    int byteValue() { return take(1)[0]; }
    void require(bool ok, string reason) {
        if(!ok) throw new UserException("Invalid GoatTracker song: " ~ reason ~ ".");
    }
    auto signature = take(4);
    if(signature != cast(const(ubyte)[])"GTS5")
        throw new UserException("Unsupported GoatTracker format; save as GTS5 in GoatTracker 2 first.");
    GoatSong song;
    song.title = cleanName(take(32)); song.author = cleanName(take(32));
    song.copyright = cleanName(take(32));
    int tunes = byteValue();
    require(tunes > 0 && tunes <= 32, "subtune count must be 1..32");
    song.orders.length = tunes;
    foreach(ref voices; song.orders) foreach(ref order; voices) {
        int length = byteValue();
        require(length >= 2, "empty orderlist");
        auto bytes = take(length + 1);
        require(bytes[length - 1] == 0xff, "missing orderlist end marker");
        int restart = bytes[length];
        require(restart < length - 1, "restart position is outside the orderlist");
        int[int] positions;
        int i;
        while(i < length - 1) {
            int start = i, transpose = int.max, repeats = 1;
            if(bytes[i] >= 0xe0 && bytes[i] < 0xff) transpose = bytes[i++] - 0xf0;
            if(i < length - 1 && bytes[i] >= 0xd0 && bytes[i] < 0xe0)
                repeats = bytes[i++] - 0xd0 + 1;
            require(i < length - 1 && bytes[i] < 0xd0, "invalid transpose/repeat command order");
            foreach(p; start .. i + 1) positions[p] = cast(int)order.steps.length;
            int pattern = bytes[i++];
            foreach(r; 0 .. repeats) {
                GoatStep step; step.pattern = pattern;
                step.transpose = r == 0 ? transpose : int.max;
                order.steps ~= step;
            }
        }
        require((restart in positions) !is null, "invalid restart position");
        order.restart = positions[restart];
    }
    int instruments = byteValue();
    require(instruments <= 63, "too many instruments");
    song.instruments.length = instruments + 1;
    foreach(ref instrument; song.instruments[1 .. $]) {
        instrument.data[] = take(9); instrument.name = cleanName(take(16));
    }
    foreach(ref table; song.tables) {
        int length = byteValue();
        table.left = take(length).dup; table.right = take(length).dup;
    }
    int patterns = byteValue();
    require(patterns > 0 && patterns <= 208, "pattern count must be 1..208");
    song.patterns.length = patterns;
    foreach(ref pattern; song.patterns) {
        int length = byteValue();
        require(length >= 2 && length <= 129, "pattern length must include 1..128 rows and an end marker");
        auto bytes = take(length * 4);
        require(bytes[(length - 1) * 4] == 0xff, "missing pattern end marker");
        foreach(r; 0 .. length - 1) {
            auto b = bytes[r * 4 .. r * 4 + 4];
            require(b[0] >= 0x60 && b[0] <= 0xbf, "invalid note token");
            require(b[1] <= instruments && b[2] <= 15, "invalid instrument or effect");
            pattern ~= GoatRow(b[0], b[1], b[2], b[3]);
        }
    }
    require(pos == data.length, "unexpected trailing data (multi-SID variants are unsupported)");
    foreach(voices; song.orders) foreach(order; voices) foreach(step; order.steps)
        require(step.pattern < patterns, "orderlist refers to a missing pattern");
    void pointer(int table, int ptr, bool entry = true) {
        require(ptr <= song.tables[table].left.length, "table pointer is outside its table");
        if(entry && ptr && table < 3)
            require(song.tables[table].left[ptr - 1] != 0xff, "table entry points directly to a jump");
    }
    void effect(int command, int parameter) {
        if(command >= 1 && command <= 4 || command == 14) pointer(3, parameter);
        if(command >= 8 && command <= 10) pointer(command - 8, parameter);
    }
    foreach(instrument; song.instruments[1 .. $]) {
        foreach(t; 0 .. 4) pointer(t, instrument.data[2 + t], false);
    }
    foreach(t; 0 .. 3) foreach(i, left; song.tables[t].left) {
        int right = song.tables[t].right[i];
        if(left == 0xff) pointer(t, right, false);
        else {
            require(i + 1 < song.tables[t].left.length, "table falls off its end without a jump");
            if(t == 0 && left >= 0xf0) {
                require(left != 0xf0 && left != 0xf8 && left != 0xfe, "illegal wavetable command");
                effect(left & 15, right);
            }
        }
    }
    foreach(pattern; song.patterns) foreach(row; pattern) effect(row.command, row.parameter);
    return song;
}

// Ready-to-install CheeseCutter data. Conversion is transactional: no live
// editor song is touched until this complete result passes capacity checks.
struct GoatConversion {
    ubyte[512] wave;
    ubyte[384] instruments;
    ubyte[256] pulse, filter, commands;
    ubyte[128] chord;
    ubyte[256][] sequences;
    ubyte[1024][3][] orders;
    string[48] names;
    ubyte[] speeds;
    string[] warnings;
    string title, author, copyright;
}

private struct Event { int tick; ubyte[4] row; bool boundary; bool delayed; }
private struct Voice {
    int step, row, transpose, countdown;
    int instrument = 1, note = 24, ad, sr;
    int effect, parameter, vibratoDelay, ccEffect;
}
private int gcd(int a, int b) { while(b) { int c = a % b; a = b; b = c; } return a; }

GoatConversion convertGoatSong(GoatSong source, const(ushort)[] frequencies) {
    try {
        return (new Converter(source, frequencies)).convert();
    } catch(UserException e) {
        if(!canFind(e.msg, "63 CheeseCutter effect commands") &&
           !canFind(e.msg, "127 playable CheeseCutter sequences") &&
           !canFind(e.msg, "timing resolution below three ticks")) throw e;
        auto converted = (new Converter(source, frequencies, true)).convert();
        converted.warnings = ["Best-effort import: exact conversion exceeded editable capacity; envelope settings were simplified."] ~ converted.warnings;
        return converted;
    }
}

private class Converter {
    GoatSong source;
    const(ushort)[] frequencies;
    GoatConversion result;
    bool approximateEnvelopes;
    bool[string] warned;
    int[64] instrumentMap, biases;
    int nextInstrument = 1, nextWave = 1, nextPulse = 1, nextFilter = 1, nextCommand = 1;
    int[string] commandMap, instrumentDefs, sequenceMap, waveDefs;
    int[int] waveMap, pulseMap, filterMap;
    int[string] filterSettings;

    this(GoatSong source, const(ushort)[] frequencies, bool approximateEnvelopes = false) {
        this.approximateEnvelopes = approximateEnvelopes;
        this.source = source; this.frequencies = frequencies;
        result.title = source.title; result.author = source.author; result.copyright = source.copyright;
        result.pulse[0 .. 4] = [0x7f, 0, 0xff, 0x7f];
        result.filter[0 .. 4] = [0x7f, 0, 0xff, 0x7f];
        result.wave[0] = 0; result.wave[256] = 0;
        result.commands[64] = 0x0f; // GoatTracker default hard-restart AD ($0F00).
        result.chord[0 .. 2] = [2, 0x80]; // Valid default groove (three play calls per row).
        ubyte[256] empty; empty[0 .. 5] = [0xf0, 0xf0, 0x60, 0, 0xbf];
        result.sequences ~= empty;
    }
    void warn(string key, string location, string message) {
        if(key in warned) return;
        warned[key] = true; result.warnings ~= location ~ ": " ~ message;
    }
    int command(int op, int hi = 0, int lo = 0, string location = "") {
        string key = format("%d:%d:%d", op, hi, lo);
        if(auto found = key in commandMap) return *found;
        // Reserve command slots for pitch effects. Only the retry simplifies
        // envelopes; the first pass always retains exact ADSR updates.
        if(approximateEnvelopes && op == 4 && nextCommand >= 48) {
            int nearest, distance = int.max;
            foreach(i; 1 .. nextCommand) {
                if(result.commands[i] != 4) continue;
                int ad = result.commands[i + 64], sr = result.commands[i + 128];
                int absDiff(int a, int b) { return a > b ? a - b : b - a; }
                // Prefer identical attack/decay; compare envelope nibbles
                // separately rather than treating ADSR bytes as scalar values.
                int score = 32 * (absDiff(hi >> 4, ad >> 4) + absDiff(hi & 15, ad & 15))
                    + absDiff(lo >> 4, sr >> 4) + absDiff(lo & 15, sr & 15);
                if(score < distance) { nearest = i; distance = score; }
            }
            if(nearest) {
                warn("envelope:" ~ key, location,
                    format("Envelope %02X/%02X approximated as %02X/%02X to fit the command table.",
                           hi, lo, result.commands[nearest + 64], result.commands[nearest + 128]));
                commandMap[key] = nearest;
                return nearest;
            }
        }
        if(nextCommand >= 64) throw new UserException((location.length ? location ~ ": " : "") ~ "GoatTracker conversion exceeds 63 CheeseCutter effect commands. The song needs more distinct effects than the editable format can store.");
        int index = nextCommand++;
        result.commands[index] = cast(ubyte)op;
        result.commands[index + 64] = cast(ubyte)hi;
        result.commands[index + 128] = cast(ubyte)lo;
        commandMap[key] = index; return index;
    }
    int pitch(int note, string location) {
        if(note < 3 || note > 94) {
            warn("pitch" ~ location, location, "Pitch outside CheeseCutter's D#0..A#7 range was clamped.");
            note = clamp(note, 3, 94);
        }
        return note;
    }
    // Flatten reachable wavetable control flow, keeping jump destinations in
    // the translated program. Negative relative notes use an instrument bias.
    int wave(int start, out int bias, string location) {
        bias = 0;
        if(!start) {
            warn("wave-stop", location, "Stopped wavetable uses a held waveform; initial waveform/frequency may differ.");
            // A valid frozen no-op program is needed by the CC export validator.
            if(auto found = 0 in waveMap) return *found;
            if(nextWave + 2 > 256) throw new UserException("Converted wavetable exceeds 256 rows.");
            int index = nextWave; nextWave += 2;
            result.wave[index] = 0; result.wave[index + 1] = 0x7e;
            waveMap[0] = index; return index;
        }
        int[] path;
        int[int] seen;
        int ptr = start, loop = -1;
        bool[int] jumps;
        while(ptr) {
            if(auto found = ptr in seen) { loop = *found; break; }
            int left = source.tables[0].left[ptr - 1], right = source.tables[0].right[ptr - 1];
            if(left == 0xff) {
                if(ptr in jumps) throw new UserException("Reachable GoatTracker wavetable jump cycle has no playable rows.");
                jumps[ptr] = true; ptr = right; continue;
            }
            seen[ptr] = cast(int)path.length; path ~= ptr;
            if(left < 0xf0 && right >= 0x60 && right < 0x80)
                bias = max(bias, 128 - right);
            ptr++;
        }
        if(auto found = start in waveMap) return *found;
        ubyte[] tuning, waveform;
        int[] relocated;
        int previous = bias;
        foreach(p; path) {
            relocated ~= cast(int)tuning.length;
            int left = source.tables[0].left[p - 1], right = source.tables[0].right[p - 1];
            int tune = previous, duration = left < 0x10 ? left + 1 : 1, control = left < 0x10 ? 0 : left;
            if(left >= 0xf0) {
                control = 0;
                warn(format("wave-cmd:%d", p), format("Wave row %02X", p),
                    format("Wavetable command %X%02X has no native equivalent and was omitted.", left & 15, right));
            } else if(right != 0x80) {
                if(right < 0x80) tune = (right >= 0x60 ? right - 128 : right) + bias;
                else tune = right;
            } else if(tuning.length == 0) {
                warn("wave-inherit", location, "Initial wavetable 'keep frequency' uses the note pitch.");
            }
            if(tune < 0 || tune > 0xdf || tune >= 0x60 && tune < 0x80)
                throw new UserException("GoatTracker wavetable pitch range cannot fit CheeseCutter's relative tuning range.");
            foreach(tick; 0 .. duration) {
                tuning ~= cast(ubyte)(tick + 1 == duration ? tune : previous); waveform ~= cast(ubyte)(tick == 0 ? control : 0);
            }
            previous = tune;
        }
        if(tuning.length == 0) throw new UserException("GoatTracker wavetable contains no playable rows.");
        int index = nextWave;
        tuning ~= cast(ubyte)(loop < 0 ? 0x7e : 0x7f);
        waveform ~= cast(ubyte)(loop < 0 ? 0 : relocated[loop]);
        string key = cast(string)tuning.idup ~ cast(string)waveform.idup;
        if(auto found = key in waveDefs) { waveMap[start] = *found; return *found; }
        if(loop >= 0) waveform[$ - 1] += index;
        if(nextWave + tuning.length > 256) throw new UserException("Converted wavetable exceeds 256 rows.");
        result.wave[index .. index + tuning.length] = tuning;
        result.wave[256 + index .. 256 + index + waveform.length] = waveform;
        nextWave += tuning.length; waveMap[start] = index; waveDefs[key] = index; return index;
    }
    int sweep(int table, int start, string location) {
        if(!start) return 0;
        auto map = table == 1 ? &pulseMap : &filterMap;
        if(auto found = start in *map) return *found;
        auto data = table == 1 ? result.pulse[] : result.filter[];
        int ptr = start, first = -1, previous = -1;
        int[int] local;
        bool[int] jumps;
        while(ptr) {
            if(auto found = ptr in *map) {
                if(previous >= 0) data[previous * 4 + 3] = cast(ubyte)*found;
                return first < 0 ? *found : first;
            }
            if(auto found = ptr in local) {
                data[previous * 4 + 3] = cast(ubyte)*found; (*map)[start] = first; return first;
            }
            int left = source.tables[table].left[ptr - 1], right = source.tables[table].right[ptr - 1];
            if(left == 0xff) {
                if(ptr in jumps) throw new UserException("Reachable GoatTracker sweep jump cycle has no modulation rows.");
                jumps[ptr] = true; ptr = right; continue;
            }
            int index = table == 1 ? nextPulse++ : nextFilter++;
            if(index >= 64) throw new UserException(table == 1 ?
                "Converted pulse table exceeds 63 programme rows." : "Converted filter table exceeds 63 programme rows.");
            local[ptr] = index; (*map)[ptr] = index;
            if(first < 0) first = index;
            else data[previous * 4 + 3] = cast(ubyte)index;
            previous = index;
            auto row = data[index * 4 .. index * 4 + 4];
            row[] = [0, 0, 0xff, 0x7f];
            if(table == 1) {
                if(left >= 0x80) {
                    int pulse = ((left & 15) << 8) | right;
                    if(pulse & 15) warn(format("pulse:%d", ptr), location, "Pulse preset rounded down to 16 SID units.");
                    row[2] = cast(ubyte)((pulse & 0xf0) | (pulse >> 8));
                } else {
                    // GoatTracker stays on a zero-duration row indefinitely without
                    // changing pulse width. The default CC row holds the value
                    // and stops the programme; later source rows are unreachable.
                    if(!left) break;
                    int delta = cast(byte)right;
                    row[0] = cast(ubyte)((left - 1) | (delta < 0 ? 0x80 : 0));
                    row[1] = cast(ubyte)(delta < 0 ? -delta : delta);
                }
            } else {
                if(left >= 0x80) {
                    row[0] = cast(ubyte)(0x80 | (left & 0x70)); row[1] = cast(ubyte)right;
                    // GT applies an immediately following cutoff preset in the
                    // same tick as filter mode/routing. CC stores both in one row.
                    if(ptr < source.tables[table].left.length &&
                       source.tables[table].left[ptr] == 0 &&
                       source.tables[table].right[ptr] != 255) {
                        row[2] = source.tables[table].right[ptr];
                        ptr++;
                    }
                } else if(!left) {
                    row[2] = cast(ubyte)(right == 255 ? 254 : right);
                    if(right == 255) warn("cutoff-ff", location, "Cutoff FF approximated as FE (FF means keep cutoff in CheeseCutter).");
                } else {
                    int delta = cast(byte)right;
                    if(delta < -32 || delta > 31) warn(format("filter:%d", ptr), location, "Filter sweep speed clamped to CheeseCutter's signed 10-bit range.");
                    row[0] = cast(ubyte)(left - 1);
                    row[1] = cast(ubyte)(clamp(delta, -32, 31) * 4);
                    warn("filter-timing", location, "Filter sweep onset differs by one tick between the players.");
                }
            }
            ptr++;
        }
        if(first < 0) return 0;
        (*map)[start] = first;
        return first;
    }
    int instrument(int src, string location) {
        if(src <= 0 || src >= source.instruments.length)
            throw new UserException("GoatTracker playback refers to missing default instrument 1.");
        if(instrumentMap[src]) return instrumentMap[src];
        auto ins = source.instruments[src]; auto d = ins.data;
        foreach(t; 0 .. 3) if(d[t + 2] && source.tables[t].left[d[t + 2] - 1] == 255)
            throw new UserException(format("Instrument %02X starts table %d on a jump row.", src, t + 1));
        int bias, waveptr = wave(d[2], bias, location);
        biases[src] = bias;
        ubyte[8] def;
        def[0] = d[0]; def[1] = d[1];
        def[2] = cast(ubyte)(d[7] & 0x40 ? 0x40 : d[7] & 0x80 ? 0 : 0x80);
        def[3] = cast(ubyte)(d[8] >= 0xfe ? 0 : d[8]);
        def[4] = cast(ubyte)sweep(2, d[4], location);
        def[5] = cast(ubyte)sweep(1, d[3], location);
        def[6] = 0x00; def[7] = cast(ubyte)waveptr;
        string key = cast(string)def[].idup;
        int index;
        if(auto found = key in instrumentDefs) {
            index = *found;
            if(result.names[index] != ins.name)
                warn(format("instrument-alias:%d", src), format("Instrument %02X", src),
                    "Identical instrument merged; keeping the first instrument's name.");
        }
        else {
            if(nextInstrument >= 48) throw new UserException("GoatTracker conversion exceeds 47 CheeseCutter instruments.");
            index = nextInstrument++; instrumentDefs[key] = index;
            foreach(col; 0 .. 8) result.instruments[index + col * 48] = def[col];
            result.names[index] = ins.name;
        }
        instrumentMap[src] = index;
        if((d[7] & 63) != 2 || d[8] >= 0xfe || !d[8])
            warn(format("hr:%d", src), format("Instrument %02X", src), "Gate/hard-restart timing approximated using CheeseCutter's restart modes.");
        return index;
    }
    int effect(int op, int param, int note, string location) {
        if(!param) return command(8);
        warn("effect-wave-timing", location, "Pitch effects use CheeseCutter's tick-zero and wavetable-reset behaviour; onset may differ by one tick.");
        int left = source.tables[3].left[param - 1], right = source.tables[3].right[param - 1];
        if(op == 4) {
            // GT reverses after floor(compare/2)+1 ticks; CC takes a half-
            // period directly. CC's initial phase and tick-zero behaviour differ.
            int period = (left & 127) / 2 + 1;
            warn("vibrato-shape", location, "Vibrato phase/onset approximated; period and depth are matched where representable.");
            if(left & 128) {
                int divider = min(right, 15);
                int ccPeriod = clamp(period, 1, 16);
                if(right > 15 || period > 16) warn(format("vibrato:%d", param), location, "Note-relative vibrato parameters clamped to hi-fi vibrato range.");
                return command(2, 0, ((ccPeriod - 1) << 4) | divider);
            }
            int depth = (right + 2) / 4;
            if(right % 4) warn(format("vibrato-depth:%d", param), location, "Fixed vibrato depth rounded to four SID frequency units.");
            return command(5, period, depth);
        }
        int speed = (left << 8) | right;
        if(left & 128) {
            int n = clamp(note, 0, cast(int)frequencies.length - 2);
            int delta = cast(int)frequencies[n + 1] - frequencies[n];
            speed = right >= 16 ? 0 : delta >> right;
            warn("relative-slide", location, "Note-relative slide speed calculated from the note pitch; wavetable pitch changes may alter the original speed.");
        }
        if(op == 3 && speed > 0xfff) {
            warn(format("porta:%d", param), location, "Tone portamento clamped to CheeseCutter's 12-bit speed range."); speed = 0xfff;
        }
        return command(op == 1 ? 0 : op == 2 ? 1 : 7, speed >> 8, speed & 255);
    }
    int filterSetting(int type, int resonance, int cutoff, string location) {
        string key = format("%d:%d:%d", type, resonance, cutoff);
        if(auto found = key in filterSettings) return *found;
        if(nextFilter >= 32) {
            warn("filter-command-range", location, "Filter command omitted: inline filter pointers only address rows 00..1F."); return 0;
        }
        int index = nextFilter++;
        result.filter[index * 4 .. index * 4 + 4] =
            [cast(ubyte)(0x80 | type), cast(ubyte)resonance, cast(ubyte)cutoff, cast(ubyte)0x7f];
        filterSettings[key] = 0x60 | index; return 0x60 | index;
    }

    GoatConversion convert() {
        if(frequencies.length < 96) throw new UserException("Missing CheeseCutter frequency table.");
        result.orders.length = source.orders.length; result.speeds.length = source.orders.length;
        foreach(sub; 0 .. source.orders.length) convertTune(cast(int)sub);
        return result;
    }
    void convertTune(int sub) {
        Voice[3] voices;
        int[3] tempos = 5;
        int[2] funk = [8, 5];
        int filterType, filterResonance;
        Event[][3] events;
        int[string] seen;
        int tick, loopTick = -1;
        string location;
        // GTS5 omits player preferences (clock, SID model, multiplier and HR
        // ADSR). Start from normal PAL 1x timing; this is reported explicitly.
        warn("preferences", "Song", "GTS5 omits clock/SID model/multispeed/hard-restart ADSR; using PAL 1x and GoatTracker HR defaults unless a recovery report supplies settings.");
        int initial = 5;
        if(source.instruments.length == 64 && !source.instruments[63].data[2] && source.instruments[63].data[0] >= 2)
            initial = source.instruments[63].data[0] - 1;
        tempos[] = initial;
        void emit(int v, int time, ubyte[4] row, bool boundary = false, bool delayed = false) {
            if(events[v].length && events[v][$ - 1].tick == time) {
                auto last = &events[v][$ - 1];
                if(row[3] && last.row[3] && row[3] != last.row[3])
                    warn("effect-conflict:" ~ location, location, "Simultaneous effects exceed the one-command-per-row limit; the later command takes priority.");
                if(row[3]) last.row[3] = row[3];
                last.boundary |= boundary;
            } else events[v] ~= Event(time, row, boundary, delayed);
        }
        for(tick = 0; tick < 1000000; tick++) {
            bool relevant;
            // Detect loops at source pattern boundaries so startup state does
            // not introduce a restart in the middle of an otherwise intact pattern.
            foreach(ref voice; voices) if(voice.countdown == 0 && voice.row == 0) relevant = true;
            if(relevant) {
                // Avoid struct padding in keys. Incoming musical state is part
                // of the key, so context changes get their own pattern variants.
                string key = format("%d:%d:%d:%d", funk[0], funk[1], filterType, filterResonance);
                foreach(v, ref s; voices) key ~= format("/%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d",
                    s.step, s.row, s.transpose, s.countdown, s.instrument, s.note, s.ad, s.sr,
                    s.effect, s.parameter, s.vibratoDelay, s.ccEffect, tempos[v]);
                if(auto found = key in seen) { loopTick = *found; break; }
                if(seen.length >= 100000) throw new UserException("GoatTracker timing cycle is too large to convert safely.");
                seen[key] = tick;
            }
            foreach(v, ref s; voices) {
                auto order = source.orders[sub][v];
                bool newNote;
                if(s.countdown == 0) {
                    auto step = order.steps[s.step];
                    if(s.row == 0 && step.transpose != int.max) s.transpose = step.transpose;
                    auto r = source.patterns[step.pattern][s.row];
                    location = format("Subtune %d voice %d pattern %02X row %02X", sub + 1, v + 1, step.pattern, s.row);
                    ubyte[4] row = [0xf0, 0xf0, 0x60, 0];
                    if(r.instrument) s.instrument = r.instrument;
                    newNote = r.note <= 0xbc;
                    if(newNote) {
                        int ins = instrument(s.instrument, location);
                        s.note = r.note - 0x60 + s.transpose;
                        row[0] = cast(ubyte)(0xc0 + ins);
                        row[2] = cast(ubyte)(0x60 + pitch(s.note - biases[s.instrument], location));
                        if(r.command == 3) row[1] = 0x5f;
                        else {
                            auto d = source.instruments[s.instrument].data;
                            s.ad = d[0]; s.sr = d[1]; s.ccEffect = 0;
                            s.effect = 0; s.parameter = d[5];
                            s.vibratoDelay = d[6];
                            if(d[4]) {
                                int ptr = d[4];
                                auto ft = source.tables[2];
                                if(ft.left[ptr - 1] >= 0x80 && ft.left[ptr - 1] != 0xff) {
                                    filterType = ft.left[ptr - 1] & 0x70;
                                    filterResonance = ft.right[ptr - 1];
                                }
                            }
                        }
                    } else if(r.note == 0xbe) row[2] = 0x61;
                    else if(r.note == 0xbf) row[2] = 0x62;
                    // Instrument selection on rest changes GT's future note
                    // instrument and default vibrato, but does not restart tables.
                    int op = r.command, param = r.parameter, cmd;
                    switch(op) {
                    case 0:
                        s.effect = 0;
                        s.parameter = s.instrument < source.instruments.length ? source.instruments[s.instrument].data[5] : 0;
                        int defaultVibrato = s.parameter && s.vibratoDelay == 1 ? effect(4, s.parameter, s.note, location) : 0;
                        if(s.ccEffect && s.ccEffect != defaultVibrato) cmd = command(8);
                        if(!defaultVibrato) s.ccEffect = 0;
                        break;
                    case 1, 2, 3, 4:
                        s.effect = op; s.parameter = param;
                        if(op == 3 && !param) {
                            // GT 300 is an instantaneous tied pitch change.
                            if(s.ccEffect) cmd = command(8);
                            s.ccEffect = 0;
                        } else {
                            int mapped = effect(op, param, s.note, location);
                            if(newNote || mapped != s.ccEffect) cmd = mapped;
                            s.ccEffect = mapped;
                        }
                        break;
                    case 5:
                        // A single ADSR nibble can use CC's inline commands,
                        // leaving scarce command-table slots for full updates.
                        if((s.ad & 15) == (param & 15)) cmd = 0xa0 | (param >> 4);
                        else if((s.ad & 0xf0) == (param & 0xf0)) cmd = 0xb0 | (param & 15);
                        else cmd = command(4, param, s.sr, location);
                        s.ad = param;
                        break;
                    case 6:
                        if((s.sr & 15) == (param & 15)) cmd = 0xc0 | (param >> 4);
                        else if((s.sr & 0xf0) == (param & 0xf0)) cmd = 0xd0 | (param & 15);
                        else cmd = command(4, s.ad, param, location);
                        s.sr = param;
                        break;
                    case 7: cmd = command(6, 0, param); break;
                    case 8:
                        warn("wave-pointer:" ~ location, location, "Wavetable pointer command omitted (no native row command)."); break;
                    case 9, 10:
                        int ptr = sweep(op - 8, param, location);
                        if(op == 10 && param) {
                            auto ft = source.tables[2];
                            if(ft.left[param - 1] >= 0x80 && ft.left[param - 1] != 0xff) {
                                filterType = ft.left[param - 1] & 0x70; filterResonance = ft.right[param - 1];
                            }
                        }
                        if(ptr >= 32) warn("table-pointer:" ~ location, location, "Table pointer command omitted: inline pointers address rows 00..1F.");
                        else cmd = (op == 9 ? 0x40 : 0x60) | ptr;
                        break;
                    case 11:
                        warn("filter-control", location, "Filter control uses a one-shot program; later filter-table mode changes are not tracked.");
                        filterResonance = param; cmd = filterSetting(filterType, filterResonance, 255, location);
                        if(!param) warn("filter-stop", location, "Filter control 00 clears routing; table stop timing may differ.");
                        break;
                    case 12:
                        cmd = filterSetting(filterType, filterResonance, param == 255 ? 254 : param, location);
                        warn("filter-cutoff", location, "Cutoff command uses a one-shot filter program and stops the previous sweep.");
                        break;
                    case 13:
                        if(param < 16) cmd = 0xe0 | param;
                        else warn("timing-marker", location, "External timing marker omitted.");
                        break;
                    case 14:
                        if(param) {
                            funk[0] = source.tables[3].left[param - 1] - 1;
                            funk[1] = source.tables[3].right[param - 1] - 1;
                            if(funk[0] < 1 || funk[1] < 1) throw new UserException("GoatTracker funktempo below 2 ticks is unsupported.");
                        }
                        tempos[] = 0; break;
                    case 15:
                        int tempo = param & 127;
                        if(tempo == 2) throw new UserException("Invalid GoatTracker tempo 02.");
                        if(tempo >= 3) tempo--;
                        if(param & 128) tempos[v] = tempo; else tempos[] = tempo;
                        break;
                    default: assert(0);
                    }
                    row[3] = cast(ubyte)cmd;
                    emit(cast(int)v, tick, row, s.row == 0);
                    s.row++;
                    if(s.row >= source.patterns[step.pattern].length) {
                        s.row = 0; s.step++;
                        if(s.step >= order.steps.length) s.step = order.restart;
                    }
                    // Reload on the following tick. Global tempo changes on
                    // other voices therefore affect the same reload phase.
                    s.countdown = -1;
                } else if(s.countdown < 0) {
                    s.countdown = (tempos[v] >= 2 ? tempos[v] : funk[tempos[v]]) - 1;
                    if(tempos[v] < 2) tempos[v] ^= 1;
                } else s.countdown--;
                if(s.effect == 0 && s.parameter && s.vibratoDelay > 0 && !newNote) {
                    if(s.vibratoDelay > 1) s.vibratoDelay--;
                    else {
                        int cmd = effect(4, s.parameter, s.note, location);
                        if(cmd != s.ccEffect) {
                            ubyte[4] row = [0xf0, 0xf0, 0x60, cast(ubyte)cmd];
                            emit(cast(int)v, tick, row, false, true);
                            s.ccEffect = cmd;
                        }
                    }
                }
            }
        }
        if(loopTick < 0) throw new UserException("GoatTracker song has no manageable repeating timing cycle.");
        int quantum = gcd(tick, loopTick);
        foreach(channel; events) foreach(event; channel) if(!event.delayed) quantum = gcd(quantum, event.tick);
        quantum = max(1, quantum);
        if(quantum > 127) quantum = 1;
        if(quantum < 3) {
            if(!approximateEnvelopes)
                throw new UserException("GoatTracker song requires timing resolution below three ticks, which CheeseCutter cannot play.");
            quantum = 3;
            warn("timing-grid", format("Subtune %d", sub + 1),
                "Events rounded down to a three-tick grid (at most two ticks early); CheeseCutter's fastest row period is three ticks.");
        }
        // The player reloads a countdown: speed 5 means SIX play calls.
        result.speeds[sub] = cast(ubyte)(quantum - 1);
        foreach(v; 0 .. 3) installEvents(sub, v, events[v], loopTick, tick, quantum);
    }
    void installEvents(int sub, int voice, Event[] events, int loopTick, int endTick, int quantum) {
        int rows = (endTick + quantum - 1) / quantum, loopRow = loopTick / quantum;
        ubyte[] raw;
        raw.length = rows * 4;
        foreach(r; 0 .. rows) raw[r * 4 .. r * 4 + 4] = [0xf0, 0xf0, 0x60, 0];
        bool[int] boundaries;
        boundaries[loopRow] = true;
        int previous = -100;
        foreach(event; events) {
            int row = event.tick / quantum;
            if(event.delayed) {
                if(event.tick % quantum)
                    warn("vibrato-delay", format("Subtune %d voice %d", sub + 1, voice + 1),
                        "Instrument vibrato delay rounded down to the song's timing step to keep patterns editable.");
                if(raw[row * 4 + 3] && raw[row * 4 + 3] != event.row[3])
                    warn("delayed-conflict", format("Subtune %d voice %d", sub + 1, voice + 1),
                        "Delayed vibrato overlaps another command; the row command takes priority.");
                else raw[row * 4 + 3] = event.row[3];
            } else raw[row * 4 .. row * 4 + 4] = event.row[];
            if(event.boundary) boundaries[row] = true;
            if(event.row[2] != 0x60 || event.row[3]) {
                if(event.tick - previous < 3)
                    warn("fast-events", format("Subtune %d voice %d", sub + 1, voice + 1), "Events less than three ticks apart may differ because CheeseCutter has a two-tick note/command pipeline.");
                previous = event.tick;
            }
        }
        int offset, track = 0, restartTrack = -1;
        auto order = result.orders[sub][voice][];
        order[] = 0;
        while(offset < rows) {
            if(offset == loopRow) restartTrack = track;
            int end = min(rows, offset + 64);
            for(int r = offset + 1; r < end; r++) if(r in boundaries) { end = r; break; }
            ubyte[256] sequence;
            sequence[0 .. (end - offset) * 4] = raw[offset * 4 .. end * 4];
            // A full 64-row sequence uses all 256 bytes; refresh() infers its
            // length without an end marker, and the packer adds its own marker.
            if(end - offset < 64) sequence[(end - offset) * 4] = 0xbf;
            string key = cast(string)sequence[].idup;
            int number, transpose;
            if(auto found = key in sequenceMap) number = *found;
            else {
                // Reuse transposed copies without allocating another sequence.
                // In the best-effort retry, allow envelope-only differences too.
                int best = int.max;
                foreach(n; 1 .. result.sequences.length) {
                    auto candidate = result.sequences[n];
                    int shift, differences;
                    bool hasNote, compatible = true;
                    foreach(r; 0 .. end - offset) {
                        int i = r * 4;
                        if(sequence[i] != candidate[i] || sequence[i + 1] != candidate[i + 1]) { compatible = false; break; }
                        int a = sequence[i + 2], b = candidate[i + 2];
                        if(a >= 0x63 && a < 0xbf && b >= 0x63 && b < 0xbf) {
                            if(hasNote && a - b != shift) { compatible = false; break; }
                            shift = a - b; hasNote = true;
                        } else if(a != b) { compatible = false; break; }
                        int ca = sequence[i + 3], cb = candidate[i + 3];
                        bool envelope(int c) { return c >= 0xa0 && c < 0xe0 || c > 0 && c < 64 && result.commands[c] == 4; }
                        if(ca != cb) {
                            if(!approximateEnvelopes || !(ca == 0 || envelope(ca)) || !(cb == 0 || envelope(cb))) { compatible = false; break; }
                            differences++;
                        }
                    }
                    if(end - offset < 64 && candidate[(end - offset) * 4] != 0xbf || shift < -31 || shift > 31) compatible = false;
                    if(!approximateEnvelopes && shift) compatible = false;
                    if(compatible && differences < best) {
                        best = differences; number = cast(int)n; transpose = shift;
                        if(!best) break;
                    }
                }
                if(best != int.max) {
                    if(best) warn(format("sequence-envelope:%d:%d:%d", sub, voice, offset),
                        format("Subtune %d voice %d row %d", sub + 1, voice + 1, offset),
                        format("Reused sequence %02X with %d different envelope change(s) to fit sequence capacity.", number, best));
                } else {
                    if(result.sequences.length >= 128) throw new UserException("GoatTracker conversion exceeds 127 playable CheeseCutter sequences after deduplication.");
                    number = cast(int)result.sequences.length;
                    result.sequences ~= sequence; sequenceMap[key] = number;
                }
            }
            if(track >= 511) throw new UserException("Converted GoatTracker orderlist exceeds 511 entries.");
            order[track * 2 .. track * 2 + 2] = [cast(ubyte)(0xa0 + transpose), cast(ubyte)number];
            track++; offset = end;
        }
        if(restartTrack < 0) throw new UserException("Internal GoatTracker conversion error: missing loop boundary.");
        // Editor track wrap is an entry index. The runtime packer converts it
        // into the byte offset used by the C64 player.
        if(restartTrack > 255) throw new UserException("Converted GoatTracker restart position exceeds 255 entries.");
        order[track * 2 .. track * 2 + 2] = [cast(ubyte)0xf0, cast(ubyte)restartTrack];
    }
}
