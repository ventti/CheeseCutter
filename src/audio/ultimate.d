/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

C64 Ultimate (1541U / Ultimate64) playback transport.

This is the HTTP/REST transport for the shared remote-playback core
(audio.remote): the player + data are injected once per song via run_prg;
thereafter only edited song-data bytes are pushed via writemem (DMA). The
orchestration (what to inject, which regions to mirror, the control block) lives
in audio.remote; this module only speaks the Ultimate's REST API.
*/
module audio.ultimate;

import std.net.curl;
import std.format;
import std.process : environment;
import std.stdio;
import core.time : dur;
import audio.remote;

private class UltimateTransport : RemoteTransport {
	private string host;
	private int port;
	private string password;

	this(string host, int port) {
		this.host = host;
		this.port = port;
		this.password = environment.get("CHEESECUTTER_ULTIMATE_PASSWORD", "");
	}

	private void httpRequest(string method, string path, const(ubyte)[] body) {
		// A fresh handle per request: the Ultimate's HTTP server answers
		// Connection: close and tears the socket down after every response
		// (verified on Ultimate64 fw — keep-alive is refused even when asked),
		// so a kept-alive handle buys nothing; each request pays a fresh ~150ms
		// connect+write. The lever for speed is fewer requests, not connection
		// reuse — see audio.remote (one writemem per region; one per command).
		string url = format("http://%s:%d%s", host, port, path);
		auto http = HTTP(url);
		final switch(method) {
			case "GET":  http.method = HTTP.Method.get;  break;
			case "POST": http.method = HTTP.Method.post; break;
			case "PUT":  http.method = HTTP.Method.put;  break;
		}
		// Fail fast on a dead/wrong host: a live Ultimate answers in well under a
		// second, so cap the TCP connect at 3s. Without this a wrong IP hangs the
		// whole (synchronous, main-thread) ensureLoaded/connect at startup. The
		// transfer itself is left untimed — a real run_prg/writemem of the 64K
		// image is sub-second but we don't want to abort a slow-but-live upload.
		http.connectTimeout = dur!"seconds"(3);
		if(password.length)
			http.addRequestHeader("X-Password", password);
		if(method != "GET")
			http.setPostData(cast(const(void)[])body, "application/octet-stream");
		http.onReceive = (ubyte[] data) => data.length;
		http.perform();
		auto code = http.statusLine.code;
		if(code == 403)
			throw new Exception("C64 Ultimate: 403 Forbidden — check CHEESECUTTER_ULTIMATE_PASSWORD.");
		if(code == 404 && path.length >= 8 && path[0 .. 8] == "/v1/runn")
			// run_prg/load_prg 404 even though the REST API answers: the C64 itself
			// isn't in a runnable state (powered off, or sitting in the Ultimate menu).
			throw new Exception("C64 Ultimate: run_prg returned 404 — is the C64 powered on and out of the Ultimate menu?");
		if(code >= 400)
			throw new Exception(format("C64 Ultimate: HTTP %d for %s", code, path));
	}

	// Liveness probe only. We deliberately do NOT issue /v1/machine:reboot: a
	// run_prg already resets the C64, loads via DMA and runs it, whereas a reboot
	// takes the whole Ultimate offline for many seconds (and on some firmware it
	// doesn't auto-recover). The GET fails fast (3s) on a dead/wrong host so the
	// core detects "down" before building+uploading the ~64K image.
	void connect() {
		httpRequest("GET", "/v1/version", []);
	}

	void runProgram(const(ubyte)[] prg) {
		httpRequest("POST", "/v1/runners:run_prg", prg);
	}

	void writeMem(int addr, const(ubyte)[] data) {
		httpRequest("POST", format("/v1/machine:writemem?address=%04X", addr & 0xffff), data);
	}

	// readmem is a GET that returns the bytes as the body (works even while the
	// POST handlers are unavailable). We capture the body here rather than via the
	// shared httpRequest, whose onReceive discards it.
	ubyte[] readMem(int addr, int len) {
		ubyte[] buf;
		string url = format("http://%s:%d/v1/machine:readmem?address=%04X&length=%d",
							 host, port, addr & 0xffff, len);
		auto http = HTTP(url);
		http.method = HTTP.Method.get;
		http.connectTimeout = dur!"seconds"(3);
		if(password.length)
			http.addRequestHeader("X-Password", password);
		http.onReceive = (ubyte[] data) { buf ~= data; return data.length; };
		http.perform();
		auto code = http.statusLine.code;
		if(code >= 400)
			throw new Exception(format("C64 Ultimate: HTTP %d for readmem", code));
		return buf;
	}

	string name() nothrow { return "Ultimate"; }

	void shutdown() nothrow {
		try { httpRequest("PUT", "/v1/machine:reset", []); }
		catch(Throwable e) { try { stderr.writeln("Ultimate: reset failed: ", e.msg); } catch(Throwable) {} }
	}
}

// Enable the Ultimate backend. Call once at startup when --ultimate is given.
void configure(string host, int port, bool ntsc) {
	audio.remote.setMode(ntsc);
	audio.remote.useTransport(new UltimateTransport(host, port));
}
