/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Transport-agnostic core for "remote" playback backends — playing the live song
image on real or emulated C64 hardware instead of (only) feeding the local reSID.

The model is the same regardless of where it runs: inject the live 64K image +
a small resident shim once per song (runProgram); thereafter push only edited
song-data bytes (writeMem / DMA); the resident shim keeps the player ticking at
the song's real rate and obeys a tiny control block we poke for start / stop /
keyjam. Only the wire protocol differs, and that lives behind RemoteTransport:
  - audio.ultimate : C64 Ultimate REST API (HTTP)
  - audio.vice     : VICE x64sc binary monitor (TCP socket)
See src/c64/ultimate_host.acme and ct.build.buildResidentImage.
*/
module audio.remote;

import std.format;
import std.stdio;
import core.time : MonoTime, dur;
import ct.base;
import ct.build;

// Thrown by a transport's connect() when the backend can never come up (e.g. the
// emulator executable is not on PATH). The core treats this as unrecoverable and
// falls back to local playback, rather than retrying forever.
class RemoteUnavailableException : Exception {
	this(string msg) { super(msg); }
}

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

// A wire transport to a real/emulated C64. Implementations own the protocol;
// the core here owns the playback orchestration.
interface RemoteTransport {
	// Ensure the backend is up and ready to receive runProgram: reboot the
	// hardware, or (re)launch + (re)connect the emulator. Idempotent — called
	// again on recovery after a lost connection. Throws on failure (throw
	// RemoteUnavailableException if it can never succeed).
	void connect();
	// Inject and run the resident image (the run_prg equivalent).
	void runProgram(const(ubyte)[] prg);
	// Push bytes into C64 RAM (DMA / monitor write).
	void writeMem(int addr, const(ubyte)[] data);
	// Tear down on app exit: reset hardware / detach emulator. Must not throw.
	void shutdown() nothrow;
}

private struct Region { int addr; int len; }
private __gshared ubyte[65536] shadow;
private __gshared Region[] regions;
private __gshared bool loaded = false;
private __gshared bool reloadPending = false;
private __gshared bool ntscMode = false;
private __gshared RemoteTransport transport; // null = no remote backend active
private __gshared MonoTime nextRetry;        // earliest next (re)establish attempt
private __gshared bool wasDown = false;       // one-shot "backend lost" logging
enum RETRY_BACKOFF = 2;                       // seconds between recovery attempts

bool isActive() nothrow { return transport !is null; }
bool isLoaded() nothrow { return loaded; }

// Install a transport (called once at startup by --ultimate / --vice wiring).
void useTransport(RemoteTransport t) { transport = t; }
void setMode(bool ntsc) { ntscMode = ntsc; }

// Mark that the resident image is stale (e.g. a different song was loaded);
// it will be re-injected on the next ensureLoaded().
void markReload() nothrow { reloadPending = true; loaded = false; }

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

// Ensure the resident image is up and current. Re-establishes the backend and
// re-uploads the player whenever it has been lost (emulator closed / connection
// dropped — flagged by a failed write setting loaded=false) or a reload is
// pending. Throttled by a backoff so a downed backend isn't hammered per frame.
void ensureLoaded(Song song) {
	if(transport is null) return;
	if(loaded && !reloadPending) return;
	// Backoff applies only between consecutive failed attempts (nextRetry is set
	// in the failure path), so the first recovery after a loss is immediate.
	if(MonoTime.currTime < nextRetry) return;
	try {
		transport.connect();   // (re)launch / (re)connect; idempotent
		buildRegions(song);
		auto prg = buildResidentImage(song, ntscMode, false); // host starts playback on Play
		transport.runProgram(prg);
		shadow[] = song.memspace[];
		loaded = true;
		reloadPending = false;
		if(wasDown) {
			stderr.writeln("Remote: backend reconnected; player re-uploaded.");
			wasDown = false;
		}
	}
	catch(RemoteUnavailableException e) {
		// Can never come up (e.g. x64sc not on PATH). Disable and fall back to
		// local reSID playback instead of retrying forever.
		stderr.writeln("Remote: backend unavailable (", e.msg,
					   "); falling back to local playback.");
		try { transport.shutdown(); } catch(Throwable) {}
		transport = null;
	}
	catch(Exception e) {
		// Transient (emulator booting / unreachable). Retry after a backoff.
		loaded = false;
		nextRetry = MonoTime.currTime + dur!"seconds"(RETRY_BACKOFF);
		if(!wasDown) {
			stderr.writeln("Remote: backend lost (", e.msg, "); retrying...");
			wasDown = true;
		}
	}
}

// Push edited song-data bytes to C64 RAM. Cheap when nothing changed.
void syncDeltas(Song song) {
	if(transport is null || !loaded) return;
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
				transport.writeMem(i, song.memspace[i .. spanEnd]);
				shadow[i .. spanEnd] = song.memspace[i .. spanEnd];
				i = spanEnd;
			}
		}
	}
	catch(Exception e) {
		stderr.writeln("Remote: writemem failed: ", e.msg);
		loaded = false;   // trigger reconnect + re-upload on the next ensureLoaded
	}
}

// ---------------------------------------------------------------- commands

private void pushBytes(Song song, int addr, int len) {
	transport.writeMem(addr, song.memspace[addr .. addr + len]);
	shadow[addr .. addr + len] = song.memspace[addr .. addr + len];
}

// Start playback from a position. song.buffer must already hold the poked
// track/sequence offsets (initPlayOffset ran in audio.player).
void cmdRestart(Song song, ubyte subtune) {
	if(transport is null || !loaded) return;
	try {
		syncDeltas(song);
		pushBytes(song, song.offsets[Offsets.TRACKLO], 6);
		pushBytes(song, song.offsets[Offsets.NEWSEQ], 3);
		pushBytes(song, song.offsets[Offsets.VOICE], 3);
		transport.writeMem(CTRL_ADDR + CTRL_SUBTUNE, [subtune]);
		transport.writeMem(CTRL_ADDR + CTRL_REQ, [cast(ubyte)REQ_RESTART]);
	}
	catch(Exception e) { stderr.writeln("Remote: restart failed: ", e.msg); loaded = false; }
}

void cmdKeyjam(Song song, int note, int voice, int instr) {
	if(transport is null || !loaded) return;
	try {
		syncDeltas(song);
		pushBytes(song, song.offsets[Offsets.VOICE], 3); // voice-on mask set by playNote
		transport.writeMem(CTRL_ADDR + CTRL_KJNOTE,
				 [cast(ubyte)note, cast(ubyte)voice, cast(ubyte)instr]);
		transport.writeMem(CTRL_ADDR + CTRL_REQ, [cast(ubyte)REQ_KEYJAM]);
	}
	catch(Exception e) { stderr.writeln("Remote: keyjam failed: ", e.msg); loaded = false; }
}

void cmdStop() nothrow {
	if(transport is null || !loaded) return;
	try { transport.writeMem(CTRL_ADDR + CTRL_REQ, [cast(ubyte)REQ_STOP]); }
	catch(Throwable) { loaded = false; }
}

// Mirror the voice-on/off mask (mute toggles) to the resident player.
void pushVoice(Song song) nothrow {
	if(transport is null || !loaded) return;
	try { pushBytes(song, song.offsets[Offsets.VOICE], 3); }
	catch(Throwable) { loaded = false; }
}

// Tear down on exit.
void shutdown() nothrow {
	if(transport is null) return;
	transport.shutdown();
	loaded = false;
}
