/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

C64 Ultimate (1541U / Ultimate64) playback backend.

Instead of (only) feeding reSID, this mirrors the live song image to a real
C64 over the Ultimate's REST API. The player + data are injected once per
song via run_prg; thereafter only edited song-data bytes are pushed via
writemem (DMA), and a small resident shim (src/c64/ultimate_host.acme) keeps
the player ticking at the song's real rate and obeys a tiny control block we
poke for start / stop / keyjam. See the plan and ultimate_host.acme.
*/
module audio.ultimate;

import std.net.curl;
import std.conv;
import std.format;
import std.process : environment;
import std.stdio;
import core.thread : Thread;
import core.time : dur;
import ct.base;
import ct.build;

// Control block layout — must match ultimate_host.acme ($0810).
enum CTRL_ADDR = 0x0810;
enum {
	CTRL_MODE = 0,
	CTRL_REQ = 1,
	CTRL_SUBTUNE = 2,
	CTRL_KJNOTE = 3,
	CTRL_KJVOICE = 4,
	CTRL_KJINSTR = 5,
}
enum {
	REQ_RESTART = 1,
	REQ_KEYJAM = 2,
	REQ_STOP = 3,
}

__gshared bool ultimateEnabled = false;
__gshared string ultimateHost;
__gshared int ultimatePort = 80;
__gshared string ultimatePassword;
__gshared bool ntscMode = false;

private struct Region { int addr; int len; }
private __gshared ubyte[65536] shadow;
private __gshared Region[] regions;
private __gshared bool booted = false;
private __gshared bool loaded = false;
private __gshared bool reloadPending = false;

bool isUltimate() nothrow { return ultimateEnabled; }
bool isLoaded() nothrow { return loaded; }

// Enable the backend. Call once at startup when --ultimate is given.
void configure(string host, int port, bool ntsc) {
	ultimateHost = host;
	ultimatePort = port;
	ntscMode = ntsc;
	ultimateEnabled = true;
	ultimatePassword = environment.get("CHEESECUTTER_ULTIMATE_PASSWORD", "");
}

// Mark that the resident image is stale (e.g. a different song was loaded);
// it will be re-injected on the next ensureLoaded().
void markReload() nothrow { reloadPending = true; loaded = false; }

// ---------------------------------------------------------------- transport

private void httpRequest(string method, string path, const(ubyte)[] body) {
	string url = format("http://%s:%d%s", ultimateHost, ultimatePort, path);
	auto http = HTTP(url);
	http.method = method == "POST" ? HTTP.Method.post : HTTP.Method.put;
	if(ultimatePassword.length)
		http.addRequestHeader("X-Password", ultimatePassword);
	http.setPostData(cast(const(void)[])body, "application/octet-stream");
	http.onReceive = (ubyte[] data) => data.length;
	http.perform();
	auto code = http.statusLine.code;
	if(code == 403)
		throw new Exception("C64 Ultimate: 403 Forbidden — check CHEESECUTTER_ULTIMATE_PASSWORD.");
	if(code >= 400)
		throw new Exception(format("C64 Ultimate: HTTP %d for %s", code, path));
}

private void runPrg(const(ubyte)[] prg) {
	httpRequest("POST", "/v1/runners:run_prg", prg);
}

private void writeMem(int addr, const(ubyte)[] data) {
	httpRequest("POST", format("/v1/machine:writemem?address=%04X", addr & 0xffff), data);
}

void reboot() { httpRequest("PUT", "/v1/machine:reboot", []); }
void resetMachine() {
	if(!ultimateEnabled) return;
	try { httpRequest("PUT", "/v1/machine:reset", []); loaded = false; }
	catch(Exception e) { stderr.writeln("Ultimate: reset failed: ", e.msg); }
}

// ---------------------------------------------------------------- mirroring

// Static song-data regions to diff/mirror. Deliberately excludes the player
// code and runtime/position vars (which the resident player advances itself).
private void buildRegions(Song song) {
	regions.length = 0;
	auto o = song.offsets;
	void add(int off, int len) {
		if(off > 0 && len > 0 && off + len <= 0x10000) regions ~= Region(off, len);
	}
	add(o[Offsets.Features], 64);
	add(o[Offsets.Songsets], 256);
	add(o[Offsets.Arp1], 512);
	add(o[Offsets.Inst], 512);
	add(o[Offsets.CMD1], 256);
	add(o[Offsets.PULSTAB], 256);
	add(o[Offsets.FILTTAB], 256);
	add(o[Offsets.SeqLO], 256);
	add(o[Offsets.SeqHI], 256);
	add(o[Offsets.ChordTable], 128);
	add(o[Offsets.ChordIndexTable], 32);
	add(o[Offsets.Track1], 0x400);
	add(o[Offsets.Track2], 0x400);
	add(o[Offsets.Track3], 0x400);
	// Sequence note data: the union of all 128 sequence pointers (+256 each).
	int slo = o[Offsets.SeqLO], shi = o[Offsets.SeqHI];
	int lo = 0x10000, hi = 0;
	for(int i = 0; i < 128; i++) {
		int p = song.data[slo + i] | (song.data[shi + i] << 8);
		if(p < lo) lo = p;
		if(p + 256 > hi) hi = p + 256;
	}
	if(hi > lo) add(lo, hi - lo);
}

// (Re)inject the whole resident image if needed. Reboots the machine once,
// before the very first injection.
void ensureLoaded(Song song) {
	if(!ultimateEnabled) return;
	if(loaded && !reloadPending) return;
	try {
		if(!booted) {
			reboot();
			Thread.sleep(dur!"seconds"(4)); // let it come back up
			booted = true;
		}
		buildRegions(song);
		auto prg = buildResidentImage(song, ntscMode);
		runPrg(prg);
		shadow[] = song.memspace[];
		loaded = true;
		reloadPending = false;
	}
	catch(Exception e) {
		stderr.writeln("Ultimate: load failed: ", e.msg);
		loaded = false;
	}
}

// Push edited song-data bytes to C64 RAM. Cheap when nothing changed.
void syncDeltas(Song song) {
	if(!ultimateEnabled || !loaded) return;
	try {
		foreach(r; regions) {
			int end = r.addr + r.len;
			int i = r.addr;
			while(i < end) {
				while(i < end && song.memspace[i] == shadow[i]) i++;
				if(i >= end) break;
				// Extend the dirty span, coalescing short runs of equal bytes.
				int j = i, lastDiff = i, gap = 0;
				while(j < end) {
					if(song.memspace[j] != shadow[j]) { lastDiff = j; gap = 0; }
					else if(++gap > 8) break;
					j++;
				}
				int spanEnd = lastDiff + 1;
				writeMem(i, song.memspace[i .. spanEnd]);
				shadow[i .. spanEnd] = song.memspace[i .. spanEnd];
				i = spanEnd;
			}
		}
	}
	catch(Exception e) {
		stderr.writeln("Ultimate: writemem failed: ", e.msg);
	}
}

// ---------------------------------------------------------------- commands

private void pushBytes(Song song, int addr, int len) {
	writeMem(addr, song.memspace[addr .. addr + len]);
	shadow[addr .. addr + len] = song.memspace[addr .. addr + len];
}

// Start playback from a position. song.buffer must already hold the poked
// track/sequence offsets (initPlayOffset ran in audio.player).
void cmdRestart(Song song, ubyte subtune) {
	if(!ultimateEnabled || !loaded) return;
	try {
		syncDeltas(song);
		pushBytes(song, song.offsets[Offsets.TRACKLO], 6);
		pushBytes(song, song.offsets[Offsets.NEWSEQ], 3);
		pushBytes(song, song.offsets[Offsets.VOICE], 3);
		writeMem(CTRL_ADDR + CTRL_SUBTUNE, [subtune]);
		writeMem(CTRL_ADDR + CTRL_REQ, [cast(ubyte)REQ_RESTART]);
	}
	catch(Exception e) { stderr.writeln("Ultimate: restart failed: ", e.msg); }
}

void cmdKeyjam(Song song, int note, int voice, int instr) {
	if(!ultimateEnabled || !loaded) return;
	try {
		syncDeltas(song);
		pushBytes(song, song.offsets[Offsets.VOICE], 3); // voice-on mask set by playNote
		writeMem(CTRL_ADDR + CTRL_KJNOTE,
				 [cast(ubyte)note, cast(ubyte)voice, cast(ubyte)instr]);
		writeMem(CTRL_ADDR + CTRL_REQ, [cast(ubyte)REQ_KEYJAM]);
	}
	catch(Exception e) { stderr.writeln("Ultimate: keyjam failed: ", e.msg); }
}

void cmdStop() nothrow {
	if(!ultimateEnabled || !loaded) return;
	try { writeMem(CTRL_ADDR + CTRL_REQ, [cast(ubyte)REQ_STOP]); }
	catch(Throwable) {}
}

// Mirror the voice-on/off mask (mute toggles) to the resident player.
void pushVoice(Song song) nothrow {
	if(!ultimateEnabled || !loaded) return;
	try { pushBytes(song, song.offsets[Offsets.VOICE], 3); }
	catch(Throwable) {}
}
