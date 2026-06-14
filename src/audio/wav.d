/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Minimal canonical PCM WAV (RIFF/WAVE) writer for the offline audio export.
*/

module audio.wav;

// Encode mono PCM (the 16-bit signed samples reSID produces) as a canonical
// 44-byte-header WAV file image (little-endian). `rate` is the sample rate in Hz;
// `bits` selects the output sample format: 8 = unsigned PCM, 16/24 = signed PCM,
// 32 = IEEE float. (The source precision is 16-bit; 24/32 just widen the format.)
// Returns the complete file bytes, ready for std.file.write.
ubyte[] wavBytes(const short[] pcm, int rate = 48000, int bits = 16) {
	if(bits != 8 && bits != 16 && bits != 24 && bits != 32) bits = 16;
	enum channels = 1;
	immutable bool isFloat = (bits == 32);
	immutable int bytesPer = bits / 8;
	int dataBytes = cast(int)(pcm.length * bytesPer);
	int byteRate = rate * channels * bytesPer;
	ushort blockAlign = cast(ushort)(channels * bytesPer);

	ubyte[] b;
	b.reserve(44 + dataBytes);

	void u32(uint v) {
		b ~= cast(ubyte)(v & 0xff);
		b ~= cast(ubyte)((v >> 8) & 0xff);
		b ~= cast(ubyte)((v >> 16) & 0xff);
		b ~= cast(ubyte)((v >> 24) & 0xff);
	}
	void u16(ushort v) {
		b ~= cast(ubyte)(v & 0xff);
		b ~= cast(ubyte)((v >> 8) & 0xff);
	}
	void tag(string s) { foreach(c; s) b ~= cast(ubyte)c; }

	tag("RIFF");
	u32(36 + dataBytes);        // RIFF chunk size = 4 + (8+16) + (8+data)
	tag("WAVE");

	tag("fmt ");
	u32(16);                    // fmt chunk size
	u16(isFloat ? 3 : 1);       // audio format: 1 = PCM, 3 = IEEE float
	u16(channels);
	u32(rate);
	u32(byteRate);
	u16(blockAlign);
	u16(cast(ushort)bits);

	tag("data");
	u32(dataBytes);
	foreach(s; pcm) {
		switch(bits) {
		case 8:
			// 8-bit WAV is unsigned: center 0 at 128.
			b ~= cast(ubyte)(((s >> 8) + 128) & 0xff);
			break;
		case 24:
			int v24 = cast(int)s << 8;          // widen 16-bit to 24-bit
			b ~= cast(ubyte)(v24 & 0xff);
			b ~= cast(ubyte)((v24 >> 8) & 0xff);
			b ~= cast(ubyte)((v24 >> 16) & 0xff);
			break;
		case 32:
			float f = s / 32768.0f;
			uint u = *cast(uint*)&f;
			b ~= cast(ubyte)(u & 0xff);
			b ~= cast(ubyte)((u >> 8) & 0xff);
			b ~= cast(ubyte)((u >> 16) & 0xff);
			b ~= cast(ubyte)((u >> 24) & 0xff);
			break;
		default:        // 16-bit signed LE
			b ~= cast(ubyte)(s & 0xff);
			b ~= cast(ubyte)((s >> 8) & 0xff);
			break;
		}
	}
	return b;
}
