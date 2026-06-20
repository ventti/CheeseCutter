/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Instrument and command editor panels (HexTable / InsTable / CmdTable).
*/

module ui.tables;
import ui.ui;
import ui.dialogs;
import ui.input;
import ui.help;
import com.session;
import com.util;
import ct.purge;
import ct.base : MAX_SEQ_NUM, NOTES;
import derelict.sdl2.sdl;
import std.string;
import std.stdio : stderr;
import std.file;
import com.fb;
import std.conv, std.array;
import audio.visualizer;
import audio.player;
import seq.sequencer : playbackBarColor, wrapBarColor;
import com.shortcuts : Ctx;
import std.algorithm : sort;

abstract class Table : Window {
	mixin ValueChangedHandler;
	const int columns, rows, visibleRows;
	protected {
		ubyte[] data;
		int column, row, cursorOffset, viewOffset;
	}

	this(Rectangle a, ubyte[] tbl, int c, int r) {
		super(a);
		columns = c;
		rows = r;
		data = tbl;
		input = new InputByte(tbl[0..1]);
		visibleRows = a.height - 1;
	}

	override void refresh() {
		update();
	}

protected:

	void adjustView();
}

private int playbackIndexColor(float brightness, int defaultColor = 12) {
	if(brightness > 0.66f) return 1;
	if(brightness > 0.33f) return 15;
	if(brightness > 0.01f) return 12;
	return defaultColor;
}

enum activeInstrumentColor = 3;

private string byteHex(int value) {
	return format("$%02X", value & 0xff);
}

private string rowHex(int value) {
	return format("$%02X", value & 0x3f);
}

private string sidControlDescription(int value) {
	string[] parts;
	if(value & 0x01) parts ~= "gate";
	if(value & 0x02) parts ~= "sync";
	if(value & 0x04) parts ~= "ring";
	if(value & 0x08) parts ~= "test";
	if(value & 0x10) parts ~= "triangle";
	if(value & 0x20) parts ~= "saw";
	if(value & 0x40) parts ~= "pulse";
	if(value & 0x80) parts ~= "noise";
	if(parts.length == 0) return "no control bits set";
	return parts.join(" + ");
}

private string sweepPointerDescription(int value, string tableName) {
	if(value == 0) return "advance to next " ~ tableName ~ " row.";
	if(value == 0x7f) return "stop " ~ tableName ~ " program.";
	if(value <= 0x3f) return "jump to " ~ tableName ~ " row " ~ rowHex(value) ~ ".";
	return "illegal " ~ tableName ~ " pointer.";
}

private class HexTable : Table, Undoable {
	this(Rectangle a, ubyte[] tbl, int c, int r) {
		super(a,tbl,c,r);
		(cast(InputValue)input).setValueChangedCallback(&valueChangedCallback);
	}

	override @property string contextId() { return Ctx.subtable; }

	void valueChangedCallback() {
		saveState(false);
	}

	override void activate() {
		initializeInput();
		showByteDescription();
	}

	void initializeInput() {
		input.setCoord(area.x + 3 + column * 3, area.y + cursorOffset + 1);
	}
	alias initializeInput set;

	override protected void adjustView() {
		if(column >= columns) {
			column -= columns;
		}
		else if(column < 0) {
			column += columns;
		}
		if(row >= rows) {
			row = row - rows;
		}
		else if(row < 0) {
			row = rows + row;
		}
		assert(row >= 0);
		if(cursorOffset >= visibleRows) {
			int i = cursorOffset - visibleRows + 1;
			viewOffset += i;
			if(viewOffset >= rows) {
				viewOffset -= rows;
			}
			cursorOffset -= i;
		}
		if(cursorOffset < 0) {
			int i = -cursorOffset;
			viewOffset -= i;
			if(viewOffset < 0)
				viewOffset += rows;
			cursorOffset += i;
		}
		initializeInput();
		showByteDescription();
	}

	void stepColumn(int n) {
		column += n;
		adjustView();
		showByteDescription();
	}

	void setColumn(int n) {
		column = n;
		adjustView();
	}

	void stepColumnWrap(int n) {
		column += n;
		if(column >= columns) {
			stepRow(1);
		}
		adjustView();
	}

	void stepRow(int n) {
		seekRow(n + row);
	}

	void setCursorOffset(int r) {
		row += r - cursorOffset;
		cursorOffset = r;
		adjustView();
	}

	void seekRow(int r) {
		cursorOffset += r - row;
		row = r;
		adjustView();
	}

	void seekRowOnTopIfNeeded(int r) {
		if(r >= rows) {
			r = r - rows;
		}
		else if(r < 0) {
			r = rows + r;
		}

		int visibleOffset = -1;
		for(int i = 0; i < visibleRows; i++) {
			if(((viewOffset + i) % rows) == r) {
				visibleOffset = i;
				break;
			}
		}

		row = r;
		if(visibleOffset < 0) {
			viewOffset = r;
			cursorOffset = 0;
		}
		else {
			cursorOffset = visibleOffset;
		}
		initializeInput();
	}

	void seekTableEnd() {
	}

	void deleteRow() {
	}

	void insertRow() {
	}

	void seekColumn(int c) {
		column = c;
	}

	override int keypress(Keyinfo key) {
        /+
		if(key.mods & KMOD_CTRL || key.mods & KMOD_ALT ||
		   key.mods & KMOD_META) return OK;
           +/
		if(key.mods & KMOD_CTRL || key.mods & KMOD_ALT ||
		   key.mods & KMOD_GUI) return OK;

		switch(key.raw)
		{
		case SDLK_LEFT:
			if(input.step(-1) == WRAP) {
				stepColumn(-1);
			}
			break;
		case SDLK_RIGHT:
			if(input.step(1) == WRAP) {
				stepColumn(1);
			}
			break;
		case SDLK_INSERT, SDLK_RETURN:
			insertRow();
			break;
		case SDLK_DELETE, SDLK_BACKSPACE:
			deleteRow();
			break;
		case SDLK_DOWN:
			stepRow(1);
			break;
		case SDLK_UP:
			stepRow(-1);
			break;
		case SDLK_PAGEUP:
			stepRow(-PAGESTEP / 2);
			break;
		case SDLK_PAGEDOWN:
			stepRow(PAGESTEP / 2);
			break;
		case SDLK_HOME:
			if(cursorOffset > 0)
				setCursorOffset(0);
			else seekRow(0);
			break;
		case SDLK_END:
			if(cursorOffset < visibleRows - 1)
				setCursorOffset(visibleRows - 1);
			else seekTableEnd();
			break;
		case SDLK_h:
			showByteDescription();
			break;

		default:
			if(input.keypress(key) == WRAP) {
				stepColumnWrap(1);
			}
			break;
		}
		initializeInput();
		return OK;
	}

	override void clickedAt(int x, int y, int button, int clicks = 1) {
		int rx = x - area.x;
		int ry = y - area.y;
		if(ry < 1 || ry > visibleRows)
			return;
		int c = (rx - 3) / 3;
		setCursorOffset(ry - 1);
		if(c < 0) c = 0;
		if(c >= columns) c = columns - 1;
		setColumn(c);
	}


protected:

	override final UndoValue createRedoState(UndoValue value) {
		return createState(true);
	}

	override final void undo(UndoValue v) {
		// if array has 1 child, assume to be data for this table
		if(v.tableData.length == 1) {
			this.data[] = v.tableData[0];
		}
		else {
			int idx;
			song.tableIterator((ct.base.Song.Table t) {
					t.data[0..$] = v.tableData[idx++][0..$];
				});
		}
		if(v.hasInsLabels) {
			song.insLabels[] = v.insLabels[];
		}
		initializeInput();
	}

	void showByteDescription() {
	}

	void showByteDescription(PetString pet) {
		if(song.ver < 9 || !state.displayHelp) return;
		string[] s = com.util.petscii2D(pet).splitLines();
		string outstr = s[0];
		if(s.length > 1)
			outstr ~= " `01[F12 for more]";
		UI.statusline.display(format("Byte %d: %s", column + 1, outstr));
	}

	bool highlightRow(int row) {
		return false;
	}

	void saveState(bool allTables) {
		auto v = createState(allTables);
		com.session.insertUndo(this, v);
	}

private:

	UndoValue createState(bool allTables) {
		UndoValue v;
		if(allTables) {
			song.tableIterator((ct.base.Song.Table t) {
					v.tableData ~= t.data.dup;
				});
			v.insLabels = song.insLabels;
			v.hasInsLabels = true;
		}
		else v.tableData = [data.dup];
		return v;
	}

}

class InsValueTable : HexTable {
	private {
		static ubyte[8] instrBuffer;
		static char[32] instrName = 0x20;
		int mark = -1;
		int width;
		FileSelectorDialog loadDialog;
	}
	this(Rectangle a) {
		width = a.width > 27 ? a.width - 27 : 0;
		if(width > 32) width = 32;
		super(a, song.instrumentTable, 8, 48);
		loadDialog = new FileSelectorDialog(Rectangle(),
											"Load Instrument",
											&loadCallback);
	}

	override void refresh() {
		data = song.instrumentTable;
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_ALT) return OK;
		if(key.mods & KMOD_CTRL) {
			switch(key.raw)  {
			case SDLK_c:
				foreach(i, ref buf; instrBuffer) {
					buf = data[row + i * 48];
				}
				instrName[0..32] = insName(row)[];
				UI.statusline.display("Instrument copied to buffer.");
				break;
			case SDLK_v:
				saveState(true);
				foreach(i, ref buf; instrBuffer) {
					data[i * 48 + row] = buf;
				}
				song.insLabels[row][] = instrName[];
				initializeInput();
				break;
			case SDLK_s:
				void delegate(string) dg = (string fn) {
					if(fn == "")
						return;
					if(!fnIsSane(fn)) {
						UI.statusline.display("Illegal characters in filename!");
						return;
					}
					try {
						com.session.song.savePatch(fn, state.activeInstrument);
					}
					catch(UserException e) {
						stderr.writeln(e.toString);
						UI.statusline.display(e.toString);
						return;
					}
					UI.statusline.display(format("Saved instrument %d", state.activeInstrument));
				};
				string fn = fnClean(std.string.stripRight
									(std.conv.to!string(song.insLabels[row])));
				if(fn.length == 0)
					fn = "unnamed";
				try {
					chdir(loadDialog.directory);
				}
				catch(FileException e) {
					stderr.writeln(e);
					UI.statusline.display(format("Could not change to directory %40s",loadDialog.directory));
					break;
				}

				mainui.activateDialog(new StringDialog("Enter filename: ",
													   dg,
													   fn ~ ".cti",
													   32));

				break;
			case SDLK_l:
				mainui.activateDialog(loadDialog);
				break;
			case SDLK_d:
				void delegate(int) dg = (int param) {
					if(param != 0) return;
					saveState(true);
					(new Purge(song)).deleteInstrument(state.activeInstrument);
				};

				mainui.activateDialog(new ConfirmationDialog("Delete current instrument (y/n)? ",
															 dg));

				break;
			case SDLK_x:
				break;
			default: break;
			}
		}
		int r = super.keypress(key);
		if(r  == WRAP) {
			stepColumn(1);
		}
		return OK;
	}

	private void loadCallback(string fn) {
		if(!std.file.exists(fn)) {
			UI.statusline.display("File does not exist or is not accessible!");
			return;
		}
		if(fn.indexOf(".cti") == -1) {
			UI.statusline.display("Not loading; possibly not an instrument def file.");
			return;
		}
		try {
			saveState(true);
			song.insertPatch(fn, state.activeInstrument);
		}
		catch(Exception e) {
			stderr.writeln(e.toString);
			UI.statusline.display("Error in parsing instrument data!");
		}
	}

	string insName(int row) {
		assert(row >= 0 && row < 48);
		return format(song.insLabels[row % 48][0..32]);
	}

	override void stepColumn(int n) {
		super.stepColumn(n);
	}

	override void stepColumnWrap(int n) {
		stepColumn(-7);
		adjustView();
	}

	override void activate() {
		super.activate();
	}

	override void update() {
		int b = 0;
		int i, j, ofs;
		int myrow = row;

		if(myrow > 48) myrow -= 48;
		screen.fprint(area.x,area.y, "`b1I`01nstruments");

		for(i = 0; i < visibleRows; i++) {
			int p = (i + viewOffset);
			if(p > 47) p -= 48;
			assert(p >= 0 && p < 48);

			// Check if entire row is zeros
			bool allZeros = true;
			for(j=0; j<8; j++) {
				if(data[p + j * 48] != 0) {
					allZeros = false;
					break;
				}
			}

			float brightness = audio.visualizer.getInstrumentBrightness(p);
			bool isActiveInstrument = state.activeInstrument >= 0 && state.activeInstrument == p;

			int instrNumColor = 12;   // default gray
			int instrNumBg = 0;
			auto uc = song.instrumentColor(p);   // user color from description ($X/$XY)
			if(uc.fg >= 0) instrNumColor = uc.fg;
			if(uc.bg >= 0) instrNumBg = uc.bg;

			if(!isActiveInstrument && brightness > 0.01f) {   // playback highlight overrides
				instrNumColor = brightness > 0.66f ? 1 :
					brightness > 0.33f ? 15 : 12;
				instrNumBg = 0;
			}
			if(isActiveInstrument) {   // active instrument overrides all
				instrNumColor = activeInstrumentColor;
				instrNumBg = 0;
			}

			screen.cprint(area.x, area.y + i + 1, instrNumColor, instrNumBg, format("%02X:", p));

		// Print instrument data bytes
		for(j=0; j<8; j++) {
			ofs = p + j * 48;
			int hl = isActiveInstrument ? activeInstrumentColor : (p == mark) ? 13 : 5;
			// Display "--" for zero values only if entire row is zeros
			string displayVal = (allZeros && data[ofs] == 0) ? "--" : format("%02X", data[ofs]);
			screen.cprint(area.x+3+j*3,area.y + i + 1,hl,0, displayVal ~ " ");
		}

			if(width > 0) {
				string label = insName(p)[0..width];
				if(paddedStringLength(label, 32) == 0) {
					string emptyLabel = "No description";
					if(width < emptyLabel.length)
						emptyLabel = emptyLabel[0..width];
					else
						emptyLabel ~= std.array.replicate(" ", width - cast(int)emptyLabel.length);
					screen.cprint(area.x + 27, area.y + 1 + i, 11, 0, emptyLabel);
				}
				else
					screen.cprint(area.x + 27, area.y + 1 + i,
								  isActiveInstrument ? activeInstrumentColor : 15, 0, label);
			}
		}
	}

	override void initializeInput() {
		super.set();
		assert(row < 48);
		int ofs = column * 48 + row;
		input.setOutput(data[ofs .. ofs+1]);
	}

	override void stepRow(int n) {
		super.stepRow(n);
		UI.activateInstrument(row);
	}

	override void showByteDescription() {
		if(song.ver > 8) {
			super.showByteDescription(song.instrumentByteDescriptions[column]);
		}
	}
}

class InsTable : Window {
	private {
		DialogString insdesc;
		InsValueTable insinput;
	}
	Window active;

	override @property string contextId() { return Ctx.instrumentTable; }

	this(Rectangle a) {
		super(a);
		insdesc = new DialogString(a, com.fb.mode ? 32 : 16);
		insinput = new InsValueTable(a);
		refresh();
		activateInsValueTable();
	}

	override const ContextHelp contextHelp() {
		if(song.ver > 8)
			return genPlayerContextHelp("Instrument table",
										song.instrumentByteDescriptions);
		return ui.help.HELPMAIN;
	}

	override void refresh() {
		super.refresh();
		insdesc.refresh();
		insinput.refresh();
	}

	@property int row() {
		return insinput.row;
	}

	void stepRow(int n) { insinput.stepRow(n); }
	void seekRow(int r) { insinput.seekRow(r); }

	override void activate() {
		activateInsValueTable();
	}

	override void deactivate() {
		if(active == insdesc) {
			commitDescInput();
		}
		activateInsValueTable();
		active.update();
		state.allowInstabNavigation = true;
	}

	void activateDescInput() {
		update();
		active = insdesc;
		input = insdesc.input;
		input.setCoord(area.x + 9 * 3, 1 + area.y + insinput.cursorOffset);
		insdesc.setString(format(song.insLabels[insinput.row]));
		initializeInput();
		state.allowInstabNavigation = false;
	}

	void activateInsValueTable() {
		active = insinput;
		input = insinput.input;
		active.activate();
		initializeInput();
		state.allowInstabNavigation = true;
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_ALT) return OK;
		if(key.unicode == SDLK_RETURN || key.unicode == SDLK_TAB) {
			if(active == insinput) {
				activateDescInput();
			}
			else {
				commitDescInput();
				activateInsValueTable();
			}
			return OK;
		}
		int r;
		r = active.keypress(key);
		return r;
	}

	override void update() {
		insinput.update();
		if(active == insdesc) {
			insdesc.update();
		}
	}

	void initializeInput() {
		if(active == insinput) insinput.initializeInput();
	}
	alias initializeInput set;

private:

	char[32] descValue() {
		return paddedString32(insdesc.toString(false));
	}

	void commitDescInput() {
		auto value = descValue();
		if(song.insLabels[insinput.row] == value)
			return;
		insinput.saveState(true);
		song.insLabels[insinput.row][] = value[];
	}

public:

	override void clickedAt(int x, int y, int button, int clicks = 1) {
		if(active == insdesc) {
			commitDescInput();
		}
		insinput.clickedAt(x,y,button,clicks);
		if((x - area.x) > 3 + 8 * 3)
			activateDescInput();
	}
}


class CmdTable : HexTable {
	alias row position;

	this(Rectangle a) {
		super(a, song.superTable, 1, 64);
		input = new InputSpecial(song.superTable);
	}

	override void update() {
		int i;
		if(state.shortTitles)
			screen.fprint(area.x,area.y, "`01Co`b1m`01mand");
		else
			screen.fprint(area.x,area.y, "`01Cmd (Alt-S)");
		for(i = 0; i < visibleRows; i++) {
			int ofs = (viewOffset + i) & 0x3f;
			ubyte cmd = song.superTable[ofs] & 15;
			ubyte val1 = song.superTable[ofs+64];
			ubyte val2 = song.superTable[ofs+128];
			// Check if entire row is zeros (cmd is part of the row check)
			bool allZeros = (cmd == 0 && val1 == 0 && val2 == 0);
			// Display "--" for zero values only if entire row is zeros
			string v1 = (allZeros && val1 == 0) ? "--" : format("%02X", val1);
			string v2 = (allZeros && val2 == 0) ? "--" : format("%02X", val2);
			screen.fprint(area.x,area.y + i + 1,
						  format("`0c%02X:`0d%01X-`05%s %s", ofs, cmd, v1, v2));
		}
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_ALT) return OK;
		switch(key.raw) {
		case SDLK_LEFT:
			input.step(-1);
			break;
		case SDLK_RIGHT:
			input.step(1);
			break;
		case SDLK_DOWN:
			stepRow(1);
			break;
		case SDLK_UP:
			stepRow(-1);
			break;
		case SDLK_PAGEUP:
			stepRow(-(PAGESTEP/2));
			break;
		case SDLK_PAGEDOWN:
			stepRow((PAGESTEP/2));
			break;
		case SDLK_HOME:
			seekRow(0);
			break;
		case SDLK_END:
			seekTableEnd();
			break;
		default:
			break;
		}
		int r = input.keypress(key);
		song.superTable[position] = input.inarray[0];
		song.superTable[position+64] = cast(ubyte)input.toIntRange(1, 3);
		song.superTable[position+128] = cast(ubyte)input.toIntRange(3, 5);
		if(r == WRAP) {
			stepRow(1);
		}
		showByteDescription();
		return OK;
	}

	override void initializeInput() {
		super.initializeInput();
		input.inarray[0] = song.superTable[position];
		input.inarray[1] = song.superTable[position+64] >> 4;
		input.inarray[2] = song.superTable[position+64] & 15;
		input.inarray[3] = song.superTable[position+128] >> 4;
		input.inarray[4] = song.superTable[position+128] & 15;
	}

	override void seekTableEnd() {
		for(int i = 63; i >= 1; i--) {
			if(data[i-1] > 0) {
				seekRow(i);
				return;
			}
		}
	}

	override ContextHelp contextHelp() {
		if(song.ver > 8)
			return genPlayerContextHelp("Command table",
										song.cmdDescriptions);
		return ui.help.HELPMAIN;
	}

	override void showByteDescription() {
		if(song.ver < 9 || !state.displayHelp) return;
		UI.statusline.display(commandFieldDescription());
	}

private:

	int descriptionByte() {
		InputSpecial special = cast(InputSpecial)input;
		if(special is null)
			return 1;
		return special.nibble < 3 ? 1 + special.nibble / 2 : 3;
	}

	string commandFieldDescription() {
		int cmd = input.inarray[0] & 15;
		int byteNo = descriptionByte();
		if(byteNo == 1)
			return format("Byte 1: Command $%X: %s", cmd, commandName(cmd));
		return format("Byte %d: %s", byteNo, commandParameterDescription(cmd, byteNo));
	}

	string commandName(int cmd) {
		switch(cmd) {
		case 0: return "Slide up";
		case 1: return "Slide down";
		case 2: return "Hi-fi vibrato";
		case 3: return "Detune current note";
		case 4: return "Set ADSR for the current note";
		case 5: return "Lo-fi vibrato";
		case 6: return "Set wave";
		case 7: return "Portamento a tie note";
		case 8: return "Stop portamento";
		default: return "Unknown command";
		}
	}

	string commandParameterDescription(int cmd, int byteNo) {
		switch(cmd) {
		case 0, 1:
			return byteNo == 2 ? "Slide speed high byte (signed 16-bit)." :
				"Slide speed low byte (signed 16-bit).";
		case 2:
			return byteNo == 2 ? "Hi-fi vibrato feel in low nibble." :
				"Hi-fi vibrato speed in high nibble, depth divider in low nibble.";
		case 3:
			return byteNo == 2 ? "Detune high byte (signed 16-bit)." :
				"Detune low byte (signed 16-bit).";
		case 4:
			return byteNo == 2 ? "Attack / decay." : "Sustain / release.";
		case 5:
			return byteNo == 2 ? "Lo-fi vibrato speed." : "Lo-fi vibrato depth.";
		case 6:
			return byteNo == 2 ? "Unused." : "SID control register waveform value.";
		case 7:
			return byteNo == 2 ? "Portamento speed high byte." :
				"Portamento speed low byte. Runs until command $8.";
		case 8:
			return "Unused. Command $8 stops portamento.";
		default:
			return "Parameter value.";
		}
	}

}

class ChordTable : HexTable {
	this(Rectangle a) {
		super(a, song.chordTable, 1, 128);
	}

	override void refresh() {
		super.refresh();
		data = song.chordTable;
	}

	override void seekTableEnd() {
		for(int i = 127; i >= 1; i--) {
			if(data[i-1] > 0) {
				seekRow(i);
				return;
			}
		}
	}

	override void update() {
		int i;
		if(state.shortTitles)
			screen.fprint(area.x,area.y, "`01Chor`b1d`01");
		else
			screen.fprint(area.x,area.y, "`01Chd (A-D)");

		for(i = 0; i < visibleRows; i++) {
			int row = (i + viewOffset) & 0x7f;
			string col = "`05";
			if(data[row] >= 0x80) col = "`0d";
			int indexColor = playbackIndexColor(
				audio.visualizer.getTableRowBrightness(audio.visualizer.PlaybackTable.Chord, row));

			// Check if all subsequent rows are zeros
			bool allSubsequentZeros = true;
			if(data[row] == 0) {
				for(int checkRow = row + 1; checkRow < 128; checkRow++) {
					if(data[checkRow] != 0) {
						allSubsequentZeros = false;
						break;
					}
				}
			}

			// Display "--" only if this value is zero and all subsequent rows are zeros
			string val = (data[row] == 0 && allSubsequentZeros) ? "--" : format("%02X", data[row]);
			screen.fprint(area.x, area.y + i + 1,
						  format("`0%x%02X:%s%s", indexColor, row, col, val));
		}

		for(i = 0; i < visibleRows; i++) {
			screen.fprint(area.x + 5, area.y + i + 1, "  ");
		}

		int[] chordno = getHighestChordIndex();

		{
			int ct;
			for(i = 0; i < viewOffset; i++) {
				if(data[i] >= 0x80) ct++;
			}
			bool doPrint = true;
			int row = viewOffset & 127;
			for(i = 0; i < visibleRows; i++,row++) {
				if(row > 127) {
					row -= 128;
					ct = 0;
					doPrint = true;
				}

				if(doPrint) {
					screen.fprint(area.x + 5, area.y + i + 1, format("`0c%X ", ct));
					doPrint = false;
				}

				if(data[row] >= 0x80) {
					if(ct >= chordno[0]) break;
					ct++;
					doPrint = true;
					if(row >= chordno[1]) {
						doPrint = false;
					}
				}
			}
		}
	}

	override void initializeInput() {
		super.initializeInput();
		input.setOutput(data[row .. row + 1]);
		song.generateChordIndex();
	}

	override void insertRow() {
		saveState(false);
		ubyte[] tmp = data[row .. $-1].dup;
		foreach(i, c; tmp) {
			if(/+row > 0  && +/ c >= (0x80 + row) && ++c < 0x100) {
				tmp[i] = c;
			}
		}
		data[row+1 .. $] = tmp;
		data[row] = 0;
		initializeInput();
	}

	override void deleteRow() {
		saveState(false);
		ubyte[] tmp = data[row + 1 .. $].dup;
		foreach(i, c; tmp) {
			if(c > (0x80 + row) && --c >= 0x80)
				tmp[i] = c;
		}
		data[row .. $ - 1] = tmp;
		data[$-1] = 0;
		initializeInput();
	}

private:

	// returns number of chords and the offset of the last chord
	int[] getHighestChordIndex() {
		foreach_reverse(counter, idx; song.chordIndexTable) {
			if(idx == 0) continue;
			return cast(int[])[counter, idx];
		}
		return [-1, -1];
	}
}

private class TrackCellInput : InputWord {
	bool editable;

	this(ubyte[] p) {
		super(p);
	}

	override int keypress(Keyinfo key) {
		if(!editable) return OK;
		return super.keypress(key);
	}

	override void update() {
		if(editable) {
			super.update();
		}
		else {
			cursor.set(x + nibble, y);
		}
	}
}

class TracksTable : Window, Undoable {
	override @property string contextId() { return Ctx.trackColumn; }
	override ContextHelp contextHelp() { return ui.help.HELPMAIN; }

	private {
		struct TrackRow {
			int offset;
		}

		ubyte[2] inputBuffer;
		TrackCellInput trackInput;
		QueryDialog queryClip;
		Clip[] clip;
		int editVoice, editTrackIndex;
		int[] offsets;
		int row, cursorOffset, viewOffset, column;
	}

	this(Rectangle a) {
		super(a);
		trackInput = new TrackCellInput(inputBuffer[]);
		trackInput.setValueChangedCallback(&valueChangedCallback);
		queryClip = new QueryDialog("Copy number of tracks to clipboard: $",
									&clipCallback, 0x80);
		input = trackInput;
		refresh();
	}

	override void refresh() {
		rebuildOffsets();
		initializeInput();
		update();
	}

	override void activate() {
		initializeInput();
	}

	override void deactivate() {
		flushInput();
	}

	override void update() {
		rebuildOffsets();
		screen.fprint(area.x, area.y, "`01Tracks");
		for(int i = 0; i < visibleRows; i++) {
			int rowIdx = viewOffset + i;
			int y = area.y + i + 1;
			screen.cprint(area.x, y, 12, 0, std.array.replicate(" ", area.width));
			if(rowIdx >= offsets.length)
				continue;

			int offset = offsets[rowIdx];
			string offsetText = offset < 0x100 ? format("%02X", offset) : format("%03X", offset);
			screen.cprint(area.x, y, 12, 0, offsetText.rightJustify(3));

			for(int voice = 0; voice < 3; voice++) {
				int trackIndex;
				int x = trackColumnX(voice);
				if(offset == trackEndOffset(voice)) {
					screen.cprint(x, y, 1, 0, "LOOP");
				}
				else if(trackAtOffset(voice, offset, trackIndex)) {
					auto trk = song.tracks[voice][trackIndex];
					int col = isActiveTrack(voice, trackIndex) ? 13 : 5;
					screen.cprint(x, y, col, 0, format("%04X", trk.smashedValue));
					if(trackIndex == seqPos[voice].mark) {
						for(int bgx = x; bgx < x + 4; bgx++) {
							if(screen.getbg(bgx, y) == 0)
								screen.setbg(bgx, y, playbackBarColor);
						}
					}
					if(trackIndex == song.tracks[voice].wrapOffset) {
						for(int bgx = x; bgx < x + 4; bgx++) {
							if(screen.getbg(bgx, y) == 0)
									screen.setbg(bgx, y, wrapBarColor);
							}
						}
					}
				else {
					screen.cprint(x, y, 5, 0, "----");
				}
			}
		}
	}

	override int keypress(Keyinfo key) {
		if((key.mods & KMOD_CTRL) && (key.mods & KMOD_ALT)) {
			switch(key.raw) {
			case SDLK_1:
				swapTracksWith(0);
				return OK;
			case SDLK_2:
				swapTracksWith(1);
				return OK;
			case SDLK_3:
				swapTracksWith(2);
				return OK;
			default:
				break;
			}
		}
		else if(key.mods & KMOD_ALT) {
			switch(key.key) {
			case SDLK_z:
				mainui.activateDialog(queryClip);
				return OK;
			case SDLK_b:
				pasteTracks(true);
				return OK;
			default:
				return OK;
			}
		}

		if(key.mods & KMOD_CTRL) {
			switch(key.raw) {
			case SDLK_INSERT, SDLK_RETURN:
				saveState();
				if(key.mods & KMOD_SHIFT) {
					for(int voice = 0; voice < 3; voice++)
						insertTrack(voice, false);
				}
				else {
					insertTrack(column, false);
				}
				return OK;
			case SDLK_DELETE, SDLK_BACKSPACE:
				saveState();
				if(key.mods & KMOD_SHIFT) {
					for(int voice = 0; voice < 3; voice++)
						deleteTrack(voice, false);
				}
				else {
					deleteTrack(column, false);
				}
				return OK;
			case SDLK_q:
				transposeFromCursor(1);
				return OK;
			case SDLK_a:
				transposeFromCursor(-1);
				return OK;
			case SDLK_c:
				mainui.activateDialog(queryClip);
				return OK;
			case SDLK_v:
				mainui.activateDialog(new ConfirmationDialog("Paste tracks; insert or overwrite? (i/o) ",
															 &pasteCallback,
															 "oi", 1));
				return OK;
			case SDLK_i:
				pasteTracks(true);
				return OK;
			case SDLK_o:
				pasteTracks(false);
				return OK;
			default:
				break;
			}
		}

		switch(key.raw) {
		case SDLK_UP:
			stepRow(-1);
			return OK;
		case SDLK_DOWN:
			stepRow(1);
			return OK;
		case SDLK_PAGEUP:
			stepRow(-PAGESTEP / 2);
			return OK;
		case SDLK_PAGEDOWN:
			stepRow(PAGESTEP / 2);
			return OK;
		case SDLK_HOME:
			seekRow(0);
			return OK;
		case SDLK_END:
			seekRow(cast(int)offsets.length - 1);
			return OK;
		case SDLK_LEFT:
			if(!trackInput.editable || trackInput.step(-1) == WRAP)
				stepColumn(-1);
			return OK;
		case SDLK_RIGHT:
			if(!trackInput.editable || trackInput.step(1) == WRAP)
				stepColumn(1);
			return OK;
		case SDLK_INSERT, SDLK_RETURN:
			if(hasActiveTrack()) {
				saveState();
				insertTrack(column, true);
			}
			return OK;
		case SDLK_DELETE, SDLK_BACKSPACE:
			if(hasActiveTrack()) {
				saveState();
				deleteTrack(column, true);
			}
			return OK;
		default:
			break;
		}

		if(trackInput.editable) {
			switch(key.unicode) {
			case 6: // Ctrl-F
				selectFreeSequence();
				return OK;
			case SDLK_LESS:
				stepSequence(-1);
				return OK;
			case SDLK_GREATER:
				stepSequence(1);
				return OK;
			default:
				break;
			}

			if(key.raw == SDLK_SPACE) {
				flushInput();
				return OK;
			}

			trackInput.keypress(key);
			flushInput();
		}
		return OK;
	}

	override void clickedAt(int x, int y, int button, int clicks = 1) {
		int ry = y - area.y - 1;
		int rx = x - area.x;
		rebuildOffsets();
		if(ry < 0 || ry >= visibleRows || viewOffset + ry >= offsets.length)
			return;
		setCursorOffset(ry);
		if(rx >= 4) {
			int c = (rx - 4) / 5;
			if(c < 0) c = 0;
			if(c > 2) c = 2;
			column = c;
		}
		initializeInput();
	}

	bool offsetAtCoord(int x, int y, out int offset) {
		rebuildOffsets();
		int ry = y - area.y - 1;
		if(ry < 0 || ry >= visibleRows) return false;
		int rowIdx = viewOffset + ry;
		if(rowIdx < 0 || rowIdx >= offsets.length)
			return false;
		offset = offsets[rowIdx];
		return true;
	}

private:

	@property int visibleRows() {
		return area.height - 1;
	}

	int trackColumnX(int voice) {
		return area.x + 4 + voice * 5;
	}

	void valueChangedCallback() {
		saveState();
	}

	void saveState() {
		com.session.insertUndo(this, createState());
	}

	UndoValue createState() {
		UndoValue v;
		for(int i = 0; i < 3; i++) {
			auto tl = song.tracks[i];
			v.trackLists ~= TracklistStore(tl.deepcopy, tl);
		}
		v.subtuneNum = song.subtune;
		return v;
	}

public:

	override void undo(UndoValue v) {
		if(v.subtuneNum != song.subtune)
			return;
		foreach(t; v.trackLists) {
			t.source.overwriteFrom(t.store);
		}
		refresh();
	}

	override UndoValue createRedoState(UndoValue value) {
		return createState();
	}

private:

	void rebuildOffsets() {
		offsets.length = 0;
		for(int voice = 0; voice < 3; voice++) {
			int offset = 0;
			auto tracks = song.tracks[voice];
			for(int i = 0; i < tracks.trackLength; i++) {
				addOffset(offset);
				offset += song.sequence(tracks[i]).rows;
			}
			addOffset(offset);
		}
		sort(offsets);
		if(offsets.length == 0) {
			row = cursorOffset = viewOffset = 0;
		}
		else {
			adjustView();
		}
	}

	void addOffset(int offset) {
		foreach(existing; offsets) {
			if(existing == offset)
				return;
		}
		offsets ~= offset;
	}

	bool trackAtOffset(int voice, int offset, out int trackIndex) {
		int pos;
		auto tracks = song.tracks[voice];
		for(int i = 0; i < tracks.trackLength; i++) {
			if(pos == offset) {
				trackIndex = i;
				return true;
			}
			pos += song.sequence(tracks[i]).rows;
			if(pos > offset) {
				trackIndex = i;
				return false;
			}
		}
		trackIndex = tracks.trackLength;
		return false;
	}

	int trackEndOffset(int voice) {
		int offset = 0;
		auto tracks = song.tracks[voice];
		for(int i = 0; i < tracks.trackLength; i++)
			offset += song.sequence(tracks[i]).rows;
		return offset;
	}

	bool isActiveTrack(int voice, int trackIndex) {
		if(seqPos !is null && seqPos[voice].trkOffset == trackIndex)
			return true;
		if(audio.player.isPlaying && fplayPos !is null &&
		   fplayPos[voice].trkOffset == trackIndex)
			return true;
		return false;
	}

	void flushInput() {
		if(!trackInput.editable) return;
		auto trk = song.tracks[editVoice][editTrackIndex];
		trk.setValue(inputBuffer[0], inputBuffer[1]);
		inputBuffer[] = [trk.trans, trk.number];
		trackInput.setOutput(inputBuffer[]);
	}

	void initializeInput() {
		rebuildOffsets();
		if(offsets.length == 0) {
			trackInput.editable = false;
			input = trackInput;
			return;
		}

		int trackIndex;
		bool editable = trackAtOffset(column, offsets[row], trackIndex);
		trackInput.editable = editable;
		if(editable) {
			auto trk = song.tracks[column][trackIndex];
			editVoice = column;
			editTrackIndex = trackIndex;
			inputBuffer[] = [trk.trans, trk.number];
			trackInput.setOutput(inputBuffer[]);
		}
		trackInput.setCoord(trackColumnX(column), area.y + cursorOffset + 1);
		input = trackInput;
	}

	void adjustView() {
		if(offsets.length == 0) {
			row = cursorOffset = viewOffset = 0;
			return;
		}

		if(row < 0) row = 0;
		if(row >= offsets.length) row = cast(int)offsets.length - 1;

		int maxView = cast(int)offsets.length - visibleRows;
		if(maxView < 0) maxView = 0;
		if(row < viewOffset)
			viewOffset = row;
		else if(row >= viewOffset + visibleRows)
			viewOffset = row - visibleRows + 1;

		if(viewOffset < 0) viewOffset = 0;
		if(viewOffset > maxView) viewOffset = maxView;
		cursorOffset = row - viewOffset;
	}

	void stepRow(int n) {
		seekRow(row + n);
	}

	void seekRow(int r) {
		flushInput();
		cursorOffset += r - row;
		row = r;
		adjustView();
		initializeInput();
	}

	void setCursorOffset(int r) {
		flushInput();
		row += r - cursorOffset;
		cursorOffset = r;
		adjustView();
		initializeInput();
	}

	void stepColumn(int n) {
		flushInput();
		column = umod(column + n, 0, 2);
		initializeInput();
	}

	bool hasActiveTrack() {
		if(offsets.length == 0) return false;
		int trackIndex;
		return trackAtOffset(column, offsets[row], trackIndex);
	}

	void insertTrack(int voice, bool atCursor) {
		auto tracks = song.tracks[voice];
		int trackIndex;
		if(atCursor) {
			if(offsets.length == 0 || !trackAtOffset(voice, offsets[row], trackIndex))
				return;
			tracks.insertAt(trackIndex);
		}
		else {
			trackIndex = tracks.trackLength;
			tracks.expand();
		}
		column = voice;
		seekTrackIndex(voice, trackIndex);
	}

	void deleteTrack(int voice, bool atCursor) {
		auto tracks = song.tracks[voice];
		int trackIndex;
		if(atCursor) {
			if(offsets.length == 0 || !trackAtOffset(voice, offsets[row], trackIndex))
				return;
			if(tracks.trackLength == 1) {
				tracks[0].setValue(0xa0, 0);
			}
			else {
				tracks.deleteAt(trackIndex);
				if(trackIndex >= tracks.trackLength)
					trackIndex = tracks.trackLength - 1;
			}
		}
		else {
			if(tracks.trackLength == 1) {
				tracks[0].setValue(0xa0, 0);
				trackIndex = 0;
			}
			else {
				tracks.shrink();
				trackIndex = tracks.trackLength - 1;
			}
		}
		column = voice;
		seekTrackIndex(voice, trackIndex);
	}

	void transposeFromCursor(int delta) {
		if(!hasActiveTrack()) return;
		saveState();
		song.tracks[column].transposeAt(editTrackIndex, song.tracks[column].length, delta);
		initializeInput();
	}

	void selectFreeSequence() {
		saveState();
		int s = song.getFreeSequence(inputBuffer[1] + 1);
		if(s > 0)
			inputBuffer[1] = cast(ubyte)s;
		flushInput();
	}

	void stepSequence(int delta) {
		saveState();
		int s = inputBuffer[1] + delta;
		if(s < 0) s = 0;
		if(s >= MAX_SEQ_NUM) s = MAX_SEQ_NUM - 1;
		inputBuffer[1] = cast(ubyte)s;
		flushInput();
	}

	void clipCallback(int num) {
		if(!hasActiveTrack()) return;
		auto tracks = song.tracks[column];
		int length = num;
		if(editTrackIndex + length >= tracks.trackLength)
			length = tracks.trackLength - editTrackIndex;
		if(length < 0) length = 0;
		clip.length = length;
		for(int i = 0; i < length; i++) {
			clip[i].trans = tracks[editTrackIndex + i].trans;
			clip[i].no = tracks[editTrackIndex + i].number;
		}
	}

	void pasteCallback(int value) {
		pasteTracks(value > 0);
	}

	void pasteTracks(bool doInsert) {
		if(clip.length == 0 || !hasActiveTrack()) return;
		saveState();
		auto tracks = song.tracks[column];
		if(doInsert) {
			for(int i = 0; i < clip.length; i++)
				tracks.insertAt(editTrackIndex + i);
		}
		int length = cast(int)clip.length;
		if(editTrackIndex + length > tracks.trackLength)
			length = tracks.trackLength - editTrackIndex;
		for(int i = 0; i < length; i++)
			tracks[editTrackIndex + i].setValue(clip[i].trans, clip[i].no);
		clip.length = 0;
		seekTrackIndex(column, editTrackIndex);
	}

	void swapTracksWith(int withVoice) {
		if(withVoice < 0 || withVoice > 2 || withVoice == column) return;
		if(!hasActiveTrack()) return;
		saveState();
		auto from = song.tracks[column];
		auto to = song.tracks[withVoice];
		int maxLength = from.length < to.length ? from.length : to.length;
		for(int i = 0; i < maxLength; i++) {
			int temptrans = to[i].trans;
			int tempno = to[i].number;
			to[i].setValue(from[i].trans, from[i].number);
			from[i].setValue(temptrans, tempno);
		}
		initializeInput();
	}

	int offsetForTrack(int voice, int trackIndex) {
		int offset = 0;
		auto tracks = song.tracks[voice];
		for(int i = 0; i < trackIndex && i < tracks.trackLength; i++)
			offset += song.sequence(tracks[i]).rows;
		return offset;
	}

	void seekTrackIndex(int voice, int trackIndex) {
		rebuildOffsets();
		int targetOffset = offsetForTrack(voice, trackIndex);
		for(int i = 0; i < offsets.length; i++) {
			if(offsets[i] == targetOffset) {
				row = i;
				break;
			}
		}
		adjustView();
		initializeInput();
	}
}

class WaveTable : HexTable {
	this(Rectangle a) {
		super(a, song.waveTable, 2, 256);
	}

	override void refresh() {
		super.refresh();
		data = song.waveTable;
	}

	override void seekTableEnd() {
		for(int i = 255; i >= 1; i--) {
			if(data[i-1] > 0) {
				seekRow(i);
				return;
			}
		}
	}

	void seekCurWave() {
		seekRow(song.instrumentTable[state.activeInstrument + 7 * 48]);
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_SHIFT) {
			switch(key.raw)
			{
			case SDLK_HOME:
				seekRow(0);
				return OK;
			case SDLK_END:
				seekTableEnd();
				return OK;
			default:
				break;
			}
		}
		else if(key.mods & KMOD_CTRL) {
			switch(key.raw) {
			case SDLK_g:
				seekCurWave();
				return OK;
			default:
				break;
			}
		}
		else switch(key.raw) {
			case SDLK_g:
				seekCurWave();
				return OK;
			case SDLK_DELETE, SDLK_BACKSPACE:
				saveState(true);
				song.tWave.deleteRow(song, row);
				refresh();
				set();
				return OK;
			case SDLK_INSERT, SDLK_RETURN:
				saveState(true);
				song.tWave.insertRow(song, row);
				refresh();
				set();
				return OK;
			case '.':
				saveState(true);
				data[column ? (256 + row) : row] = 0;
				stepColumnWrap(1);
				return OK;
			default:
				break;
			}
		return super.keypress(key);
	}

	override void update() {
		int i;
		int t1, t2;
		if(state.shortTitles)
			screen.fprint(area.x,area.y, "`b1W`01ave");
		else
			screen.fprint(area.x,area.y, "`01Wave (A-W)");
		for(i = 0; i < visibleRows; i++) {
			int row = (i + viewOffset) & 255;
			t1 = data[row];
			t2 = data[row+256];
			int col = (t1 == 0x7e || t1 == 0x7f) ?  0x0d : 0x05;

			// Check if entire row is zeros
			bool allZeros = (t1 == 0 && t2 == 0);

			// Check if all subsequent rows are also zeros
			bool allSubsequentZeros = true;
			if(allZeros) {
				for(int checkRow = row + 1; checkRow < 256; checkRow++) {
					if(data[checkRow] != 0 || data[checkRow+256] != 0) {
						allSubsequentZeros = false;
						break;
					}
				}
			}

			// Display "--" only if this row and all subsequent rows are zeros
			bool showDashes = allZeros && allSubsequentZeros;
			string val1 = (showDashes && t1 == 0) ? "--" : format("%02X", t1);
			string val2 = (showDashes && t2 == 0) ? "--" : format("%02X", t2);
			int indexColor = playbackIndexColor(
				audio.visualizer.getTableRowBrightness(audio.visualizer.PlaybackTable.Wave, row));
			if(highlightRow(row)) indexColor = activeInstrumentColor;
			screen.fprint(area.x,area.y + i + 1, format("`0%x%02X:`%02x%s %s",
													indexColor, row, col, val1, val2));

		}
	}

	override void initializeInput() {
		int offset = column ? (256 + row) : row;
		(cast(InputByte)input).setOutput(data[offset..offset+1]);
		super.set();
	}

	override void stepColumnWrap(int n) {
		stepRow(1);
		adjustView();
	}


	override void showByteDescription() {
		if(song.ver < 9 || !state.displayHelp) return;
		UI.statusline.display(waveFieldDescription());
	}

	override bool highlightRow(int row) {
		return state.activeInstrument >= 0 &&
			row == song.instrumentTable[state.activeInstrument + 7 * 48];
	}

	override ContextHelp contextHelp() {
		if(song.ver > 8)
			return genPlayerContextHelp("Wave table",
										song.waveDescriptions);
		return ui.help.HELPMAIN;

	}

private:

	string waveFieldDescription() {
		int transpose = data[row];
		int wave = data[row + 256];
		if(column == 0)
			return "Byte 1: " ~ waveTransposeDescription(transpose, wave);
		return "Byte 2: " ~ waveControlDescription(transpose, wave);
	}

	string waveTransposeDescription(int value, int waveValue) {
		if(value <= 0x5f) {
			if(value == 0)
				return byteHex(value) ~ " no transpose.";
			return format("%s relative transpose +%d semitones.",
						  byteHex(value), value);
		}
		if(value == 0x7e)
			return byteHex(value) ~ " loop to previous row / end marker.";
		if(value == 0x7f)
			return format("%s loop marker; byte 2 jumps to wave row %s.",
						  byteHex(value), byteHex(waveValue));
		if(value >= 0x80 && value <= 0xdf) {
			int note = value & 0x7f;
			string noteText = note < NOTES.length ? " (" ~ NOTES[note] ~ ")" : "";
			return format("%s absolute note %d%s.", byteHex(value), note, noteText);
		}
		return byteHex(value) ~ " reserved transpose value.";
	}

	string waveControlDescription(int transpose, int value) {
		if(transpose == 0x7f)
			return format("%s loop target row.", byteHex(value));
		if(value == 0)
			return byteHex(value) ~ " leave waveform unchanged.";
		if(value <= 0x0f)
			return format("%s override wave delay to %d frame%s.",
						  byteHex(value), value, value == 1 ? "" : "s");
		if(value <= 0xdf)
			return format("%s SID control register: %s.",
						  byteHex(value), sidControlDescription(value));
		if(value <= 0xef) {
			int raw = value & 0x0f;
			return format("%s raw SID control %s: %s.",
						  byteHex(value), byteHex(raw), sidControlDescription(raw));
		}
		return byteHex(value) ~ " reserved waveform value.";
	}
}

class SweepTable : HexTable {
	this(Rectangle a, ubyte[] d) {
		super(a, d, 4, 64);
	}

	override int keypress(Keyinfo key) {
		switch(key.raw) {
		case SDLK_DELETE, SDLK_BACKSPACE:
			deleteRow();
			refresh();
			set();
			return OK;
		case SDLK_INSERT, SDLK_RETURN:
			insertRow();
			refresh();
			set();
			return OK;
		default: return super.keypress(key);
		}
	}

	override void update() {
		for(int i = 0; i < visibleRows; i++) {
			int curRow = (i + viewOffset) & 63;
			int p = curRow * 4;
			string col = "`05", col2 = "`05";
			if(data[p+3] > 0) col = "`0d";
			if(data[p+3] > 0x3f && data[p+3] != 0x7f) col = "`0a";
			if(highlightRow(curRow)) { col2 = col = "`03"; }

			// Empty ("all-zero") rows render as dashes. dashEmptyRow() decides
			// which empty rows qualify (see the hook below).
			bool allZeros = (data[p] == 0 && data[p+1] == 0 && data[p+2] == 0 && data[p+3] == 0);
			bool showDashes = allZeros && dashEmptyRow(curRow);

			// An empty row may dim its dashes (emptyRowColor() != null).
			if(showDashes) {
				string dc = emptyRowColor();
				if(dc !is null) col = col2 = dc;
			}

			string val0 = (showDashes && data[p] == 0) ? "--" : format("%02X", data[p]);
			string val1 = (showDashes && data[p+1] == 0) ? "--" : format("%02X", data[p+1]);
			string val2 = (showDashes && data[p+2] == 0) ? "--" : format("%02X", data[p+2]);
			string val3 = (showDashes && data[p+3] == 0) ? "--" : format("%02X", data[p+3]);
			int indexColor = playbackIndexColor(playbackBrightness(curRow));
			screen.fprint(area.x,area.y + i + 1,
					  format("`0%x%02X:%s%s %s %s %s%s",
							 indexColor, curRow, col2,
							 val0, val1, val2, col, val3));
		}
	}

	override void initializeInput() {
		InputByte i = cast(InputByte)input;
		int ofs = row * 4 + column;
		i.setOutput(data[ofs..ofs+1]);
		super.initializeInput();

	}

	override void seekTableEnd() {
		for(int i = 63; i >= 0; i--) {
			ubyte[] arr = data[i * 3 .. i * 3 + 3];
			bool flag;
			foreach(a; arr) {
				if(a) {
					int row = i + 1;
					if(row > 63) row = 63;
					seekRow(row);
					return;
				}
			}
		}
	}

	protected bool highlightActiveFor(int startFrom, int currentRow) {
		if(startFrom > 0x3f || startFrom == 0) return false;

		if(startFrom == currentRow)
			return true;

		bool[0x40] visited;
		for(int row = startFrom; row < 0x40;) {
			if(visited[row]) break;
			visited[row] = true;
			if(row == currentRow) return true;
			int jumpValue = data[row * 4 + 3];
			if(jumpValue > 0x3f && jumpValue != 0x7f) // if illegal, break
				break;
			if(jumpValue == 0x7f)
				break; // if loops or ends, break
			else if(jumpValue == 0)
				row++;
			else row = jumpValue;
		}
		return false;
	}

	void seekProgram(int startFrom) {
		if(startFrom > 0x3f) return;
		seekRowOnTopIfNeeded(startFrom);
	}

	// Which empty ("all-zero") rows render as dashes. By default only the
	// trailing run of empty rows is dashed; FilterTable dashes every empty row.
	protected bool dashEmptyRow(int curRow) {
		for(int r = curRow + 1; r < 64; r++) {
			int q = r * 4;
			if(data[q] || data[q+1] || data[q+2] || data[q+3]) return false;
		}
		return true;
	}

	// Colour for an empty row's dashes (null = keep the normal table colour).
	protected string emptyRowColor() { return null; }

	protected float playbackBrightness(int row) {
		return 0.0f;
	}
}

class PulseTable : SweepTable {
	this(Rectangle a) {
		super(a, song.pulseTable);
	}

	override void refresh() {
		super.refresh();
		data = song.pulseTable;
	}

	override void update() {
		if(state.shortTitles)
			screen.fprint(area.x, area.y, "`b1P`01ulse");
		else
			screen.fprint(area.x, area.y, "`01Pulse (Alt-P)");
		super.update();
	}

	override void showByteDescription() {
		if(song.ver < 9 || !state.displayHelp) return;
		UI.statusline.display(pulseFieldDescription());
	}

	override ContextHelp contextHelp() {
		if(song.ver > 8)
			return genPlayerContextHelp("Pulse table",
										song.pulseDescriptions);
		return ui.help.HELPMAIN;
	}

	override void deleteRow() {
		saveState(true);
		ct.purge.pulseDeleteRow(song, row);
	}

	override void insertRow() {
		saveState(true);
		ct.purge.pulseInsertRow(song, row);
	}

	override bool highlightRow(int row) {
		return highlightActiveFor(song.instrumentTable[state.activeInstrument + 5 * 48], row);
	}

	override protected float playbackBrightness(int row) {
		return audio.visualizer.getTableRowBrightness(audio.visualizer.PlaybackTable.Pulse, row);
	}

private:

	string pulseFieldDescription() {
		int offset = row * 4;
		int value = data[offset + column];
		final switch(column) {
		case 0: return "Byte 1: " ~ pulseDurationDescription(value);
		case 1: return "Byte 2: " ~ pulseAddDescription(value, data[offset]);
		case 2: return "Byte 3: " ~ pulseInitialDescription(value);
		case 3: return "Byte 4: " ~ sweepPointerDescription(value, "pulse");
		}
	}

	string pulseDurationDescription(int value) {
		int frames = value & 0x7f;
		string direction = value & 0x80 ? "subtract" : "add";
		return format("%s %s for %d frame%s.",
					  byteHex(value), direction, frames, frames == 1 ? "" : "s");
	}

	string pulseAddDescription(int value, int duration) {
		string direction = duration & 0x80 ? "subtract" : "add";
		return format("%s %s this amount from pulse width each frame.",
					  byteHex(value), direction);
	}

	string pulseInitialDescription(int value) {
		if(value == 0xff)
			return byteHex(value) ~ " keep current pulse width.";
		int pulse = ((value & 0x0f) << 8) | (value & 0xf0);
		return format("%s initial pulse width $%03X (nibbles reversed).",
					  byteHex(value), pulse);
	}
}

class FilterTable : SweepTable {
	this(Rectangle a) {
		super(a, song.filterTable);
		refresh();
	}

	override void refresh() {
		super.refresh();
		data = song.filterTable;
	}

	// Every empty row in the filter table shows dashes, dimmed to dark grey
	// (`0b) -- the same colour empty note rows use in the track view.
	protected override bool dashEmptyRow(int curRow) { return true; }
	protected override string emptyRowColor() { return "`0b"; }

	override void update() {
		if(state.shortTitles)
			screen.fprint(area.x, area.y, "`b1F`01ilter");
		else
			screen.fprint(area.x, area.y, "`01Filter (Alt-F)");
		super.update();
	}

	override ContextHelp contextHelp() {
		if(song.ver > 8)
			return genPlayerContextHelp("Filter table",
										song.filterDescriptions);
		return ui.help.HELPMAIN;
	}

	override void showByteDescription() {
		if(song.ver < 9 || !state.displayHelp) return;
		UI.statusline.display(filterFieldDescription());
	}

	override void deleteRow() {
		saveState(true);
		ct.purge.filterDeleteRow(song, row);
	}

	override void insertRow() {
		saveState(true);
		ct.purge.filterInsertRow(song, row);
	}

	override bool highlightRow(int row) {
		return highlightActiveFor(song.instrumentTable[state.activeInstrument + 4 * 48], row);
	}

	override protected float playbackBrightness(int row) {
		return audio.visualizer.getTableRowBrightness(audio.visualizer.PlaybackTable.Filter, row);
	}

private:

	string filterFieldDescription() {
		int offset = row * 4;
		int value = data[offset + column];
		final switch(column) {
		case 0: return "Byte 1: " ~ filterDurationDescription(value);
		case 1: return "Byte 2: " ~ filterSecondByteDescription(value, data[offset]);
		case 2: return "Byte 3: " ~ filterInitialDescription(value);
		case 3: return "Byte 4: " ~ sweepPointerDescription(value, "filter");
		}
	}

	string filterDurationDescription(int value) {
		if((value & 0x80) == 0)
			return format("%s sweep duration %d frame%s.",
						  byteHex(value), value, value == 1 ? "" : "s");
		return format("%s select filter mode: %s.",
					  byteHex(value), filterModeDescription(value));
	}

	string filterSecondByteDescription(int value, int duration) {
		if(duration & 0x80) {
			int resonance = value >> 4;
			int mask = value & 0x0f;
			return format("%s resonance %d, channel mask %s.",
						  byteHex(value), resonance, byteHex(mask));
		}
		int signedValue = value < 0x80 ? value : value - 0x100;
		return format("%s sweep add %+0.2f cutoff units per frame.",
					  byteHex(value), cast(double)signedValue / 4.0);
	}

	string filterInitialDescription(int value) {
		if(value == 0xff)
			return byteHex(value) ~ " keep current cutoff.";
		return format("%s initial cutoff high byte; low bits reset.",
					  byteHex(value));
	}

	string filterModeDescription(int value) {
		string[] parts;
		if(value & 0x10) parts ~= "low-pass";
		if(value & 0x20) parts ~= "band-pass";
		if(value & 0x40) parts ~= "high-pass";
		if(parts.length == 0) return "filter off";
		return parts.join(" + ");
	}
}
