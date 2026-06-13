/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
*/

module ui.dialogs;
import derelict.sdl2.sdl;
import main;
import com.fb;
import com.util;
import com.session;
private import ct.base;
import ct.build : ExportOptions;
import ui.help;
import ui.ui;
import ui.input;
import std.algorithm;
import std.string;
import std.file;
import std.utf;
import std.array;
import std.stdio;
import std.process;

abstract class QueryDialogBase(T) : Window {
	string query;
	ubyte[1] byt;
	alias void delegate(T) Callback;
	Callback callback;
	protected int frameWidth;
	this(string s, Callback fp) {
		super(Rectangle(0, 0, 1));
		query = s;
		callback = fp;
		frameWidth = cast(int)query.length;
	}

	// Replace the prompt text (e.g. to embed live state); keeps the frame and
	// the input-field position in sync with the new length.
	void setQuery(string s) {
		query = s;
		frameWidth = cast(int)s.length;
	}

	override void update() {
		int x = cast(int)(screen.width / 2 - (frameWidth + 6)/2);
		int y = cast(int)(screen.height / 2 - 11);
		drawFrame(Rectangle(x, y, 5, frameWidth + 9));
		screen.cprint(x + 4, y + 2, 15, 0, query);
		input.setCoord(cast(int)(x + 4 + query.length), cast(int)( y + 2));
	}

	override void activate() {
		return;
	}
}

class QueryDialog : QueryDialogBase!int {
	const int maxValue;
	this(string s,Callback fp, int m) {
		super(s, fp);
		input = new InputBoundedByte(byt);
		maxValue = m;
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_ALT) return OK;
		int r = input.keypress(key);
		if(r == WRAP &&
		   (cast(InputBoundedByte)input).value >= maxValue) {
			input.setOutput(cast(ubyte[])[maxValue - 1]);
			return OK;
		}
		else if(r == RETURN) {
			input.nibble = 0;
			callback(input.toInt());
		}
		else if(r == CANCEL) { // no callback
		}
		else r = OK;
		if(input.value >= maxValue)
			input.setOutput(cast(ubyte[])[maxValue - 1]);
		return r;
	}
}

class ConfirmationDialog : QueryDialogBase!int {
	this(string title, Callback cb, string keys, int defaultkey) {
		super(title, cb);
		input = new InputSingleChar(byt, keys, defaultkey);
	}

	this(string title, Callback cb) {
		this(title, cb, "yn", 1);
	}
	
	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_ALT) return OK;
		int r = input.keypress(key);
		if(r == CANCEL)
			return CANCEL; // just close dialog
		if(r == RETURN) { // received legal key
			callback(input.toInt);
			return RETURN;
		}
		return OK;
	}
}

class StringDialog : QueryDialogBase!string {
	int inputLength;
	this(string query,Callback fp, string inp, int length) {
		super(query, fp);
		input = new InputString(inp, length);
		this.inputLength = length;
		frameWidth = cast(int)query.length + inputLength;
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_ALT) return OK;
		int r = input.keypress(key);
		if(r == CANCEL)
			return CANCEL; // just close dialog
		if(r == RETURN) {
			input.nibble = 0;
			callback((cast(InputString)input).toString(false));
			return RETURN;
		}
		return OK;
	}
}

class HelpDialog : Window {
	enum MAX_LINE_LENGTH = 80;
	string[][] pages;
	const string title;
	int numpages;
	int page = 1;
	int txt_x;
	
	this(Rectangle a, ContextHelp ctx) {
		super(a);
		pages.length = ctx.text.length;
		foreach(i,page; ctx.text) {
			pages[i] = std.string.splitLines(page);
		}
		numpages = cast(int)pages.length; // deprecate
		title = ctx.title;
		txt_x = area.x + (area.width / 2 - MAX_LINE_LENGTH / 2);
	}

	override void update() {
		int ypos = area.y + 2;
		drawFrame(area);
		screen.cprint(area.x + 2, area.y, 1, 0, format(" %s %d/%d (press SPACE for more) ", title,
											   page,numpages));

		screen.cprint(area.x + 1, area.y + 2, 1, 0, 
					  std.array.replicate(" ", area.width-3));

		foreach(line; pages[page-1]) {
			screen.cprint(area.x+1, ypos, 1, 0, std.array.replicate(" ", area.width-3));
			screen.fprint(txt_x, ypos, "`0f" ~ line);
			ypos++;
		}
		for(; ypos < 36; ypos++) {
			screen.cprint(area.x+1, ypos, 1, 0, std.array.replicate(" ", area.width-2));
		}
		
	}

	override int keypress(Keyinfo key) {
		int k = key.unicode;
		if(key.raw == SDLK_F12 && key.mods == 0) {
			if(title != ui.help.HELPMAIN.title) {
				mainui.activateDialog(new HelpDialog(area, ui.help.HELPMAIN));
			}
			return OK;
		}
		if(k == SDLK_SPACE ||
		   k == SDLK_PLUS ||
			k == SDLK_RIGHT ||
			k == SDLK_PAGEDOWN)
			if(page++ >= numpages) page = 1;
		if(key.unicode == SDLK_RETURN ||
			key.unicode == SDLK_ESCAPE) return RETURN;
		return OK;
	}
}

class DebugDialog : Window {
	Sequence seq;
	
	this(Sequence s) {
		super(Rectangle(screen.width / 2 - 24,
				   screen.height / 2 - 10,
				   20, 55));
		seq = s;
	}
	
	this(Rectangle a) {
		super(a);
	}

	override void update() {
		assert(seq !is null);
		ubyte[] data = seq.compact();
		data.length = 256;
		int y,pos;
		string str;
		drawFrame(area);
		for(y=0;y<area.h-2;y++) {
			screen.fprint(area.x+1,area.y+1+y,
						  std.array.replicate(" ", area.width-2));
		}

		for(y=0; y<16; y++) {
			str = format("%02X:",y*16);
			for(int i = 0; i < 16 ; i++) {
				str ~= format("%02X ", data[pos++]);
			}
			screen.fprint(area.x+2,area.y+y+2,"`0f" ~ str);
		}
	}

	override int keypress(Keyinfo key) {
		switch(key.unicode) {
		case SDLK_SPACE:
			com.util.hexdump(seq.compact(),16);
			break;
		case 0:
			break;
		default:
			return RETURN;
		}
		return OK;
	}
}

// The splash / about screen. Rendering is owned by Video.drawSplash(); this
// dialog just toggles video.splashActive while it is the active dialog. The
// artwork (CheeseCutterEXT.png -> src/font/splash.dat) already carries the
// credits, so there is no text to draw here.
class AboutDialog : Window {
	this(Rectangle a) {
		super(a);
	}

	override void activate() {
		video.splashActive = true;
	}

	override void deactivate() {
		video.splashActive = false;
		screen.refresh(); // force a full cell redraw so the editor reappears
	}

	override void update() {
		// no-op: Video.drawSplash() renders the image every frame while active.
	}

	override void clickedAt(int scrx, int scry, int button, int clicks = 1) {
		mainui.closeDialog();
	}

	override int keypress(Keyinfo key) {
		if(key.mods) return OK;
		return RETURN; // any unmodified key dismisses the splash
	}
}

class FileSelector : Window {
	struct FileSelPos {
		int offset, pos;
		void reset() { offset = pos = 0; }
	}
	
	struct File {
		string name;
		int exists, isdir;
	}
	
	FileSelPos fpos;
	private File[] filelist;
	string directory;
	alias area filearea;
	private int lastClickNum = -1;
	private uint lastClickTicks;
	// Type-ahead: typing jumps to the first entry whose name starts with the
	// typed prefix (case-insensitive); the buffer expires after a short pause.
	private enum TYPEAHEAD_TIMEOUT_MS = 1000;
	private string typeahead;
	private uint typeaheadDeadline;
	
	this(Rectangle a) {
		super(a);
		directory = getcwd();
		refresh();
	}

	override void refresh() {
		if(!exists(directory)) {
			UI.statusline.display("Directory not found!");
		}
		else {
			chdir(directory);
			getdir(directory);
			if(num >= filelist.length)
				cursorEnd();
		}
	}

	void reset() {
		fpos.offset = fpos.pos = 0;
		lastClickNum = -1;
		typeahead = "";
	}

	/// The live type-ahead prefix, "" once it has expired (for the dialog header).
	@property string typeaheadDisplay() {
		return SDL_GetTicks() <= typeaheadDeadline ? typeahead : "";
	}

	override void update() { 
		int y, i;
		for(y = area.y, i = 0; i < area.height; y++,i++) {
			int ofs = fpos.offset + i;
			string fs = null;
			int col = 15;
			if(ofs < filelist.length) {
				File f = filelist[ofs];
				auto ind = 1+f.name.lastIndexOf(DIR_SEPARATOR);
				if( ofs < 2 || (f.exists && f.isdir) ) {
					col = 13;
				}
				fs = fstr(format("  %s", f.name[ind..$].leftJustify(area.width-2)));
			}
			screen.cprint(area.x+5,y,col,0,fs);
		}
	}

	void blink() {
		int y = area.y + fpos.pos;
		auto ind = 1 + filelist[num].name.lastIndexOf(DIR_SEPARATOR);
		screen.fprint(area.x+5,y,fstr("`b1  " ~ filelist[num].name[ind..$].leftJustify(area.width-3)) ~ "  ");
	}
	
	int fileHandler() {
		if(isDir(selected)) {
			string s;
			if(selected == ".." ) {
				int i = cast(int) directory.lastIndexOf(DIR_SEPARATOR);
				if(i >= 0) {
					s = directory[0..i];
					if(s.lastIndexOf(DIR_SEPARATOR) < 0) {
						s ~= DIR_SEPARATOR;
					}
					directory = s;
				}
			}
			else if(selected != ".") {
				directory = cast(string)(selected.dup);
			}   
			reset();
			refresh();
			return OK;
		}
		return RETURN;
	}

	override int keypress(Keyinfo key) {
		switch(key.raw) 
		{
		case SDLK_UP:
			step(-1);
			return WRAP;
		case SDLK_DOWN:
			step(1);
			return WRAP;
		case SDLK_PAGEUP:
			step(-area.height);
			return WRAP;
		case SDLK_PAGEDOWN:
			step(area.height);
			return WRAP;
		case SDLK_HOME:
			reset();
			return WRAP;
		case SDLK_END:
			cursorEnd();
			return WRAP;
		case SDLK_BACKSPACE:
			if(typeaheadDisplay.length) {
				typeahead = typeahead[0 .. $ - 1];
				typeaheadDeadline = SDL_GetTicks() + TYPEAHEAD_TIMEOUT_MS;
				if(typeahead.length && jumpToPrefix(typeahead))
					return WRAP;
			}
			break;
		default:
			// Type-ahead: printable chars accumulate a prefix and jump to the
			// first matching entry. An expired buffer restarts from scratch.
			if(key.unicode >= 0x20 && key.unicode < 0x7f
			   && !(key.mods & (KMOD_CTRL | KMOD_ALT | KMOD_GUI))) {
				uint now = SDL_GetTicks();
				if(now > typeaheadDeadline) typeahead = "";
				typeahead ~= cast(char)key.unicode;
				typeaheadDeadline = now + TYPEAHEAD_TIMEOUT_MS;
				if(jumpToPrefix(typeahead))
					return WRAP;
			}
			break;
		}
		return OK;
	}

	// Move the cursor to the first entry whose displayed name starts with
	// `prefix` (case-insensitive). Keeps the cursor visible by scrolling.
	private bool jumpToPrefix(string prefix) {
		foreach(i, f; filelist) {
			auto ind = 1 + f.name.lastIndexOf(DIR_SEPARATOR);
			string nm = f.name[ind .. $];
			if(nm.length >= prefix.length
			   && icmp(nm[0 .. prefix.length], prefix) == 0) {
				int n = cast(int)i;
				if(n < area.height) {
					fpos.offset = 0;
					fpos.pos = n;
				}
				else {
					fpos.offset = n - (area.height - 1);
					fpos.pos = area.height - 1;
				}
				return true;
			}
		}
		return false;
	}

	int mouseClick(int x, int y, int button) {
		if(button != SDL_BUTTON_LEFT) return OK;
		if(y < area.y || y >= area.y + area.height) return OK;

		int row = y - area.y;
		int clickedNum = fpos.offset + row;
		if(clickedNum < 0 || clickedNum >= filelist.length) return OK;

		uint now = SDL_GetTicks();
		bool doubleClick = clickedNum == lastClickNum &&
			now - lastClickTicks <= 500;

		fpos.pos = row;
		lastClickNum = clickedNum;
		lastClickTicks = now;

		if(doubleClick && filelist[clickedNum].isdir) {
			fileHandler();
			return WRAPR;
		}

		return WRAP;
	}

	override void clickedAt(int x, int y, int button, int clicks = 1) {
		mouseClick(x, y, button);
	}
	
	char[][] listdir(string udir) {
		char[][] ret;
		auto app = appender(ret);
		foreach (DirEntry e; dirEntries(udir, SpanMode.shallow)){
			app.put( e.name.dup );	
		}

		return app.data;
	}

	void getdir(string udir) {
		char[][] dir;
		char[][] dirs, files;
		dir = listdir(udir);
		dirs.length = dir.length+2;
		files.length = dir.length;

		int idxd, idxf;

		foreach(i, d; dir) {
			char[] first = d[0..1];
			// skip hidden / temp files
			if(first == "." || first == "#")
				continue;
			try {
				if(d.isDir()) {
					dirs[idxd++] = d;
				} else {
					files[idxf++] = d;
				}
			}
			catch(FileException) {
				// may occur if entry "d" does not
				// exist or is a dangling symlink
				continue;
			}
		}

		dirs.length = idxd;
 		dirs.sort;
		
		files.length = idxf;
		files.sort;

		string[] all = cast(string[])(dirs ~ files);
		
		filelist.length = all.length + 2;
		filelist[0] = File(".", true, true);
                filelist[1] = File("..",true, true);
		for(int i = 0; i < all.length; i++) {
			filelist[i+2] = File(all[i], all[i].exists(), all[i].isDir());
		}
	}

	// move the cursor to last entry & set scroll window pos
	void cursorEnd() {
		if(filelist.length >= area.height) {
			fpos.offset = cast(int)(filelist.length - area.height);
			fpos.pos = cast(int)(area.height-1);
		}
		else {
			fpos.offset = 0;
			fpos.pos = cast(int)(filelist.length - 1);
		}
	}

	void step(int st) {
		fpos.pos += st;
		if(fpos.pos >= filearea.height) {
			int r = fpos.pos-filearea.height;
			fpos.offset += r+1;
			fpos.pos -= r+1;
			if(num >= filelist.length && filelist.length > filearea.height) {
				fpos.offset = cast(int)(filelist.length - filearea.height);
				fpos.pos = cast(int)(filearea.height-1);
			}
		}
		else if(fpos.pos < 0) {
			int r = -fpos.pos;
			fpos.offset -= r;
			if(fpos.offset < 0) fpos.offset=0;
			fpos.pos += r;
		}
		if(num >= filelist.length)
			cursorEnd();
	}

	@property string selected() { return filelist[num].name; }
	alias selected getSelected;
  
private:

	@property int num() { return fpos.offset + fpos.pos; }
	string fstr(string fs) {
		if(fs.length > (area.width))
			fs.length = area.width;
		return fs;
	}
}

// wraps inputstring
class DialogString : Window {
	this(Rectangle a) {
		this(a, 50);
	}

	this(Rectangle a, int len) {
		input = new InputString("", len);
		input.setCoord(a.x, a.y);
		super(a);
	}

	override string toString() { return toString(false); }
	
	string toString(bool p) { return (cast(InputString)input).toString(p); }
	
	void setString(string s) {
		(cast(InputString)input).setOutput(s);
	}
	alias setString setOutputString;

	bool containsPoint(int x, int y) {
		return y == input.y &&
			x >= input.x &&
			x < input.x + input.inputLength;
	}

	override void clickedAt(int x, int y, int button, int clicks = 1) {
		if(button != SDL_BUTTON_LEFT || y != input.y) return;

		int n = x - input.x;
		if(n < 0) n = 0;
		if(n >= input.inputLength) n = input.inputLength - 1;
		input.nibble = n;
	}

	override void update() {
		input.update();
	}

	override int keypress(Keyinfo key) { input.keypress(key); return OK; }
}
		
class FileSelectorDialog : WindowSwitcher {
	alias void delegate(string) CB;
	const CB callback;
	alias callback processFileCallback;
	private DialogString sfile, sdir;
	FileSelector fsel;
	private string header;
	private char[][] filelist;
	Rectangle filearea;
	// Metadata preview of the focused .ct/.ct2 file (title/author/release).
	// update() runs ~25x/s, so the header read is cached per selected path.
	private string previewPath;
	private SongInfo previewInfo;
	
	this(Rectangle a, string h, CB cb) {
		header = h;
		if(a == Rectangle.init) {
			int dialog_width = screen.width - 32;
			int dialog_height = screen.height - 10;
			int dialog_x = screen.width / 2 - dialog_width / 2;
			int dialog_y = screen.height / 2 - dialog_height / 2;
			a = Rectangle(dialog_x, dialog_y, dialog_height, dialog_width);
		}
		filearea = Rectangle(a.x + 5, a.y + 2, a.height - 6, a.width - 10);
		fsel = new FileSelector(Rectangle(a.x + 5, a.y + 2, a.height - 6, 
								a.width - 18));
		sfile = new DialogString(Rectangle(a.x+3+11, a.y+a.height-2), 50);
		sdir = new DialogString(Rectangle(a.x+3+11, a.y+a.height-3), 50);
		sdir.setString(getcwd());
		super(a, [cast(Window)fsel, sdir, sfile]);
		activateWindow(0);
		callback = cb;
	}

	void setFilename(string s) {
		sfile.setString(cast(string)s.dup);
	}

	void setDirectory(string s) {
		fsel.directory = cast(string)s.dup;
		sdir.setString(cast(string)s.dup);
	}

	@property string filename() {
		return sfile.toString();
	}

	@property string fullname() {
		return getcwd() ~ DIR_SEPARATOR ~ sfile.toString();
	}

	@property string directory() {
		return fsel.directory;
	}
	
	override void activate() {
		refresh();
		fsel.refresh();
	}

	override void refresh() { 
		update();
	}
	
	override void update() {
		int x,y,i;

		for(y = area.y; y < area.y+area.height; y++) {
			screen.cprint(area.x, y, 1, 0, std.array.replicate(" ",area.width)); 
		}
		drawFrame(area);
		x = area.x + 3;
		y = area.y + 2;
		string hdr = " " ~ header ~ " ";
		if(fsel.typeaheadDisplay.length)
			hdr ~= "- find: " ~ fsel.typeaheadDisplay ~ " ";
		screen.cprint(x,area.y,1,0,hdr);

		drawPreview(x, area.y + area.height - 4);
		screen.fprint(x,area.y+area.height-3,format("`0fDirectory: `0d%s",sdir.toString()));
		
		string f = sfile.toString();
		int ind = cast(int) (1+f.lastIndexOf(DIR_SEPARATOR));
		screen.fprint(x,area.y+area.height-2,format("`0f Filename: `0d%s",f[ind..$]));
		
		activeWindow.update();
		if(activeWindow == fsel) {
			fsel.blink();
		} else {
			fsel.update();
		}
		input = activeWindow.input;
	}

	// Draw the focused entry's song metadata on the spare row above the
	// Directory/Filename rows; nothing is drawn for dirs / non-.ct files
	// (update() has already space-filled the row).
	private void drawPreview(int x, int y) {
		string sel = fsel.selected;
		if(sel != previewPath) {
			previewPath = sel;
			previewInfo = SongInfo.init;
			try {
				if(sel != "." && sel != ".." && std.file.exists(sel)
				   && !std.file.isDir(sel))
					previewInfo = readSongInfo(sel);
			}
			catch(Exception e) {}
		}
		if(!previewInfo.valid) return;
		int limit = area.x + area.width - 3;
		void seg(string s, int fg) {
			if(x >= limit || s.length == 0) return;
			if(x + cast(int)s.length > limit) s = s[0 .. limit - x];
			screen.cprint(x, y, fg, 0, s);
			x += cast(int)s.length;
		}
		seg("    Title: ", 15); seg(previewInfo.title, 13);
		seg("  Author: ", 15);  seg(previewInfo.author, 13);
		seg("  Release: ", 15); seg(previewInfo.release, 13);
	}

	override void clickedAt(int x, int y, int button, int clicks = 1) {
		if(button != SDL_BUTTON_LEFT) return;

		if(y >= fsel.area.y && y < fsel.area.y + fsel.area.height &&
		   x >= fsel.area.x && x < fsel.area.x + fsel.area.width + 5) {
			activateWindow(0);
			int r = fsel.mouseClick(x, y, button);
			if(r == WRAPR)
				sdir.setString(getcwd());
			if(r == WRAP) {
				int ind = cast(int) (1 + fsel.getSelected().lastIndexOf(DIR_SEPARATOR));
				sfile.setString(cast(string)(fsel.getSelected()[ind..$]));
			}
			return;
		}

		if(sfile.containsPoint(x, y)) {
			activateWindow(2);
			sfile.clickedAt(x, y, button, clicks);
		}
	}

	override int keypress(Keyinfo key) {
		if(key.mods && !key.mods & KMOD_SHIFT) return OK;
		switch(key.raw)
		{
		case SDLK_TAB:
			return super.keypress(key);
		case SDLK_ESCAPE:
			return RETURN;
		case SDLK_RETURN:
			return returnPressed(callback);
		default:
			int r = activeWindow.keypress(key);
			if(r == WRAP){
				int ind = cast(int) (1 + fsel.getSelected().lastIndexOf(DIR_SEPARATOR)); 
				sfile.setString(cast(string)(fsel.getSelected()[ind..$]));
			}
			break;
		}
		return OK;
	}

	protected int returnPressed(CB cb) {
		if(activeWindow == fsel) {
			int r = fsel.fileHandler();
			if(r == RETURN)
				cb(cast(string)(fsel.selected));
			sdir.setString(getcwd());
			return r;
		}
		else if(activeWindow == sfile) { // pressed RETURN in file dialog
			//string filename = getcwd() ~ DIR_SEPARATOR ~ sfile.toString();
			cb(fullname);
			return RETURN;
		}
		else {
			fsel.directory = sdir.toString();
			fsel.reset();
			fsel.refresh();
		}
		return OK;
	}
}

class LoadFileDialog : FileSelectorDialog {
	CB cbimport;
	
	this(Rectangle a, CB cbload, CB cbimp) {
		super(a, "Load Song", cbload);
		cbimport = cbimp;
	}

	override protected int returnPressed(CB cb) {
		if(activeWindow != fsel && activeWindow != sfile)
			return super.returnPressed(cb);

		if(std.file.exists(fullname) && !std.file.isDir(fullname)
					     && shouldUpgrade(fullname)) {
			mainui.activateDialog(new ConfirmationDialog("Upgrade to latest player (Y/n)? ",
														 &confirmCallback, "yn", 0));
			return OK;
		}
		else return super.returnPressed(cb);
	}

	private bool shouldUpgrade(string fn) {
		// Header-only read; no need to construct a full Song just for `ver`.
		auto info = readSongInfo(fn);
		return info.valid && SONG_REVISION > info.ver;
	}

	private void confirmCallback(int param) {
		auto cb = param ? callback : cbimport;

		if(activeWindow == fsel) {
			int r = fsel.fileHandler();
			if(r == RETURN)
				cb(cast(string)(fsel.selected));
			sdir.setString(getcwd());
		}
		else if(activeWindow == sfile) { // pressed RETURN in file dialog
			string filename = getcwd() ~ DIR_SEPARATOR ~ sfile.toString();
			cb(filename);
		}
	}
}

class SaveFileDialog : FileSelectorDialog {
	this(Rectangle a, CB cb, string header = "Save Song") {
		super(a, header, cb);
		activateWindow(2);
	}

	override protected int returnPressed(CB cb) {
		if(activeWindow != fsel && activeWindow != sfile)
			return super.returnPressed(cb);

		if(std.file.exists(fullname) && !std.file.isDir(fullname)) {
			mainui.activateDialog(new ConfirmationDialog("Overwrite destination file (y/N)? ",
														 &confirmCallback));
			return OK;
		}
		else return super.returnPressed(cb);
	}

	private void confirmCallback(int param) {
		if(param != 0) return;

		// copypasted from super.returnPressed, ugh...
		// need to implement getSelectedFilename to cut repetition

		if(activeWindow == fsel) {
			int r = fsel.fileHandler();
			if(r == RETURN)
				processFileCallback(cast(string)(fsel.selected));
			sdir.setString(getcwd());
		}
		else if(activeWindow == sfile) { // pressed RETURN in file dialog
			string filename = getcwd() ~ DIR_SEPARATOR ~ sfile.toString();
			processFileCallback(filename);
		}
	}
}

// Popup that collects export options (the same knobs ct2util exposes on the
// command line, plus the executable PRG display toggles) before the file is
// saved. On Return it hands the gathered ExportOptions to onConfirm (which opens
// the save-file dialog); Esc cancels. Used for both packed .prg and .sid export.
class ExportOptionsDialog : Window {
	enum Mode { Prg, Sid }
	alias void delegate(ExportOptions) ConfirmCB;

	private {
		Mode mode;
		ConfirmCB onConfirm;
		string header;
		int sel;
		// Working values (assembled into ExportOptions on confirm). singleSubtune
		// is held as 0 = "all" here; defaultSubtune is 1-based.
		int fAddr = 0x1000, fZp = 0, fSingle = 0, fDef = 1;
		bool fExe = true, fInfo = true, fRaster = true, fTimer = true;
	}

	this(Mode mode, string header, ConfirmCB cb) {
		super(Rectangle(0, 0, 1));
		this.mode = mode;
		this.header = header;
		this.onConfirm = cb;
	}

	// kind codes: a=addr(hex16) z=zp(hex8) s=single(dec) d=default(dec),
	// E/I/R/T = executable / show-info / raster-meter / timer toggles.
	private struct Row { string label; char kind; }
	private Row[] rows() {
		Row[] r;
		r ~= Row("Reloc address   $", 'a');
		r ~= Row("Zero page       $", 'z');
		r ~= Row("Single subtune   ", 's');
		if(mode == Mode.Sid) {
			r ~= Row("Default subtune  ", 'd');
		}
		else {
			r ~= Row("Executable       ", 'E');
			if(fExe) {
				r ~= Row("  Show info      ", 'I');
				r ~= Row("  Raster meter   ", 'R');
				r ~= Row("  Timer          ", 'T');
			}
		}
		return r;
	}

	private string valStr(char kind) {
		switch(kind) {
		case 'a': return format("%04X", fAddr);
		case 'z': return fZp == 0 ? "00 (default)" : format("%02X", fZp);
		case 's': return fSingle == 0 ? "all" : format("%d", fSingle);
		case 'd': return format("%d", fDef);
		case 'E': return fExe ? "yes" : "no";
		case 'I': return fInfo ? "yes" : "no";
		case 'R': return fRaster ? "yes" : "no";
		case 'T': return fTimer ? "yes" : "no";
		default: return "";
		}
	}

	override void activate() { sel = 0; }

	override void update() {
		auto rs = rows();
		int fw = 46;
		int h = cast(int)rs.length + 6;
		int x = screen.width / 2 - (fw + 2) / 2;
		int y = screen.height / 2 - h / 2;
		drawFrame(Rectangle(x, y, h, fw + 2));
		screen.cprint(x + 2, y, 1, 0, " " ~ header ~ " ");
		foreach(i, row; rs) {
			int ry = y + 2 + cast(int)i;
			int fg = (cast(int)i == sel) ? 0 : 15;
			int bg = (cast(int)i == sel) ? 15 : 0;
			string line = format(" %s%s", row.label, valStr(row.kind));
			screen.cprint(x + 2, ry, fg, bg, line.leftJustify(fw - 2));
		}
		screen.cprint(x + 2, y + h - 3, 13, 0, "Up/Dn pick  Spc/<>/keys edit");
		screen.cprint(x + 2, y + h - 2, 13, 0, "Return: file & export   Esc: cancel");
	}

	private void clampAll() {
		if(fAddr < 0) fAddr = 0; if(fAddr > 0xffff) fAddr = 0xffff;
		if(fZp < 0) fZp = 0; if(fZp > 0xff) fZp = 0xff;
		if(fSingle < 0) fSingle = 0; if(fSingle > SUBTUNE_MAX) fSingle = SUBTUNE_MAX;
		if(fDef < 1) fDef = 1; if(fDef > SUBTUNE_MAX) fDef = SUBTUNE_MAX;
	}

	private void toggle(char kind) {
		switch(kind) {
		case 'E': fExe = !fExe; break;
		case 'I': fInfo = !fInfo; break;
		case 'R': fRaster = !fRaster; break;
		case 'T': fTimer = !fTimer; break;
		case 's': fSingle++; if(fSingle > SUBTUNE_MAX) fSingle = 0; break;
		case 'd': fDef++; if(fDef > SUBTUNE_MAX) fDef = 1; break;
		case 'a': fAddr = (fAddr + 0x100) & 0xffff; break;
		case 'z': fZp = (fZp + 1) & 0xff; break;
		default: break;
		}
	}

	private void editDigit(char kind, int uc) {
		int hex = -1;
		if(uc >= '0' && uc <= '9') hex = uc - '0';
		else if(uc >= 'a' && uc <= 'f') hex = uc - 'a' + 10;
		else if(uc >= 'A' && uc <= 'F') hex = uc - 'A' + 10;
		if(hex < 0) return;
		switch(kind) {
		case 'a': fAddr = ((fAddr << 4) | hex) & 0xffff; break;
		case 'z': fZp = ((fZp << 4) | hex) & 0xff; break;
		case 's': if(hex <= 9) { fSingle = fSingle * 10 + hex; if(fSingle > SUBTUNE_MAX) fSingle = hex; } break;
		case 'd': if(hex <= 9) { fDef = fDef * 10 + hex; if(fDef > SUBTUNE_MAX) fDef = hex; } break;
		default: break;
		}
		clampAll();
	}

	private void backspace(char kind) {
		switch(kind) {
		case 'a': fAddr >>= 4; break;
		case 'z': fZp >>= 4; break;
		case 's': fSingle /= 10; break;
		case 'd': fDef /= 10; break;
		default: break;
		}
		clampAll();
	}

	override int keypress(Keyinfo key) {
		if(key.mods & KMOD_ALT) return OK;
		auto rs = rows();
		int n = cast(int)rs.length;
		if(sel >= n) sel = n - 1;
		char kind = rs[sel].kind;
		switch(key.raw) {
		case SDLK_ESCAPE:
			return CANCEL;
		case SDLK_RETURN:
			ExportOptions o;
			o.relocAddress = fAddr;
			o.zpAddress = fZp;
			o.singleSubtune = (fSingle == 0) ? -1 : fSingle;
			o.defaultSubtune = (mode == Mode.Sid) ? fDef : 1;
			o.executable = (mode == Mode.Prg) ? fExe : false;
			o.showInfo = fInfo;
			o.showRastertime = fRaster;
			o.showTimer = fTimer;
			onConfirm(o);   // opens the save-file dialog; keep loop from closing it
			return OK;
		case SDLK_UP:
			sel = (sel + n - 1) % n;
			return OK;
		case SDLK_DOWN:
			sel = (sel + 1) % n;
			return OK;
		case SDLK_LEFT:
		case SDLK_RIGHT:
		case SDLK_SPACE:
			toggle(kind);
			return OK;
		case SDLK_BACKSPACE:
			backspace(kind);
			return OK;
		default:
			editDigit(kind, key.unicode);
			return OK;
		}
	}
}
