/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Song-image build and export — validation plus the FullPrg / OptimizedPrg / PSID formats (ExportOptions).
*/

module ct.build;
import ct.base;
import ct.dump;
import ct.purge;
import com.cpu;
import com.util;
import std.stdio;
import std.string;
import std.conv;
import core.stdc.string;
import core.stdc.stdlib;
import std.array;
import std.math : lround;
import std.algorithm : sort;

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
 + Shared export API used by BOTH the ct2util CLI and the editor, so the
 + purge/validate/relocate logic lives in exactly one place.
 + ExportOptions mirrors the ct2util command-line switches (-r/-zp/-s/-d) plus the
 + editor-only output format + PRG display toggles.
 +/

// Output format the editor's "Export song" dialog offers.
//  FullPrg      - the verbatim live-image self-running .prg (buildResidentImage)
//  OptimizedPrg - purged/relocated player+data, optionally wrapped in the shim
//  Psid         - PSID .sid file
enum ExportFormat { FullPrg, OptimizedPrg, Psid }

struct ExportOptions {
	ExportFormat format = ExportFormat.FullPrg;
	int  relocAddress   = 0x1000;  // -r  : relocate player+data here
	int  zpAddress      = 0;       // -zp : relocate zero page (0 = leave default)
	int  singleSubtune  = -1;      // -s  : export only this subtune (1-based; -1 = all)
	int  defaultSubtune = 1;       // -d  : PSID start tune (1-based)
	bool executable     = true;    // PRG: embed shim+player+UI vs bare player+data
	bool showInfo       = true;    // executable PRG: show Title/Author/Release rows
	bool showRastertime = true;    // executable PRG: border raster meter + $RR value
	bool showTimer      = true;    // executable PRG: MM:SS playback clock
}

class ValidateException : Exception {
	this(string msg) {
		super(msg);
	}

	override string toString() {
		return "Validation error: " ~ msg;
	}
}

// Check the song is exportable (wavetables wrap, pulse/filter valid, chord
// programs terminate). Throws ValidateException on the first problem found.
void validate(Song song) {
	for(int i = 0; i < song.numInstr; i++) {
		int waveptr = song.wavetablePointer(i);
		int pulseptr = song.pulsetablePointer(i);
		int filtptr = song.filtertablePointer(i);
		if(!song.tWave.isValid(waveptr)) {
			throw new ValidateException(format("Error: instrument %d is not valid (wavetable does not wrap).", i));
		}
		if(!song.tPulse.isValid(pulseptr)) {
			throw new ValidateException(format("Cannot save; pulse %d is not valid.", pulseptr));
		}
		if(!song.tFilter.isValid(filtptr)) {
			throw new ValidateException(format("Cannot save; filter %d is not valid.", filtptr));
		}
		song.seqIterator((int seqno, Sequence s, Element e) {
				if(e.cmd.value >= 0x80 && e.cmd.value <= 0x9f) {
					int idx = song.chordIndexTable[e.cmd.value & 0x1f];
					for(int i = idx; i < 128; i++) {
						if(song.chordTable[i] >= 0x80) return;
					}
					throw new ValidateException(format("sequence $%02x, could not find end for chord %x. The song has a 8x command pointing to nonexistant chord program.", seqno, e.cmd.value & 0x1f));
				}
			});
	}
}

// Produce an export-ready song: clone the live song (so the caller's working
// copy is never mutated), optionally reduce to a single subtune, purge unused
// data and validate. Throws PurgeException / ValidateException on failure.
Song prepareForExport(Song live, ref ExportOptions o, bool verbose) {
	Song s = live.dup();
	if(o.singleSubtune >= 1) {
		for(int i = 0; i < ct.base.SUBTUNE_MAX; i++) {
			if(i == o.singleSubtune - 1) continue;
			s.subtunes.clear(i);
		}
		s.subtunes.swap(0, o.singleSubtune - 1);
		o.defaultSubtune = 1;
	}
	Purge p = new Purge(s, verbose);
	p.purgeAll();
	validate(s);
	return s;
}

// Export to a PSID .sid file (optimized, relocated).
ubyte[] exportSid(Song live, ref ExportOptions o, bool verbose = false) {
	Song s = prepareForExport(live, o, verbose);
	return doBuild(s, o.relocAddress, o.zpAddress, true, o.defaultSubtune, verbose);
}

// Export to a .prg. With o.executable the optimized player+data is wrapped in the
// self-running shim (autostart + on-screen display, same look & feel as the live
// editor .prg); otherwise the bare relocatable player+data blob is returned (what
// `ct2util prg` emits).
ubyte[] exportPrg(Song live, bool ntsc, ref ExportOptions o, bool verbose = false) {
	int startSub = (o.singleSubtune >= 1) ? 0 : live.subtune;
	Song s = prepareForExport(live, o, verbose);
	ubyte[] payload = doBuild(s, o.relocAddress, o.zpAddress, false, o.defaultSubtune, verbose);
	if(!o.executable)
		return payload;
	// Strip the 2-byte load address and wrap the relocated player+data. Keyjam
	// entry points are dead in a standalone autostart prg, so pass dummies.
	int reloc = o.relocAddress;
	return wrapWithShim(s, ntsc, true, payload[2 .. $], reloc,
						reloc, reloc + 3, reloc + 6,
						reloc, reloc, reloc,
						s.ver > 7, startSub,
						o.showInfo, o.showRastertime, o.showTimer);
}

// Single entry point for the editor's "Export song" dialog: dispatch on the
// chosen format. The full-player .prg ships the live image verbatim (current
// subtune, not relocated/purged) but honours the same display toggles.
ubyte[] exportSong(Song live, bool ntsc, ref ExportOptions o) {
	final switch(o.format) {
	case ExportFormat.FullPrg:
		return buildResidentImage(live, ntsc, true, o.showInfo, o.showRastertime, o.showTimer);
	case ExportFormat.OptimizedPrg:
		return exportPrg(live, ntsc, o);
	case ExportFormat.Psid:
		return exportSid(live, o);
	}
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
// Raster geometry for placing the player-call lines (the shim is raster-IRQ
// driven). TOTAL = lines per frame; CENTER = visible-screen vertical centre
// (PAL display ~lines 51-250, NTSC ~41-240) so the green raster meter is centred.
enum ULTIMATE_PAL_LINES = 312;
enum ULTIMATE_NTSC_LINES = 263;
enum ULTIMATE_PAL_CENTER = 150;
enum ULTIMATE_NTSC_CENTER = 140;
// ctrl_subtune in the shim's control block ($0810): the A value passed to init().
enum ULTIMATE_SN_SUBTUNE = 0x0812;
// Fixed addresses of the raster-line table in ultimate_host.acme (poked here).
enum ULTIMATE_SN_NUMSLOTS = 0x0816;
enum ULTIMATE_SN_RASLO = 0x0817;   // 16 bytes: low 8 bits of each line
enum ULTIMATE_SN_RASHI = 0x0827;   // 16 bytes: bit 8 of each line
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

// Wrap a relocatable player+data payload in the self-running shim image (BASIC
// autostart at $0801, raster-IRQ player driver, on-screen display) and return one
// contiguous PRG loading at $0801. Shared by the live editor image
// (buildResidentImage) and the packed export (exportPrg, executable variant).
// payloadBody loads at payloadLoad; the player's jump table is at initAddr (play
// = +3, mplay = +6). The display rows / raster meter / clock can be opted out.
private ubyte[] wrapWithShim(Song song, bool ntsc, bool autoPlay,
							 const(ubyte)[] payloadBody, int payloadLoad,
							 int initAddr, int playAddr, int mplayAddr,
							 int subnote, int submplay, int shtrans,
							 bool newKeyjam, int startSubtune,
							 bool showInfo, bool showRastertime, bool showTimer) {
	int mult = song.multiplier < 1 ? 1 : song.multiplier;
	if(mult > 16) mult = 16;   // the shim reserves 16 raster slots
	// The shim is driven by a VIC raster IRQ on `mult` pre-defined lines per
	// frame (one player call per line). Place them evenly spaced (TOTAL/mult
	// apart) with the set centred on the visible-screen centre, so the green
	// raster-time meter sits in the middle: 1x -> one line at centre; 2x -> two
	// lines equidistant above/below; etc. Sorted ascending so slot 0 (the first
	// line reached each frame) is the full PLAY tick and the rest are MPLAY.
	int total = ntsc ? ULTIMATE_NTSC_LINES : ULTIMATE_PAL_LINES;
	int center = ntsc ? ULTIMATE_NTSC_CENTER : ULTIMATE_PAL_CENTER;
	int[] rasLines;
	foreach(i; 0 .. mult) {
		double pos = center + (i - (mult - 1) / 2.0) * (cast(double)total / mult);
		int line = cast(int)lround(pos);
		line = ((line % total) + total) % total;
		rasLines ~= line;
	}
	rasLines.sort();

	// Constants consumed by ultimate_host.acme, prepended before assembly.
	// (The raster-line table itself is poked into RAM below, not assembled.)
	string defs =
		format("INITADDR = $%04x\n", initAddr & 0xffff) ~
		format("PLAYADDR = $%04x\n", playAddr & 0xffff) ~
		format("MPLAYADDR = $%04x\n", mplayAddr & 0xffff) ~
		format("SUBNOTE = $%04x\n", subnote & 0xffff) ~
		format("SUBMPLAY = $%04x\n", submplay & 0xffff) ~
		format("SHTRANSADDR = $%04x\n", shtrans & 0xffff) ~
		format("NEWKEYJAM = %d\n", newKeyjam ? 1 : 0) ~
		format("FRAMERATE = %d\n", ntsc ? 60 : 50) ~
		format("STARTMODE = %d\n", autoPlay ? 1 : 0) ~
		format("SHOW_RASTERTIME = %d\n", showRastertime ? 1 : 0) ~
		format("SHOW_TIMER = %d\n", showTimer ? 1 : 0);

	ubyte[] shim = cast(ubyte[])assemble(defs ~ ultimateShimSource);
	if(shim.length < 2)
		throw new UserException("Could not assemble Ultimate host shim.");
	// assemble() output is [loadlo, loadhi, body...]; the shim loads at $0801.
	int shimLoad = shim[0] | (shim[1] << 8);
	if(shimLoad != 0x0801)
		throw new UserException(format("Ultimate shim has unexpected load address $%04x.", shimLoad));
	ubyte[] shimBody = shim[2 .. $];
	int shimRegion = payloadLoad - 0x0801; // bytes from $0801 up to (not incl.) payloadLoad
	if(shimBody.length > shimRegion)
		throw new UserException(format("Ultimate host shim is too large (overruns $%04x).", payloadLoad));

	ubyte[] prg;
	prg ~= cast(ubyte)(0x0801 & 0xff);
	prg ~= cast(ubyte)(0x0801 >> 8);
	prg ~= shimBody;
	prg.length = 2 + shimRegion;                 // zero-pad the gap up to payloadLoad

	// Paint the text rows (screen codes) into the shim's buffers (40 wide).
	void putText(int addr, const(char)[] s) {
		int off = (addr - 0x0801) + 2;
		foreach(i; 0 .. 40)
			prg[off + i] = toScreenCode(i < s.length ? cast(ubyte)s[i] : 0x20);
	}
	const(char)[] tTitle   = showInfo ? cast(const(char)[])song.title[]   : "";
	const(char)[] tAuthor  = showInfo ? cast(const(char)[])song.author[]  : "";
	const(char)[] tRelease = showInfo ? cast(const(char)[])song.release[] : "";
	putText(ULTIMATE_SN_TITLE, tTitle);
	putText(ULTIMATE_SN_AUTHOR, tAuthor);
	putText(ULTIMATE_SN_RELEASE, tRelease);
	putText(ULTIMATE_SN_APPVER, APP_NAME ~ " " ~ APP_VERSION);
	putText(ULTIMATE_SN_PLAYER, "Player: " ~ song.playerID[0 .. 6].idup);
	// Time/raster status row: show only the enabled fields (cells aligned to the
	// shim's CELL_* positions: MM:SS at +6.., $RR at +15..+16).
	char[] status = "Time: 00:00 / $00".dup;
	if(!showTimer)      status[6 .. 11] = ' ';   // MM:SS cells
	if(!showRastertime) status[12 .. 17] = ' ';  // "/ $RR" cells
	putText(ULTIMATE_SN_STATUS, (showTimer || showRastertime) ? cast(const(char)[])status : "");

	// Poke the raster-line table the shim reads (same fixed-address mechanism).
	void shimPoke(int addr, int v) { prg[(addr - 0x0801) + 2] = cast(ubyte)v; }
	shimPoke(ULTIMATE_SN_NUMSLOTS, mult);
	foreach(i; 0 .. mult) {
		shimPoke(ULTIMATE_SN_RASLO + i, rasLines[i] & 0xff);
		shimPoke(ULTIMATE_SN_RASHI + i, (rasLines[i] >> 8) & 1);
	}
	shimPoke(ULTIMATE_SN_SUBTUNE, startSubtune); // ctrl_subtune: subtune init() plays

	prg ~= cast(ubyte[])payloadBody;
	return prg;
}

ubyte[] buildResidentImage(Song song, bool ntsc, bool autoPlay,
						   bool showInfo = true, bool showRastertime = true,
						   bool showTimer = true) {
	bool newKeyjam = song.ver > 7;
	int subnote = newKeyjam ? song.offsets[Offsets.Subnoteplay] : 0x1009;
	int submplay = newKeyjam ? song.offsets[Offsets.Submplayplay] : 0x100c;
	int shtrans = song.offsets[Offsets.SHTRANS];

	// Ship the live editor memory image verbatim ($0e00..) so addresses match
	// song.offsets[] 1:1. Display toggles default on (the --ultimate/--vice host
	// upload path keeps the full display); the editor's export dialog can opt out.
	ubyte[] liveImg = song.memspace[ULTIMATE_IMG_LO .. ULTIMATE_IMG_HI].dup;
	ubyte[] prg = wrapWithShim(song, ntsc, autoPlay, liveImg, ULTIMATE_IMG_LO,
							   0x1000, 0x1003, 0x1006, subnote, submplay, shtrans,
							   newKeyjam, 0, showInfo, showRastertime, showTimer);

	// Prime the player to start the current subtune from the top, mirroring
	// audio.player.initPlayOffset([0,0,0],[0,0,0]) + all voices on. The
	// active subtune already lives in Track1/2/3, so this plays it. With
	// editorflag == 0 the player's init keeps these seeded values.
	// imgBase is the prg offset of $0e00 (right after the zero-padded shim).
	int imgBase = cast(int)prg.length - cast(int)liveImg.length;
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
