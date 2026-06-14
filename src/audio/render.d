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
import std.math : pow, lround;
import std.algorithm : splitter;
import std.string : strip;

// Linearly fade the last `fadeSec` seconds of PCM to silence, in place. A fixed
// render length otherwise ends abruptly mid-note. Clamped to [0, 30] s. `rate`
// is the sample rate the PCM was rendered at.
void applyFade(short[] pcm, int fadeSec, int rate) {
	if(fadeSec < 0) fadeSec = 0;
	if(fadeSec > 30) fadeSec = 30;
	long fade = cast(long)fadeSec * rate;
	if(fade <= 0) return;
	if(fade > pcm.length) fade = pcm.length;
	size_t start = cast(size_t)(pcm.length - fade);
	foreach(i; 0 .. cast(size_t)fade) {
		// gain goes 1.0 -> 0.0 across the fade window
		double gain = 1.0 - (cast(double)i / cast(double)fade);
		pcm[start + i] = cast(short)(pcm[start + i] * gain);
	}
}

// Peak-normalize PCM in place so the loudest sample reaches `targetDb` dBFS.
// No-op on silence (or when the signal already sits below a meaningful peak).
void normalizePcm(short[] pcm, double targetDb) {
	int peak = 0;
	foreach(s; pcm) {
		int a = s < 0 ? -cast(int)s : cast(int)s;
		if(a > peak) peak = a;
	}
	if(peak <= 0) return;
	double targetPeak = pow(10.0, targetDb / 20.0) * 32767.0;
	double gain = targetPeak / cast(double)peak;
	foreach(ref s; pcm) {
		long v = lround(s * gain);
		if(v > 32767) v = 32767;
		else if(v < -32768) v = -32768;
		s = cast(short)v;
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
	int rate = o.wavSampleRate > 0 ? o.wavSampleRate : audio.audio.freq;
	if(o.normalize) normalizePcm(pcm, o.normalizeDb);
	applyFade(pcm, o.fadeSec, rate);
	ubyte[] wav = wavBytes(pcm, rate, o.wavBits);

	if(o.format == ExportFormat.Flac) {
		string tmp = path.setExtension("tmp.wav");
		std.file.write(tmp, wav);
		string err;
		try {
			// Build the flac command from the user-editable options string; the
			// -s/-f/-o/input args stay structural (silent / force / output / source).
			string[] userArgs;
			foreach(tok; o.flacOptions.splitter(' '))
				if(tok.strip().length) userArgs ~= tok.strip();
			string[] args = "flac" ~ userArgs ~ ["-s", "-f", "-o", path, tmp];
			auto r = execute(args);
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
