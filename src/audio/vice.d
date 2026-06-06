/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

VICE (x64sc) playback transport over the binary monitor.

This is the TCP transport for the shared remote-playback core (audio.remote):
the live song image + resident shim is injected once per song (AUTOSTART of a
temp PRG, the run_prg equivalent), and edited song-data bytes are pushed with
MEM_SET into the "ram" bank thereafter. The user gives either host[:port] of a
running `x64sc -binarymonitor`, or a path to the x64sc executable, in which case
we launch it ourselves and connect.

Binary monitor protocol (VICE): see audio.remote for the playback model.
*/
module audio.vice;

import std.socket;
import std.process;
import std.file : exists, isDir, write, tempDir;
import std.path : buildPath;
import std.string : lastIndexOf;
import std.conv : to;
import std.format;
import std.stdio;
import core.thread : Thread;
import core.time : dur;
import audio.remote;

enum DEFAULT_PORT = 6502;

// Binary monitor command types.
private enum {
	CMD_MEM_GET = 0x01,
	CMD_MEM_SET = 0x02,
	CMD_PING = 0x81,
	CMD_BANKS_AVAILABLE = 0x82,
	CMD_EXIT = 0xaa,
	CMD_RESET = 0xcc,
	CMD_AUTOSTART = 0xdd,
}

// Bound every monitor read: VICE may briefly not service the socket (slow boot,
// monitor not yet ready). Without this a stuck read would block ccutter's UI
// thread forever (the "spinning beachball"). Normal responses arrive in <50ms.
private enum RECV_TIMEOUT = 4;  // seconds

private __gshared bool viceDebug = false;  // set from CCVICE_DEBUG

private class ViceTransport : RemoteTransport {
	private string host;
	private int port;
	private string execPath;   // null => attach to a running monitor
	private TcpSocket sock;
	private ushort ramBank;
	private uint reqId;
	private Pid child;

	this(string host, int port, string execPath) {
		this.host = host;
		this.port = port;
		this.execPath = execPath;
	}

	// ------------------------------------------------------------ socket I/O

	private void closeSock() {
		if(sock !is null) { try { sock.close(); } catch(Throwable) {} sock = null; }
	}

	private void sendAll(const(ubyte)[] data) {
		size_t sent = 0;
		while(sent < data.length) {
			auto n = sock.send(data[sent .. $]);
			if(n == Socket.ERROR || n == 0) {
				closeSock();   // connection unusable -> force reconnect on recovery
				throw new Exception("VICE monitor: send failed");
			}
			sent += n;
		}
	}

	private void readExact(ubyte[] buf) {
		size_t got = 0;
		while(got < buf.length) {
			auto n = sock.receive(buf[got .. $]);
			if(n == Socket.ERROR || n == 0) {
				closeSock();
				throw new Exception("VICE monitor: no response (timeout) or connection closed");
			}
			got += n;
		}
	}

	private static void appendLE16(ref ubyte[] b, ushort v) {
		b ~= cast(ubyte)(v & 0xff); b ~= cast(ubyte)((v >> 8) & 0xff);
	}
	private static void appendLE32(ref ubyte[] b, uint v) {
		b ~= cast(ubyte)(v & 0xff); b ~= cast(ubyte)((v >> 8) & 0xff);
		b ~= cast(ubyte)((v >> 16) & 0xff); b ~= cast(ubyte)((v >> 24) & 0xff);
	}

	// Send a command and return its response body, skipping async events.
	private ubyte[] command(ubyte cmd, const(ubyte)[] body) {
		if(sock is null) throw new Exception("VICE monitor: not connected");
		uint id = ++reqId;
		ubyte[] f;
		f ~= 0x02; f ~= 0x02;            // STX, API version
		appendLE32(f, cast(uint)body.length);
		appendLE32(f, id);
		f ~= cmd;
		f ~= body;
		if(viceDebug) { stderr.writefln("vice: > cmd=0x%02x id=%d bodylen=%d", cmd, id, body.length); stderr.flush(); }
		sendAll(f);
		// Read frames until we see our request id (events use id 0xffffffff).
		for(;;) {
			ubyte[12] hdr;
			readExact(hdr[]);
			if(hdr[0] != 0x02) {
				closeSock();   // stream desync -> reconnect
				throw new Exception("VICE monitor: bad response header");
			}
			uint blen = hdr[2] | (hdr[3] << 8) | (hdr[4] << 16) | (hdr[5] << 24);
			ubyte type = hdr[6];
			ubyte err = hdr[7];
			uint rid = hdr[8] | (hdr[9] << 8) | (hdr[10] << 16) | (hdr[11] << 24);
			ubyte[] rbody;
			rbody.length = blen;
			if(blen) readExact(rbody);
			if(viceDebug) { stderr.writefln("vice:   < type=0x%02x err=0x%02x rid=%d len=%d%s",
				type, err, rid, blen, rid == id ? " [RESP]" : " [event]"); stderr.flush(); }
			if(rid != id) continue; // async event for someone else
			if(err != 0)
				throw new Exception(format("VICE monitor: error 0x%02x (response type 0x%02x)", err, type));
			return rbody;
		}
	}

	// ------------------------------------------------------------ bring-up

	private void launch() {
		auto args = [execPath, "-binarymonitor", "-binarymonitoraddress",
					 format("ip4://%s:%d", host, port)];
		// ccutter owns the terminal (full-screen TUI), so keep VICE's stdio off
		// it: feed the child /dev/null and discard its output.
		auto devNullIn = File("/dev/null", "rb");
		auto devNullOut = File("/dev/null", "wb");
		try {
			// Not detached, so we can tryWait() it for liveness (relaunch on
			// close). On ccutter exit the child is simply orphaned and keeps
			// running (we never kill it in shutdown()).
			child = spawnProcess(args, devNullIn, devNullOut, devNullOut, null);
		}
		catch(ProcessException e) {
			// Executable not found / not runnable: unrecoverable, don't retry.
			throw new RemoteUnavailableException(
				format("could not launch '%s': %s", execPath, e.msg));
		}
		if(viceDebug) stderr.writefln("vice: launched %s", execPath);
	}

	// Open a fresh TCP connection to the monitor (single attempt). Throws on
	// failure; the caller's loop retries.
	private void openSocket() {
		sock = new TcpSocket(new InternetAddress(host, cast(ushort)port));
		sock.blocking = true;
		// Cap blocking reads/writes so a stuck monitor can't hang the UI.
		sock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(RECV_TIMEOUT));
		sock.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, dur!"seconds"(RECV_TIMEOUT));
	}

	private ushort queryRamBank() {
		auto b = command(CMD_BANKS_AVAILABLE, []);
		if(b.length < 2) return 0;
		ushort count = cast(ushort)(b[0] | (b[1] << 8));
		size_t p = 2;
		foreach(i; 0 .. count) {
			if(p >= b.length) break;
			ubyte itemSize = b[p];
			if(p + 4 > b.length) break;
			ushort id = cast(ushort)(b[p + 1] | (b[p + 2] << 8));
			ubyte nameLen = b[p + 3];
			if(p + 4 + nameLen > b.length) break;
			string name = cast(string)b[p + 4 .. p + 4 + nameLen].idup;
			if(name == "ram") return id;
			p += 1 + itemSize;
		}
		return 0; // fall back to the default bank
	}

	private void setRecvTimeout(int secs) {
		sock.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(secs));
	}

	// Ensure a working monitor connection, (re)launching x64sc if we own it.
	// Idempotent: a no-op when already connected; on recovery it relaunches a
	// closed emulator and/or reconnects a dropped socket, then re-confirms the
	// ram bank. The connection drops are surfaced by closeSock() in command().
	void connect() {
		// (Re)launch the emulator if we own it and it isn't running.
		if(execPath !is null) {
			bool alive = (child !is null) && !tryWait(child).terminated;
			if(!alive) { launch(); closeSock(); }   // new instance -> reconnect
		}
		if(sock !is null) return;   // already connected

		// (Re)connect. The TCP port can accept before x64sc's emulation loop is
		// actually servicing the monitor (and a freshly-launched x64sc needs a
		// few seconds to boot), so probe with a short timeout and retry; each
		// failed probe closes the socket (command()), so reopen as needed.
		Exception last;
		foreach(attempt; 0 .. 40) {
			if(sock is null) {
				try { openSocket(); }
				catch(Exception e) { last = e; Thread.sleep(dur!"msecs"(300)); continue; }
			}
			setRecvTimeout(1);
			try {
				ramBank = queryRamBank();
				setRecvTimeout(RECV_TIMEOUT);
				if(viceDebug) stderr.writefln("vice: connected to %s:%d", host, port);
				return;
			}
			catch(Exception e) {
				last = e;
				if(viceDebug) stderr.writefln("vice: monitor not ready (%s), retry %d", e.msg, attempt);
				Thread.sleep(dur!"msecs"(300));
			}
		}
		throw new Exception("VICE monitor not responding: " ~ (last is null ? "" : last.msg));
	}

	// Resume emulation. VICE re-enters (stops) the monitor to service each
	// command, so after writing we must EXIT or the C64 stays frozen (silent).
	private void resume() {
		command(CMD_EXIT, []);
	}

	// ------------------------------------------------------------ commands

	void runProgram(const(ubyte)[] prg) {
		// AUTOSTART loads + runs a host file: write the PRG to a temp file and
		// have VICE reset and RUN it (the image's BASIC SYS stub starts the shim).
		string path = buildPath(tempDir(), "cheesecutter_vice.prg");
		write(path, prg);
		if(path.length > 255)
			throw new Exception("VICE monitor: temp PRG path too long");
		ubyte[] body;
		body ~= 1;               // run after load
		appendLE16(body, 0);     // file index
		body ~= cast(ubyte)path.length;
		body ~= cast(ubyte[])path.dup;
		command(CMD_AUTOSTART, body);
	}

	// Read C64 RAM (for diagnostics). Returns the bytes [start, end].
	ubyte[] readMem(int start, int end) {
		ubyte[] body;
		body ~= 0;                                    // side effects: none
		appendLE16(body, cast(ushort)(start & 0xffff));
		appendLE16(body, cast(ushort)(end & 0xffff));
		body ~= 0;                                    // memspace: main memory
		appendLE16(body, ramBank);
		auto r = command(CMD_MEM_GET, body);
		if(r.length < 2) return [];
		int n = r[0] | (r[1] << 8);
		return r[2 .. 2 + n];
	}

	void writeMem(int addr, const(ubyte)[] data) {
		if(data.length == 0) return;
		int endAddr = (addr + cast(int)data.length - 1) & 0xffff;
		ubyte[] body;
		body ~= 0;                                   // side effects: none
		appendLE16(body, cast(ushort)(addr & 0xffff)); // start
		appendLE16(body, cast(ushort)endAddr);         // end (inclusive)
		body ~= 0;                                   // memspace: main memory
		appendLE16(body, ramBank);                   // write RAM (under ROM)
		body ~= data;
		command(CMD_MEM_SET, body);
		resume();  // keep the C64 running after the DMA write
	}

	void shutdown() nothrow {
		// Leave any launched x64sc running so the user keeps hearing it. VICE
		// "opens" (pauses) the monitor when a client disconnects, so resume
		// emulation with EXIT before detaching, then close the connection.
		try {
			if(sock !is null) {
				try { command(CMD_EXIT, []); } catch(Throwable) {} // resume before detaching
				sock.close();
				sock = null;
			}
		}
		catch(Throwable) {}
	}
}

// Enable the VICE backend. `target` is empty (launch `x64sc` from PATH),
// host[:port] of a running `x64sc -binarymonitor`, or a path to an x64sc
// executable to launch.
void configure(string target, int portOverride, bool ntsc) {
	viceDebug = environment.get("CCVICE_DEBUG", "").length > 0;
	string host;
	int port;
	string execPath = null;
	if(target.length == 0) {
		execPath = "x64sc";   // resolved via PATH by spawnProcess
		host = "127.0.0.1";
		port = portOverride > 0 ? portOverride : DEFAULT_PORT;
	}
	else if(exists(target) && !isDir(target)) {
		execPath = target;
		host = "127.0.0.1";
		port = portOverride > 0 ? portOverride : DEFAULT_PORT;
	}
	else {
		auto idx = target.lastIndexOf(':');
		if(idx >= 0) {
			host = target[0 .. idx];
			port = to!int(target[idx + 1 .. $]);
		}
		else {
			host = target;
			port = portOverride > 0 ? portOverride : DEFAULT_PORT;
		}
	}
	audio.remote.setMode(ntsc);
	active = new ViceTransport(host, port, execPath);
	audio.remote.useTransport(active);
}

private __gshared ViceTransport active;

// Diagnostic: read the player's runtime vars ($1900-$1990) twice and report how
// many bytes changed — nonzero proves the emulated C64 is actually running the
// player. Returns -1 if no VICE transport is active.
int debugRunningCheck() {
	if(active is null) return -1;
	auto a = active.readMem(0x1900, 0x1990);
	active.resume();
	Thread.sleep(dur!"msecs"(500));
	auto b = active.readMem(0x1900, 0x1990);
	active.resume();
	int diff = 0;
	foreach(i; 0 .. (a.length < b.length ? a.length : b.length))
		if(a[i] != b[i]) diff++;
	return diff;
}

// Test hook: simulate the user closing x64sc — kill the launched emulator and
// drop the monitor connection, so the recovery path can be exercised headless.
void debugKillEmulator() {
	if(active is null) return;
	try { if(active.child !is null) kill(active.child); } catch(Throwable) {}
	active.closeSock();
}
