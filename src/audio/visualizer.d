/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Oscilloscope / SID-register visualizer: tracks per-voice envelope brightness and player table rows, and keeps a read-only per-frame recording of each voice's real SID state (control/freq/pulse/cutoff/resonance/routing/mode/amplitude) since the last note trigger for the Sound Editor to draw the actual played audio.
(This visualizer lib vibe-coded by Vent.)

*/

module audio.visualizer;
import std.algorithm : max, min;

/**
 * Modular audio visualization system that monitors SID register writes
 * without modifying the SID emulation code.
 *
 * This allows various visualization types to be added in the future.
 */

// ADSR timing constants (in milliseconds) from SID specification
// Attack times (ms) for ADSR attack parameter values 0-15
private immutable float[16] ATTACK_TIME_MS = [
	2.0, 8.0, 16.0, 24.0, 38.0, 56.0, 68.0, 80.0,
	100.0, 250.0, 500.0, 800.0, 1000.0, 3000.0, 5000.0, 8000.0
];

// Decay/Release times (ms) for ADSR decay/release parameter values 0-15
private immutable float[16] DECAY_RELEASE_TIME_MS = [
	6.0, 24.0, 48.0, 72.0, 114.0, 168.0, 204.0, 240.0,
	300.0, 750.0, 1500.0, 2400.0, 3000.0, 9000.0, 15000.0, 24000.0
];

// PAL frame rate: 50.125 Hz
private immutable float MS_PER_FRAME = 1000.0 / 50.125;  // ~19.95 ms

/// Envelope state for a single voice
private enum EnvelopeState {
	Silent,   // Gate off, envelope at zero
	Attack,   // Gate on, rising to peak
	Decay,    // Gate on, falling to sustain
	Sustain,  // Gate on, holding at sustain level
	Release   // Gate off, falling to zero
}

/// Voice activity tracking
private struct VoiceActivity {
	EnvelopeState state = EnvelopeState.Silent;
	int instrumentNum = 255;     // Current instrument number playing on this voice (255 = invalid/unset)
	float brightness = 0.0f;     // Current brightness (0.0 to 1.0)
	float targetBrightness = 0.0f;
	float deltaPerFrame = 0.0f;  // Change in brightness per frame
	ubyte sustainLevel = 0;      // Target sustain level (0-15)
	bool gateOn = false;

	// ADSR timing parameters (frames to complete each phase)
	int attackFrames = 2;
	int decayFrames = 6;
	int releaseFrames = 6;

	// Decay/Release are EXPONENTIAL (reSID envelope.h:119-178): the envelope
	// counter's decrement clock is divided by 1,2,4,8,16,30 as it falls through
	// levels 255,93,54,26,14,6 — a piece-wise-linear approximation of an
	// exponential. (Attack is strictly LINEAR.) We replay that curve over the
	// per-nibble decay/release time: envElapsed = frames into the phase; envFrac0 =
	// the curve fraction the phase STARTED at (0 for decay-from-peak; for release
	// it's where the current level sits on the curve, so releasing from a low level
	// is proportionally faster, as on the real chip).
	int envElapsed = 0;
	float envFrac0 = 0.0f;
}

// Decay/release envelope shape. reSID (envelope.h:119-178) approximates the SID's
// exponential decay with a piece-wise-LINEAR curve: the counter clock is divided by
// 1,2,4,8,16,30 at levels 255,93,54,26,14,6 — i.e. it is *approximating* a true
// exponential with line segments for cycle efficiency. Its breakpoints
// (frac,level) = (0,1)(.21,.365)(.32,.212)(.47,.102)(.59,.055)(.76,.024)(1,0) lie
// almost exactly on level = e^(-5·frac) (e.g. e^-1.05≈0.35 at frac .21). So we draw
// that SMOOTH exponential instead of the segments: same shape reSID intends, but it
// renders smooth at ANY note length/zoom (the segments only "kinked" visibly on
// short notes). EXP_K sets the steepness; normalised so level(0)=1, level(1)=0.
private enum float EXP_K = 5.0f;
private float expLevel(float frac) nothrow {
	import std.math : exp;
	if(frac <= 0.0f) return 1.0f;
	if(frac >= 1.0f) return 0.0f;
	immutable float e = exp(-EXP_K);
	return (exp(-EXP_K * frac) - e) / (1.0f - e);
}

// Inverse: the curve fraction at which the level equals `lvl` — where on the
// exponential a release starting from a mid level begins.
private float expLevelInv(float lvl) nothrow {
	import std.math : log, exp;
	if(lvl >= 1.0f) return 0.0f;
	if(lvl <= 0.0f) return 1.0f;
	immutable float e = exp(-EXP_K);
	return -log(lvl * (1.0f - e) + e) / EXP_K;
}

private __gshared VoiceActivity[3] voices;
private __gshared ubyte[3] lastInstrument = [0, 0, 0];  // Last instrument triggered per voice

/// Instrument brightness values (48 instruments)
private __gshared float[48] instrumentBrightness;

/// Debug: track last shinst offset and values
private __gshared int lastShinstOffset = -1;
private __gshared ubyte[3] lastShinstValues = [255, 255, 255];

/// Persistent brightness history for track visualization
/// Structure: [voice][rowCounter] = brightness
private __gshared float[int][3] persistentBrightness;
private __gshared int[3] lastRowCounter = [-1, -1, -1];

enum PlaybackTable {
	Wave,
	Pulse,
	Filter,
	Chord
}

private __gshared int[3] activeWaveRows = [-1, -1, -1];
private __gshared int[3] activePulseRows = [-1, -1, -1];
private __gshared int[3] activeChordRows = [-1, -1, -1];
private __gshared int activeFilterRow = -1;

// ---- §11.1 per-voice per-frame RECORDING of the real SID state ----------------
// A rolling log of the ACTUAL played audio, per voice, appended once per player
// frame from the real `sidreg` in updateSidRegisters() (called every player tick
// from audio.callback), so it works for keyjam on real HW AND for song playback /
// ccdriver `ff:` headless. Reset on a gate 0->1 transition (new note = frame 0).
// The Sound Editor reads these to draw its bands from the recording instead of a
// table simulation. Capped at RECORD_FRAMES, which MUST be >= the Sound Editor's
// widest dynamic X window (§12: MAX_VIS + the restart pre-roll) so even a long,
// slow-release note records to its actual end and the axis can auto-fit it.
// All read-only: we record playback state, never write song bytes.
enum int RECORD_FRAMES = 1650;

private __gshared int[RECORD_FRAMES][3]   recCtrl;    // control byte (sidreg[v*7+4])
private __gshared int[RECORD_FRAMES][3]   recFreq;    // 16-bit frequency
private __gshared int[RECORD_FRAMES][3]   recPulse;   // 12-bit pulse width
private __gshared int[RECORD_FRAMES][3]   recCutoff;  // 11-bit filter cutoff
private __gshared int[RECORD_FRAMES][3]   recRes;     // resonance 0..15
private __gshared int[RECORD_FRAMES][3]   recRoute;   // filter routing (b0..b2)
private __gshared int[RECORD_FRAMES][3]   recMode;    // filter mode (sidreg[0x18]&0x70)
private __gshared float[RECORD_FRAMES][3] recAmp;     // envelope amplitude 0..1
private __gshared int[3]  recLen     = [0, 0, 0];       // frames recorded since trigger
private __gshared bool[3] recActive  = [false, false, false]; // a note has played
private __gshared bool[3] recPrevGate = [false, false, false];// gate edge tracking

// Append one frame of the voice's real SID state to its rolling recording log.
// Resets the log on a gate 0->1 edge (new note). Independent gate tracking so it
// doesn't disturb the envelope state machine's own voice.gateOn.
private void recordVoiceFrame(int v, const ubyte[] sidreg) nothrow {
	int baseReg = v * 7;
	ubyte ctrl = sidreg[baseReg + 4];
	bool gate = (ctrl & 0x01) != 0;
	if(gate && !recPrevGate[v]) {   // new note: restart the log at frame 0
		recLen[v] = 0;
		recActive[v] = true;
	}
	recPrevGate[v] = gate;
	if(!recActive[v]) return;               // nothing played on this voice yet
	if(recLen[v] >= RECORD_FRAMES) return;  // window full: freeze (trigger-aligned)
	int i = recLen[v];
	recCtrl[v][i]   = ctrl;
	recFreq[v][i]   = sidreg[baseReg + 0] | (sidreg[baseReg + 1] << 8);
	recPulse[v][i]  = sidreg[baseReg + 2] | ((sidreg[baseReg + 3] & 0x0f) << 8);
	recCutoff[v][i] = (sidreg[0x15] & 7) | (sidreg[0x16] << 3);
	recRes[v][i]    = sidreg[0x17] >> 4;
	recRoute[v][i]  = sidreg[0x17] & 0x0f;
	recMode[v][i]   = sidreg[0x18] & 0x70;
	recAmp[v][i]    = voices[v].brightness;
	recLen[v]++;
}

/**
 * Call this from audio callback to update SID register monitoring.
 * Monitors control registers (0x04, 0x0b, 0x12) for gate changes.
 * Also reads current instrument numbers from player memory.
 */
void updateSidRegisters(const ubyte[] sidreg, const ubyte[] playerMem, int playerStateOffset, int multiplier = 1) nothrow {
	if(sidreg.length < 0x19) return;
	// Player ticks per screen frame (multispeed). Phase lengths below are converted
	// from the ms tables into TICKS (× mult) so the per-tick envelope advance covers
	// the correct real time at any multiplier.
	immutable int mult = max(1, multiplier);

	// Store offset for debug
	lastShinstOffset = playerStateOffset + 6;

	// Process each voice
	for(int v = 0; v < 3; v++) {
		int baseReg = v * 7;
		ubyte controlReg = sidreg[baseReg + 0x04];
		ubyte attackDecay = sidreg[baseReg + 0x05];
		ubyte sustainRelease = sidreg[baseReg + 0x06];

		bool gateOn = (controlReg & 0x01) != 0;
		ubyte attack = (attackDecay >> 4) & 0x0F;
		ubyte decay = attackDecay & 0x0F;
		ubyte sustain = (sustainRelease >> 4) & 0x0F;
		ubyte release = sustainRelease & 0x0F;

		VoiceActivity* voice = &voices[v];

		// Read current instrument from player memory
		// Try multiple approaches to get the instrument number
		if(gateOn) {
			int currentInstrument = voice.instrumentNum; // Keep current by default

			// Approach 1: Read from shinst if available
			int shinstOffset = playerStateOffset + 6;
			if(playerStateOffset > 0 && shinstOffset + v < playerMem.length) {
				ubyte memInstr = playerMem[shinstOffset + v];
				lastShinstValues[v] = memInstr; // Store for debug
				if(memInstr < 48) {
					currentInstrument = memInstr;
				}
			}

			// Approach 2: Fallback - use voice number as test (temporary debug)
			// This will light up instruments 0, 1, 2 for voices 0, 1, 2
			if(currentInstrument >= 48) {
				currentInstrument = v;
			}

			voice.instrumentNum = currentInstrument;
		}

		if(playerStateOffset > 0 && playerStateOffset + 118 < playerMem.length) {
			activeWaveRows[v] = playerMem[playerStateOffset + 110 + v];
			activePulseRows[v] = playerMem[playerStateOffset + 80 + v] >> 2;
			int chordPos = playerMem[playerStateOffset + 116 + v];
			activeChordRows[v] = chordPos < 0x80 ? chordPos : -1;
		}

		// Detect gate on transition
		if(gateOn && !voice.gateOn) {
			// Gate turned on - start attack phase
			voice.state = EnvelopeState.Attack;
			voice.gateOn = true;
			voice.targetBrightness = 1.0f;

			// Calculate frame counts from actual SID timings
			// Convert milliseconds to frames (at 50.125 Hz PAL)
			voice.attackFrames = max(1, cast(int)(ATTACK_TIME_MS[attack] / MS_PER_FRAME * mult));
			voice.decayFrames = max(1, cast(int)(DECAY_RELEASE_TIME_MS[decay] / MS_PER_FRAME * mult));
			voice.sustainLevel = sustain;
			voice.deltaPerFrame = 1.0f / max(1, voice.attackFrames);
		}
		// Detect gate off transition
		else if(!gateOn && voice.gateOn) {
			// Gate turned off - start release phase
			voice.state = EnvelopeState.Release;
			voice.gateOn = false;
			voice.targetBrightness = 0.0f;
			voice.releaseFrames = max(1, cast(int)(DECAY_RELEASE_TIME_MS[release] / MS_PER_FRAME * mult));
			// Exponential release (reSID): start on the curve where the current level
			// sits, so a release from a low level is proportionally faster.
			voice.envElapsed = 0;
			voice.envFrac0 = expLevelInv(voice.brightness);
		}
		// If gate is on and we're in sustain or other states, keep updating instrument
		else if(gateOn && voice.state != EnvelopeState.Attack && voice.state != EnvelopeState.Decay) {
			// Ensure we're in sustain state if gate is on
			if(voice.state == EnvelopeState.Silent || voice.state == EnvelopeState.Release) {
				voice.state = EnvelopeState.Sustain;
				voice.brightness = sustain / 15.0f;
				voice.sustainLevel = sustain;
			}
		}
	}

	if(playerStateOffset > 0 && playerStateOffset + 45 < playerMem.length) {
		activeFilterRow = playerMem[playerStateOffset + 45] >> 2;
	}

	// Advance each voice's envelope ONE PLAYER TICK, then append this tick's real SID
	// state to its recording log (§11.1). Advancing per tick (not per screen frame)
	// with tick-scaled phase lengths keeps the recorded envelope a SMOOTH curve at any
	// multiplier — sampling a per-screen-frame envelope per tick made a staircase.
	for(int v = 0; v < 3; v++) {
		advanceEnvelope(v);
		recordVoiceFrame(v, sidreg);
	}
}

/**
 * Call this each frame to update envelope states.
 */
// Advance one voice's envelope by ONE player TICK along its current phase. Attack is
// linear; decay/release follow the smooth exponential (expLevel). Phase lengths are in
// TICKS (updateSidRegisters scales the ms tables by the multiplier), so calling this
// once per player tick yields a smooth curve at any multiplier — the old per-screen-
// frame advance, sampled per tick by the recording, drew a staircase at multispeed.
private void advanceEnvelope(int v) nothrow {
	VoiceActivity* voice = &voices[v];
	final switch(voice.state) {
		case EnvelopeState.Silent:
			voice.brightness = 0.0f;
			break;

		case EnvelopeState.Attack:
			// Attack is strictly LINEAR (reSID: the counter increments by 1 every
			// rate period, no exponential division).
			voice.brightness += voice.deltaPerFrame;
			if(voice.brightness >= voice.targetBrightness) {
				voice.brightness = voice.targetBrightness;
				// Transition to (exponential) decay, starting at the top of the curve.
				voice.state = EnvelopeState.Decay;
				voice.targetBrightness = voice.sustainLevel / 15.0f;
				voice.envElapsed = 0;
				voice.envFrac0 = 0.0f;
				if(voice.brightness <= voice.targetBrightness)
					voice.state = EnvelopeState.Sustain;   // sustain >= peak: nothing to decay
			}
			break;

		case EnvelopeState.Decay: {
			// Exponential decay toward the sustain level along the reSID curve;
			// halt at sustain (the decay-to-sustain time is the matching portion).
			voice.envElapsed++;
			float sLvl = voice.sustainLevel / 15.0f;
			float lvl = expLevel(cast(float)voice.envElapsed / max(1, voice.decayFrames));
			if(lvl <= sLvl) {
				voice.brightness = sLvl;
				voice.state = EnvelopeState.Sustain;
			}
			else voice.brightness = lvl;
			break;
		}

		case EnvelopeState.Sustain:
			// Hold at sustain level
			voice.brightness = voice.sustainLevel / 15.0f;
			break;

		case EnvelopeState.Release: {
			// Exponential release along the reSID curve, continuing from the fraction
			// the current level sat at (envFrac0). Advancing 1/releaseFrames per frame
			// makes a release from a low level proportionally faster (as on the chip).
			voice.envElapsed++;
			float frac = voice.envFrac0 + cast(float)voice.envElapsed / max(1, voice.releaseFrames);
			float lvl = expLevel(frac);
			voice.brightness = lvl;
			if(frac >= 1.0f || lvl <= 0.0f) {
				voice.brightness = 0.0f;
				voice.state = EnvelopeState.Silent;
			}
			break;
		}
		}

	// Clamp brightness
	voice.brightness = max(0.0f, min(1.0f, voice.brightness));
}

// Called each SCREEN frame (frameDone). The per-tick envelope advance now lives in
// updateSidRegisters, so this only aggregates the instrument/persistent brightness
// from the already-advanced voice envelopes.
void updateVisualizerFrame() nothrow {
	// Update instrument brightness array (max brightness of all voices playing that instrument)
	foreach(ref b; instrumentBrightness) {
		b = 0.0f;
	}

	for(int v = 0; v < 3; v++) {
		int ins = voices[v].instrumentNum;
		if(ins >= 0 && ins < 48) {
			instrumentBrightness[ins] = max(instrumentBrightness[ins], voices[v].brightness);
		}
	}
}

/**
 * Notify the visualizer that an instrument has been triggered on a voice.
 * Call this when a note is played.
 */
void notifyInstrumentTrigger(int voiceNum, int instrumentNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return;
	if(instrumentNum < 0 || instrumentNum >= 48) return;

	lastInstrument[voiceNum] = cast(ubyte)instrumentNum;
}

/**
 * Get the current brightness for an instrument (0.0 to 1.0)
 */
float getInstrumentBrightness(int instrumentNum) nothrow {
	if(instrumentNum < 0 || instrumentNum >= 48) return 0.0f;
	return instrumentBrightness[instrumentNum];
}

float getTableRowBrightness(PlaybackTable table, int row) nothrow {
	if(row < 0) return 0.0f;

	float brightness = 0.0f;
	final switch(table) {
	case PlaybackTable.Wave:
		for(int v = 0; v < 3; v++)
			if(activeWaveRows[v] == row)
				brightness = max(brightness, voices[v].brightness);
		break;
	case PlaybackTable.Pulse:
		for(int v = 0; v < 3; v++)
			if(activePulseRows[v] == row)
				brightness = max(brightness, voices[v].brightness);
		break;
	case PlaybackTable.Filter:
		if(activeFilterRow == row) {
			for(int v = 0; v < 3; v++)
				brightness = max(brightness, voices[v].brightness);
		}
		break;
	case PlaybackTable.Chord:
		for(int v = 0; v < 3; v++)
			if(activeChordRows[v] == row)
				brightness = max(brightness, voices[v].brightness);
		break;
	}
	return brightness;
}

/**
 * Get the current brightness for a voice/channel (0.0 to 1.0)
 */
float getVoiceBrightness(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return 0.0f;
	return voices[voiceNum].brightness;
}

/**
 * Get the current instrument number for a voice/channel
 */
int getVoiceInstrument(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return -1;
	return voices[voiceNum].instrumentNum;
}

/**
 * Get debug info: last shinst offset used
 */
int getDebugShinstOffset() nothrow {
	return lastShinstOffset;
}

/**
 * Get debug info: last shinst memory value for a voice
 */
int getDebugShinstValue(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return -1;
	return lastShinstValues[voiceNum];
}

/**
 * Update persistent brightness for a voice at a specific row counter position.
 * Call this from the player/sequencer during playback.
 * Stores the MAXIMUM brightness ever seen at this position.
 */
void updatePersistentBrightness(int voiceNum, int rowCounter) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return;
	lastRowCounter[voiceNum] = rowCounter;
	float br = voices[voiceNum].brightness;

	// Only update if this is brighter than what we've stored before
	auto ptr = rowCounter in persistentBrightness[voiceNum];
	if(ptr) {
		if(br > *ptr) {
			persistentBrightness[voiceNum][rowCounter] = br;
		}
	} else {
		persistentBrightness[voiceNum][rowCounter] = br;
	}
}

/**
 * Get persistent brightness for a voice at a specific row counter position.
 * Returns 0.0 if no brightness was recorded at this position.
 */
float getPersistentBrightness(int voiceNum, int rowCounter) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return 0.0f;
	auto ptr = rowCounter in persistentBrightness[voiceNum];
	return ptr ? *ptr : 0.0f;
}

/**
 * Clear persistent brightness history (e.g., when starting new playback)
 */
void clearPersistentBrightness() nothrow {
	foreach(ref pb; persistentBrightness) {
		pb.clear();
	}
	lastRowCounter[] = -1;
}

/**
 * Get the player's current wave-table row for a voice (-1 if none).
 * Read-only accessor used by the Sound Editor to place the wave-lane playhead.
 */
int getActiveWaveRow(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return -1;
	return activeWaveRows[voiceNum];
}

/**
 * Get the player's current pulse-table row for a voice (-1 if none).
 * Read-only accessor used by the Sound Editor to place the pulse-timeline playhead.
 */
int getActivePulseRow(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return -1;
	return activePulseRows[voiceNum];
}

/**
 * Get the player's current chord/arp-table row for a voice (-1 if none).
 */
int getActiveChordRow(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return -1;
	return activeChordRows[voiceNum];
}

/**
 * Get the player's current filter-table row (filter is global, one row; -1 if none).
 * Read-only accessor used by the Sound Editor to place the filter-timeline playhead.
 */
int getActiveFilterRow() nothrow {
	return activeFilterRow;
}

// ---- §11.1 recording read-only getters ---------------------------------------
// Each returns a slice of the voice's rolling per-frame log (length = frames
// recorded since the last trigger). The slices are views into __gshared storage;
// the Sound Editor reads them synchronously on the UI thread. All read-only.

/// True once a note has played on the voice and its recording log has >=1 frame.
bool voiceHasRecording(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return false;
	return recActive[voiceNum] && recLen[voiceNum] > 0;
}

/// Number of frames recorded on the voice since the last note trigger.
int getRecordingLength(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return 0;
	return recLen[voiceNum];
}

const(int)[] getRecordedControl(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return null;
	return recCtrl[voiceNum][0 .. recLen[voiceNum]];
}
const(int)[] getRecordedFreq(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return null;
	return recFreq[voiceNum][0 .. recLen[voiceNum]];
}
const(int)[] getRecordedPulse(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return null;
	return recPulse[voiceNum][0 .. recLen[voiceNum]];
}
const(int)[] getRecordedCutoff(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return null;
	return recCutoff[voiceNum][0 .. recLen[voiceNum]];
}
const(int)[] getRecordedResonance(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return null;
	return recRes[voiceNum][0 .. recLen[voiceNum]];
}
const(int)[] getRecordedRouting(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return null;
	return recRoute[voiceNum][0 .. recLen[voiceNum]];
}
const(int)[] getRecordedMode(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return null;
	return recMode[voiceNum][0 .. recLen[voiceNum]];
}
const(float)[] getRecordedAmp(int voiceNum) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return null;
	return recAmp[voiceNum][0 .. recLen[voiceNum]];
}

/// §12.1: one past the index of the LAST recorded frame whose envelope amplitude
/// exceeded `eps` — i.e. the recorded note's audible length. 0 when the note
/// never rose above eps. The Sound Editor uses this to auto-fit the X axis to the
/// note's ACTUAL end: when this is < the record head, silent frames follow, so the
/// note has ENDED and its real duration (this value) wins over the ADSR estimate.
int getRecordedAmpEnd(int voiceNum, float eps) nothrow {
	if(voiceNum < 0 || voiceNum >= 3) return 0;
	int last = -1;
	foreach(i; 0 .. recLen[voiceNum]) if(recAmp[voiceNum][i] > eps) last = i;
	return last + 1;
}

/**
 * Reset all visualization state
 */
void resetVisualizer() nothrow {
	for(int v = 0; v < 3; v++) {
		voices[v] = VoiceActivity.init;
		lastInstrument[v] = 0;
		activeWaveRows[v] = -1;
		activePulseRows[v] = -1;
		activeChordRows[v] = -1;
		recLen[v] = 0;
		recActive[v] = false;
		recPrevGate[v] = false;
	}
	activeFilterRow = -1;
	instrumentBrightness[] = 0.0f;
}
