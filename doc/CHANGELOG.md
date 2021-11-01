# News

**If you're a Facebook user, join the CheeseCutter SID music editor group to hear the latest gossip.**

## Version 2.9

* Added undo/redo (<kbd>Ctrl</kbd>-<kbd>Z</kbd> / <kbd>Ctrl</kbd>-<kbd>R</kbd>) functions for most editing functions in the sequencer.
* Fixed a serious bug in the player which caused song speed to go wrong (Y-register was not properly initialized).
* Position information for each subtune is retained. So as you change to another subtune, the editor jumps back to where you were last time in that subtune.
* Redesigned tracklist copy/paste functionality
        
  * <kbd>Ctrl</kbd>-<kbd>c</kbd> copies to memory
  * <kbd>Ctrl</kbd>-<kbd>v</kbd> pastes; dialog is opened for selecting paste mode (insert or overwrite)
  * <kbd>Ctrl</kbd>-<kbd>o</kbd> pastes overwriting the trackdata (exactly how <kbd>Alt</kbd>-<kbd>B</kbd> works)
  * <kbd>Ctrl</kbd>-<kbd>i</kbd> pastes by inserting to the cursor position

For convenience, old <kbd>Alt</kbd>-<kbd>Z</kbd> & <kbd>Alt</kbd>-<kbd>B</kbd> still work.
    
* Added "sync" support into the player. `F0` command increases counter at a sort-of fixed memory location. removes the possibility to use two chord programs for song speeds.
* Fixed a bug when deleting rows in chord table.
* Fixed crash in fileselector when last file in list had been moved/deleted and cursor was pointing to that file.
* Keyjam: gate is kept on for as long as the key is pressed. gate will be set off once key is released.
* Linux version now distributed as a snap package (64 bit only).
* `CC_HOME` shell variable sets default directory for load and save.

## Version 2.8 (28-11-2015)

* Can insert & delete rows in filter and pulse tables (<kbd>Shift</kbd>-<kbd>Insert</kbd> & <kbd>Shift</kbd>-<kbd>Delete</kbd>)
* Filter and pulse programs used by current instrument are highlighted.
* Window is resizable in YUV mode (no aspect ratio preserved).
* In the sequencer, <kbd>Keypad 0</kbd> plays the current row (all voices) and advances cursor a step down.
* Simple oscilloscope view via <kbd>Ctrl</kbd>-<kbd>F9</kbd> (works only in standard graphics mode).
* Simple instrument saver: Can now save, load and delete instruments with <kbd>Ctrl</kbd>-<kbd>L</kbd>, <kbd>Ctrl</kbd>-<kbd>S</kbd>, <kbd>Ctrl</kbd>-<kbd>D</kbd> when in instrument table. Instruments are saved to disk in a CSV-like format.

* Various confirmation dialogs added, e.g. when trying to overwrite an already existing file.
* Minor fix in 6502 emulation.
* Some checks for illegal values in the worktune during packing.
* Various stability fixes.
* Player changes:

* Improved preview note playback - used to randomly fail on notes with maximum sustain or long attack.

* Direct pulse width values via instrument byte 5:

	* Values `$00-$3F` launch pulse program (as previously)..
	* Values `$80-$8F` will just set the pulse high byte, no pulse program is launched.

* StereoSID version's `-mono` commandline flag disables stereo output.

## Version 2.7 (1-11-2014)

* New packing system. In short: the player is assembled from source up is used instead of byte banging. Allows optimizing unused effect code away, hence smaller (and a tiny bit faster) tunes.
* ct2util can export a single subtune with `-s` switch.
* "keyjam" bugfixed. It's still not perfect. Basically the started note plays until you enter a note off (<kbd>1</kbd> on the keyboard).
Also the header color changes when keyjam enabled to indicate the mode you're in.
* On Mac, keypad <kbd>=</kbd> equals PC's keypad <kbd>+</kbd>
* Lots of other MacOS related fixes from contributors.
* Also released a separate StereoSID version for StereoSID goodness. See d/l page. 

## Version 2.6.1 (13-6-2014) - Never say never.

Quick fix for the scaled full screen mode - the screen should be now centered properly.
Also, all builds were compiled with compiler optimizations enabled, so the program should waste little less CPU cycles.
Also, a possible fix to mac build script. Can't test it since I don't own a mac.

## Version 2.6 (10-5-2014) - The first real stable, hopefully.

The program is now based on the Mac version 2.5.1, which ported the whole source to D2 along with mac specific fixes, hence lots of internal changes. 
Hopefully no new bugs.

### What's new
 
* Third number dropped from version numbering scheme. It might still make occasional appearance if the release includes only small additions or bugfixes.
* Added some keymap translation mainly for laptop and mac use. These are currently not documented in the inbuilt help as it has already gotten pretty bloated.
	* Keypad Enter now works as alternative insert key (why the hell has insert been removed from modern keyboards in the first place?)

* <kbd><</kbd> and <kbd>></kbd> work as octave change in sequencer (<kbd>+</kbd> and <kbd>-</kbd> don't work right on some keymaps and keypad might be inaccessible)
* <kbd>Shift</kbd>-<kbd>up</kbd> / <kbd>Shift</kbd>-<kbd>down</kbd> corresponds to <kbd>Page Up</kbd> and <kbd>Page Down</kbd>, for laptops which have those keys in awkward location.

* "Logo key" (aka Windows/Super/Meta/Cmd-key) works as short for <kbd>Ctrl</kbd>-<kbd>Shift</kbd> keycombos in sequencer. Ie. <kbd>Ctrl</kbd>-<kbd>Shift</kbd>-<kbd>Insert</kbd> (which inserts a track for all voices) can be done
with "logo"-<kbd>Insert</kbd>. "Logo" and <kbd>1</kbd>-<kbd>9</kbd> corresponds to keypad <kbd>1</kbd>-<kbd>9</kbd>. The plan is to map at all keypad functions to "logo" key as alternative.
However, there's no guarantee that all platforms and desktop environments allow programs to use this key freely.

* Simple backup system implemented. Can be disabled with `-nobackup` command line flag.
* Exporting multispeed tunes work right on triple/quadruple/etc tunes.
* Chordtable purging had a bug which caused it to destroy the 1st chord in some cases.
* Using sequence 00 in the song caused ALL seqdata to be dumped into the exported tune. It would still play right but there was plenty of useless data included.
* Player updated to *4.03*. It uses the 7th instrument byte as hard restart SR envelope value.

Also, thanks to everyone who participated in the Release the Cheese competition. The 8 top entries are now included in the example tunes.

## Mac port released

Ruk / Triad has done a great job and ported the latest CC to Mac. Get it from the download page.

## Version 2.5.0 (13-5-2013) - The last beta (or the first stable?)

Plenty of bugfixes here and couple of new features and example tunes. Also, this new shiny web page makes its first appearance. 
The development will be put to rest for a while.

### Brief list of changes:

Editor

* Player specific help integrated into the tables - should make memorizing the meanings of bytes easier. Just press F12 on any table and a help box pops up. <kbd>Alt</kbd>-<kbd>H</kbd> switches this off.
Since the documentation is in the player binary itself, and you happen to use some older player in your tune, the help won't work.
* Aspect correction works right (ie. keeping the 4:3 ratio) on wider screens. You will need to launch the program with parameter *-ya* to enable it.
* Transpose is now always preserved on wrap point on packed tune.
* Packer sets the speed flags correctly when exporting to SID.
* Extra checks for note+trans overflows in the sequencer.
* Note data in sequencer are now by default displayed relative to the current transpose value (you can still get the old behavior with <kbd>Ctrl-T</kbd>).
* Keyjam thingy debugged (<kbd>Ctrl</kbd>-<kbd>Space</kbd>).
* Wrap position marker (purple bar) is actually visible behind the start position marker (blue bar). It looks a bit busy now though.
* Extra keybindings:
   * <kbd>Ctrl</kbd>-<kbd>Alt</kbd>-<kbd>c</kbd> = Clear all sequences.
   * <kbd>Ctrl</kbd>-<kbd>Alt</kbd>-<kbd>o</kbd> = Optimize song data.
* Track data swapping in the track table (<kbd>F5</kbd> or <kbd>F7</kbd> mode) - press <kbd>Ctrl</kbd>-<kbd>Alt</kbd>-<kbd>1</kbd> to swap the current voice's tracks from cursor down with voice 1's tracks. <kbd>Ctrl</kbd>-<kbd>Alt</kbd>-<kbd>2</kbd> swaps with voice 2's, etc. Note that wrap pointers are not updated and it's generally quite easy to mess up your song with this so use some caution.
* Multispeed driver bugfixed and doesn't fuck up the play after the song is restarted (playback counter was previously left uninitialized). Uses one extra ZP byte though.
* ct2util 'import': infs-array overflow error fixed
* 20ms delay before playback is started + cpucall is now never doing PauseAudio - should fix the long standing race condition thingy when calling 6502 emu from another thread.
* More verbose output on some error messages in playback.
* Purging used to cause chordindextable not to be regenerated (some "chords" could be played wrong after purging).
* Fixes to transposed octave input column.
* Some old example tunes imported to the latest player (kalma.ct still uses the old one since it wouldn't sound right with the changes to wave routine).
* Lots of internal stuff improved/rewritten.
* Lots of safety checks for Sequence splitting.
* Packer checks for overflow when relocating.
* Packer checks against the max. no of subtunes correctly when setting default subtune.
* and LOTS MORE.

Player
* Some editor specific code moved to upper memory and will be left out from the exported tune after packing.
* Lo-fi (cmd 5-xx xx) vibrato debugged.
* Wave program optimized and debugged. The player hogs 1-2 lines less (though it's still a piggy, make no mistake&#x2026;)
* Vibrafeel add done BEFORE main freq modulation - lofi-vibrato skips the unnecessary adds.
* Some size optimizations.

## Version 2.4.0 (23-9-2012)
### Editor

* YUV12 video overlay mode (parameter `-y`). Basically allows to use the editor in 
full screen independently of the actual screen resolution used. The YUV scaling can make the font seem a bit distorted. Also it will take more CPU time to draw the screen. The screen aspect ratio is not taken into account (unless you specify parameter -ya) so the program may look funny (funnier that usual&#x2026;) in certain resolutions.
* The allocated screen surface is now 32 bits instead of 8. This because YUV overlays don't work in 8
bits and possibly not in 16 bits either. Might be necessary to use 8 bit surface for regular mode and 32 bits only for YUV mode.
* ct2util: command "init" working now.
* Crucial packer fixes.
* Chord, filter, pulse & cmd tables are now also purged. Whee!
* Instrument & cmd tables are properly packed.
* Dumping to source works much better.
* Exporting multispeed tunes to SID bugfixed.
* Fixes for track deleting. When there are no more tracks to delete, an "empty" track (A000) is inserted.
* 1024x768 mode removed for now.

### Player

* Per-voice freq offsets reintroduced.
* Subtune which uses swingtempo is now initialized properly.
* Swing tempo inited correctly when setting speed from a sequence.
* Portamento logic yet again rewritten. Basically 7-xx xx starts the portamento and it stays on until another frequency altering command (0, 1, 2, 5 or 8) is issued.
* Three extra commands: 
   * 5-xx xx is now a "lo-fi" vibrato with parameter byte A corresponding duration and byte B the depth.
   * 6-xx xx sets the waveform (byte B). It's tricky to use since the wavetable is run continously and overwrites the waveform command unless you are specifically skipping the waveform in your wavetable program (using waveform value 0).
   * 8-xx xx stops any frequency altering command. Mostly useful with portamento (which now runs continously). The parameter bytes are ignored. Note that applying a slide command with value 0 basically does the same thing.

## Version 2.3.2 (29-3-2012)

* Chord number indicator for the chord table.
* A huge load of fixes for track editor, wrapmark handling etc.
* More codebase reorganizing.
* For better or worse, the Windows binaries are now compiled with -O2.

## Version 2.3.1 (24-3-2012)

* Console output on Windows (ct2util)

## Version 2.3.0 (18-3-2012) - First beta!

### Editor

* Major reorganization of the codebase.
* Now using Derelict SDL bindings. The program should finally run natively on MacOS X. The SDL libraries are linked dynamically and might cause problems where used not to be any.
* Can now skip forwards and backwards while in followplay mode (keys <kbd>+</kbd> and <kbd>-</kbd>) (very experimental, expect issues)
* Song data importing from Load File dialog (key <kbd>Shift</kbd>-<kbd>Enter</kbd>). Only the music data is loaded and the player that you currently have in memory is kept. This allows you to i.e. update your tune made with an older player to the current one.
* Sequencer: Lots of improvements to <kbd>F5</kbd> (the track view/editor)
* Instead of being centered, the pointer is "anchored" to top of the screen when browsing up & down like it used to work in 0.x. <kbd>Ctrl</kbd>-<kbd>L</kbd> centers the display.
* <kbd>Shift</kbd>-<kbd>F5</kbd> toggles the "hybrid" view where the following/preceding tracks are also displayed.
* Clear-command (<kbd>Alt</kbd>-<kbd>Keypad 0</kbd>) clears subtunes as well.

### Packer
* **ct2pack** replaced with **ct2util** which includes a few extra commands for song manipulation, besides packing.
* Song relocating implemented. When exporting to a SID-file, multispeed tunes cannot be relocated, or rather, the code
for playing the extra frames can't be relocated. There shouldn't be any need to relocate songs inside SID-files anyway.
* Dumping song data to acme source code implemented (BETA - instrument tables are not packed but dumped entirely).
* Importing (same as <kbd>Shift</kbd>-<kbd>Enter</kbd> in fileselector)

## Version 2.2.6 (2-3-2012)
* Added a simple mouse support: Tables and voices can be activated and the cursor moved to the desired spot with a mouse click. Mouse wheel acts similarly to pressing cursor up or down on the activated window. Some elements on the screen are clickable as well: 
  * Title
  * Playback multiplier (left button decreases the value, right increases)
  * SID Model & Filter preset (left button toggles the model, right button changes the preset)
* Inactive voices are properly shut down when entering notes.
* Caps lock also enables/disables keyjam.
* Entered notes are always played on the voice the cursor is currently on.
* Playback position is displayed in trackmap (<kbd>F7</kbd>).
* Song purging (<kbd>Alt</kbd>-<kbd>Keypad Del</kbd>) actually works: Unused sequences and instruments are removed & wave- and chord tables are cleaned. Also, sequences are checked against duplicates (ie. their length and data is identical) and removed if necessary.
* Doesn't crash when trying to load a non-editor file.
* Lots of internal rewrites. New bugs may have been introduced.
* Sequencer: <kbd>Ctrl</kbd>-<kbd>G</kbd> "grabs" the instrument value in the current row.
* <kbd>Enter</kbd> jumps between track and sequence editing (like <kbd>F5</kbd> does).
* Default audio frequency 48000hz instead of 44100hz.

## Version 2.2.5 (19-2-2012)

### Player 
* Portamento logic changed: it's not affected by set instrument command anymore. This causes portamento to 'regular' (not tied) notes not to work :/ 

### Sequencer
* When entering notes, the note on currently activated instrument gets played (on 1st voice only though).

## Version 2.2.4 (15-2-2012)

* 1st version of the keyjam mode (<kbd>Ctrl</kbd>-<kbd>Space</kbd>). All editing functions disabled during keyjam. 

## Version 2.2.3 (11-2-2012)

* Packer now supports subtunes. 
* Clock counter sometimes overwrapped when changing multiplier during play.

## Version 2.2.2 (9-2-2012)

* Sequencer: instrument values not autoinserted when entering tied notes.
* Message displayed when autoinsert mode gets toggled (with key <kbd>;</kbd>)
* Key <kbd>.</kbd> in wave table clears the row and moves cursor one row down.
* Extra keys: <kbd>[</kbd> and <kbd>]</kbd> for speed change; <kbd>{</kbd> and <kbd>}</kbd> for multiplier change.
* Some crucial packer bugfixes.

## Version 2.2.1 (7-2-2012)

* Followplay bugfixes: doesn't get out of sync when tracking songs with swingtempos. Should not screw up anymore when fastforwarding over a song speed change command.
* Wrapmark also displayed in <kbd>F7</kbd>.

## Version 2.2.0 (6-2-2012)

* New wrapmark logic: the value is stored with the track end indicator byte in he tracklist.
* Editor updated to display a marker for wrap mark position (the brown bar). 
* Song playback always wraps to this point independent of the method the playback was started with (using keys <kbd>F1</kbd>, <kbd>F2</kbd> or <kbd>F3</kbd>) <kbd>Ctrl</kbd>-<kbd>Backspace</kbd> in the sequencer sets the wrapmark.
* Revised packer: attaches custom player for multispeed tunes on SID export. 
* Player: filter sweeps use 10 bit resolution instead of 11.
* Default song speeds stored for each subtune now.
* "Context help" implemented: <kbd>F12</kbd> displays its own help screen for the Sequencer.
Pressing <kbd>F12</kbd> twice displays the global help screen.

## Version 2.1.0 (1-2-2012)

* Swing speeds are read from the chord table.
* Resid-fp is now used as default (`-nofp` uses old resid instead).
### Sequencer
* <kbd>F5</kbd> (track view) also displays the tracklist. The display is centered.
* v0.5 docs removed.
* First alpha version of the commandline song packer.
* All info strings editable with <kbd>Alt</kbd>-<kbd>T</kbd>.
* Default audiobuffer size 2048 instead of 1024.
* Help texts brought up to date.

## Version 2.0.0 (9-12-2011)
* Can navigate between sequencer and tables using <kbd>Ctrl</kbd>-<kbd>Tab</kbd>.
* Copy & paste functions for instrument table (<kbd>Ctrl</kbd>-<kbd>C</kbd> / <kbd>Ctrl</kbd>-<kbd>V</kbd>).
