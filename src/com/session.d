/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Editor session state — the undo/redo stack (Undoable) plus editor and tracklist state.
*/

module com.session;
import ct.base;
import com.fb;
import com.util;
import ui.ui;
import seq.sequencer;
import std.typecons;
import com.util;

interface Undoable {
	void undo(UndoValue);
	UndoValue createRedoState(UndoValue);
}

struct TracklistStore {
	Tracklist store, source;
}

struct UndoValue {
	import ct.base;

	alias Array = Tuple!(ubyte[], "target", ubyte[], "source");

	// undo data needed by sequencer
	Array array;
	Sequence seq;
	Sequence[] seqSources;
	ubyte[][] seqData;
	// undo data needed by track editor
	TracklistStore[] trackLists;
	ushort trackValue;
	ubyte[][] tableData;
	char[32][48] insLabels;
	bool hasInsLabels;
	char[32] songTitle, songAuthor, songRelease;
	bool hasSongInfo;
	int subtuneNum;
	PosDataTable posTable;
	bool allVoices;
}

// A make-unique transaction snapshots only the destination sequences alongside
// the owning view's tracklists. Keep redo symmetrical with the same destinations.
void snapshotSequences(ref UndoValue value, Sequence[] sources) {
	value.seqSources = sources.dup;
	foreach(source; sources) value.seqData ~= source.data.raw.dup;
}

void restoreSequences(UndoValue value) {
	foreach(i, source; value.seqSources) {
		source.data.raw[] = value.seqData[i][];
		source.refresh();
	}
}

bool makeTracksUnique(Track[] entries, Undoable owner, UndoValue delegate() snapshot) {
	if(entries.length == 0) return false;
	auto song = state.song;
	Sequence[] destinations;
	int[] numbers;
	bool[MAX_SEQ_NUM] used;
	song.trackIterator((Track entry) {
		if(entry.number < MAX_SEQ_NUM) used[entry.number] = true;
	});
	// Plan all copies before changing anything. Unreferenced sequences can still
	// contain authored music, so require blank rows as well as no references in
	// any subtune. Slot zero is always reserved.
	for(int number = 1; destinations.length < entries.length; number++) {
		if(number == MAX_SEQ_NUM) {
			UI.statusline.display("Not enough empty sequences to make tracks unique.");
			return false;
		}
		if(used[number]) continue;
		auto candidate = song.seqs[number];
		bool empty = true;
		foreach(r; 0 .. candidate.rows)
			if(candidate.data.raw[r * 4 .. r * 4 + 4] != CLEAR) empty = false;
		if(!empty) continue;
		numbers ~= number;
		destinations ~= candidate;
	}
	auto before = snapshot();
	snapshotSequences(before, destinations);
	insertUndo(owner, before);
	foreach(i, entry; entries) {
		destinations[i].copyFrom(song.seqs[entry.number]);
		entry.number = cast(ubyte)numbers[i];
	}
	UI.statusline.display("Made selected tracks unique.");
	return true;
}

struct UndoState {
	Undoable func;
	UndoValue value;
}

struct EditorState {
	__gshared Song song;
	PosDataTable fplayPos, seqPos;
	int octave = 3;
	int activeInstrument;
	// Chord referenced by the effect cell under the sequence cursor (0..31), or
	// -1 when the cursor is not on a chord command. Drives the cyan cursor hint
	// on the matching chord-table rows, mirroring the active-instrument hint.
	int cursorChord = -1;
	bool autoinsertInstrument = true;
	bool shortTitles = true;
	bool displayHelp = true;
	bool keyjamStatus = false;
	bool allowInstabNavigation = true;
	// Song edited since the last load/save: any undoable change sets it (see
	// insertUndo / executeUndo / executeRedo); UI.saveCallback / loadCallback
	// reset it. Drives the unsaved-changes warning in the quit confirmation.
	bool songModified = false;
	// Bumped on every change to the song data (undoable edits, undo/redo, load).
	// Read by the read-only filter-track trace to know when to recompute.
	int editGeneration = 0;
	string filename;
	auto undoQueue = Queue!UndoState();
	auto redoQueue = Queue!UndoState();
}

UI mainui;
Video video;
Screen screen;
EditorState state;

void insertUndo(Undoable undoable, UndoValue value) {
	state.undoQueue.insert(UndoState(undoable, value));
	state.redoQueue.clear();
	state.songModified = true;
	state.editGeneration++;
}

void executeUndo() {
	if(state.undoQueue.empty) return;
	auto u = state.undoQueue.pop();
	// make entry for redo (copy current state)
	auto redo = makeRedoOrUndo(u);
	state.redoQueue.insert(redo);
	u.func.undo(u.value);
	state.songModified = true;
	state.editGeneration++;
}

void executeRedo() {
	if(state.redoQueue.empty) return;
	auto r = state.redoQueue.pop();
	// make entry for undo (copy current state)
	auto undo = makeRedoOrUndo(r);
	state.undoQueue.insert(undo);
	r.func.undo(r.value);
	state.songModified = true;
	state.editGeneration++;
}

private UndoState makeRedoOrUndo(UndoState state) {
	state.value = state.func.createRedoState(state.value);
	return state;
}

@property song() {
	return state.song;
}

@property seqPos() {
	return state.seqPos;
}

@property fplayPos() {
	return state.fplayPos;
}

void initSession() {
	state.song = new Song();
	state.seqPos = new PosDataTable();
	state.fplayPos = new PosDataTable();
	for(int i = 0; i < 3; i++) {
		state.seqPos[i].tracks = song.tracks[i];
		state.fplayPos[i].tracks = song.tracks[i];
	}
}
