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
static import com.session;

// Thrown by a transport's connect() when the backend can never come up (e.g. the
// emulator executable is not on PATH). The core treats this as unrecoverable and
// falls back to local playback, rather than retrying forever.
class RemoteUnavailableException : Exception {
	this(string msg) { super(msg); }
}

// Control/command block layout — must match ultimate_host.acme ($0bf0). The
// request, keyjam fields and position seeds are one contiguous block so a
// restart/keyjam is a single writemem (each ~150ms on real hardware, so request
// count is what matters).
enum CTRL_ADDR = 0x0bf0;
enum {
	CTRL_MODE = 0,
	CTRL_REQ = 1,
	CTRL_SUBTUNE = 2,
	CTRL_KJNOTE = 3,
	CTRL_KJVOICE = 4,
	CTRL_KJINSTR = 5,
	CTRL_SEED_TRACKLO = 6,   // 6 bytes -> TRACKLO (applied by the shim on restart)
	CTRL_SEED_NEWSEQ = 12,   // 3 bytes -> NEWSEQ
	CTRL_SEED_VOICE = 15,    // 3 bytes -> VOICE (restart and keyjam)
	CTRL_BLOCK_LEN = 18,
	// Read-only byte the shim writes once at install: $ff=not detected yet,
	// 0=6581, 1=8580. Outside the command block, so writeCommand never touches it.
	CTRL_SIDMODEL = 18,
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
	// Read `len` bytes of C64 RAM from `addr` (DMA / monitor / readmem GET).
	ubyte[] readMem(int addr, int len);
	// Tear down on app exit: reset hardware / detach emulator. Must not throw.
	void shutdown() nothrow;
	// Short backend name for the UI (e.g. "Ultimate", "Vice").
	string name() nothrow;
}

private struct Region { int addr; int len; }
private __gshared ubyte[65536] shadow;
private __gshared Region[] regions;
private __gshared bool loaded = false;
private __gshared bool reloadPending = false;
// Cached resident image. Building it runs the (non-reentrant, leaky) ACME
// assembler, so we assemble ONCE per song and only re-upload the cached bytes on
// connection retries — re-assembling every retry would accumulate memory and
// eventually crash the assembler. Invalidated by markReload (song changed).
private __gshared ubyte[] cachedPrg;
private __gshared bool prgValid = false;
// SID model the shim detected on the target ("" until known). Reset on every
// (re)inject so a new backend/song re-detects. See pollSidModel / ctrl_sidmodel.
private __gshared string sidModel = "";
private __gshared bool sidModelKnown = false;
private __gshared MonoTime nextSidPoll;
private __gshared int sidPollTries = 0;
enum SID_POLL_MAX = 24;   // ~6s of 250ms polls, then give up (show backend name only)
// Last unsaved-changes state pushed to the File row; resynced after each inject.
private __gshared bool lastMod = false;
private __gshared bool modSynced = false;
private __gshared bool ntscMode = false;
private __gshared RemoteTransport transport; // null = no remote backend active
private __gshared MonoTime nextRetry;        // earliest next (re)establish attempt
private __gshared bool wasDown = false;       // one-shot "backend lost" logging
enum RETRY_BACKOFF = 2;                       // seconds between recovery attempts

bool isActive() nothrow { return transport !is null; }
bool isLoaded() nothrow { return loaded; }

// Name of the active backend for the UI ("Ultimate"/"Vice"), or "" if local.
string backendName() nothrow { return transport is null ? "" : transport.name(); }

// Detected SID model on the target ("6581"/"8580"), or "" until known.
string backendSidModel() nothrow { return sidModelKnown ? sidModel : ""; }

// Read back the shim's one-shot SID detection (ctrl_sidmodel). Driven from
// ensureLoaded once the shim is loaded — detection is tied to the injected
// shim's lifecycle, not the playback loop — so it is private. Self-throttling
// and a no-op once known. The shim writes 0/1 from install a moment after
// inject; until then it reads $ff. Read failures are non-fatal — never disturb
// playback/connection state.
private void pollSidModel() nothrow {
	if(transport is null || !loaded || sidModelKnown) return;
	if(sidPollTries >= SID_POLL_MAX) return;   // give up; never stutter a monitor backend forever
	if(MonoTime.currTime < nextSidPoll) return;
	nextSidPoll = MonoTime.currTime + dur!"msecs"(250);
	sidPollTries++;
	try {
		auto b = transport.readMem(CTRL_ADDR + CTRL_SIDMODEL, 1);
		if(b.length < 1) return;
		if(b[0] == 0)      { sidModel = "6581"; sidModelKnown = true; }
		else if(b[0] == 1) { sidModel = "8580"; sidModelKnown = true; }
		// $ff (or anything else): install hasn't written it yet — retry next tick.
		if(sidModelKnown)
			stderr.writeln("Remote: ", transport.name(), " SID detected: ", sidModel);
	}
	catch(Throwable) { /* transient read error; retry next tick */ }
}

// Mirror the host's unsaved-changes state to the on-target File row: a '*'
// ($2a) one space after the filename when modified, a blank when clean. Only
// writes when the state flips (each writeMem is ~150ms on real hardware). The
// File row is screen $0400 + 2*40 ("File: " = 6 chars, then the name).
private void pushModifiedFlag(Song song) nothrow {
	if(transport is null || !loaded) return;
	try {
		bool mod = com.session.state.songModified;
		if(modSynced && mod == lastMod) return;
		int len = cast(int)com.session.state.filename.length;
		if(len > 0)
			transport.writeMem(0x0400 + 2*40 + 6 + len + 1,
							   [cast(ubyte)(mod ? 0x2a : 0x20)]);
		lastMod = mod;
		modSynced = true;
	}
	catch(Throwable) {}
}

// Install a transport (called at startup by --ultimate / --vice wiring, and at
// runtime by the Properties dialog when switching backend). Shuts the previous
// transport down first and flags a re-inject so the next ensureLoaded brings the
// new backend up. Pass null to return to local-only playback.
void useTransport(RemoteTransport t) {
	if(transport !is null && transport !is t) {
		try { transport.shutdown(); } catch(Throwable) {}
	}
	transport = t;
	loaded = false;
	reloadPending = (t !is null);
	wasDown = false;
	sidModel = ""; sidModelKnown = false; sidPollTries = 0; modSynced = false;   // re-detect on the new backend
	nextRetry = MonoTime.zero;   // allow an immediate (re)connect attempt
}

// Switch back to local reSID playback (no remote backend).
void goLocal() { useTransport(null); }

void setMode(bool ntsc) { ntscMode = ntsc; }

// Mark that the resident image is stale (e.g. a different song was loaded);
// it will be rebuilt and re-injected on the next ensureLoaded().
void markReload() nothrow {
	reloadPending = true; loaded = false; prgValid = false;
	sidModel = ""; sidModelKnown = false; sidPollTries = 0; modSynced = false;   // fresh image re-detects the SID
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

// Ensure the resident image is up and current. Re-establishes the backend and
// re-uploads the player whenever it has been lost (emulator closed / connection
// dropped — flagged by a failed write setting loaded=false) or a reload is
// pending. Throttled by a backoff so a downed backend isn't hammered per frame.
void ensureLoaded(Song song) {
	if(transport is null) return;
	if(loaded && !reloadPending) {
		// Shim already injected: read back its one-shot SID probe (self-throttled,
		// no-op once known). Driven from here so the SID readback belongs to the
		// shim's lifecycle rather than the playback/frame loop.
		pollSidModel();
		pushModifiedFlag(song);   // mirror the host's unsaved-changes dot to the File row
		return;
	}
	// Backoff applies only between consecutive failed attempts (nextRetry is set
	// in the failure path), so the first recovery after a loss is immediate.
	if(MonoTime.currTime < nextRetry) return;
	try {
		transport.connect();   // (re)launch / (re)connect; idempotent
		// Assemble the resident image only when it's actually stale (first bring-up
		// or a song change). On a plain connection retry we reuse the cached bytes,
		// so the leaky ACME assembler is never re-run in a tight retry loop.
		if(!prgValid) {
			buildRegions(song);
			// host starts playback on Play; pass the loaded .ct name for the display.
			cachedPrg = buildResidentImage(song, ntscMode, false, true, true, true,
										   com.session.state.filename.idup);
			prgValid = true;
		}
		transport.runProgram(cachedPrg);
		shadow[] = song.memspace[];
		loaded = true;
		reloadPending = false;
		// Let the target boot + run install (which does the SID probe) uninterrupted
		// before the first readback — on a monitor backend each read halts the CPU,
		// which would otherwise race the autostart sequence.
		nextSidPoll = MonoTime.currTime + dur!"seconds"(3);
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
//
// One writemem per dirty *region*, covering its first..last changed byte in a
// single request. On real hardware a request is ~150ms fixed + ~6ms/KB, so an
// extra request costs as much as ~25KB of redundant payload: collapsing a
// region's scattered edits (and the clean bytes between them) into one write is
// always the win. Each region is bounded mirror data, so the span never reaches
// runtime/position vars or I/O.
void syncDeltas(Song song) {
	if(transport is null || !loaded) return;
	try {
		foreach(r; regions) {
			int end = r.addr + r.len;
			int lo = -1, hi = -1;
			foreach(i; r.addr .. end)
				if(song.memspace[i] != shadow[i]) { if(lo < 0) lo = i; hi = i; }
			if(lo < 0) continue;   // region unchanged
			int spanEnd = hi + 1;
			transport.writeMem(lo, song.memspace[lo .. spanEnd]);
			shadow[lo .. spanEnd] = song.memspace[lo .. spanEnd];
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

// Issue a one-shot command as a single writemem: the request byte, keyjam
// fields and the position seeds (read from song.memspace, where initPlayOffset
// / playNote already poked them) in one contiguous block from CTRL_REQ to the
// end. The shim applies the seeds to the player's own vars and clears the
// request next IRQ; the writemem DMA is atomic vs that IRQ (the Ultimate halts
// the CPU during DMA), so the request is never seen with half-written seeds.
private void writeCommand(Song song, ubyte req, ubyte subtune,
						  ubyte kjnote, ubyte kjvoice, ubyte kjinstr) {
	ubyte[CTRL_BLOCK_LEN - CTRL_REQ] b;   // CTRL_REQ .. end of block
	b[CTRL_REQ      - CTRL_REQ] = req;
	b[CTRL_SUBTUNE  - CTRL_REQ] = subtune;
	b[CTRL_KJNOTE   - CTRL_REQ] = kjnote;
	b[CTRL_KJVOICE  - CTRL_REQ] = kjvoice;
	b[CTRL_KJINSTR  - CTRL_REQ] = kjinstr;
	void seed(int dst, int off, int len) {
		b[dst - CTRL_REQ .. dst - CTRL_REQ + len] = song.memspace[off .. off + len];
	}
	seed(CTRL_SEED_TRACKLO, song.offsets[Offsets.TRACKLO], 6);
	seed(CTRL_SEED_NEWSEQ,  song.offsets[Offsets.NEWSEQ], 3);
	seed(CTRL_SEED_VOICE,   song.offsets[Offsets.VOICE], 3);
	transport.writeMem(CTRL_ADDR + CTRL_REQ, b[]);
}

// Start playback from a position. song.memspace must already hold the poked
// track/sequence offsets (initPlayOffset ran in audio.player); the shim seeds
// them into the player on restart.
void cmdRestart(Song song, ubyte subtune) {
	if(transport is null || !loaded) return;
	try {
		syncDeltas(song);
		writeCommand(song, cast(ubyte)REQ_RESTART, subtune, 0, 0, 0);
	}
	catch(Exception e) { stderr.writeln("Remote: restart failed: ", e.msg); loaded = false; }
}

void cmdKeyjam(Song song, int note, int voice, int instr) {
	if(transport is null || !loaded) return;
	try {
		syncDeltas(song);   // voice-on mask (set by playNote) rides along as the voice seed
		writeCommand(song, cast(ubyte)REQ_KEYJAM, 0,
					 cast(ubyte)note, cast(ubyte)voice, cast(ubyte)instr);
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
