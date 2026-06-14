/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Minimal canonical PCM WAV (RIFF/WAVE) writer for the offline audio export.
*/

module audio.wav;

// Encode 16-bit signed mono PCM as a canonical 44-byte-header WAV file image
// (little-endian, the format reSID already produces). `rate` is the sample rate
// in Hz. Returns the complete file bytes, ready for std.file.write.
ubyte[] wavBytes(const short[] pcm, int rate = 48000) {
	enum channels = 1, bits = 16;
	int dataBytes = cast(int)(pcm.length * short.sizeof);
	int byteRate = rate * channels * (bits / 8);
	ushort blockAlign = cast(ushort)(channels * (bits / 8));

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
	u32(16);                    // PCM fmt chunk size
	u16(1);                     // audio format = PCM
	u16(channels);
	u32(rate);
	u32(byteRate);
	u16(blockAlign);
	u16(bits);

	tag("data");
	u32(dataBytes);
	foreach(s; pcm) {
		b ~= cast(ubyte)(s & 0xff);
		b ~= cast(ubyte)((s >> 8) & 0xff);
	}
	return b;
}
