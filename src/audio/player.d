/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

High-level playback control: play/stop/keyjam state, SID model selection and reSID engine wiring.
*/

module audio.player;
import com.cpu;
import com.session;
private import ct.base;
import audio.timer;
import audio.callback;
import audio.audio;
import audio.visualizer;
static import audio.remote;
import audio.resid.filter;
import seq.sequencer;
import ui.ui;
import derelict.sdl2.sdl;
import std.stdio;

enum Status { Stop, Play, Keyjam };

int fixedGateExpiresAfter(int ticks) pure nothrow @safe {
	return ticks < 1 ? 1 : ticks;
}

// R41 timing contract: arming N ticks must keep the gate high for exactly N player
// calls, independently of when the physical key is released.
static assert(fixedGateExpiresAfter(1) == 1);
static assert(fixedGateExpiresAfter(40) == 40);
shared private int playstatus;
// Bumped on every keyjam/preview note-on (playNote). The oscilloscope watches it
// to know when to re-capture: in keyjam mode it freezes the played note's
// waveform and holds it until the next note bumps this counter. UI-thread only.
__gshared int keyjamNoteTrigger;
// Sound-Editor-only one-shot gate clock. It advances in audio.callback.audio_frame,
// i.e. at the same player-tick rate as the tables and graph recordings. Classic
// keyjam never arms it and therefore retains key-release gate behavior.
__gshared private int fixedGateTicksRemaining;
__gshared private int fixedGateVoice;
__gshared private int fixedGateInstrument;
__gshared private bool fixedGateStarted;
__gshared private bool fixedGateForceLow;
shared int[3] muted;
int usefp = 1, sidtype, interpolate = 1, badline, ntsc;
__gshared Filterparams curfp;
int curfp6581 = 0, curfp8580 = 0;

int getPlaystatus() nothrow {
	return playstatus;
}

bool isPlaying() nothrow {
	return playstatus == Status.Play || playstatus == Status.Keyjam;
}

bool keyjamEnabled() nothrow {
	return playstatus == Status.Keyjam;
}

void cancelFixedKeyjamGate() nothrow {
	fixedGateTicksRemaining = 0;
	fixedGateStarted = false;
	fixedGateForceLow = false;
}

void armFixedKeyjamGate(int ticks, int voice, int instrument) nothrow {
	// The audio callback treats a non-zero remaining count as the publication flag.
	// Publish it last so it can never observe a fresh count with stale routing data.
	fixedGateVoice = voice < 0 ? 0 : (voice > 2 ? 2 : voice);
	fixedGateInstrument = instrument < 0 ? 0 : instrument;
	fixedGateStarted = false;
	fixedGateForceLow = false;
	fixedGateTicksRemaining = fixedGateExpiresAfter(ticks);
}

int fixedKeyjamGateRemaining() nothrow {
	return fixedGateTicksRemaining;
}

// Called once after each keyjam player call and visualizer sample. Consequently an
// N-tick gate records N high samples; the key-off becomes visible at sample N.
private void issueFixedKeyoff() nothrow {
	fixedGateForceLow = true;
	try {
		song.cpu.reset();
		song.cpu.regs.a = NOTE_KEYOFF;
		song.cpu.regs.x = cast(ubyte)fixedGateVoice;
		song.cpu.regs.y = cast(ubyte)fixedGateInstrument;
		if(song.ver > 8)
			song.memspace[song.offsets[Offsets.SHTRANS] + fixedGateVoice] = 0;
		ushort call = song.ver > 7 ? song.offsets[Offsets.Subnoteplay] : 0x1009;
		cpuCall(call, false);
		if(audio.remote.isActive()) {
			audio.remote.ensureLoaded(song);
			audio.remote.cmdKeyjam(song, NOTE_KEYOFF, fixedGateVoice, fixedGateInstrument);
		}
	} catch(Exception) {
		// Match the realtime callback's fail-closed behavior: the clock is already
		// disarmed, so a malformed/unsupported player cannot repeatedly throw here.
		cancelFixedKeyjamGate();
	}
}

// Called after the player tick and before its SID shadow is recorded. The normal
// KEYOFF command still updates player state (and remote hardware), while this mask
// hides its fixed restart-pipeline latency from the local, user-visible gate span.
void applyFixedKeyjamGateMask() nothrow {
	if(fixedGateForceLow)
		song.sidbuf[fixedGateVoice * 7 + 4] &= 0xfe;
}

void advanceFixedKeyjamGate() nothrow {
	if(fixedGateTicksRemaining <= 0) return;
	if(playstatus != Status.Keyjam) { cancelFixedKeyjamGate(); return; }
	// Restart pre-roll is not sustain time: begin on the first actual gate-high sample.
	if(!fixedGateStarted) {
		if((song.sidbuf[fixedGateVoice * 7 + 4] & 1) == 0) return;
		fixedGateStarted = true;
	}
	if(--fixedGateTicksRemaining > 0) return;
	issueFixedKeyoff();
}

// Sound Editor note-on + one-shot arming is one audio-device transaction. This
// prevents the realtime callback from consuming an unarmed note-on tick.
void playNoteOnVoiceWithFixedGate(Element emt, int voice, int ticks) {
	SDL_LockAudio();
	scope(exit) SDL_UnlockAudio();
	playNoteImpl(emt, true, voice);
	armFixedKeyjamGate(ticks, voice, emt.instr.value);
}

void init() {
	if(audio_init(ntsc ? 60 : 50, &audio_frame) < 0) {
		throw new Error("Could not init audio.");
	}
	SDL_LockAudio();
	curfp = sidtype ? FP8580[curfp8580] : FP6581[curfp6581];
	sid_init(usefp, &curfp, freq, sidtype, ntsc, interpolate, 0);
	/+
	if(!audioinited) {
		writefln("audio init: engine=%s, freq=%d, buf=%d, sid=%d, clock=%s, interpolation=%s%s",
				 usefp ? "resid-fp" : "resid",
				 audio.audio.audiospec.freq, audio.audio.bufferSize,
				 sidtype ? 8580 : 6581,
				 ntsc ? "ntsc" : "pal",
				 interpolate ? "on" : "off" ,
				 badline ? ", badlines=on" : "");
	}
	if(badline) {
		audio.audio.residdelay = 48;  // 4
	}
	else audio.audio.residdelay = 0;
	+/
	SDL_UnlockAudio();
}

void setSidModel(int v) {
	assert(v == 0 || v == 1);
	if(sidtype == v) return;
	sidtype = v;
	init();
}

void toggleSIDModel() {
	setSidModel(sidtype ^ 1);
}

private void playNoteImpl(Element emt, bool notifyRemote, int voiceOverride = -1) {
	if(playstatus == Status.Play) return;
	if(emt.note.value >= 3) {
		cancelFixedKeyjamGate();
		keyjamNoteTrigger++; // signal a genuinely new/re-rendered note (not key-off)
	}
	int v = voiceOverride >= 0 && voiceOverride < 3
		? voiceOverride : seq.sequencer.activeVoiceNum;
	// Start a fresh recording only on an actual struck note (>=3); a keyoff (1),
	// keyon (2) or rest (0) keeps recording into the current note so the release
	// tail is captured rather than starting a new (empty) recording.
	if(emt.note.value >= 3) {
		// captureBlock samples the previous tick's SID shadow before audio_frame runs.
		// Clear a stale gate from an earlier note/voice so every fresh capture begins
		// with honest restart pre-roll instead of a one-sample false onset.
		audio.audio.sidreg[v * 7 + 4] = cast(char)(audio.audio.sidreg[v * 7 + 4] & 0xfe);
		audio.visualizer.beginVoiceRecording(v);
		audio.audio.captureStart(v);   // record this note for the oscilloscope view
		audio.audio.captureInstr = emt.instr.value;  // remember which instrument, so the
		                               // Sound Editor can bind the recording to it
	}

	// no audio reset if already inited
	if(playstatus != Status.Keyjam) {
		audio.callback.reset();
		audio.audio.reset();
	}

	playstatus = Status.Stop;

	song.setVoicon([v == 0 ? 0 : 1, v == 1 ? 0 : 1, v == 2 ? 0 : 1]);
	muteSID(1,1,1);
	song.cpu.reset();
	song.cpu.regs.a = emt.note.value;
	song.cpu.regs.x = cast(ubyte)v;
	song.cpu.regs.y = emt.instr.value;
	if(song.ver > 8)
		song.memspace[song.offsets[Offsets.SHTRANS] + v] = 0;
	ushort call = 0x1009;
	if(song.ver > 7) {
		call = song.offsets[Offsets.Subnoteplay];
	}
	cpuCall(call,true);
	playstatus = Status.Keyjam;

	if(notifyRemote && audio.remote.isActive()) {
		audio.remote.ensureLoaded(song);
		audio.remote.cmdKeyjam(song, emt.note.value, v, emt.instr.value);
	}
}

void playNote(Element emt) { playNoteImpl(emt, true); }
void playNoteOnVoice(Element emt, int voice) { playNoteImpl(emt, true, voice); }

// Local-only note setup for an offline reSID preview. The caller pauses SDL output;
// suppressing the remote command keeps hardware backends silent as well.
void playNoteSilent(Element emt) { playNoteImpl(emt, false); }
void playNoteSilentOnVoice(Element emt, int voice) { playNoteImpl(emt, false, voice); }

void playRow(Voice[] voices) {
	if(playstatus == Status.Play) return;
	int[] trk, seq;
	foreach(v; voices) {
		auto r = v.activeRow;
		trk ~= r.trkOffset;
		seq ~= r.seqOffset;
	}
	SDL_PauseAudio(1);
	if(SDL_GetAudioStatus() == SDL_AUDIO_PLAYING)
		std.stdio.writefln("Audio thread not finished!");
	SDL_Delay(20);
	stop();

	initPlayOffset(trk, seq);

	song.cpu.reset();

	cpuCall(0x1003,true);
	cpuCall(0x1003,true);
	cpuCall(0x1003,true);

	playstatus = Status.Keyjam;

	if(audio.remote.isActive()) {
		audio.remote.ensureLoaded(song);
		int sr, ls, le; remotePosSeed(trk, seq, sr, ls, le);
		audio.remote.cmdRestart(song, 0, sr, ls, le);
	}

	SDL_PauseAudio(0);
}


void start(int[] trk, int[] seq) {
	SDL_PauseAudio(1);
	if(SDL_GetAudioStatus() == SDL_AUDIO_PLAYING)
		std.stdio.writefln("Audio thread not finished!");
	SDL_Delay(20);
	stop();
	initPlayOffset(trk,seq);
	audio.timer.start();
	audio.callback.reset();
	audio.audio.reset();

	// Clear ADSR visualization history when starting new playback
	audio.visualizer.clearPersistentBrightness();

	playstatus = Status.Play;

	if(audio.remote.isActive()) {
		audio.remote.ensureLoaded(song);
		int sr, ls, le; remotePosSeed(trk, seq, sr, ls, le);
		audio.remote.cmdRestart(song, 0, sr, ls, le);
	}

	SDL_PauseAudio(0);
}

void start() {
	start([0, 0, 0], [0, 0, 0]);
}

void stop() nothrow {
	cancelFixedKeyjamGate();
	playstatus = Status.Stop;
	muteSID(1,1,1);
	audio.audio.captureStop();   // end any keyjam note recording
	if(audio.remote.isActive()) audio.remote.cmdStop();
}

void toggleVoice(int v) {
	if(v > 2 || v < 0) return;
	muted[v] = muted[v] ^ 1;
	setVoicon(muted);
}

void setVoicon(int v1, int v2, int v3) {
	setVoicon([v1, v2, v3]);
}

void setVoicon(int[] m) {
	muted[0] = m[0];
	muted[1] = m[1];
	muted[2] = m[2];
	muteSID(m[0], m[1], m[2]);
	song.setVoicon(muted);
	if(audio.remote.isActive()) audio.remote.pushVoice(song);
}

void setVoicon(shared int[] m) {
	muted[0] = m[0];
	muted[1] = m[1];
	muted[2] = m[2];
	muteSID(m[0], m[1], m[2]);
	song.setVoicon(muted);
	if(audio.remote.isActive()) audio.remote.pushVoice(song);
}

void initFP() {
	init();
	song.fppres = sidtype ? curfp8580 : curfp6581;
}

void nextFP() {
    if (usefp) {
        if (sidtype) {
            ++curfp8580;
            curfp8580 %= FP8580.length;
        } else {
            ++curfp6581;
            curfp6581 %= FP6581.length;
        }

        initFP();
    }
}


void setFP(int fp) {
    if (usefp) {
        if (sidtype) {
			curfp8580 = cast(int)(fp % FP8580.length);
        } else {
			curfp6581 = cast(int)(fp % FP6581.length);
        }
        initFP();
    }
}


void prevFP() {
    if (usefp) {
        if (sidtype) {
            --curfp8580;
            if (curfp8580 < 0) curfp8580 = cast(int)(FP8580.length-1);
        } else {
            --curfp6581;
            if (curfp6581 < 0) curfp6581 = cast(int)(FP6581.length-1);
        }

        initFP();
    }
}

void fastForward(int val) {
	int step = val * 16;
	SDL_LockAudio();
	for(int i = 0 ; i < step; i++) {
		audio_frame();
	}
	SDL_UnlockAudio();
}

// Render `durationSec` seconds of the given subtune (1-based; <=0 = current) to
// 16-bit mono PCM at audio.audio.freq, offline (non-realtime). Mirrors the realtime
// audio_callback_2 loop (sid_fillbuffer + audio_frame per frame) with the SDL audio
// device locked out, so the result matches live playback (same SID model / filter /
// multiplier). Restores playback state and the active subtune on return.
short[] renderPcm(int subtune1based, int durationSec, int sampleRate = 0) {
	if(durationSec < 1) durationSec = 1;
	int prevSubtune = song.subtune;
	bool changedSub = false;
	// Render at the requested rate by re-initing reSID at it; the global freq is
	// restored (and the engine re-init'd) before returning to live playback.
	int savedFreq = audio.audio.freq;
	if(sampleRate > 0) audio.audio.freq = sampleRate;

	stop();
	if(subtune1based >= 1 && (subtune1based - 1) != song.subtune) {
		song.subtunes.activate(subtune1based - 1);
		changedSub = true;
	}

	init();                                          // fresh reSID state at audio.audio.freq
	audio.audio.setCallMultiplier(song.multiplier);  // sets callbackInterval + framerate

	int interval = audio.audio.getCallbackInterval();
	long target = cast(long)durationSec * audio.audio.freq;
	short[] pcm;
	pcm.reserve(cast(size_t)(target + interval));
	short[] tmp;
	tmp.length = interval;

	SDL_LockAudio();          // keep the device callback off the engine during render
	initPlayOffset([0, 0, 0], [0, 0, 0]);
	SDL_PauseAudio(1);        // initPlayOffset unpauses; re-pause for the offline run
	audio.timer.start();
	audio.callback.reset();
	playstatus = Status.Play; // audio_frame only advances while playing
	while(pcm.length < target) {
		int n = sid_fillbuffer(tmp.ptr, interval, audio.callback.cyclesPerFrame);
		pcm ~= tmp[0 .. n];
		audio.callback.recordRenderedSidTick();
		audio_frame();
	}
	playstatus = Status.Stop;
	SDL_UnlockAudio();

	if(pcm.length > target) pcm.length = cast(size_t)target;
	if(changedSub) song.subtunes.activate(prevSubtune);
	audio.audio.freq = savedFreq;   // restore live sample rate before re-init
	init();                   // reset reSID for subsequent live playback
	return pcm;
}

void dumpFrame() {
	if(playstatus == Status.Play || playstatus == Status.Keyjam)
		audio.callback.requestDump();
}

void setMultiplier(int m) {
	if(m < 1 || m > 16) return;

	// The multispeed rate is baked into the resident image (CIA timer + MULT),
	// not mirrored as data, so a change needs a full re-inject of the backend.
	if(m != song.multiplier && audio.remote.isActive())
		audio.remote.markReload();

	song.multiplier = m;
	audio.audio.setCallMultiplier(m);
}

void decMultiplier() {
	setMultiplier(song.multiplier - 1);
}

void incMultiplier() {
	setMultiplier(song.multiplier + 1);
}

// The position triple the remote shim needs to show "Pos": where playback
// begins, and the song's loop bounds, all as absolute note-rows of voice 0 (the
// canonical song position, matching the editor's playback cursor). The shim
// seeds its counter with startRow and wraps loopEnd->loopStart, so the on-target
// Pos starts at the play-from row and loops with the song. Recomputed each
// restart, so it reflects any song-end / loop-point edit made before play.
private void remotePosSeed(int[] t, int[] s,
						   out int startRow, out int loopStart, out int loopEnd) {
	auto tl = song.tracks[0];
	int trackLen = tl.trackLength;
	int rowAt(int trkOff, int seqOff) {
		if(trkOff > trackLen) trkOff = trackLen;
		int sum = 0;
		foreach(i; 0 .. trkOff) sum += song.sequence(tl[i]).rows;
		return sum + seqOff;
	}
	startRow  = rowAt(t[0], s[0]);
	loopStart = rowAt(tl.wrapOffset, 0);
	loopEnd   = rowAt(trackLen, 0);
}

private void initPlayOffset(int[] t, int[] s) {
	void out16b(int offs, int value) {
		song.buffer[offs] = value & 255;
		song.buffer[offs + 1] = (value >> 8) & 255;
	}
	address off1 = cast(ushort)(song.offsets[Offsets.Track1] + t[0] * 2);
	address off2 = cast(ushort)(song.offsets[Offsets.Track2] + t[1] * 2);
	address off3 = cast(ushort)(song.offsets[Offsets.Track3] + t[2] * 2);
	int tpoin2 = song.offsets[Offsets.Songsets];
	int tpoin = song.offsets[Offsets.TRACKLO];
	song.cpu.reset();
	if(song.ver >= 6) {
		song.buffer[tpoin] = off1 & 255;
		song.buffer[tpoin+1] = off2 & 255;
		song.buffer[tpoin+2] = off3 & 255;
		song.buffer[tpoin+3] = off1 >> 8;
		song.buffer[tpoin+4] = off2 >> 8;
		song.buffer[tpoin+5] = off3 >> 8;
		out16b(tpoin2, song.offsets[Offsets.Track1]);
		out16b(tpoin2+2, song.offsets[Offsets.Track2]);
		out16b(tpoin2+4, song.offsets[Offsets.Track3]);
	}
 	else {
		out16b(tpoin2, off1);
		out16b(tpoin2+2, off2);
		out16b(tpoin2+4, off3);
	}
	cpuCall(0x1000,false);
 	int seqcnt = song.offsets[Offsets.NEWSEQ];
	song.buffer[seqcnt] = cast(ubyte)(s[0] * 4 + 1);
	song.buffer[seqcnt+1] = cast(ubyte)(s[1] * 4 + 1);
	song.buffer[seqcnt+2] = cast(ubyte)(s[2] * 4 + 1);
	song.setVoicon(muted);

	SDL_PauseAudio(0);
}

private void muteSID(int v1, int v2, int v3 ) nothrow {
	if(v1) song.sidbuf[4] = 0x08;
	if(v2) song.sidbuf[7 + 4] = 0x08;
	if(v3) song.sidbuf[14 + 4]= 0x08;
}
