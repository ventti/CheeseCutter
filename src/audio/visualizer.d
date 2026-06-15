/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Oscilloscope / SID-register visualizer rendering into the text framebuffer.
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

/**
 * Call this from audio callback to update SID register monitoring.
 * Monitors control registers (0x04, 0x0b, 0x12) for gate changes.
 * Also reads current instrument numbers from player memory.
 */
void updateSidRegisters(const ubyte[] sidreg, const ubyte[] playerMem, int playerStateOffset) nothrow {
	if(sidreg.length < 0x19) return;

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
			voice.attackFrames = max(1, cast(int)(ATTACK_TIME_MS[attack] / MS_PER_FRAME));
			voice.decayFrames = max(1, cast(int)(DECAY_RELEASE_TIME_MS[decay] / MS_PER_FRAME));
			voice.sustainLevel = sustain;
			voice.deltaPerFrame = 1.0f / max(1, voice.attackFrames);
		}
		// Detect gate off transition
		else if(!gateOn && voice.gateOn) {
			// Gate turned off - start release phase
			voice.state = EnvelopeState.Release;
			voice.gateOn = false;
			voice.targetBrightness = 0.0f;
			voice.releaseFrames = max(1, cast(int)(DECAY_RELEASE_TIME_MS[release] / MS_PER_FRAME));
			voice.deltaPerFrame = -voice.brightness / max(1, voice.releaseFrames);
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
}

/**
 * Call this each frame to update envelope states.
 */
void updateVisualizerFrame() nothrow {
	// Update each voice envelope
	for(int v = 0; v < 3; v++) {
		VoiceActivity* voice = &voices[v];

		final switch(voice.state) {
		case EnvelopeState.Silent:
			voice.brightness = 0.0f;
			break;

		case EnvelopeState.Attack:
			voice.brightness += voice.deltaPerFrame;
			if(voice.brightness >= voice.targetBrightness) {
				voice.brightness = voice.targetBrightness;
				// Transition to decay
				voice.state = EnvelopeState.Decay;
				float sustainBrightness = voice.sustainLevel / 15.0f;
				voice.targetBrightness = sustainBrightness;
				if(voice.brightness > sustainBrightness) {
					voice.deltaPerFrame = -(voice.brightness - sustainBrightness) / max(1, voice.decayFrames);
				}
				else {
					// Already below sustain (shouldn't happen)
					voice.state = EnvelopeState.Sustain;
				}
			}
			break;

		case EnvelopeState.Decay:
			voice.brightness += voice.deltaPerFrame;
			if(voice.brightness <= voice.targetBrightness) {
				voice.brightness = voice.targetBrightness;
				voice.state = EnvelopeState.Sustain;
				voice.deltaPerFrame = 0.0f;
			}
			break;

		case EnvelopeState.Sustain:
			// Hold at sustain level
			voice.brightness = voice.sustainLevel / 15.0f;
			break;

		case EnvelopeState.Release:
			voice.brightness += voice.deltaPerFrame;
			if(voice.brightness <= 0.0f) {
				voice.brightness = 0.0f;
				voice.state = EnvelopeState.Silent;
				voice.deltaPerFrame = 0.0f;
			}
			break;
		}

		// Clamp brightness
		voice.brightness = max(0.0f, min(1.0f, voice.brightness));
	}

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
 * Reset all visualization state
 */
void resetVisualizer() nothrow {
	for(int v = 0; v < 3; v++) {
		voices[v] = VoiceActivity.init;
		lastInstrument[v] = 0;
		activeWaveRows[v] = -1;
		activePulseRows[v] = -1;
		activeChordRows[v] = -1;
	}
	activeFilterRow = -1;
	instrumentBrightness[] = 0.0f;
}
