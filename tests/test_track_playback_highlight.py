"""The Tracks table distinguishes playback position from editor position."""
import re
import unittest

from tests.ccdriver_session import CCDriverSession


class TrackPlaybackHighlightTests(unittest.TestCase):
    def test_playback_moves_one_highlight_per_voice_and_stop_restores_editor(self):
        with CCDriverSession('load:tunes/vent-arkijuusto.ct', 'key:ESC') as session:
            x, y, height = map(int, re.search(
                r'x=(\d+) y=(\d+) height=(\d+)',
                session.run('trackgeometry')).groups())

            def highlighted_rows():
                return [
                    [row for row in range(height)
                     if 'fg=13 ' in session.run(
                         f'cellstate:{x + 4 + voice * 5},{y + 1 + row}')]
                    for voice in range(3)
                ]

            self.assertEqual(highlighted_rows(), [[0], [0], [0]])
            session.run('key:F1')
            positions = []
            for _ in range(8):
                session.run('ff:12')
                session.run('tick:2')
                rows = highlighted_rows()
                for voice_rows in rows:
                    self.assertEqual(len(voice_rows), 1, rows)
                positions.append(rows)
            # The song must actually advance beyond the stationary edit cursor.
            for voice in range(3):
                self.assertTrue(any(rows[voice][0] > 0 for rows in positions))
            session.run('key:F4')
            self.assertEqual(highlighted_rows(), [[0], [0], [0]])


if __name__ == '__main__':
    unittest.main()
