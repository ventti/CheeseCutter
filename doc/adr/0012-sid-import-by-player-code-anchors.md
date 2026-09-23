# 0012 — .sid import finds the player's tables by code anchors

**Status:** Accepted.

## Context

File → Import .sid (and `ct2util sid2ct`) turns a CheeseCutter-made PSID back
into a song. An exported `.sid` is not an editor image:

- `ct.build` purges the song and **reassembles** `player_v4.acme` at the chosen
  address with only the effect code the song uses, so code size and every table
  address differ per song.
- The export drops the `$0fa0` offset table, the `CCx.xx` player ID, instrument
  names and table descriptions. Nothing in the file says where anything is.
- The **data order differs between player generations**. Today's exporter
  follows `ct.dump` (`arp1 … cmd3 songsets tracks sequences chord chordindex`);
  2012-era exports put `songsets` first; 4.00-era exports interleave tracks,
  tables and sequences. SIDs in the wild come from all of them.

Matching fixed offsets or whole-player byte signatures would need one entry per
player build × relocation × `INCLUDE_*` combination.

## Decision

`ct.sidimport` decodes the player code (up to the frequency table, which is
identical in every 4.x build and is the first proof of a CheeseCutter player)
into instructions and matches short instruction sequences ("anchors") that the
player's table-reading code has kept since 4.00, capturing their operands:

- `asl / asl / asl / tay / ldx #0 … lda songsets,y`
- `ldy x / lda seqlo,y / sta zp / lda seqhi,y / sta zp`
- `ldy x / lda inst,y / sta x / lda inst+SR,y / sta x` (gives the column stride)
- `lda arp1+1,y / cmp #$7e / … / lda arp2,y / tay`
- `pulstab`/`filttab`: the tables read at +0..+3 (pulstab is the `adc` one)
- `and #$1f / tay / lda chordindex,y`, `lda chord,y / cmp #$40`
- cmd1-3: the evenly spaced triple of `abs,y` targets nobody else claims

Tracks and sequences are then reached through their pointers. Every table start
is sorted, and each table's length is the gap to the next start, which works for
any dump order. The orderlists and sequences are unpacked by inverting
`Tracklist.compact` / `Sequence.compact`. The parser is pure (`SidSong` out, no
`ct.base`); `Song.importSidSong` writes it into a song.

Semantic differences between generations are mapped to today's player. The one
found is the hard-restart SR: before 4.01 it was one global byte (`lda cmd3`), so
the importer copies it into every instrument's column 6 (`897b02f`).

Correctness is judged by playback, not bytes: `ct2util sidtrace` prints the SID
registers after each play call, and `tests/test_sid_import.py` requires
`trace(export(original)) == trace(export(import(sid)))` for every bundled tune,
relocation, zero-page and subtune variant, plus real 2013/14 releases replaying
exactly against their own `.sid`.

## Consequences

- Any relocation, zero page, subtune selection or multispeed wrapper works
  without per-build tables. A player without the frequency table or any
  required anchor is rejected as "not a CheeseCutter 2.x SID" rather than
  half-converted. 3.x-player SIDs are untested (no reference file; see `TODO`).
- The recovered song is the *purged* song: renumbered, names lost, identical
  instruments possibly merged. That is inherent in the export, not the importer.
- Changing the player's table-reading code can break an anchor. The round-trip
  tests fail if today's exports stop converting; old releases are covered by the
  fixtures in `tests/fixtures/sid/`.
- 2012-era player builds also differ from 4.07 in playback (not only data order).
  Their songs convert, but sound the way the old-`.ct` upgrade path makes them
  sound.
