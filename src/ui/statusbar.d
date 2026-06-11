/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
*/

module ui.statusbar;
import derelict.sdl2.sdl;
import std.conv;
import main;
import ct.base;
import com.session;
import ui.help;
import ui.input;
import ui.window;
import ui.ui;
import audio.player;
import seq.sequencer;
import audio.audio;
import com.fb;
import com.util;
import com.shortcuts;
import std.string;
import audio.audio, audio.timer, audio.callback;

class Infobar : Window, Undoable {
	private {
		const int x1, infoX, playerX;
		int idx;
		bool editing;
	}
	InputString inputTitle, inputAuthor, inputReleased;

	override @property string contextId() { return Ctx.songInfo; }
	override ContextHelp contextHelp() { return ui.help.HELPMAIN; }

	this(Rectangle a) {
		super(a);
		x1 = area.x;
		infoX = x1 + (com.fb.mode > 0 ? 64 : 48);
		playerX = infoX + 43;
	}

	override void update() {
		// Row 0 (the title/menu bar) is now owned by MenuBar (UI.drawMenu);
		// the Infobar only paints the song-info area at the bottom.
		int c1 = audio.player.isPlaying ? 13 : 12;
		screen.fprint(x1,area.y,format("`05Time: `0%x%02d:%02d / $%02x",
									   c1,audio.timer.min, audio.timer.sec,
									   audio.callback.linesPerFrame & 255));

		screen.fprint(x1 + 19,area.y,
				   format("`05Oct: `0d%d  `05Spd: `0d%X  `05St: `0d%d ",
						  state.octave, song.speed, seq.sequencer.stepValue));
		screen.fprint(x1,area.y+1,format("`05Filename: `0d%s", state.filename.leftJustify(38)));
		drawSongField(0, "  `b1T`01itle:", inputTitle, song.title);
		drawSongField(1, " `01Author:", inputAuthor, song.author);
		drawSongField(2, "`01Release:", inputReleased, song.release);
		screen.fprint(playerX, area.y,
				   format("`05Rate:   `0d%-1d*%dhz",
						  song.multiplier, audio.player.ntsc ? 60 : 50));
		screen.fprint(playerX, area.y+1,
				   format("`05SID:    `0d%s%s",
						  audio.player.usefp ? audio.player.curfp.id : audio.player.sidtype ? "8580" : "6581",
						  audio.player.badline ? "&0fb" : " "));
		screen.fprint(playerX, area.y+2,format("`05Player: `0d%s", ztos(song.playerID)));
	}

	override void refresh() {
		inputTitle = new InputString(cast(string)(song.title), cast(int)(song.title.length));
		inputReleased = new InputString(cast(string)(song.release), cast(int)( song.release.length));
		inputAuthor = new InputString(cast(string)(song.author), cast(int)(song.author.length));
		input = ([ inputTitle, inputAuthor, inputReleased ])[idx];
		input.setCoord(infoX + 9,area.y + idx);
	}

	override void activate() {
		editing = true;
		idx = 0;
		refresh();
	}

	override void deactivate() {
		outputStrings();
		editing = false;
	}

	private void outputStrings() {
		auto title = inputValue(inputTitle);
		auto release = inputValue(inputReleased);
		auto author = inputValue(inputAuthor);
		if(song.title == title && song.release == release && song.author == author)
			return;
		com.session.insertUndo(this, createState());
		song.title[] = title[];
		song.release[] = release[];
		song.author[] = author[];
	}

	override int keypress(Keyinfo key) {
		int r = input.keypress(key);
		if(r == RETURN) {
			idx++;
			if(idx > 2) {
				idx = 0;
				return RETURN;
			}
			outputStrings();
			refresh();
		}
		else if(r == CANCEL) {
			idx = 0; update();
			return RETURN;
		}
		return OK;
	}

	private:

	void drawSongField(int row, string label, InputString field, ref char[32] value) {
		screen.fprint(infoX, area.y + row, format("`05%s ", label));
		if(editing && field !is null && idx == row) {
			field.update();
		}
		else {
			screen.fprint(infoX + 9, area.y + row,
						  format("`0d%-32s", value));
		}
	}

	char[32] inputValue(InputString input) {
		return paddedString32(input.toString(false));
	}

	UndoValue createState() {
		UndoValue v;
		v.songTitle = song.title;
		v.songRelease = song.release;
		v.songAuthor = song.author;
		v.hasSongInfo = true;
		return v;
	}

public:

	override void undo(UndoValue v) {
		if(!v.hasSongInfo)
			return;
		song.title[] = v.songTitle[];
		song.release[] = v.songRelease[];
		song.author[] = v.songAuthor[];
		refresh();
		update();
	}

	override UndoValue createRedoState(UndoValue value) {
		return createState();
	}
}

class Statusline : Window {
	int counter;
	string message;

	this(Rectangle a) {
		super(a);
	}

	void display(string msg) {
		message = msg;
		counter = CONFIRM_TIMEOUT;
		screen.clrtoeol(2, 0);
		update();
	}

	override void deactivate() {
		counter = 0;
		update();
	}

	override void update() {
		if(counter)
			screen.fprint(4, 2, "`0f " ~ message);
		else screen.clrtoeol(2, 0);
	}

	void timerEvent() {
		if(counter > 0) {
			--counter;
			if(!counter) update();
		}
	}
}
