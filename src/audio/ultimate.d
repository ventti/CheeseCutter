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
import core.thread : Thread;
import core.time : dur;
import audio.remote;

private class UltimateTransport : RemoteTransport {
	private string host;
	private int port;
	private string password;
	private bool firstBoot = true;

	this(string host, int port) {
		this.host = host;
		this.port = port;
		this.password = environment.get("CHEESECUTTER_ULTIMATE_PASSWORD", "");
	}

	private void httpRequest(string method, string path, const(ubyte)[] body) {
		string url = format("http://%s:%d%s", host, port, path);
		auto http = HTTP(url);
		http.method = method == "POST" ? HTTP.Method.post : HTTP.Method.put;
		if(password.length)
			http.addRequestHeader("X-Password", password);
		http.setPostData(cast(const(void)[])body, "application/octet-stream");
		http.onReceive = (ubyte[] data) => data.length;
		http.perform();
		auto code = http.statusLine.code;
		if(code == 403)
			throw new Exception("C64 Ultimate: 403 Forbidden — check CHEESECUTTER_ULTIMATE_PASSWORD.");
		if(code >= 400)
			throw new Exception(format("C64 Ultimate: HTTP %d for %s", code, path));
	}

	// Bring-up: reboot the machine once, then let it come back up. On recovery
	// (re-inject after a lost connection / reset) the run_prg in runProgram is
	// enough — it resets+loads+runs — so we don't reboot again.
	void connect() {
		if(firstBoot) {
			httpRequest("PUT", "/v1/machine:reboot", []);
			Thread.sleep(dur!"seconds"(4));
			firstBoot = false;
		}
	}

	void runProgram(const(ubyte)[] prg) {
		httpRequest("POST", "/v1/runners:run_prg", prg);
	}

	void writeMem(int addr, const(ubyte)[] data) {
		httpRequest("POST", format("/v1/machine:writemem?address=%04X", addr & 0xffff), data);
	}

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
