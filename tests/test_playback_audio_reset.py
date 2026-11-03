"""Explicit Play commands recover a lost device; note entry does not reopen it."""
import re
import unittest

from tests.ccdriver_session import CCDriverSession


SONG = 'load:tunes/vent-arkijuusto.ct'


def audio_state(session):
    output = session.run('audiostate')
    match = re.search(r'audio: playing=(true|false) status=(\d+) ticks=(\d+)', output)
    if match is None:
        raise AssertionError(output)
    return match[1] == 'true', int(match[2]), int(match[3])


class PlaybackAudioResetTests(unittest.TestCase):
    def assert_playing(self, session):
        playing, status, ticks = audio_state(session)
        self.assertTrue(playing)
        self.assertEqual(status, 1)  # SDL_AUDIO_PLAYING
        self.assertGreater(ticks, 0, 'the real SDL audio callback must advance playback')

    def test_all_play_shortcuts_recover_lost_audio(self):
        for key in ('F1', 'F2', 'F3', 'Shift-F1', 'Shift-F2', 'Shift-F3'):
            with self.subTest(key=key), CCDriverSession(SONG, 'key:ESC') as s:
                s.run('audioloss')
                self.assertEqual(audio_state(s), (False, 0, 0))
                s.run('key:' + key)
                self.assert_playing(s)

    def test_resume_tracking_recovers_while_logically_playing(self):
        with CCDriverSession(SONG, 'key:ESC', 'key:F1') as s:
            self.assert_playing(s)
            s.run('audioloss')
            self.assertEqual(audio_state(s), (True, 0, 0))
            s.run('key:Shift-F3')
            self.assert_playing(s)
            # F1 drops tracking when already following; it must recover too.
            s.run('audioloss')
            s.run('key:F1')
            self.assert_playing(s)

    def test_play_menu_uses_the_same_recovery(self):
        with CCDriverSession(SONG, 'key:ESC') as s:
            s.run('audioloss')
            s.run('key:ESC')
            for _ in range(3):
                s.run('key:RIGHT')  # Playback menu, first item = Play from mark
            s.run('key:RET')
            self.assert_playing(s)

    def test_keyjam_does_not_reopen_device(self):
        with CCDriverSession(SONG, 'key:ESC', 'key:F6', 'key:Ctrl-k') as s:
            s.run('audioloss')
            s.run('key:z')
            self.assertEqual(audio_state(s), (True, 0, 0))

    def test_note_entry_does_not_reopen_device(self):
        with CCDriverSession(SONG, 'key:ESC', 'key:F6') as s:
            s.run('audioloss')
            s.run('key:z')
            _, status, ticks = audio_state(s)
            self.assertEqual((status, ticks), (0, 0))


if __name__ == '__main__':
    unittest.main()
