/* reSID interface
 *
 * much of the code here is from GOATTRACKER, (c) Cadaver
 */
#define PALCLOCKRATE 985248
#define NTSCCLOCKRATE 1022727

#define NUMSIDREGS 0x19
#define SIDWRITEDELAY 9 // lda $xxxx,x 4 cycles, sta $d400,x 5 cycles
#define SIDWAVEDELAY 4 // and $xxxx,x 4 cycles extra

#include <stdlib.h>
#include <resid/sid.h>
#include <resid-fp/sidfp.h>
//#include <assert.h>
#include <stdio.h>

// Run one complete player-tick register-write schedule against an isolated SID.
// This is the same 25-register order and 9-cycle write cost used by sid_fillbuffer;
// generated PCM is discarded by the caller.
template<class Engine>
static int fill_tick(Engine& engine, const unsigned char regs[0x19],
		int clock_rate, int sample_rate, short *scratch, int sample_count,
		int player_cycles)
{
	static const unsigned char order[] = {
		0x0e,0x0f,0x14,0x13,0x10,0x11,0x12,
		0x07,0x08,0x0d,0x0c,0x09,0x0a,0x0b,
		0x00,0x01,0x06,0x05,0x02,0x03,0x04,
		0x16,0x17,0x18,0x15
	};
	int remaining_samples = sample_count;
	short *ptr = scratch;
	int remaining_cycles = clock_rate * sample_count / sample_rate;
	for(unsigned c = 0; c < sizeof(order); ++c) {
		// The music routine's execution time is split before each voice, exactly as
		// in the realtime path. This matters when AD/SR/GATE change on this tick.
		if(player_cycles > 0 && (c == 0 || c == 7 || c == 14)) {
			cycle_count delay = player_cycles / 3;
			int produced = engine.clock(delay, ptr, remaining_samples);
			ptr += produced;
			remaining_samples -= produced;
			remaining_cycles -= player_cycles / 3;
		}
		unsigned char reg = order[c];
		engine.write(reg, regs[reg]);
		cycle_count delay = SIDWRITEDELAY;
		int produced = engine.clock(delay, ptr, remaining_samples);
		ptr += produced;
		remaining_samples -= produced;
		remaining_cycles -= SIDWRITEDELAY;
	}
	cycle_count tail = remaining_cycles;
	return (ptr - scratch) + engine.clock(tail, ptr, remaining_samples);
}

extern "C" {
	typedef struct
	{
		float distortionrate;
		float distortionpoint;
		float distortioncfthreshold;
		float type3baseresistance;
		float type3offset;
		float type3steepness;
		float type3minimumfetresistance;
		float type4k;
		float type4b;
		float voicenonlinearity;
	} FILTERPARAMS;

	int clockrate;
	int samplerate;
	unsigned char sidreg[NUMSIDREGS];
	const unsigned char sidorder[] = {
        0x0e,0x0f,0x14,0x13,0x10,0x11,0x12,
        0x07,0x08,0x0d,0x0c,0x09,0x0a,0x0b,
        0x00,0x01,0x06,0x05,0x02,0x03,0x04,
        0x16,0x17,0x18,0x15
	};
	SID *sid= 0;
	SIDFP *sidfp = 0;
	int residdelay = 0;
	int usefp = 0;

	void sid_close() {
		if(sid) { delete sid; sid = 0; }
		if(sidfp) { delete sidfp; sidfp = 0; }
	}

	// Snapshot the selected backend's three raw 8-bit envelope counters. This is
	// deliberately separate from SID register reads: ENV3 exposes only voice 3 and
	// also models bus behaviour, while the visualizer needs a side-effect-free value
	// for every voice at the end of the PCM block just rendered.
	void sid_read_envelopes(unsigned char out[3])
	{
		if(!out) return;
		for(int i = 0; i < 3; ++i) {
			if(usefp && sidfp) out[i] = sidfp->readENV((reg8)i);
			else if(sid) out[i] = sid->readENV((reg8)i);
			else out[i] = 0;
		}
	}

	// Render an isolated, silent envelope trace with the same digital envelope core as
	// the selected audio backend. No global SID instance, register shadow, PCM buffer,
	// SDL device, capture state, or remote backend is touched.
	int sid_render_envelope_preview(unsigned char attack_decay,
		unsigned char sustain_release, int gate_ticks, int multiplier, int restart_ticks,
		unsigned char *out, int ticks)
	{
		if(!out || ticks < 1) return 0;
		if(gate_ticks < 1) gate_ticks = 1;
		if(multiplier < 1) multiplier = 1;
		int screenrate = clockrate == NTSCCLOCKRATE ? 60 : 50;
		int samples = samplerate / (screenrate * multiplier);
		if(samples < 1) samples = 1;
		if(restart_ticks < 0) restart_ticks = 0;
		short *scratch = new short[samples];
		unsigned char regs[NUMSIDREGS] = {0};
		if(usefp) {
			SIDFP preview;
			preview.set_sampling_parameters(clockrate, SAMPLE_INTERPOLATE, samplerate);
			preview.reset();
			for(int tick = 0; tick < restart_ticks; ++tick)
				fill_tick(preview, regs, clockrate, samplerate, scratch, samples, 0);
			for(int tick = 0; tick < ticks; ++tick) {
				regs[5] = attack_decay;
				regs[6] = sustain_release;
				regs[4] = tick < gate_ticks ? 0x11 : 0x10;
				fill_tick(preview, regs, clockrate, samplerate, scratch, samples, 0);
				out[tick] = preview.readENV(0);
			}
		} else {
			SID preview;
			preview.set_sampling_parameters(clockrate, SAMPLE_FAST, samplerate, 20000);
			preview.reset();
			for(int tick = 0; tick < restart_ticks; ++tick)
				fill_tick(preview, regs, clockrate, samplerate, scratch, samples, 0);
			for(int tick = 0; tick < ticks; ++tick) {
				regs[5] = attack_decay;
				regs[6] = sustain_release;
				regs[4] = tick < gate_ticks ? 0x11 : 0x10;
				fill_tick(preview, regs, clockrate, samplerate, scratch, samples, 0);
				out[tick] = preview.readENV(0);
			}
		}
		delete[] scratch;
		return ticks;
	}
	
	void sid_init(int fp, FILTERPARAMS *fparams, int speed, unsigned m, unsigned ntsc, unsigned interpolate, unsigned customclockrate)
	{
		int c;

		usefp = fp;
		
		if (ntsc) clockrate = NTSCCLOCKRATE;
		else clockrate = PALCLOCKRATE;
	
		if (customclockrate)
			clockrate = customclockrate;
	
		samplerate = speed;
	
		if (!sidfp) sidfp = new SIDFP();
		if (!sid) sid = new SID();
		
		if(usefp) {
			switch(interpolate)
			{
			case 0:
				sidfp->set_sampling_parameters(clockrate, SAMPLE_INTERPOLATE, speed);
				break;
			default:
				sidfp->set_sampling_parameters(clockrate, SAMPLE_RESAMPLE_INTERPOLATE, speed);
				break;
			}
			sidfp->reset();
			for (c = 0; c < NUMSIDREGS; c++) {
				sidreg[c] = 0x00;
			}

			if (m == 1)
				sidfp->set_chip_model(MOS8580);
			else
				sidfp->set_chip_model(MOS6581);
			sidfp->get_filter().set_distortion_properties(
                fparams->distortionrate,
                fparams->distortionpoint,
                fparams->distortioncfthreshold);
			sidfp->get_filter().set_type3_properties(
                fparams->type3baseresistance,
                fparams->type3offset,
                fparams->type3steepness,
                fparams->type3minimumfetresistance);
			sidfp->get_filter().set_type4_properties(
                fparams->type4k,
                fparams->type4b);
			sidfp->set_voice_nonlinearity(
                fparams->voicenonlinearity);
			sidfp->enable_filter(true);
		}
		else {
			switch(interpolate)
			{
			case 0:
				sid->set_sampling_parameters(clockrate, SAMPLE_FAST, speed, 20000);
				break;
			default:
				sid->set_sampling_parameters(clockrate, SAMPLE_INTERPOLATE, speed, 20000);
				break;
			}
			sid->reset();
			for (c = 0; c < NUMSIDREGS; c++) {
				sidreg[c] = 0x00;
			}
  
			if (m == 1) {
				sid->set_chip_model(MOS8580);
			}
			else {
				sid->set_chip_model(MOS6581);
			}
		}
	}
  
	unsigned char sid_getorder(unsigned char index) {
		return sidorder[index];
	}
	
	int sid_fillbuffer(short *ptr, int samples, const int cyc) {
		if(usefp) return fill_tick(*sidfp, sidreg, clockrate, samplerate, ptr, samples, cyc);
		return fill_tick(*sid, sidreg, clockrate, samplerate, ptr, samples, cyc);
	}
}
