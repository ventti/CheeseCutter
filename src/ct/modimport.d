/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

ProTracker .mod importer — parses a 31-sample MOD's first three channels into note/instrument cells for Song.importModule (samples and effects are not imported).
*/
module ct.modimport;
import com.util;
import std.string;

// One imported cell: a CheeseCutter note value (or -1 = none) and the MOD
// sample number that triggered it (0 = none). Effects are discarded.
struct ModCell {
	int note = -1;   // CheeseCutter note value (see periodToNote), or -1
	int instr = 0;   // MOD sample number 1..31, or 0 for none
}

// A parsed ProTracker module. `patterns[p][row][voice]` covers only the first
// three channels (voice 0..2); higher channels are read for sizing but dropped.
struct ModModule {
	string title;
	string[32] sampleNames;   // indexed by MOD sample number 1..31
	int channels;             // channels in the file (>= voices we keep)
	int songLength;           // number of played order positions
	ubyte[128] order;         // order table (pattern number per position)
	int numPatterns;          // unique patterns stored in the file
	ModCell[3][64][] patterns; // [pattern][row 0..63][voice 0..2]
}

// Amiga period table for finetune 0, three octaves C-1..B-3 (index 0 == C-1).
private immutable int[] PERIODS = [
	856,808,762,720,678,640,604,570,538,508,480,453,   // C-1..B-1
	428,404,381,360,339,320,302,285,269,254,240,226,   // C-2..B-2
	214,202,190,180,170,160,151,143,135,127,120,113,   // C-3..B-3
];

// Map an Amiga period to a CheeseCutter note value. The value indexes the
// editor's NOTES table (see ct.base), where index 12 == "C-1", so period-table
// index 0 (C-1) maps to value 12 and the module's note names are preserved.
// Periods off the table snap to the nearest tabled note; period 0 == no note.
private int periodToNote(int period) {
	if(period == 0) return -1;
	int best = 0, bestDiff = int.max;
	foreach(i, pv; PERIODS) {
		int d = period > pv ? period - pv : pv - period;
		if(d < bestDiff) { bestDiff = d; best = cast(int)i; }
	}
	return best + 12;
}

// Channel count from the 4-byte format tag at offset 1080. Returns 0 for an
// unrecognised tag (a 15-sample Soundtracker module or an unsupported variant).
private int channelsFromTag(string tag) {
	switch(tag) {
	case "M.K.", "M!K!", "FLT4", "4CHN": return 4;
	default:
		// "6CHN"/"8CHN"/"2CHN"... : single leading digit + "CHN"
		if(tag.length == 4 && tag[1 .. 4] == "CHN" &&
		   tag[0] >= '1' && tag[0] <= '9')
			return tag[0] - '0';
		// "10CH".."32CH" : two leading digits + "CH"
		if(tag.length == 4 && tag[2 .. 4] == "CH" &&
		   tag[0] >= '0' && tag[0] <= '9' && tag[1] >= '0' && tag[1] <= '9')
			return (tag[0] - '0') * 10 + (tag[1] - '0');
		return 0;
	}
}

// Trim a fixed MOD name field to a clean printable ASCII string (cut at the
// first NUL, drop unprintable bytes, strip surrounding whitespace).
private string cleanName(const(ubyte)[] raw) {
	char[] s;
	foreach(b; raw) {
		if(b == 0) break;
		s ~= (b >= 0x20 && b < 0x7f) ? cast(char)b : ' ';
	}
	return strip(cast(string)s.idup);
}

// Parse a 31-sample ProTracker module image. Throws UserException on anything
// that isn't a recognisable tagged 31-sample MOD.
ModModule parseModule(const(ubyte)[] data) {
	enum HEADER_END = 1084;   // 20 title + 31*30 samples + 1+1+128 + 4 tag
	if(data.length < HEADER_END)
		throw new UserException("Not a ProTracker module (file too small).");

	ModModule m;
	m.title = cleanName(data[0 .. 20]);

	int ofs = 20;
	for(int i = 1; i <= 31; i++) {
		m.sampleNames[i] = cleanName(data[ofs .. ofs + 22]);
		ofs += 30;   // 22 name + 2 len + 1 finetune + 1 vol + 2 rep + 2 replen
	}

	m.songLength = data[950];
	if(m.songLength < 1 || m.songLength > 128)
		throw new UserException("Not a ProTracker module (bad song length).");
	m.order[0 .. 128] = data[952 .. 1080];

	string tag = cast(string)data[1080 .. 1084].idup;
	m.channels = channelsFromTag(tag);
	if(m.channels == 0)
		throw new UserException(format("Unsupported module format (tag '%s'). " ~
			"Only tagged 31-sample modules are supported.", cleanName(data[1080 .. 1084])));

	int maxPat = 0;
	foreach(o; m.order) if(o > maxPat) maxPat = o;
	m.numPatterns = maxPat + 1;

	int patBytes = 64 * m.channels * 4;
	if(data.length < HEADER_END + m.numPatterns * patBytes)
		throw new UserException("ProTracker module is truncated (missing pattern data).");

	m.patterns.length = m.numPatterns;
	int p = HEADER_END;
	for(int pat = 0; pat < m.numPatterns; pat++) {
		for(int row = 0; row < 64; row++) {
			for(int ch = 0; ch < m.channels; ch++) {
				ubyte b0 = data[p], b1 = data[p + 1], b2 = data[p + 2];
				p += 4;   // b3 (effect parameter) discarded
				if(ch >= 3) continue;
				int sample = (b0 & 0xF0) | (b2 >> 4);
				int period = ((b0 & 0x0F) << 8) | b1;
				m.patterns[pat][row][ch] =
					ModCell(periodToNote(period), sample);
			}
		}
	}
	return m;
}
