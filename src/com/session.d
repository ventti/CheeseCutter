/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
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

struct UndoState {
	Undoable func;
	UndoValue value;
}

struct EditorState {
	__gshared Song song;
	PosDataTable fplayPos, seqPos;
	int octave = 3;
	int activeInstrument;
	bool autoinsertInstrument = true;
	bool shortTitles = true;
	bool displayHelp = true;
	bool keyjamStatus = false;
	bool allowInstabNavigation = true;
	// Song edited since the last load/save: any undoable change sets it (see
	// insertUndo / executeUndo / executeRedo); UI.saveCallback / loadCallback
	// reset it. Drives the unsaved-changes warning in the quit confirmation.
	bool songModified = false;
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
}

void executeUndo() {
	if(state.undoQueue.empty) return;
	auto u = state.undoQueue.pop();
	// make entry for redo (copy current state)
	auto redo = makeRedoOrUndo(u);
	state.redoQueue.insert(redo);
	u.func.undo(u.value);
	state.songModified = true;
}

void executeRedo() {
	if(state.redoQueue.empty) return;
	auto r = state.redoQueue.pop();
	// make entry for undo (copy current state)
	auto undo = makeRedoOrUndo(r);
	state.undoQueue.insert(undo);
	r.func.undo(r.value);
	state.songModified = true;
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
