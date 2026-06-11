/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
*/

module seq.seqtable;
import main;
import ui.ui;
import com.fb;
import com.util;
import seq.sequencer;
import com.session;
import com.selection;
import ct.base;
import ui.input;
import derelict.sdl2.sdl;
import std.string;
import audio.player;
import audio.visualizer;

private enum activeInstrumentColor = 3;

class SeqVoice : Voice, Undoable {
	InputSeq seqinput;

	this(VoiceInitParams v) {
		super(v);
		activeRow = getRowData(0, 0);
		seqinput = new InputSeq();
		(cast(InputSeq)seqinput).setElement(activeRow.element);
		seqinput.setCoord(area.x + 4, 0);
		(cast(InputSeq)seqinput).setPointer(area.x + 4, 0);
		activeInput = seqinput;
	}

	override int keyrelease(Keyinfo key) {
		return seqinput.keyrelease(key);
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_SHIFT) {
			switch(key.raw)
			{
			case SDLK_RETURN:
				saveState();
				int r = activeRow.seq.rows;
				int t = 4 * song.highlight;
				activeRow.seq.expand(activeRow.seqOffset,
								   (t - (r + t) % t));
				break;
			case SDLK_INSERT:  // FIXME need substitute key for Macbook too
				saveState();
				activeRow.seq.expand(activeRow.seqOffset, 1);
				break;
			case SDLK_DELETE, SDLK_BACKSPACE:
				saveState();
				activeRow.seq.shrink(activeRow.seqOffset, 1, true);
				break;
			default:
				return seqinput.keypress(key);
			}
		}
		else if(key.mods & KMOD_CTRL) {
			switch(key.raw)
			{
			case SDLK_INSERT, SDLK_RETURN:
				saveState();
				activeRow.seq.expand(0, 1, false);
				break;
			case SDLK_DELETE, SDLK_BACKSPACE:
				saveState();
				if(activeRow.seqOffset < activeRow.seq.rows - 1)
					activeRow.seq.shrink(0, 1, false);
				break;
			case SDLK_q:
				saveState();
				activeRow.seq.transpose(activeRow.seqOffset, 1);
				break;
			case SDLK_a:
				saveState();
				activeRow.seq.transpose(activeRow.seqOffset, -1);
				break;
			case SDLK_w:
				saveState();
				activeRow.seq.transpose(activeRow.seqOffset, 12);
				break;
			case SDLK_s:
				saveState();
				activeRow.seq.transpose(activeRow.seqOffset, -12);
				break;

			default:
				return seqinput.keypress(key);
			}
		}
		else switch(key.raw)
			 {
			 case SDLK_LEFT:
				 return seqinput.step(-1);
			 case SDLK_RIGHT:
				 return seqinput.step(1);
			 case SDLK_INSERT, SDLK_RETURN:
				 saveState();
				 activeRow.seq.insert(activeRow.seqOffset);
				 break;
			 case SDLK_DELETE, SDLK_BACKSPACE:
				 saveState();
				 activeRow.seq.remove(activeRow.seqOffset);
				 break;
			 default:
				 return seqinput.keypress(key);
			 }
		return OK;
	}

	override void refreshPointer(int y) {
		assert(seqinput !is null);
		assert(pos !is null);
		activeRow = getRowData(pos.trkOffset, pos.seqOffset + y);
		activeInput.setCoord(0, 1 + area.y + y + anchor);
		(cast(InputSeq)seqinput).setElement(activeRow.element);
	}

	override void update() {
		RowData wseq;
		int scry = area.y + area.height;
		int trkofs = pos.trkOffset, seqofs = pos.seqOffset - anchor;
		int lasttrk = tracks.trackLength;
		int hcount = pos.rowCounter - anchor + area.height - 1;
		int row = area.height;
		Sequence seq;

		seqofs += area.height;// - pos.delta;
		wseq = getRowData(trkofs, seqofs);
		trkofs = wseq.trkOffset2;
		seqofs = wseq.seqOffset;
		seq = new Sequence(wseq.seq.data.raw[0 .. $], seqofs);
		void printEmpty() {
			import std.array;

			screen.cprint(area.x - 1, scry, 1, 0,
						  replicate(" ", 16));
		}

		void printTrack() {
			screen.cprint(area.x - 1, scry, 1, 0,
						  " " ~ formatTrackValue(wseq.track.smashedValue));
			if(trkofs == pos.mark) {
				for(int i = 0; i < 13; i++) {
					int xpos = area.x + i;
					if(screen.getbg(xpos, scry) == 0)
						screen.setbg(xpos, scry, playbackBarColor);
				}
			}
			if(trkofs == tracks.wrapOffset) {
				for(int i = 0; i < 15; i++) {
					int xpos = area.x + i - 1;
					if(screen.getbg(xpos, scry) == 0)
						screen.setbg(xpos, scry, wrapBarColor);
				}
			}
		}

		int rows = seq.rows;
		while(scry >= area.y + 1) {
			if(trkofs < 0) {
				printEmpty();
				scry--; row--;
			}
			else if(trkofs >= lasttrk+1) {
				printEmpty();
				if(trkofs == lasttrk+1) {
					wseq = getRowData(trkofs, 0);
					printTrack();
				}
				hcount--; scry--; trkofs--;
				if(trkofs >= 0) rows = 0;
				continue;
			}
			else {
				for(int i = rows - 1; i >= 0;
					i--, scry--, hcount--, row--) {
					printEmpty();
					if(scry < area.y + 1) break;
					Element d = seq.data[i];
					screen.fprint(area.x + 4, scry, d.toString(wseq.element.transpose));
					if(state.activeInstrument >= 0 &&
					   d.instr.hasValue &&
					   d.instr.value == state.activeInstrument) {
						screen.setColor(area.x + 8, scry, activeInstrumentColor, 0);
						screen.setColor(area.x + 9, scry, activeInstrumentColor, 0);
					}
					if(i == 0) printTrack();
					else {
						if(.seq.sequencer.displaySequenceRowcounter == true) {
							int c = (hcount - song.highlightOffset) %
								song.highlight ? 11 : 12;
							screen.cprint(area.x, scry, c, 0, format(" %02X ", i));
						}
						else screen.cprint(area.x, scry, 0, 0, "    ");
					}
				}
			}
			trkofs--;
			if(trkofs >= 0) {
				wseq = getRowData(trkofs, 0);
				seq = wseq.seq;
				rows = seq.rows;
			}
		}

	}

protected:

	override final void undo(UndoValue entry) {
		auto data = entry.array.target;
		auto target = entry.array.source;
		target[] = data;
		assert(parent !is null);
		entry.seq.refresh();
		parent.step(0);
	}

	void saveState() {
		UndoValue v;
		import std.typecons;
		v.array = UndoValue.Array(activeRow.seq.data.raw.dup,
								  activeRow.seq.data.raw);
		v.seq = activeRow.seq;
		com.session.insertUndo(this, v);
	}

	override final UndoValue createRedoState(UndoValue value) {
		value.array.target = value.array.source.dup;
		return value;
	}
}

class SequenceTable : VoiceTable, Undoable {
	this(Rectangle a, PosDataTable pi) {
		int x = 5 + com.fb.border + a.x;
		for(int v=0;v<3;v++) {
			Rectangle na = Rectangle(x, a.y, a.height, 13 + com.fb.border);
			x += 13 + com.fb.border;
			voices[v] = new SeqVoice(VoiceInitParams(song.tracks[v],
													 na, pi[v], this));
		}
		super(a, pi);
	}

	override void activate() {
		super.activate();
		// works as scroll(1) would but does not store variables
		int steps = 0;
		foreach(Voice v; voices) {
			with(v.pos) {
				RowData s = v.getRowData(trkOffset);
				if(trkOffset >= v.tracks.trackLength) {
					trkOffset = 0;
					rowCounter = -pointerOffset;
				}
			}

		}

	}

	override void update() {
		// First, call parent to render all the voices
		super.update();

		// Store persistent brightness for current playback positions
		if(audio.player.isPlaying && !audio.player.keyjamEnabled) {
			for(int i = 0; i < 3; i++) {
				PosData fp = fplayPos[i];
				audio.visualizer.updatePersistentBrightness(i, fp.rowCounter);
			}
		}

		// NOTE: Visualization colors are now applied in renderVisualization()
		// which is called from UI layer after all updates complete
		// (selection tint is applied by the base VoiceTable.update).
	}

	// Called from UI layer AFTER all window updates are complete
	void renderVisualization() {
		// Always render persistent ADSR visualization (not just in Regs mode)
		// This allows colors to persist after playback stops

		// Render playback visualization AFTER all other rendering is done
		// This ensures our background colors don't get overwritten
		for(int i = 0 ; i < 3; i++) {
			PosData vp = posTable[i];

			// Render all visible rows
			for(int rowIdx = 0; rowIdx < area.height; rowIdx++) {
				int rowCounter = vp.rowCounter + rowIdx - anchor;

				// Get brightness for this voice at this row
				float brightness = 0.0f;

				// During playback: show current position with live brightness
				if(audio.player.isPlaying && !audio.player.keyjamEnabled) {
					PosData fp = fplayPos[i];
					if(rowCounter == fp.rowCounter) {
						brightness = audio.visualizer.getVoiceBrightness(i);
					} else {
						// Show persistent brightness for other rows
						brightness = audio.visualizer.getPersistentBrightness(i, rowCounter);
					}
				} else {
					// After playback: show persistent brightness
					brightness = audio.visualizer.getPersistentBrightness(i, rowCounter);
				}

				if(brightness > 0.01f) {
					// Map brightness to 16-step gradient (palette indices 16-31)
					// brightness ranges from 0.0 to 1.0
					// Map to gradient: 16 (brightest) to 31 (darkest/black)
					int step = cast(int)(brightness * 15.0f);
					if(step > 15) step = 15;
					int bgcolor = 16 + (15 - step); // Invert so high brightness = low index (brighter color)

					// Apply the visualization as a background-only tint. Existing
					// nonzero backgrounds carry editor semantics such as tied notes,
					// playback marks, and wrap marks, so leave those cells intact.
					for(int x = voices[i].area.x;
						x < voices[i].area.x + voices[i].area.width; x++) {
						int y = 1 + area.y + rowIdx;
						int existingChar = screen.getChar(x, y);
						int existingBg = (existingChar >> 16) & 0xff;
						if(existingBg != 0) continue;

						int existingFg = (existingChar >> 8) & 15;
						screen.setColor(x, y, existingFg, bgcolor);
					}
				}
			}
		}
	}

	override void stepVoice(int i) {
		int n = activeVoiceNum + i;
		int c = (n - activeVoiceNum) > 0 ? 0 : 1;
		n = umod(n, 0, 2);
		if(!voices[n].atEnd())
			super.stepVoice(i);

		SeqVoice v = cast(SeqVoice)voices[n];
		(cast(InputSeq)v.seqinput).columnReset(-c);
	}

	// for positioning the cursor using mouse. x is not used
	override void clickedAt(int x, int y, int button, int clicks = 1) {
		y -= 1;
		step(y-posTable.normalPointerOffset);
	}

	override int keypress(Keyinfo key) {
		// Block-selection commands (copy/cut/paste/merge/paste-new/markers) get
		// first refusal; if consumed, don't fall through to editing.
		if(handleSelectionKey(key)) return OK;
		// globals
		super.keypress(key);
		if(!key.mods) {
			switch(key.raw)
			{
			case SDLK_HOME:
				SeqVoice v = cast(SeqVoice)activeVoice;
				InputSeq i = cast(InputSeq)v.seqinput;
				if(i.activeColumn > 0) {
					(cast(InputSeq)v.seqinput).columnReset(0);
					break;
				}
				int ofs = activeVoice.activeRow.seqOffset;
				int cy = posTable.normalPointerOffset;
				int m;
				if(cy == 0) m = 1;
				else if(ofs == 0) break;
				else if(ofs > 0 && ofs > cy)  {
					m = 0;
				}
				else m = 1;

				if(m) {
					toSeqStart();
				}
				else
					toScreenTop();

				break;
			case SDLK_END:
				SeqVoice v = cast(SeqVoice)activeVoice;
				InputSeq i = cast(InputSeq)v.seqinput;
				if(i.activeColumn < i.columns) {
					(cast(InputSeq)v.seqinput).columnReset(i.columns,0);
					break;
				}
				// something might be wrong here...
				int scrend = tableTop - posTable.pointerOffset - 1;
				assert(scrend >= 0);

				int rows = activeVoice.activeRow.seq.rows;
				int seqend = rows -
					activeVoice.activeRow.seqOffset - 1;

				int m;
				if(scrend == 0) toSeqEnd();
				else if(seqend == 0) toScreenBot();
				else if(seqend >= scrend) {
					toScreenBot();
				}
				else {
					toSeqEnd();
				}
				break;
			case SDLK_KP_0:
				audio.player.playRow(voices);
				step(1);
				break;
			default:
				break;
			}

		}
		else if(key.mods & KMOD_CTRL) {
			switch(key.raw) {
			case SDLK_p:
				RowData r = activeVoice.activeRow;
				// bad coding because all the rowcountergetters are flawed one way or another
				int rowcount = activeVoice.getRowcounter(r.trkOffset) + r.seqOffset;
				song.splitSequence(r.track.number, r.seqOffset);
				jump(Jump.toBeginning,false);
				step(rowcount);
				centerTo(0);
				break;
			default:
				break;
			}
		}
		int r;
		if((r = activeVoice.keypress(key)) != OK) {
			switch(r) {
			case WRAPL:
				stepVoice(-1);
				break;
			case WRAPR:
				stepVoice(1);
				break;
			default:
				step(stepValue);
				break;
			}
		}
		return OK;
	}

	// ----------------------------------------------------------------
	// Block-selection surface hooks (note/data column). Cells are 4-byte
	// note Elements addressed by absolute song row (rowCounter).
	// ----------------------------------------------------------------

	override bool selectionEnabled() { return true; }
	protected override ClipKind cellKind() { return ClipKind.note; }
	protected override int cellSize() { return 4; }

	protected override int activeRowAbs() {
		return activeVoice.pos.rowCounter + posTable.pointerOffset;
	}

	protected override int rowAtScreenY(int voiceIdx, int localY) {
		int rowIdx = localY - 1;
		if(rowIdx < 0 || rowIdx >= area.height) return int.min;
		return voices[voiceIdx].pos.rowCounter + rowIdx - anchor;
	}

	// Resolve absolute song row `absRow` in voice v to (trkOffset, seqOffset).
	// false if before song start or past the last track's data.
	private bool locate(Voice v, int absRow, out int trkOffset, out int seqOffset) {
		if(absRow < 0) return false;
		int pos = 0;
		int last = v.tracks.trackLength - 1;
		for(int ti = 0; ti <= last; ti++) {
			int rows = song.sequence(v.tracks[ti]).rows;
			if(absRow < pos + rows) {
				trkOffset = ti;
				seqOffset = absRow - pos;
				return true;
			}
			pos += rows;
		}
		return false;
	}

	protected override ubyte[] readCellBytes(int voiceIdx, int absRow) {
		int t, s;
		Voice v = voices[voiceIdx];
		if(!locate(v, absRow, t, s)) return null;
		Sequence seq = song.seqs[v.tracks[t].number];
		return seq.data.raw[s * 4 .. s * 4 + 4].dup;
	}

	protected override void blankCellAt(int voiceIdx, int absRow) {
		int t, s;
		Voice v = voices[voiceIdx];
		if(!locate(v, absRow, t, s)) return;
		Sequence seq = song.seqs[v.tracks[t].number];
		seq.data.raw[s * 4 .. s * 4 + 4] = cast(ubyte[])CLEAR;
	}

	// Paste from the per-voice cursor down, clipped to the current sequence's
	// end (overflow dropped). mergeOnly: write only into empty target rows.
	protected override void pasteColumn(int voiceIdx, int clipCol, bool mergeOnly) {
		Voice v = voices[voiceIdx];
		RowData rd = v.activeRow;
		Sequence seq = rd.seq;
		int start = rd.seqOffset;
		for(int r = 0; r < rowClip.rows; r++) {
			int dst = start + r;
			if(dst >= seq.rows) break;          // stop at current sequence end
			int off = dst * 4;
			if(mergeOnly && seq.data.raw[off .. off + 4] != cast(ubyte[])CLEAR)
				continue;
			seq.data.raw[off .. off + 4] = rowClip.cell(clipCol, r)[0 .. 4];
		}
	}

	// Allocate a free sequence, size it to the clip, fill it, and insert a
	// track entry referencing it at the cursor.
	protected override void pasteNewColumn(int voiceIdx, int clipCol) {
		Voice v = voices[voiceIdx];
		int n = song.getFreeSequence(1);
		if(n <= 0) {
			UI.statusline.display("No free sequence for paste-new.");
			return;
		}
		Sequence seq = song.seqs[n];
		seq.clear();                 // leaves 1 row + end mark
		int need = rowClip.rows;
		if(need > 1) seq.expand(0, need - 1, false);
		for(int r = 0; r < need; r++)
			seq.data.raw[r * 4 .. r * 4 + 4] = rowClip.cell(clipCol, r)[0 .. 4];
		// rows/end-mark already set by clear()+expand(); don't refresh() (a note
		// data byte could collide with SEQ_END_MARK on a rescan).
		v.tracks.insertAt(v.activeRow.trkOffset);
		v.tracks[v.activeRow.trkOffset].setValue(0xa0, n);
	}

	// ---- Block undo: snapshot all sequences + tracklists (correct over
	// minimal; block edits are user-initiated and infrequent). ----

	protected override void saveSelState() {
		com.session.insertUndo(this, createSelState());
	}

	private UndoValue createSelState() {
		UndoValue v;
		foreach(s; song.seqs) {
			v.seqSources ~= s;
			v.seqData ~= s.data.raw.dup;
		}
		for(int i = 0; i < 3; i++) {
			auto tl = song.tracks[i];
			v.trackLists ~= TracklistStore(tl.deepcopy, tl);
		}
		v.posTable = posTable.dup();
		v.subtuneNum = song.subtune;
		return v;
	}

	override void undo(UndoValue v) {
		if(v.subtuneNum != song.subtune) return;
		foreach(t; v.trackLists)
			t.source.overwriteFrom(t.store);
		foreach(i, s; v.seqSources) {
			s.data.raw[] = v.seqData[i][];
			s.refresh();
		}
		if(v.posTable !is null)
			posTable.copyFrom(v.posTable);
		refresh();
		step(0);
	}

	override UndoValue createRedoState(UndoValue value) {
		return createSelState();
	}
}
