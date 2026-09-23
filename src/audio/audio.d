/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

SDL audio device setup and the mix buffer that carries reSID output to the sound card.
*/

module audio.audio;
import derelict.sdl2.sdl;
import audio.resid.filter;
import audio.player;
import audio.callback;
static import audio.remote;
static import audio.visualizer;
import std.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import std.conv;

enum MIXBUF_MUL = 2;
__gshared SDL_AudioSpec audiospec;
__gshared bool audioInited = false;
__gshared int framerate = 50;
__gshared int multiplier;
__gshared int freq = 48000, bufferSize = 2048;
__gshared private int callbackCounter = 0;
__gshared private int bufferUsed; // in samples
__gshared private int callbackInterval;
__gshared short* mixbuf = null;

// --- Keyjam note capture (for the oscilloscope's recorded-waveform view) ---
// A few seconds of the reSID mix output, recorded from a keyjam note-on, plus a
// per-frame gate-bit timeline of the played voice. Written by the audio callback
// (audio_callback_2), read by the UI scope draw. No lock — like sidreg, minor
// tearing between the two threads is visually harmless.
// §16 START-alignment: reserve a few extra blocks so the pre-gate hard/soft-restart
// phase (captured before the note's gate goes high) fits ahead of the audible onset.
enum int CAPTURE_LEAD_FRAMES = 16;
__gshared short[] captureBuf;      // recorded samples
__gshared ubyte[] captureGate;     // gate bit (0/1), one per captureFrameSamples block
__gshared int captureCap;          // buffer capacity in samples
__gshared int captureLen;          // samples recorded so far
__gshared int captureGateLen;      // gate entries recorded so far
__gshared int captureOnsetSample;  // §16 sample offset in captureBuf of the FIRST
                                   // gate-high block = the audible onset. Maps to
                                   // axis tick 0 (== rec* frame 0, reset on the same
                                   // gate 0->1 edge). -1 until the gate first opens.
__gshared bool capturing;
__gshared int captureVoice;        // SID voice (0..2) whose gate we track
__gshared int captureInstr = -1;   // instrument # this keyjam capture is of (set by
                                   // audio.player.playNote on the struck note). Lets
                                   // the Sound Editor match a keyjam recording to the
                                   // viewed instrument WITHOUT the player-memory
                                   // instrument read, which is wrong for old players.
__gshared int captureFrameSamples; // samples per gate entry (= callbackInterval)
__gshared int captureSilenceRun;   // consecutive near-silent samples recorded
__gshared bool captureWasLoud;     // §16.3: seen an audibly-loud block yet? The
                                   // decay-to-silence stop is gated on this so a
                                   // quiet (slow/low) attack ONSET can't end the
                                   // recording before the note is ever heard.

// Begin recording the given voice's keyjam note from scratch.
void captureStart(int voice) {
	captureVoice = (voice < 0 || voice > 2) ? 0 : voice;
	captureFrameSamples = callbackInterval > 0 ? callbackInterval : (freq / framerate);
	// §16 END-alignment: size the capture to the SAME window (in player ticks) the
	// rec* visualizer arrays hold (RECORD_FRAMES), so the Output waveform spans the
	// note's full recorded extent at ANY multiplier — instead of a fixed
	// CAPTURE_SECONDS that truncated long/held notes (a 12 s note stopped at 3 s).
	// Sizing by ticks (not seconds) keeps it mult-correct: captureFrameSamples already
	// scales with the multiplier, so the same tick count covers the same rec window.
	int capFrames = audio.visualizer.RECORD_FRAMES + CAPTURE_LEAD_FRAMES;
	int cap = captureFrameSamples * capFrames;
	if(cast(int)captureBuf.length != cap) {
		captureBuf.length = cap;
		captureGate.length = capFrames + 4;   // one gate entry per captured block
	}
	captureCap = cap;
	captureLen = 0;
	captureGateLen = 0;
	captureSilenceRun = 0;
	captureWasLoud = false;
	captureOnsetSample = -1;
	capturing = true;
}
void captureStop() nothrow { capturing = false; }

// Record one freshly-mixed block (`n` samples at `block`) into the keyjam capture:
// copy the samples, append the played voice's gate bit, and apply the decay-to-
// silence stop. Shared by the live callback (audio_callback_2) and the offline
// renderKeyjamCapture path so both record identically. No-op unless capturing.
private void captureBlock(short* block, int n) nothrow {
	if(!capturing || captureLen >= captureCap) return;
	if(captureLen + n > captureCap) n = captureCap - captureLen;
	memcpy(captureBuf.ptr + captureLen, block, n * short.sizeof);
	captureLen += n;
	int gbit = sidreg[4 + captureVoice*7] & 1;
	if(captureGateLen < cast(int)captureGate.length)
		captureGate[captureGateLen++] = cast(ubyte)gbit;
	// §16 START-alignment: the FIRST gate-high block is the note's audible onset — the
	// audio rendered from the tick that opened the gate, the same tick rec* frame 0 is
	// recorded on. Everything before it is the hard/soft-restart pre-roll (gate low).
	// Remember its sample offset so the Output band can put it at axis tick 0, aligned
	// with the ADSR/Freq/Pulse/Filter/Gate bands (which begin at that gate 0->1 edge).
	if(gbit && captureOnsetSample < 0)
		captureOnsetSample = captureLen - n;
	// Stop once the note has decayed to silence (after a minimum record length):
	// the recording ends at the release tail instead of padding to CAPTURE_SECONDS.
	int peak = 0;
	for(int k = 0; k < n; k++) {
		int a = block[k]; if(a < 0) a = -a;
		if(a > peak) peak = a;
	}
	enum int SILENCE = 200;
	if(peak >= SILENCE) captureWasLoud = true;   // note has become audible
	if(peak < SILENCE) captureSilenceRun += n; else captureSilenceRun = 0;
	// §16.3: only allow the decay-to-silence stop AFTER the note has actually been
	// heard (captureWasLoud). A slow/quiet attack ramps up through near-silence for
	// many blocks; without this gate the run of quiet onset samples would trip the
	// stop and cut the Output waveform short of the real note. The hard cap on
	// captureCap still bounds the recording regardless.
	// §16.4: additionally require the note's gate to have gone OFF (gbit == 0) before
	// the decay-to-silence stop may fire. While the gate is HIGH the note is still
	// sounding, so a momentary quiet dip within a still-gated note — an arp/chord or a
	// pulse-width sweep (e.g. wave $0F + PW sweep) that passes through near-silence —
	// must NOT end the capture, which truncated the Output waveform to a tiny onset
	// blip. The capture now spans attack->sustain->release; the capacity cap still
	// terminates a note held (gate-on) indefinitely.
	bool gateOff = (gbit == 0);
	if((gateOff && captureWasLoud && captureLen > freq / 4 && captureSilenceRun > freq / 6)
	   || captureLen >= captureCap) capturing = false;
}

// Offline (no audio device) keyjam-note capture. With the SDL callback locked out,
// runs `ticks` player ticks of the SAME per-tick loop audio_callback_2 uses —
// sid_fillbuffer -> captureBlock (samples+gate) -> audio_frame — filling BOTH
// captureBuf (the Output scope) and the rec* visualizer arrays deterministically,
// exactly as a real device would. Requires a keyjam note to have armed capture
// (via playNote/captureStart) first; otherwise captureBlock is a no-op. This is
// what makes the Output waveform verifiable headless (the ff:/dummy paths never
// fill captureBuf). Read-only re: song data — mirrors renderPcm's device handling.
void renderKeyjamCapture(int ticks) {
	if(!audioInited || mixbuf is null || ticks < 1) return;
	int interval = callbackInterval > 0 ? callbackInterval : (freq / framerate);
	if(interval < 1) return;
	if(interval > bufferSize * MIXBUF_MUL) interval = bufferSize * MIXBUF_MUL;
	SDL_LockAudio();   // keep the device callback off the engine during the render
	for(int i = 0; i < ticks; i++) {   // captureBlock self-stops at the release tail
		int t = sid_fillbuffer(mixbuf, interval, audio.callback.cyclesPerFrame);
		captureBlock(mixbuf, t);
		audio.callback.recordRenderedSidTick();
		audio_frame();
	}
	SDL_UnlockAudio();
}


extern(C) {
	extern __gshared char[0x19] sidreg;
	extern __gshared int residdelay;
	extern __gshared int sid_init(int, Filterparams*, int, int, int, int, int) nothrow ;
	extern __gshared int sid_fillbuffer(short *, int, int) nothrow ;
	extern __gshared int sid_close();
	__gshared void function() nothrow callback;


	int audio_init(int fr, void function() nothrow cb) {
		SDL_AudioSpec requested;

		if(audioInited) return 0;

		audioInited = true;

		framerate = fr;

		if(bufferSize < freq / framerate) {
			// fprintf(stderr,"Minimum buffer size is %d bytes.\n", freq / framerate);
			return -1;
		}

		requested.freq = freq;
		requested.format = AUDIO_S16LSB;
		requested.channels = 1;
		requested.samples = cast(ushort) bufferSize;

		requested.callback = &audio_callback_2;
		
		requested.userdata = null;
		callback = cb;
		// Pass a null `obtained` so SDL guarantees the callback is fed our
		// requested format (S16 mono), converting from the hardware format
		// internally. With a non-null `obtained`, SDL_OpenAudio allows any
		// change and hands back the native device format -- on Windows
		// (WASAPI) that is float32/stereo, which the engine cannot consume
		// (it would fail with "Incorrect audio format obtained").
		if(SDL_OpenAudio(&requested, null) < 0) {
			writeln("Could not open audio: ", to!string(SDL_GetError()));
			return -1;
		}
		audiospec = requested;
		bufferSize = audiospec.samples;
		mixbuf = cast(short *)malloc(bufferSize * short.sizeof * MIXBUF_MUL);
        memset(mixbuf, 0, bufferSize * short.sizeof * MIXBUF_MUL);
		setCallMultiplier(1);
		return 0;
	}

	int getbufsize() {
		return cast(int)(bufferSize * MIXBUF_MUL);
	}

	// Samples filled per player frame (freq / framerate). The offline audio
	// render (audio.player.renderPcm) chunks its manual fill loop with it, the
	// same way audio_callback_2 does.
	int getCallbackInterval() {
		return callbackInterval;
	}

	void audio_close() {
		SDL_CloseAudio();
		if(mixbuf) free(mixbuf);
		sid_close();
	}
	
	void reset() {
		bufferUsed = callbackCounter = 0;
	}

	void setCallMultiplier(int m) {
		if(m < 1 || m > 16) return;
		if(m == multiplier) return;
		SDL_LockAudio();
		multiplier = m;
		framerate = 50 * m;
		callbackInterval = audiospec.freq / framerate;
		reset();
		SDL_UnlockAudio();
	}

	void audio_callback(void *data, ubyte* stream, int len) nothrow {
		int samplesRequested = cast(int) (len / short.sizeof);
		int total = 0,todo = 0,t = 0;
		int steps;
		if(!audio.player.isPlaying()) return;
		while(total < samplesRequested) {
			todo = samplesRequested - total;
			assert(todo >= 0);
			if(callbackCounter + todo >= callbackInterval) {
				int c = callbackInterval - callbackCounter;
				assert(c > 0);
				t = sid_fillbuffer(cast(short*)stream + total,
								   c, 0);
				audio.callback.recordRenderedSidTick();
				(*callback)();
				callbackCounter -= callbackInterval;
				assert(callbackCounter + todo >= 0);
			}
			else {
				assert(total + todo <= samplesRequested);
				t = sid_fillbuffer(cast(short*)stream + total,
								   todo, 0);
				
			}
			total += t;
			callbackCounter += t;
			steps++;
		}
		assert(total == samplesRequested);
	}

	__gshared void audio_callback_2(void *data, ubyte* stream, int len) nothrow {
		int samplesRequested = cast(int) (len / short.sizeof);
		int i,t;
		if(!audio.player.isPlaying()) {
            //memcpy(stream, cast(ubyte*)mixbuf, len);
            memset(stream, 0, len);
            return;
        }
		while((bufferUsed + callbackInterval) <= bufferSize * MIXBUF_MUL) {
			int prevUsed = bufferUsed;
			t = sid_fillbuffer(mixbuf+bufferUsed, callbackInterval, cyclesPerFrame);
			// Record the fresh block into the keyjam capture (samples + gate bit).
			captureBlock(mixbuf + prevUsed, t);
			audio.callback.recordRenderedSidTick();
			bufferUsed += t;
			(*callback)();
		}

		// With a remote backend the real/emulated C64 is the only sound
		// source; keep the emulation running (for visualizer/timer) but mute.
		if(audio.remote.isActive())
			memset(stream, 0, len);
		else
			memcpy(stream, cast(ubyte*)mixbuf, len);
		bufferUsed -= samplesRequested;
		if(bufferUsed < 0) {
      //			writeln("Audio buffer underrun ", bufferUsed);
			bufferUsed = 0;
		}

		short* pi, po;
		for(i = 0, pi = mixbuf, po = mixbuf + samplesRequested;
			i < bufferSize * MIXBUF_MUL - samplesRequested; i++) {
			*(pi++) = *(po++);
		}
	}
}

import std.string : toStringz, fromStringz;

// (Re)open the SDL audio device with the current freq/bufferSize and our
// callback, (re)allocating the mix buffer. Mirrors audio_init's open path but is
// safe to call again at runtime (after SDL_CloseAudio) for a driver swap; it
// recomputes callbackInterval for the current framerate and leaves reSID alone.
private int openDevice() {
	SDL_AudioSpec requested;
	requested.freq = freq;
	requested.format = AUDIO_S16LSB;
	requested.channels = 1;
	requested.samples = cast(ushort) bufferSize;
	requested.callback = &audio_callback_2;
	requested.userdata = null;
	if(SDL_OpenAudio(&requested, null) < 0) {
		writeln("Could not open audio: ", to!string(SDL_GetError()));
		return -1;
	}
	audiospec = requested;
	bufferSize = audiospec.samples;
	if(mixbuf) free(mixbuf);
	mixbuf = cast(short *)malloc(bufferSize * short.sizeof * MIXBUF_MUL);
	memset(mixbuf, 0, bufferSize * short.sizeof * MIXBUF_MUL);
	if(framerate > 0) callbackInterval = audiospec.freq / framerate;
	reset();
	return 0;
}

// Explicit song-play commands reopen even an apparently healthy device: after
// sleep some backends report PLAYING while callbacks have stopped. Keep reSID,
// the selected driver and playback position intact (Shift-F3 can resume tracking).
// Called on the UI thread only, never for note entry or automatic loop restarts.
bool resetPlaybackDevice() {
	bool resume = audio.player.isPlaying();
	// Closing joins the callback; do not hold its audio lock across teardown.
	SDL_CloseAudio();
	if(openDevice() < 0) return false;
	SDL_PauseAudio(resume ? 0 : 1);
	return true;
}

// SDL audio drivers compiled into this build (e.g. "coreaudio", "dummy"), for
// the Properties dialog to choose from.
string[] availableAudioDrivers() {
	string[] r;
	int n = SDL_GetNumAudioDrivers();
	for(int i = 0; i < n; i++) {
		auto p = SDL_GetAudioDriver(i);
		if(p !is null) r ~= to!string(fromStringz(p));
	}
	return r;
}

// The driver currently in use ("" if none/unknown).
string currentAudioDriver() {
	auto p = SDL_GetCurrentAudioDriver();
	return p is null ? "" : to!string(fromStringz(p));
}

// Switch the SDL audio driver at runtime. `name` is an SDL driver name (empty =
// SDL default). Pauses + locks the callback, tears down and re-initialises the
// audio subsystem with the new driver, then re-opens our device. reSID and the
// current multiplier are preserved. No-op if already on that driver.
void setAudioDriver(string name) {
	if(!audioInited) return;
	if(name.length && name == currentAudioDriver()) return;

	bool wasPlaying = SDL_GetAudioStatus() == SDL_AUDIO_PLAYING;
	int savedMult = multiplier < 1 ? 1 : multiplier;

	SDL_PauseAudio(1);
	SDL_Delay(30);          // let any in-flight callback finish
	SDL_LockAudio();
	SDL_CloseAudio();
	if(mixbuf) { free(mixbuf); mixbuf = null; }
	SDL_AudioQuit();        // unload the old driver
	const(char)* drv = name.length ? name.toStringz() : null;
	if(SDL_AudioInit(drv) < 0) {
		writeln("Could not select audio driver '", name, "': ",
				to!string(SDL_GetError()), " — reverting to default.");
		SDL_AudioInit(null);
	}
	multiplier = 0;         // force the multiplier restore below to recompute
	int rc = openDevice();
	SDL_UnlockAudio();
	if(rc < 0) { audioInited = false; return; }
	setCallMultiplier(savedMult);
	SDL_PauseAudio(wasPlaying ? 0 : 1);
}
