/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.
*/

module ct.build;
import ct.base;
import ct.dump;
import com.cpu;
import com.util;
import std.stdio;
import std.string;
import std.conv;
import core.stdc.string;
import core.stdc.stdlib;
import std.array;

extern(C) {
	extern char* acme_assemble(const char*,int*,char*);
}

static const string playerSource = import("player_v4.acme");
static const string ultimateShimSource = import("ultimate_host.acme");

const ubyte[] SIDHEADER = [
  0x50, 0x53, 0x49, 0x44, 0x00, 0x02, 0x00, 0x7c, 0x00, 0x00, 0x10, 0x00,
  0x10, 0x03, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x53, 0x77,
  0x61, 0x6d, 0x70, 0x20, 0x50, 0x6f, 0x6f, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x54, 0x68, 0x6f, 0x6d, 0x61, 0x73,
  0x20, 0x4d, 0x6f, 0x67, 0x65, 0x6e, 0x73, 0x65, 0x6e, 0x20, 0x28, 0x44,
  0x52, 0x41, 0x58, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x32, 0x30, 0x30, 0x34, 0x20, 0x4d, 0x61, 0x6e, 0x69, 0x61,
  0x63, 0x73, 0x20, 0x6f, 0x66, 0x20, 0x4e, 0x6f, 0x69, 0x73, 0x65, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14,
  0x00, 0x00, 0x00, 0x00 
];

enum {
	PSID_LOAD_ADDR_OFFSET = 0x08,
	PSID_INIT_OFFSET = 0x0a,
	PSID_PLAY_OFFSET = 0x0c,
	PSID_TITLE_OFFSET = 0x16,
	PSID_FLAGS_OFFSET = 0x76,
	PSID_NUM_SONGS = 0x0e,
	PSID_START_SONG = 0x10,
	PSID_SPEED_OFFSET = 0x12,
//	CIA_OFFSET = 0x09,
//	DIV_COUNTER = 0x1b,
	PAL_CLOCK = 0x4cc7,
	PSID_DATA_START = 0x7c 
}

// quick and ugly hack to circumvent D2 phobos weirdness
private int paddedStringLength(char[] s, char padchar) {
	int i;
	for(i = cast(int)(s.length - 1); i >= 0; i--) {
		if(s[i] != padchar) return cast(int)(i+1);
	}
	return 0;
}

private char[] assemble(string source) {
	int length;
	char[1024] error_message;
	memset(&error_message, '\0', 1024);
	char* input = acme_assemble(toStringz(source), &length, &error_message[0]);
	
	if(input is null) {
		string msg = to!string(&error_message[0]);
		throw new UserException(format("Could not assemble player. Message:\n%s", msg));
	}
	char[] assembled = new char[length];
	memcpy(assembled.ptr, input, length);
	free(input);
	return assembled;
}

private ubyte[] generatePSIDHeader(Song insong, ubyte[] data, int initAddress,
								   int playAddress, int defaultSubtune) {
	/+ SID default tune indicatior starts from value 1... +/
	if(defaultSubtune > insong.subtunes.numOf)
		throw new UserException(format("This song has only %d subtunes", insong.subtunes.numOf));
	data = SIDHEADER ~ data;
	void outstr(char[] s, int offset) {
		data[offset .. offset + s.length] = cast(ubyte[])s;
	}
	data[PSID_TITLE_OFFSET .. PSID_TITLE_OFFSET + 0x20] = '\0';
	data[PSID_TITLE_OFFSET + 0x20 .. PSID_TITLE_OFFSET + 0x40] = '\0';
	data[PSID_TITLE_OFFSET + 0x40 .. PSID_TITLE_OFFSET + 0x60] = '\0';

	// circumventing D2 phobos weirdness
	char[32] title = insong.title; title[paddedStringLength(title,' ') .. $] = '\0';
	char[32] author = insong.author; author[paddedStringLength(author,' ') .. $] = '\0';
	char[32] release = insong.release; release[paddedStringLength(release,' ') .. $] = '\0';
	outstr(title,PSID_TITLE_OFFSET);
	outstr(author,PSID_TITLE_OFFSET + 0x20);
	outstr(release,PSID_TITLE_OFFSET + 0x40); 
	data[PSID_NUM_SONGS + 1] = cast(ubyte)insong.subtunes.numOf;
	data[PSID_START_SONG + 1] = cast(ubyte)defaultSubtune;
	if(insong.multiplier > 1) {
		data[PSID_SPEED_OFFSET .. PSID_SPEED_OFFSET + 4] = 255;
	}
	data[PSID_INIT_OFFSET .. PSID_INIT_OFFSET + 2] = cast(ubyte[])[ initAddress >> 8, initAddress & 255 ];
	data[PSID_PLAY_OFFSET .. PSID_PLAY_OFFSET + 2] = cast(ubyte[])[ playAddress >> 8, playAddress & 255 ];
	int endAddr = cast(int)(initAddress + data.length);
	if(endAddr > 0xfff9)
		throw new UserException(format("The relocated tune goes past $fff9 (by $%x bytes).",endAddr-0xfff9));
	
	data[PSID_FLAGS_OFFSET + 1] 
		= cast(ubyte)(0x04 /+ PAL +/ | (insong.sidModel ? 0x20 : 0x10));

	return data;
}

ubyte[] doBuild(Song song, int address, int zpAddress,
				bool genPSID, int defaultSubtune,
				bool verbose) {
	// Valid range for subtunes is 1 - 32.
	if(!(defaultSubtune >= 1 && defaultSubtune <= ct.base.SUBTUNE_MAX))
		throw new UserException(format("Valid range for subtunes is 1 - %d.", ct.base.SUBTUNE_MAX));

	if(song.subtunes.numOf == 0) {
		throw new UserException("No subtunes found");
	}
	// Dump data to asm source
	string input = dumpOptimized(song, address, zpAddress,
								 genPSID, verbose);

	if(verbose)
		writeln("Assembling...");

	ubyte[] assembled = cast(ubyte[])assemble(input);
	
	if(verbose)
		writeln(format("Size %d bytes ($%04x-$%04x).", assembled.length - 2,
					   address, address + assembled.length - 2));

	return genPSID ? generatePSIDHeader(song, assembled, address, address + 3,
										defaultSubtune) : assembled;
}

/+
 + Build the self-running resident image for C64 Ultimate playback.
 +
 + Unlike doBuild()/dumpOptimized() (which relocate+pack a finalized tune),
 + this ships the *live* editor memory image verbatim so that addresses match
 + song.offsets[] 1:1 and the host can mirror edits straight into C64 RAM.
 + The result is one contiguous PRG loading at $0801:
 +   $0801..$0dff  BASIC autostart + control block + IRQ shim (ultimate_host.acme)
 +   $0e00..       the live player + song data (song.memspace), incl. RAM under ROM
 + See src/c64/ultimate_host.acme and src/audio/ultimate.d.
 +/
enum ULTIMATE_IMG_LO = 0x0e00;   // first address taken verbatim from song.memspace
enum ULTIMATE_IMG_HI = 0xf840;   // one past the last (covers the player's $f83d end)
enum ULTIMATE_PAL_CLOCK = 0x4cc7;
enum ULTIMATE_NTSC_CLOCK = 0x4295;
// Fixed addresses of the text-row buffers in ultimate_host.acme (40 bytes each).
enum ULTIMATE_SN_TITLE = 0x0b00;
enum ULTIMATE_SN_AUTHOR = 0x0b28;
enum ULTIMATE_SN_RELEASE = 0x0b50;
enum ULTIMATE_SN_APPVER = 0x0b78;
enum ULTIMATE_SN_PLAYER = 0x0ba0;
enum ULTIMATE_SN_STATUS = 0x0bc8;

// ASCII -> C64 screen code for the lowercase/mixed charset (VIC char base
// $1800, set by the shim). A-Z map to $41-$5A, a-z to $01-$1A.
private ubyte toScreenCode(ubyte c) {
	if(c >= 65 && c <= 90) return c;                    // A-Z -> $41-$5A
	if(c >= 97 && c <= 122) return cast(ubyte)(c - 96); // a-z -> $01-$1A
	if(c >= 32 && c <= 63) return c;                    // space, digits, punctuation
	return 0x20; // space for anything unprintable
}

ubyte[] buildResidentImage(Song song, bool ntsc) {
	int mult = song.multiplier < 1 ? 1 : song.multiplier;
	// CIA fires at 50*mult Hz (one frame divided by the multiplier), and the
	// shim makes exactly one player call per IRQ — play on the frame boundary,
	// mplay on the in-between subframes. So a 2x song triggers the player at
	// 100 Hz, evenly spaced (~156 raster lines apart), not back-to-back.
	int ciaval = (ntsc ? ULTIMATE_NTSC_CLOCK : ULTIMATE_PAL_CLOCK) / mult;
	bool newKeyjam = song.ver > 7;
	int subnote = newKeyjam ? song.offsets[Offsets.Subnoteplay] : 0x1009;
	int submplay = newKeyjam ? song.offsets[Offsets.Submplayplay] : 0x100c;
	int shtrans = song.offsets[Offsets.SHTRANS];

	// Constants consumed by ultimate_host.acme, prepended before assembly.
	string defs =
		format("INITADDR = $1000\n") ~
		format("PLAYADDR = $1003\n") ~
		format("MPLAYADDR = $1006\n") ~
		format("SUBNOTE = $%04x\n", subnote & 0xffff) ~
		format("SUBMPLAY = $%04x\n", submplay & 0xffff) ~
		format("SHTRANSADDR = $%04x\n", shtrans & 0xffff) ~
		format("CIAVAL = $%04x\n", ciaval & 0xffff) ~
		format("MULT = %d\n", mult - 1) ~
		format("NEWKEYJAM = %d\n", newKeyjam ? 1 : 0) ~
		format("FRAMERATE = %d\n", ntsc ? 60 : 50);

	ubyte[] shim = cast(ubyte[])assemble(defs ~ ultimateShimSource);
	if(shim.length < 2)
		throw new UserException("Could not assemble Ultimate host shim.");
	// assemble() output is [loadlo, loadhi, body...]; the shim loads at $0801.
	int shimLoad = shim[0] | (shim[1] << 8);
	if(shimLoad != 0x0801)
		throw new UserException(format("Ultimate shim has unexpected load address $%04x.", shimLoad));
	ubyte[] shimBody = shim[2 .. $];
	int shimRegion = ULTIMATE_IMG_LO - 0x0801; // bytes from $0801 up to (not incl.) $0e00
	if(shimBody.length > shimRegion)
		throw new UserException("Ultimate host shim is too large (overruns $0e00).");

	ubyte[] prg;
	prg ~= cast(ubyte)(0x0801 & 0xff);
	prg ~= cast(ubyte)(0x0801 >> 8);
	prg ~= shimBody;
	prg.length = 2 + shimRegion;                 // zero-pad the gap up to $0e00

	// Paint the text rows (screen codes) into the shim's buffers (40 wide).
	void putText(int addr, const(char)[] s) {
		int off = (addr - 0x0801) + 2;
		foreach(i; 0 .. 40)
			prg[off + i] = toScreenCode(i < s.length ? cast(ubyte)s[i] : 0x20);
	}
	putText(ULTIMATE_SN_TITLE, song.title);
	putText(ULTIMATE_SN_AUTHOR, song.author);
	putText(ULTIMATE_SN_RELEASE, song.release);
	putText(ULTIMATE_SN_APPVER, APP_NAME ~ " " ~ APP_VERSION);
	putText(ULTIMATE_SN_PLAYER, "Player: " ~ song.playerID[0 .. 6].idup);
	putText(ULTIMATE_SN_STATUS, "Time: 00:00 / $00");

	int imgBase = cast(int)prg.length;           // prg index of address $0e00
	prg ~= song.memspace[ULTIMATE_IMG_LO .. ULTIMATE_IMG_HI];

	// Prime the player to start the current subtune from the top, mirroring
	// audio.player.initPlayOffset([0,0,0],[0,0,0]) + all voices on. The
	// active subtune already lives in Track1/2/3, so this plays it. With
	// editorflag == 0 the player's init keeps these seeded values.
	void poke(int addr, ubyte v) { prg[imgBase + (addr - ULTIMATE_IMG_LO)] = v; }
	void poke16(int addr, int v) { poke(addr, cast(ubyte)(v & 0xff)); poke(addr + 1, cast(ubyte)((v >> 8) & 0xff)); }
	int t1 = song.offsets[Offsets.Track1];
	int t2 = song.offsets[Offsets.Track2];
	int t3 = song.offsets[Offsets.Track3];
	int tracklo = song.offsets[Offsets.TRACKLO];
	poke(tracklo,     cast(ubyte)(t1 & 0xff));
	poke(tracklo + 1, cast(ubyte)(t2 & 0xff));
	poke(tracklo + 2, cast(ubyte)(t3 & 0xff));
	poke(tracklo + 3, cast(ubyte)(t1 >> 8));
	poke(tracklo + 4, cast(ubyte)(t2 >> 8));
	poke(tracklo + 5, cast(ubyte)(t3 >> 8));
	int songsets = song.offsets[Offsets.Songsets];
	poke16(songsets,     t1);
	poke16(songsets + 2, t2);
	poke16(songsets + 4, t3);
	int newseq = song.offsets[Offsets.NEWSEQ];
	poke(newseq, 1); poke(newseq + 1, 1); poke(newseq + 2, 1);
	int voice = song.offsets[Offsets.VOICE];
	poke(voice, 0x00); poke(voice + 1, 0x07); poke(voice + 2, 0x0e); // all voices on

	return prg;
}

string dumpOptimized(Song song, int address, int zpAddress,
					 bool genPSID, bool verbose) {
	string input = playerSource;
	input ~= dumpData(song);
	input = setArgumentValue("INSNO", format("%d", song.numInstr+1), input);
	char[] linkedPlayerID = (new Song()).playerID;
	if(song.playerID[0..6] != linkedPlayerID[0..6] && verbose) {
		writeln("Warning: your song uses an old version of the player!\n",
				"The assembled song may sound different.\nSong player: ",
				to!string(song.playerID[0..6]), ", linked player: ",
				to!string(linkedPlayerID[0..6]));
	}
	
	bool chordUsed, swingUsed, filterUsed, vibratoUsed;
	bool setAttUsed, setDecUsed, setSusUsed, setRelUsed, setVolUsed, setSpeedUsed;
	bool offsetUsed, slideUpUsed, slideDnUsed, lovibUsed, portaUsed, setADSRUsed;
	
	song.seqIterator((Sequence s, Element e) { 
			int val = e.cmd.value;
			int cmdval = -1;
			if(val == 0) return;
			if(val < 0x40) {
				cmdval = song.superTable[val];
				if(cmdval < 1) slideUpUsed = true;
				else if(cmdval == 1)
					slideDnUsed = true;
				else if(cmdval == 2)
					vibratoUsed = true;
				else if(cmdval == 3)
					offsetUsed = true;
				else if(cmdval == 4)
					setADSRUsed = true;
				else if(cmdval == 5)
					lovibUsed = true;
				else if(cmdval == 7)
					portaUsed = true;
				return;
			}
			else if(val < 0x60)
				return;
			else if(val < 0x80)
				filterUsed = true;
			else if(val < 0xa0)
				chordUsed = true;
			else if(val < 0xb0)
				setAttUsed = true;
			else if(val < 0xc0)
				setDecUsed = true;
			else if(val < 0xd0)
				setSusUsed = true;
			else if(val < 0xe0)
				setRelUsed = true;
			else if(val < 0xf0) 
				setVolUsed = true;
			else {
				if(val == 0xf0 || val == 0xf1) swingUsed = true;
				setSpeedUsed = true;
			}
		});
	for(int i = 0; i < song.subtunes.numOf; i++) {
		if(song.songspeeds[i] < 2) swingUsed = true;
	}
	for(int i = 0; i < 48; i++) {
		if(song.filtertablePointer(i) > 0)
			filterUsed = true;
	}

	if(verbose) {
		string[] fxdescr =
			[ "slup", "sldn", "vib", "porta", "adsr",
			  "8x", "offset", "lovib", "Ax", "Bx", "Cx", "Dx",
			  "Ex", "Fx", "swing", "filter" ];
		auto fxused = std.array.appender!string();
		foreach(idx, used; [slideUpUsed, slideDnUsed, vibratoUsed, portaUsed,
							setADSRUsed, chordUsed, offsetUsed, lovibUsed,
							setAttUsed, setDecUsed, setSusUsed, setRelUsed,
							setVolUsed, setSpeedUsed, swingUsed, filterUsed]) {
			if(used)
				fxused.put(fxdescr[idx] ~ " ");
		}
		if(fxused.data.length > 0) {
			writeln("Effects used: " ~ fxused.data);
		}
	}
	
	void setArgVal(string arg, string val) {
		input = setArgumentValue(arg, val, input);
	}

	input = setArgumentValue("EXPORT", "TRUE", input);
	if(zpAddress > 0)
		setArgVal("ZREG", format("$%02X", zpAddress));
	setArgVal("INCLUDE_CMD_SLUP", slideUpUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_CMD_SLDOWN", slideDnUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_CMD_VIBR", vibratoUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_CMD_PORTA", portaUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_CMD_SET_ADSR", setADSRUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_SEQ_SET_CHORD", chordUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_CHORD", chordUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_CMD_SET_OFFSET", offsetUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_CMD_SET_LOVIB", lovibUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_SEQ_SET_ATT", setAttUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_SEQ_SET_DEC", setDecUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_SEQ_SET_SUS", setSusUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_SEQ_SET_REL", setRelUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_SEQ_SET_VOL", setVolUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_SEQ_SET_SPEED", setSpeedUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_BREAKSPEED", swingUsed ? "TRUE" : "FALSE");
	setArgVal("INCLUDE_FILTER", filterUsed ? "TRUE" : "FALSE");
	setArgVal("MULTISPEED", song.multiplier > 1 ? "TRUE" : "FALSE");
	if(song.multiplier > 1) {
		setArgVal("USE_MDRIVER", genPSID ? "TRUE" : "FALSE");
		setArgVal("CIA_VALUE",
				  format("$%04x", PAL_CLOCK / song.multiplier));
		setArgVal("MULTIPLIER", format("%d", song.multiplier - 1));
	}
	setArgVal("BASEADDRESS", format("$%04x", address), );

	return input;
}
