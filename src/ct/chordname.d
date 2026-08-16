/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Deterministic chord naming — maps a set of (relative) semitone offsets to a chord quality name and back.
*/

module ct.chordname;

// One chord quality, keyed by its canonical root-relative semitone offsets.
// The offsets double as the reverse-direction answer (quality -> offsets) used
// by a future "pick a quality, fill the arp" feature in the chord editor.
struct ChordQuality {
	string name;
	immutable(int)[] offsets;
}

// Starter quality table. Offsets are root-relative semitones with the root at 0.
// Keep entries free of pitch-class collisions: the forward lookup folds every
// chord into a 12-bit pitch-class mask, so two qualities must never share a mask.
immutable ChordQuality[] QUALITIES = [
	ChordQuality("5",    [0, 7]),
	ChordQuality("maj",  [0, 4, 7]),
	ChordQuality("min",  [0, 3, 7]),
	ChordQuality("dim",  [0, 3, 6]),
	ChordQuality("aug",  [0, 4, 8]),
	ChordQuality("sus2", [0, 2, 7]),
	ChordQuality("sus4", [0, 5, 7]),
	ChordQuality("6",    [0, 4, 7, 9]),
	ChordQuality("m6",   [0, 3, 7, 9]),
	ChordQuality("7",    [0, 4, 7, 10]),
	ChordQuality("maj7", [0, 4, 7, 11]),
	ChordQuality("m7",   [0, 3, 7, 10]),
	ChordQuality("m7b5", [0, 3, 6, 10]),
	ChordQuality("dim7", [0, 3, 6, 9]),
	ChordQuality("add9", [0, 2, 4, 7]),
];

private __gshared string[ushort] byMask;

shared static this() {
	foreach(q; QUALITIES)
		byMask[pcMask(q.offsets)] = q.name;
}

// Normalize a set of offsets to a 12-bit pitch-class mask. Per the design:
// treat the lowest offset as the root (no inversion detection), subtract it so
// the root becomes 0, then fold each remaining offset mod 12 into a bit. OR is
// order- and duplicate-insensitive, so the input may be an unsorted arp stream.
private ushort pcMask(const(int)[] offsets) pure nothrow {
	if(offsets.length == 0) return 0;
	int lo = int.max;
	foreach(o; offsets)
		if(o < lo) lo = o;
	ushort mask;
	foreach(o; offsets) {
		int pc = ((o - lo) % 12 + 12) % 12;
		mask |= cast(ushort)(1 << pc);
	}
	return mask;
}

// Forward direction: offsets -> quality name (e.g. {7,0,4} -> "maj"), or null
// when the mask is not a known quality or there is no chord (0/1 distinct notes).
// Callers fall back to showing the raw interval list when this returns null.
string chordQualityName(const(int)[] offsets) {
	if(offsets.length < 2) return null;
	ushort mask = pcMask(offsets);
	// A single pitch class (e.g. an octave-only arp) is not a chord.
	import core.bitop : popcnt;
	if(popcnt(mask) < 2) return null;
	if(auto p = mask in byMask) return *p;
	return null;
}

// Reverse direction: quality name -> canonical root-relative offsets, or null
// for an unknown name. The primary tracker use case (quality picked in the UI,
// offsets written into the chord table).
int[] chordOffsets(string name) {
	foreach(q; QUALITIES)
		if(q.name == name) return q.offsets.dup;
	return null;
}

unittest {
	// Forward: unsorted, root not first.
	assert(chordQualityName([7, 0, 4]) == "maj");
	assert(chordQualityName([0, 3, 7]) == "min");
	assert(chordQualityName([0, 4, 7, 11]) == "maj7");

	// Symmetric chords resolve via lowest-after-subtract = root, and octaves fold.
	assert(chordQualityName([4, 8, 12]) == "aug");   // -> {0,4,8}
	assert(chordQualityName([0, 3, 6, 9]) == "dim7");

	// Inversion is not detected: {4,7,12} normalizes to {0,3,8}, unknown.
	assert(chordQualityName([4, 7, 12]) is null);

	// Degenerate inputs.
	assert(chordQualityName([]) is null);
	assert(chordQualityName([0]) is null);
	assert(chordQualityName([0, 12, 24]) is null); // single pitch class

	// Every table entry round-trips.
	foreach(q; QUALITIES) {
		assert(chordQualityName(q.offsets) == q.name);
		assert(chordOffsets(q.name) == q.offsets);
	}
	assert(chordOffsets("nonexistent") is null);
}
