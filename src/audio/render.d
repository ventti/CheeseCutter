/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Offline audio export: fade-out, FLAC availability/transcode, and writing the
rendered PCM (from audio.player.renderPcm) to a .wav or .flac file.
*/

module audio.render;

import audio.wav;
static import audio.audio;
import ct.build : ExportOptions, ExportFormat;
import com.util : UserException;
import std.process;
import std.file;
import std.path : setExtension;
import std.format : format;

// Linearly fade the last `fadeSec` seconds of PCM to silence, in place. A fixed
// render length otherwise ends abruptly mid-note. Clamped to [0, 30] s.
void applyFade(short[] pcm, int fadeSec) {
	if(fadeSec < 0) fadeSec = 0;
	if(fadeSec > 30) fadeSec = 30;
	long fade = cast(long)fadeSec * audio.audio.freq;
	if(fade <= 0) return;
	if(fade > pcm.length) fade = pcm.length;
	size_t start = cast(size_t)(pcm.length - fade);
	foreach(i; 0 .. cast(size_t)fade) {
		// gain goes 1.0 -> 0.0 across the fade window
		double gain = 1.0 - (cast(double)i / cast(double)fade);
		pcm[start + i] = cast(short)(pcm[start + i] * gain);
	}
}

// Whether the `flac` CLI is on PATH (so the dialog can offer .flac). Cached.
bool flacAvailable() {
	static int cached = -1; // -1 unknown, 0 no, 1 yes
	if(cached < 0) {
		cached = 0;
		try {
			auto r = execute(["flac", "--version"]);
			if(r.status == 0) cached = 1;
		}
		catch(Exception e) { cached = 0; }
	}
	return cached == 1;
}

// Write the rendered PCM to `path` as WAV or FLAC per o.format, applying the
// fade-out first. FLAC is produced by transcoding a temporary WAV through the
// `flac` CLI. Throws UserException on a transcode failure.
void writeAudioFile(string path, short[] pcm, ref ExportOptions o) {
	applyFade(pcm, o.fadeSec);
	ubyte[] wav = wavBytes(pcm, audio.audio.freq);

	if(o.format == ExportFormat.Flac) {
		string tmp = path.setExtension("tmp.wav");
		std.file.write(tmp, wav);
		string err;
		try {
			auto r = execute(["flac", "--best", "-s", "-f", "-o", path, tmp]);
			if(r.status != 0)
				err = format("flac failed (exit %d): %s", r.status, r.output);
		}
		catch(ProcessException e) {
			err = "Could not run 'flac': " ~ e.msg;
		}
		try { std.file.remove(tmp); } catch(Exception e) {}
		if(err.length) throw new UserException(err);
	}
	else {
		std.file.write(path, wav);
	}
}
