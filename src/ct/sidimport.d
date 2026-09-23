/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

CheeseCutter .sid importer — recognises a 4.x player in a PSID image by code anchors and unpacks its tables into a SidSong for Song.importSidSong.
*/
module ct.sidimport;

import com.cpu;
import std.algorithm : sort, uniq, min, canFind, filter, map;
import std.array : array;
import std.format : format;
import std.math : round;

// An exported .sid is not an editor image: ct.build purges the song and
// reassembles player_v4.acme at the relocation address with only the effect
// code the song uses. There is no offset table and no player ID, and the data
// table order differs between player generations (2012-era exports put
// `songsets` first, 4.00 interleaves tracks and tables, 4.07 follows
// ct.dump). So nothing is located by fixed offset. Instead:
//
//   1. The player's code is decoded instruction by instruction and short,
//      version-stable instruction sequences ("anchors") yield the addresses of
//      songsets, seqlo/seqhi, inst (+ column stride), arp1/arp2, pulstab,
//      filttab, chord and chordindex. cmd1-3 are the one evenly spaced triple
//      of `lda abs,y` targets left over.
//   2. Tracks and sequences are reached through songsets / seqlo+seqhi.
//   3. Every table start is sorted; a table's length is the gap to the next
//      start (tables are dumped back to back with no padding).
//   4. The packed orderlists and sequences are unpacked into the editor's
//      fixed row format (the inverse of Tracklist.compact / Sequence.compact).
//
// See doc/adr/0012-sid-import-by-player-code-anchors.md.

class NotCheeseCutterSid : Exception {
	this(string reason) { super(reason); }
}

// A decoded PSID/RSID file: the C64 memory image plus the header fields the
// importer needs.
struct PsidFile {
	ubyte[] image;              // 64K, data placed at [loadAddress, endAddress)
	int loadAddress, endAddress, initAddress, playAddress;
	int songs = 1, startSong = 1;
	uint speedFlags;            // bit n set = song n+1 is CIA-timed
	int sidModel;               // 0 = 6581, 1 = 8580 (ct.base convention)
	char[32] title, author, release;
}

// Everything recovered from the image, in the editor's table formats.
struct SidSong {
	string playerGeneration;
	int multiplier = 1, sidModel;
	char[32] title, author, release;
	ubyte[512] wave;            // arp1 [0..256], arp2 [256..512]
	ubyte[512] instr;           // column-major, INSTR_COLUMN bytes per column
	ubyte[256] cmd;             // cmd1 [0..64], cmd2 [64..128], cmd3 [128..192]
	ubyte[256] pulse, filter;
	ubyte[128] chord;
	ubyte[32] chordIndex;       // as exported; the editor regenerates its own
	ubyte[256][] sequences;     // editor rows: [instr, tie, note, cmd] + $bf
	ubyte[1024][3][] orderlists;// per subtune, per voice: [trans, seq] pairs
	ubyte[] speeds;             // per subtune
	string[] warnings;
}

// Addresses of the player's data tables inside the image. -1 = the player was
// assembled without the code that reads that table (so the song doesn't use it).
struct PlayerLayout {
	int freqtable = -1, songsets = -1, seqlo = -1, seqhi = -1;
	int inst = -1, instStride, arp1 = -1, arp2 = -1;
	int pulstab = -1, filttab = -1, cmd1 = -1, cmdStride;
	int chord = -1, chordindex = -1;
	int multiplier = 1;
	bool hasSyncByte;
	// Players before 4.01 take the hard-restart SR from one global byte
	// (`lda cmd3`) instead of instrument column 6; its address, else -1.
	int globalHrSr = -1;
}

enum {
	PSID_HEADER_MIN = 0x76,
	INSTR_COLUMN = 48,          // editor instrument column length
	MAX_INSTRUMENTS = 48,
	MAX_SEQUENCES = 128,
	MAX_SEQ_ROWS = 64,
	MAX_SUBTUNES = 32,
	ORDERLIST_BYTES = 1024,
	FREQTABLE_BYTES = 192,
	PAL_CIA_TIMER = 0x4cc7,     // player_v4.acme CIA_VALUE for multiplier 1
	SEQ_END = 0xbf,
	EMPTY_ROW_INSTR = 0xf0, EMPTY_ROW_TIE = 0xf0, TIE = 0x5f, NOTE_BASE = 0x60
}

// freqtable_lo followed by freqtable_hi — identical in every 4.x player, and
// the first proof that the image holds a CheeseCutter-family player.
private immutable ubyte[FREQTABLE_BYTES] FREQTABLE = [
	0x16,0x27,0x38,0x4b,0x5f,0x73,0x8a,0xa1,0xba,0xd4,0xf0,0x0e,0x2d,0x4e,0x71,0x96,
	0xbd,0xe7,0x13,0x42,0x74,0xa9,0xe0,0x1b,0x5a,0x9b,0xe2,0x2c,0x7b,0xce,0x27,0x85,
	0xe8,0x51,0xc1,0x37,0xb4,0x37,0xc4,0x57,0xf5,0x9c,0x4e,0x09,0xd0,0xa3,0x82,0x6e,
	0x68,0x6e,0x88,0xaf,0xeb,0x39,0x9c,0x13,0xa1,0x46,0x04,0xdc,0xd0,0xdc,0x10,0x5e,
	0xd6,0x72,0x38,0x26,0x42,0x8c,0x08,0xb8,0xa0,0xb8,0x20,0xbc,0xac,0xe4,0x70,0x4c,
	0x84,0x18,0x10,0x70,0x40,0x70,0x40,0x78,0x58,0xc8,0xe0,0x98,0x08,0x30,0x20,0x2e,
	0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x02,0x02,0x02,0x02,0x02,
	0x02,0x02,0x03,0x03,0x03,0x03,0x03,0x04,0x04,0x04,0x04,0x05,0x05,0x05,0x06,0x06,
	0x06,0x07,0x07,0x08,0x08,0x09,0x09,0x0a,0x0a,0x0b,0x0c,0x0d,0x0d,0x0e,0x0f,0x10,
	0x11,0x12,0x13,0x14,0x15,0x17,0x18,0x1a,0x1b,0x1d,0x1f,0x20,0x22,0x24,0x27,0x29,
	0x2b,0x2e,0x31,0x34,0x37,0x3a,0x3e,0x41,0x45,0x49,0x4e,0x52,0x57,0x5c,0x62,0x68,
	0x6e,0x75,0x7c,0x83,0x8b,0x93,0x9c,0xa5,0xaf,0xb9,0xc4,0xd0,0xdd,0xea,0xf8,0xfd ];

// ---------------------------------------------------------------------------
// PSID header

PsidFile parsePsid(const(ubyte)[] file) {
	if(file.length < PSID_HEADER_MIN + 2)
		throw new NotCheeseCutterSid("file is too short to be a SID");
	string magic = cast(string)file[0 .. 4];
	if(magic != "PSID" && magic != "RSID")
		throw new NotCheeseCutterSid("not a PSID/RSID file");

	int word(size_t at) { return (file[at] << 8) | file[at + 1]; }
	PsidFile p;
	int version_ = word(4), dataOffset = word(6);
	if(version_ < 1 || version_ > 4 || dataOffset >= file.length)
		throw new NotCheeseCutterSid("malformed SID header");
	p.loadAddress = word(8);
	p.initAddress = word(10);
	p.playAddress = word(12);
	p.songs = word(14);
	p.startSong = word(16);
	p.speedFlags = (word(18) << 16) | word(20);
	foreach(i, field; [&p.title, &p.author, &p.release]) {
		size_t at = 0x16 + i * 32;
		(*field)[] = cast(const(char)[])file[at .. at + 32];
		foreach(ref c; *field) if(c == 0) c = ' ';   // editor pads with spaces
	}
	if(version_ >= 2 && dataOffset >= 0x78)
		p.sidModel = ((file[0x77] & 0x30) == 0x20) ? 1 : 0;

	const(ubyte)[] data = file[dataOffset .. $];
	if(p.loadAddress == 0) {
		if(data.length < 2) throw new NotCheeseCutterSid("SID has no data");
		p.loadAddress = data[0] | (data[1] << 8);
		data = data[2 .. $];
	}
	p.endAddress = p.loadAddress + cast(int)data.length;
	if(p.endAddress > 0x10000)
		throw new NotCheeseCutterSid("SID data runs past the end of memory");
	if(p.initAddress == 0) p.initAddress = p.loadAddress;
	if(p.songs < 1) p.songs = 1;
	if(p.songs > MAX_SUBTUNES)
		throw new NotCheeseCutterSid("more subtunes than CheeseCutter supports");
	p.image = new ubyte[0x10000];
	p.image[p.loadAddress .. p.endAddress] = data[];
	return p;
}

// ---------------------------------------------------------------------------
// Instruction decoding + anchors

private enum Opc : ubyte {
	ASL_A = 0x0a, TAY = 0xa8, INY = 0xc8, LDX_IMM = 0xa2, LDY_IMM = 0xa0, LDA_IMM = 0xa9,
	LDA_ABSY = 0xb9, LDA_ABS = 0xad, ADC_ABSY = 0x79, LDY_ABSX = 0xbc, LDY_ABS = 0xac,
	STA_ZP = 0x85, STA_ABSX = 0x9d, STA_ABS = 0x8d, STX_ABS = 0x8e, STY_ABS = 0x8c,
	CMP_IMM = 0xc9, AND_IMM = 0x29, BEQ = 0xf0, BNE = 0xd0, BPL = 0x10, JMP = 0x4c
}

// Read-only `op abs,y` opcodes (ORA AND EOR ADC LDA LDX CMP SBC): the only
// way the player touches its data tables.
private immutable ubyte[] READ_ABSY = [0x19, 0x39, 0x59, 0x79, 0xb9, 0xbe, 0xd9, 0xf9];

private struct Insn {
	int addr;
	ubyte op;
	int arg;       // immediate / zp byte or absolute word; -1 if none
}

private Insn[] decode(const(ubyte)[] image, int from, int to) {
	Insn[] code;
	for(int pc = from; pc < to;) {
		ubyte op = image[pc];
		int len = CPU.instructionLength(op);
		int arg = -1;
		if(pc + len > to) break;
		if(len == 2) arg = image[pc + 1];
		else if(len == 3) arg = image[pc + 1] | (image[pc + 2] << 8);
		code ~= Insn(pc, op, arg);
		pc += len;
	}
	return code;
}

// One step of an anchor: an opcode and optionally a required argument.
private struct Step {
	ubyte op;
	int arg = -1;
}

// Indices of every position where `steps` matches consecutive instructions.
private size_t[] findAll(const Insn[] code, const Step[] steps) {
	size_t[] hits;
	outer: for(size_t i = 0; i + steps.length <= code.length; i++) {
		foreach(k, s; steps) {
			const Insn c = code[i + k];
			if(c.op != s.op || (s.arg >= 0 && c.arg != s.arg)) continue outer;
		}
		hits ~= i;
	}
	return hits;
}

private int findFreqtable(const(ubyte)[] image, int from, int to) {
	for(int a = from; a + FREQTABLE_BYTES <= to; a++) {
		if(image[a .. a + FREQTABLE_BYTES] == FREQTABLE[]) return a;
	}
	return -1;
}

PlayerLayout locatePlayer(const ref PsidFile p) {
	PlayerLayout l;
	l.freqtable = findFreqtable(p.image, p.loadAddress, p.endAddress);
	if(l.freqtable < 0)
		throw new NotCheeseCutterSid("no CheeseCutter frequency table");
	// The player code (and any multispeed wrapper) precedes the freqtable.
	Insn[] code = decode(p.image, p.loadAddress, l.freqtable);
	bool isFreq(int a) { return a >= l.freqtable && a < l.freqtable + FREQTABLE_BYTES; }

	// subinit: asl / asl / asl / tay / ldx #0, then the first lda songsets,y.
	foreach(i; findAll(code, [Step(Opc.ASL_A), Step(Opc.ASL_A), Step(Opc.ASL_A),
							  Step(Opc.TAY), Step(Opc.LDX_IMM, 0)])) {
		foreach(c; code[i + 5 .. min(i + 10, code.length)]) {
			if(c.op == Opc.LDA_ABSY) { l.songsets = c.arg; break; }
		}
		if(l.songsets >= 0) {
			int init = code[i].addr;   // [jmp init][jmp play][sync byte] init: ...
			l.hasSyncByte = init >= 4 && p.image[init - 1] == 0 && p.image[init - 4] == Opc.JMP;
			break;
		}
	}

	// nextnote: ldy curseq,x / lda seqlo,y / sta zp / lda seqhi,y / sta zp.
	// The freqtable is read the same way, so skip hits on it.
	foreach(i; findAll(code, [Step(Opc.LDY_ABSX), Step(Opc.LDA_ABSY), Step(Opc.STA_ZP),
							  Step(Opc.LDA_ABSY), Step(Opc.STA_ZP)])) {
		if(isFreq(code[i + 1].arg)) continue;
		l.seqlo = code[i + 1].arg;
		l.seqhi = code[i + 3].arg;
		break;
	}

	// Instrument ADSR copy: ldy shinst,x / lda inst,y / sta x / lda inst+SR,y / sta x.
	foreach(i; findAll(code, [Step(Opc.LDY_ABSX), Step(Opc.LDA_ABSY), Step(Opc.STA_ABSX),
							  Step(Opc.LDA_ABSY), Step(Opc.STA_ABSX)])) {
		int stride = code[i + 3].arg - code[i + 1].arg;
		if(stride < 1 || stride > MAX_INSTRUMENTS) continue;
		l.inst = code[i + 1].arg;
		l.instStride = stride;
		break;
	}

	// Wave step: lda arp1+1,y / cmp #$7e / beq / iny / cmp #$7f / bne / lda arp2,y / tay.
	foreach(i; findAll(code, [Step(Opc.LDA_ABSY), Step(Opc.CMP_IMM, 0x7e), Step(Opc.BEQ),
							  Step(Opc.INY), Step(Opc.CMP_IMM, 0x7f), Step(Opc.BNE),
							  Step(Opc.LDA_ABSY), Step(Opc.TAY)])) {
		l.arp1 = code[i].arg - 1;
		l.arp2 = code[i + 6].arg;
		break;
	}

	// Named chord: and #$1f / tay / lda chordindex,y.
	foreach(i; findAll(code, [Step(Opc.AND_IMM, 0x1f), Step(Opc.TAY), Step(Opc.LDA_ABSY)])) {
		l.chordindex = code[i + 2].arg;
		break;
	}
	// Chord walker (lda chord,y / cmp #$40) or break-speed table
	// (ldy speedpos / lda chord,y / bpl).
	foreach(i; findAll(code, [Step(Opc.LDA_ABSY), Step(Opc.CMP_IMM, 0x40)]))
		{ l.chord = code[i].arg; break; }
	if(l.chord < 0) {
		foreach(i; findAll(code, [Step(Opc.LDY_ABS), Step(Opc.LDA_ABSY), Step(Opc.BPL)]))
			{ l.chord = code[i + 1].arg; break; }
	}

	int[] targets = code.filter!(c => READ_ABSY.canFind(c.op)).map!(c => c.arg)
		.array.sort.uniq.array;
	bool isTarget(int a) { return targets.canFind(a); }

	// pulstab and filttab are the two tables read at +0..+3; pulstab is the
	// one summed into the pulse width (adc pulstab+1,y).
	bool insideInst(int a) { return l.inst >= 0 && a >= l.inst && a < l.inst + 8 * l.instStride; }
	foreach(t; targets) {
		if(isFreq(t) || insideInst(t) || !(isTarget(t + 1) && isTarget(t + 2) && isTarget(t + 3)))
			continue;
		bool summed = code.canFind!(c => c.op == Opc.ADC_ABSY && c.arg == t + 1);
		if(summed && l.pulstab < 0) l.pulstab = t;
		else if(!summed && l.filttab < 0 && t != l.songsets) l.filttab = t;
	}

	// cmd1-3: an evenly spaced triple among the targets nothing else claims.
	bool claimed(int t) {
		int[2][] spans = [[l.songsets, 2], [l.arp1, 2], [l.arp2, 1], [l.pulstab, 4],
						  [l.filttab, 4], [l.seqlo, 1], [l.seqhi, 1], [l.chord, 2], [l.chordindex, 1]];
		foreach(s; spans) {
			if(s[0] >= 0 && t >= s[0] && t < s[0] + s[1]) return true;
		}
		return isFreq(t) || insideInst(t);
	}
	int[] rest = targets.filter!(t => !claimed(t)).array;
	findTriple: foreach(a; rest) {
		foreach(b; rest) {
			int step = b - a;
			if(step < 1 || step > 64 || !rest.canFind(b + step)) continue;
			l.cmd1 = a;
			l.cmdStride = step;
			break findTriple;
		}
	}

	// Hard-restart gap: ... sta ad,x / lda <SR> / sta sr,x / lda #$fe (gate off).
	// A plain absolute load here is the pre-4.01 global SR byte.
	foreach(i; findAll(code, [Step(Opc.STA_ABSX), Step(Opc.LDA_ABS), Step(Opc.STA_ABSX),
							  Step(Opc.LDA_IMM, 0xfe)])) {
		l.globalHrSr = code[i + 1].arg;
		break;
	}

	l.multiplier = detectMultiplier(code);

	string missing;
	if(l.songsets < 0) missing ~= " songsets";
	if(l.seqlo < 0) missing ~= " seqlo/seqhi";
	if(l.inst < 0) missing ~= " inst";
	if(l.arp1 < 0) missing ~= " arp1/arp2";
	if(l.pulstab < 0) missing ~= " pulstab";
	if(missing.length)
		throw new NotCheeseCutterSid("player tables not found:" ~ missing);
	return l;
}

// Multispeed songs start a CIA timer at PAL_CIA_TIMER / multiplier: find the
// immediates stored to $dc04/$dc05 (the lo/hi timer latch).
private int detectMultiplier(const Insn[] code) {
	int lo = -1, hi = -1;
	enum { REG_A = 0, REG_X = 1, REG_Y = 2 }
	int[3] reg = [-1, -1, -1];
	foreach(c; code) {
		switch(c.op) {
		case Opc.LDA_IMM: reg[REG_A] = c.arg; break;
		case Opc.LDX_IMM: reg[REG_X] = c.arg; break;
		case Opc.LDY_IMM: reg[REG_Y] = c.arg; break;
		case Opc.STA_ABS, Opc.STX_ABS, Opc.STY_ABS:
			int v = reg[c.op == Opc.STA_ABS ? REG_A : c.op == Opc.STX_ABS ? REG_X : REG_Y];
			if(c.arg == 0xdc04) lo = v;
			else if(c.arg == 0xdc05) hi = v;
			break;
		default: break;
		}
	}
	if(lo < 0 || hi < 0 || (lo | (hi << 8)) == 0) return 1;
	int mult = cast(int)round(cast(double)PAL_CIA_TIMER / (lo | (hi << 8)));
	return mult < 1 ? 1 : mult;
}

// ---------------------------------------------------------------------------
// Unpacking

private void require(bool ok, lazy string why) {
	if(!ok) throw new NotCheeseCutterSid(why);
}

// Inverse of ct.base.Tracklist.compact: [trans]? seq ... [$f0|hi, lo], where
// transpose bytes ($80..$bf) appear only when they change (and always at the
// wrap target) and the end marker holds the wrap target's byte offset.
private ubyte[ORDERLIST_BYTES] unpackOrderlist(const ref PsidFile p, int addr, int numSeqs,
											   ref string[] warnings) {
	ubyte[ORDERLIST_BYTES] list;
	int[] entryOffsets;
	int entries, pos = addr, pendingTrans = -1;
	while(true) {
		require(pos + 1 < p.endAddress, format("orderlist at $%04x runs off the end", addr));
		require(entries < ORDERLIST_BYTES / 2 - 1, format("orderlist at $%04x is too long", addr));
		ubyte b = p.image[pos];
		if(b >= 0xf0) {
			int wrapByte = ((b & 0x0f) << 8) | p.image[pos + 1];
			require(entries > 0, format("empty orderlist at $%04x", addr));
			int wrapIndex = -1;
			foreach(idx, off; entryOffsets) if(off == wrapByte) wrapIndex = cast(int)idx;
			if(wrapIndex < 0) {
				warnings ~= format("orderlist at $%04X loops to no entry; it now loops to the start", addr);
				wrapIndex = 0;
			}
			int end = 0xf000 | (wrapIndex * 2);
			list[entries * 2] = cast(ubyte)(end >> 8);
			list[entries * 2 + 1] = cast(ubyte)(end & 0xff);
			return list;
		}
		if(b >= 0x80) {
			require(b < 0xc0, format("bad orderlist byte $%02x at $%04x", b, pos));
			if(pendingTrans < 0) entryOffsets ~= pos - addr;
			pendingTrans = b;
			pos++;
			continue;
		}
		require(b < numSeqs, format("orderlist at $%04x names missing sequence $%02x", addr, b));
		if(pendingTrans < 0) entryOffsets ~= pos - addr;
		list[entries * 2] = cast(ubyte)(pendingTrans < 0 ? 0x80 : pendingTrans);
		list[entries * 2 + 1] = b;
		entries++;
		pendingTrans = -1;
		pos++;
	}
}

// Inverse of ct.base.Sequence.compact. Each note event becomes one row
// followed by `duration` empty rows; instrument, duration and tie bytes are
// sticky/prefix bytes in front of the note.
private ubyte[256] unpackSequence(const ref PsidFile p, int addr, int seqNo, ref string[] warnings) {
	ubyte[256] raw;
	int rows, duration, instr = -1, pos = addr;
	bool tie, truncated;

	void addRow(ubyte i, ubyte t, ubyte note, ubyte cmd) {
		if(rows >= MAX_SEQ_ROWS) { truncated = true; return; }
		raw[rows * 4 .. rows * 4 + 4] = [i, t, note, cmd];
		rows++;
	}

	while(true) {
		require(pos < p.endAddress && pos - addr < 256,
				format("sequence $%02x at $%04x has no end mark", seqNo, addr));
		ubyte b = p.image[pos++];
		if(b == SEQ_END) break;
		if(b >= 0xf0) { duration = b & 0x0f; continue; }
		if(b >= 0xc0) { instr = b - 0xc0; continue; }
		if(b == TIE) { tie = true; continue; }
		ubyte note = b, cmd = 0;
		if(b >= NOTE_BASE) {
			require(pos < p.endAddress, format("sequence $%02x is cut short", seqNo));
			cmd = p.image[pos++];
		}
		else note += NOTE_BASE;
		addRow(instr >= 0 ? cast(ubyte)(0xc0 + instr) : EMPTY_ROW_INSTR,
			   tie ? TIE : EMPTY_ROW_TIE, note, cmd);
		foreach(_; 0 .. duration)
			addRow(EMPTY_ROW_INSTR, EMPTY_ROW_TIE, NOTE_BASE, 0);
		instr = -1;
		tie = false;
	}
	if(rows == 0) addRow(EMPTY_ROW_INSTR, EMPTY_ROW_TIE, NOTE_BASE, 0);
	if(truncated)
		warnings ~= format("sequence $%02X was longer than %d rows and was cut", seqNo, MAX_SEQ_ROWS);
	if(rows < MAX_SEQ_ROWS) raw[rows * 4] = SEQ_END;   // a full page has no end mark
	return raw;
}

// ---------------------------------------------------------------------------
// Top level

SidSong importSid(const(ubyte)[] file) {
	PsidFile p = parsePsid(file);
	PlayerLayout l = locatePlayer(p);
	SidSong s;
	s.title = p.title;
	s.author = p.author;
	s.release = p.release;
	s.sidModel = p.sidModel;
	s.multiplier = l.multiplier;
	s.playerGeneration = l.globalHrSr >= 0 ? "4.00" : l.hasSyncByte ? "4.07" : "4.01-4.06";

	int numSeqs = l.seqhi - l.seqlo;
	require(numSeqs >= 1 && numSeqs <= MAX_SEQUENCES, "implausible sequence count");
	require(l.instStride <= INSTR_COLUMN, "implausible instrument count");
	bool inside(int a) { return a >= p.loadAddress && a < p.endAddress; }
	require(inside(l.songsets + 8 * p.songs - 1), "songsets outside the SID data");
	foreach(a; [l.songsets, l.seqlo, l.seqhi + numSeqs - 1, l.inst, l.inst + 8 * l.instStride - 1,
				l.arp1, l.arp2, l.pulstab, l.filttab, l.cmd1, l.chord, l.chordindex]) {
		require(a < 0 || inside(a), format("player table at $%04x lies outside the SID data", a));
	}
	if(l.cmd1 >= 0)
		require(inside(l.cmd1 + 3 * l.cmdStride - 1), "cmd table lies outside the SID data");

	// Every table start, so each table can be sized by the gap to the next one.
	int[] starts = [l.songsets, l.arp1, l.arp2, l.pulstab, l.inst, l.seqlo, l.seqhi,
					l.filttab, l.chord, l.chordindex, p.endAddress];
	if(l.cmd1 >= 0) starts ~= [l.cmd1, l.cmd1 + l.cmdStride, l.cmd1 + 2 * l.cmdStride];

	int[] seqAddr;
	foreach(i; 0 .. numSeqs) {
		int a = p.image[l.seqlo + i] | (p.image[l.seqhi + i] << 8);
		require(inside(a), format("sequence $%02x points outside the SID data", i));
		seqAddr ~= a;
	}
	starts ~= seqAddr;

	int[3][] trackAddr;
	foreach(sub; 0 .. p.songs) {
		int[3] t;
		foreach(v; 0 .. 3) {
			int at = l.songsets + sub * 8 + v * 2;
			t[v] = p.image[at] | (p.image[at + 1] << 8);
			require(inside(t[v]), format("subtune %d voice %d track is outside the SID data", sub + 1, v + 1));
		}
		trackAddr ~= t;
		starts ~= t[];
		s.speeds ~= p.image[l.songsets + sub * 8 + 6];
	}
	starts = starts.filter!(a => a >= 0).array.sort.uniq.array;

	int gap(int start, int cap) {
		if(start < 0) return 0;
		foreach(a; starts) if(a > start) return min(a - start, cap);
		return 0;
	}
	void copy(ubyte[] dst, int start, int len) {
		if(start >= 0 && len > 0) dst[0 .. len] = p.image[start .. start + len];
	}

	require(l.arp2 > l.arp1 && l.arp2 - l.arp1 <= 256, "implausible wave table");
	int waveLen = l.arp2 - l.arp1;
	// Without filter code the player never names filttab, but every exporter
	// dumps it right after arp2 (and before pulstab).
	if(l.filttab < 0 && l.arp2 + waveLen < l.pulstab && !starts.canFind(l.arp2 + waveLen)) {
		l.filttab = l.arp2 + waveLen;
		starts = (starts ~ l.filttab).sort.array;
	}
	copy(s.wave[0 .. 256], l.arp1, waveLen);
	copy(s.wave[256 .. 512], l.arp2, waveLen);
	copy(s.pulse[], l.pulstab, gap(l.pulstab, 256));
	copy(s.filter[], l.filttab, gap(l.filttab, 256));
	foreach(col; 0 .. 8)
		copy(s.instr[col * INSTR_COLUMN .. (col + 1) * INSTR_COLUMN],
			 l.inst + col * l.instStride, l.instStride);
	if(l.cmd1 >= 0) {
		foreach(col; 0 .. 3)
			copy(s.cmd[col * 64 .. (col + 1) * 64], l.cmd1 + col * l.cmdStride, min(l.cmdStride, 64));
	}
	// 4.01 moved the hard-restart SR into instrument column 6: give every
	// instrument the old global value so the current player sounds the same.
	if(l.globalHrSr >= 0)
		s.instr[6 * INSTR_COLUMN .. 6 * INSTR_COLUMN + l.instStride] = p.image[l.globalHrSr];
	copy(s.chord[], l.chord, gap(l.chord, 128));
	copy(s.chordIndex[], l.chordindex, gap(l.chordindex, 32));

	foreach(i, a; seqAddr)
		s.sequences ~= unpackSequence(p, a, cast(int)i, s.warnings);
	foreach(t; trackAddr) {
		ubyte[1024][3] voices;
		foreach(v; 0 .. 3) voices[v] = unpackOrderlist(p, t[v], numSeqs, s.warnings);
		s.orderlists ~= voices;
	}
	return s;
}
