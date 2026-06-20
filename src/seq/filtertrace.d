/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Offline per-song-row SID filter-state trace built by running the real player in a private 6502 emulator.
*/

module seq.filtertrace;

import ct.base;
import com.cpu;

// Per absolute-song-row snapshot of the global SID filter state, derived by
// running the song's own compiled player offline. `valid` is false for rows
// where no filter program is engaged (rendered blank).
struct FilterRowState {
	ushort cutoff;       // 11-bit FC value (FC_HI:FC_LO from the private image)
	ubyte  res;          // resonance, $d417 high nibble
	ubyte  mask;         // channel mask, $d417 low nibble (bits 0-2 = voices 1-3)
	ubyte  mode;         // filter-mode bits 0x70 -> Low/Band/High pass
	bool   cutoffStatic; // cutoff is a table-exact value (set or held), not swept
	bool   sweeping;     // cutoff is being swept this row -> "calculated"
	bool   valid;        // false => no active filter program (render blank)
}

// SHTRANS-relative player-state variable offsets (see src/c64/player_v4.acme:
// 1988-2016). Confirmed against audio.visualizer which reads filtcur at +45.
private enum : int {
	OFF_CURSEQ  = 36, // curseq[3]
	OFF_SEQCNT  = 39, // seqcnt[3]
	OFF_BANDPASS = 42,
	OFF_FILTER   = 43, // cutoff high (mirrors $d416)
	OFF_FILTCNT  = 44,
	OFF_FILTCUR  = 45, // active filttab step, used directly as byte index
	OFF_FILTNXT  = 46,
	OFF_FILTADD  = 47, // [47]=whole, [48]=fractional carry
	OFF_FILTLO   = 49,
}

// Player entry points (mirror audio.callback / audio.player.initPlayOffset).
private enum : ushort {
	ENTRY_INIT  = 0x1000,
	ENTRY_PLAY  = 0x1003, // main tick: advances sequence/track + sound
	ENTRY_SOUND = 0x1006, // multispeed sound-only tick (no sequence advance)
}

private enum int MAX_TRACE_ROWS = 4096;
private enum int MAX_TRACE_FRAMES = 2_000_000;
private enum int WRAP_MARK = 0xf0; // tracklist entry trans >= 0xf0 marks the loop

// Offline filter-state trace. Owns a private CPU over a copy of the live song
// image, so it computes identically regardless of which playback transport
// (internal reSID / VICE / Ultimate) is active and never disturbs live audio.
class FilterTrace {
	private FilterRowState[] rows;
	private int builtGen = int.min;
	private int builtSub = int.min;
	private bool hasFilter;

	// Recompute only when the song was edited (edit generation) or the active
	// subtune changed. Cheap to call every draw.
	void ensureFresh(Song song, int editGen, int subtune) {
		if(rows !is null && editGen == builtGen && subtune == builtSub)
			return;
		rebuild(song);
		builtGen = editGen;
		builtSub = subtune;
	}

	int length() const { return cast(int)rows.length; }
	bool active() const { return hasFilter; }

	// Bounds-checked accessor. The trace only covers the first pass (up to the
	// loop point); rows before song start or at/after the loop point are blank.
	FilterRowState at(int absRow) const {
		FilterRowState blank;
		if(absRow < 0 || absRow >= rows.length) return blank;
		return rows[absRow];
	}

	private void rebuild(Song song) {
		rows = null;
		hasFilter = false;
		if(song is null) return;

		int n = firstPassRows(song, 0);
		if(n <= 0) return;
		if(n > MAX_TRACE_ROWS) n = MAX_TRACE_ROWS;

		// Private 64K image + CPU; never touch song.cpu / song.memspace.
		ubyte[] img = song.memspace.dup;
		auto cpu = new CPU(img);

		int base    = song.offsets[Offsets.SHTRANS];
		// speedcnt sits right after `speed` in the player (player_v4.acme:1941-1942).
		int speedcntAddr = song.offsets[Offsets.SPEED] + 1;

		try {
			initToStart(song, img, cpu);

			auto traced = new FilterRowState[](n);
			int mul = song.multiplier < 1 ? 1 : song.multiplier;
			int absRow = -1;
			int tick = 0;
			int frames = 0;

			while(frames < MAX_TRACE_FRAMES) {
				bool mainTick = (tick % mul) == 0;
				cpu.execute(mainTick ? ENTRY_PLAY : ENTRY_SOUND);
				frames++;
				// A song-frame boundary (speedcnt counts down to 0) is exactly one
				// displayed row: updseq fetches the next sequence element there.
				// This maps one-to-one to the editor's row grid, without the
				// double counting that watching curseq/seqcnt suffers at sequence
				// boundaries (updtrack resets seqcnt a frame before the fetch).
				//
				// At this instant the just-fetched row's own note/command has NOT
				// taken effect yet (gate / hard-restart delay), but the *previous*
				// row's filter program has fully settled. So attribute the snapshot
				// to the previous row — that keeps the column aligned with the
				// note/command that produced the filter change.
				if(mainTick && img[speedcntAddr] == 0) {
					if(absRow >= 0) {
						traced[absRow] = snapshot(img, base);
						if(traced[absRow].valid) hasFilter = true;
					}
					absRow++;
					if(absRow >= n) break;
				}
				tick++;
			}
			rows = traced;
		}
		catch(Exception e) {
			// A malformed image shouldn't take the editor down; just show nothing.
			rows = null;
			hasFilter = false;
		}
	}

	// Read the global filter register state out of the private image.
	private static FilterRowState snapshot(const ubyte[] img, int base) {
		FilterRowState st;
		// A non-zero sweep slope means the cutoff is being calculated this row;
		// otherwise it is a table-exact value (set or held flat).
		bool sweeping = (img[base + OFF_FILTADD] != 0) ||
						(img[base + OFF_FILTADD + 1] != 0);
		int d415 = img[0xd415];
		int d416 = img[0xd416];
		int d417 = img[0xd417];
		int bandpass = img[base + OFF_BANDPASS];

		st.cutoff = cast(ushort)((d416 << 3) | (d415 & 7));
		st.res    = cast(ubyte)(d417 >> 4);
		st.mask   = cast(ubyte)(d417 & 0x0f);
		st.mode   = cast(ubyte)(bandpass & 0x70);
		st.sweeping = sweeping;
		st.cutoffStatic = !sweeping;
		st.valid = (st.mask & 0x07) != 0 || st.mode != 0;
		return st;
	}

	// Mirror audio.player.initPlayOffset([0,0,0],[0,0,0]) on the private image:
	// seek the player to song start (subtune already active in song.memspace).
	private void initToStart(Song song, ubyte[] img, CPU cpu) {
		void out16b(int offs, int value) {
			img[offs] = value & 0xff;
			img[offs + 1] = (value >> 8) & 0xff;
		}
		ushort off1 = cast(ushort)song.offsets[Offsets.Track1];
		ushort off2 = cast(ushort)song.offsets[Offsets.Track2];
		ushort off3 = cast(ushort)song.offsets[Offsets.Track3];
		int tpoin2 = song.offsets[Offsets.Songsets];
		int tpoin = song.offsets[Offsets.TRACKLO];
		cpu.reset();
		if(song.ver >= 6) {
			img[tpoin]   = off1 & 0xff;
			img[tpoin+1] = off2 & 0xff;
			img[tpoin+2] = off3 & 0xff;
			img[tpoin+3] = off1 >> 8;
			img[tpoin+4] = off2 >> 8;
			img[tpoin+5] = off3 >> 8;
			out16b(tpoin2, off1);
			out16b(tpoin2+2, off2);
			out16b(tpoin2+4, off3);
		}
		else {
			out16b(tpoin2, off1);
			out16b(tpoin2+2, off2);
			out16b(tpoin2+4, off3);
		}
		cpu.execute(ENTRY_INIT);
		int ns = song.offsets[Offsets.NEWSEQ];
		img[ns]   = 1; // row 0 of each voice (s[v]*4+1, s=[0,0,0])
		img[ns+1] = 1;
		img[ns+2] = 1;
		// Force all three voices audible regardless of the editor's mute state,
		// so instrument-driven filter programs actually trigger.
		int vo = song.offsets[Offsets.VOICE];
		img[vo]   = 0x19;
		img[vo+1] = 0x19;
		img[vo+2] = 0x19;
	}

	// Number of rows in one pass of a voice's tracklist (up to the loop mark) =
	// the loop period for the common case where all voices share a length.
	private int firstPassRows(Song song, int voice) {
		auto tl = song.tracks[voice];
		int n = 0;
		for(int i = 0; i < tl.trackLength; i++) {
			Track t = tl[i];
			if(t.trans >= WRAP_MARK) break;
			n += song.sequence(t).rows;
		}
		return n;
	}
}
