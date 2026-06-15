/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Generic 2-D selection geometry + a block clipboard, shared by the sequencer note and track columns.
Deliberately free of SDL / screen / ct.base dependencies so it can be reused
anywhere a grid of cells needs rectangular select + copy/cut/paste/merge.

"Col" is a voice index (0..2). "Row" is an integer in the host view's natural
row space: the flattened song rowCounter for the note column, the track offset
for the track column. The host translates screen coordinates to/from these.
*/
module com.selection;

import std.algorithm : min, max;

/// What kind of cells a clipboard holds, so a note block is never pasted onto
/// the track column or vice versa.
enum ClipKind { none, note, track }

/**
 * A rectangular selection: an anchor cell plus the current end cell. The
 * rectangle is the inclusive span between them in both axes. `active` marks
 * whether anything is selected; a plain click clears it.
 */
struct Selection {
	bool active;
	int anchorCol, anchorRow;
	int endCol, endRow;

	void clear() { active = false; }

	void setBegin(int col, int row) {
		anchorCol = endCol = col;
		anchorRow = endRow = row;
	}

	void setEnd(int col, int row) {
		endCol = col;
		endRow = row;
	}

	int loCol() const { return min(anchorCol, endCol); }
	int hiCol() const { return max(anchorCol, endCol); }
	int loRow() const { return min(anchorRow, endRow); }
	int hiRow() const { return max(anchorRow, endRow); }

	int cols() const { return hiCol - loCol + 1; }
	int rows() const { return hiRow - loRow + 1; }

	bool contains(int col, int row) const {
		return active && col >= loCol && col <= hiCol
			&& row >= loRow && row <= hiRow;
	}
}

/**
 * A column-major block clipboard. One flat byte array per column; each cell is
 * `cellSize` bytes (4 for a note Element, 2 for a Track). Distinct from the
 * legacy `Clip[]` (which only held trans+seq# pairs for the old track paste).
 */
final class ClipBlock {
	ClipKind kind = ClipKind.none;
	int cols, rows, cellSize;
	private ubyte[][] columns;

	void reset(ClipKind k, int ncols, int nrows, int csize) {
		kind = k;
		cols = ncols;
		rows = nrows;
		cellSize = csize;
		columns.length = ncols;
		foreach(ref c; columns)
			c = new ubyte[nrows * csize];
	}

	bool empty() const {
		return kind == ClipKind.none || cols <= 0 || rows <= 0;
	}

	/// Mutable view of one cell's bytes (length == cellSize).
	ubyte[] cell(int col, int row) {
		return columns[col][row * cellSize .. row * cellSize + cellSize];
	}
}

/// Single shared block clipboard used by the selection verbs.
ClipBlock rowClip;

static this() {
	rowClip = new ClipBlock();
}
