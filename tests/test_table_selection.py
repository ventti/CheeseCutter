"""Table row selection through real mouse and keyboard dispatch."""
import re
import unittest
from tests.ccdriver_session import CCDriverSession

KINDS = ('instrument', 'wave', 'pulse', 'filter', 'command', 'chord')


def table(session, kind):
    output = session.run('tablebytes:' + kind)
    match = re.search(r'x=(\d+) y=(\d+) rows=(\d+) cols=(\d+)', output)
    geometry = tuple(map(int, match.groups()))
    values = [bytes.fromhex(row) for row in re.findall(r'^row \d+:(.*)$', output, re.M)]
    return geometry, values


class TableSelectionTests(unittest.TestCase):
    def test_all_table_encodings_cut_paste_and_undo(self):
        for kind in KINDS:
            with self.subTest(kind=kind), CCDriverSession('key:ESC') as s:
                (x, y, _, cols), _ = table(s, kind)
                # Real byte entry supplies a non-zero source, even in a blank song.
                if kind == 'command':
                    s.run(f'click:{x+3},{y+1}')
                    for digit in '12345':
                        s.run('key:' + digit)
                else:
                    for col in range(cols):
                        s.run(f'click:{x+3+col*3},{y+1}')
                        s.run('key:1')
                        s.run('key:2')
                _, original = table(s, kind)
                self.assertTrue(all(original[0]))
                s.run(f'drag:{x+3},{y+3},{x+3},{y+1}')  # reverse selection
                s.run('key:Ctrl-c')
                s.run('key:Ctrl-x')
                _, cut = table(s, kind)
                self.assertEqual(cut[:3], [bytes(cols)] * 3)
                self.assertEqual(cut[3:], original[3:])
                s.run('key:Ctrl-z')
                self.assertEqual(table(s, kind)[1], original)
                s.run('key:Ctrl-y')
                self.assertEqual(table(s, kind)[1], cut)
                s.run('key:Ctrl-z')
                s.run(f'click:{x+3},{y+6}')
                s.run('key:Ctrl-v')
                _, pasted = table(s, kind)
                expected = original.copy()
                expected[5:8] = original[:3]
                self.assertEqual(pasted, expected)
                s.run('key:Ctrl-z')
                self.assertEqual(table(s, kind)[1], original)
                # A smaller highlighted destination clips the clipboard.
                s.run(f'drag:{x+3},{y+10},{x+3},{y+11}')
                s.run('key:Ctrl-v')
                expected = original.copy()
                expected[9:11] = original[:2]
                self.assertEqual(table(s, kind)[1], expected)

    def test_plain_click_clears_shift_click_extends_and_clipboard_is_typed(self):
        with CCDriverSession('key:ESC') as s:
            (x, y, _, _), _ = table(s, 'wave')
            s.run(f'click:{x+3},{y+1}')
            s.run('key:1')
            s.run('key:2')
            original = table(s, 'wave')[1]
            s.run(f'click:{x+3},{y+1}')
            s.run(f'shiftclick:{x+3},{y+3}')
            s.run('key:Ctrl-c')
            # Single click cancels cut selection.
            s.run(f'click:{x+3},{y+6}')
            s.run('key:Ctrl-x')
            self.assertEqual(table(s, 'wave')[1], original)
            s.run('key:Ctrl-v')
            self.assertEqual(table(s, 'wave')[1][5:8], original[:3])
            for kind in ('pulse', 'filter', 'command', 'chord', 'instrument'):
                (tx, ty, _, _), before = table(s, kind)
                s.run(f'click:{tx+3},{ty+1}')
                s.run('key:Ctrl-v')
                self.assertEqual(table(s, kind)[1], before, kind)

    def test_paste_clips_at_table_end(self):
        with CCDriverSession('key:ESC') as s:
            (x, y, rows, _), _ = table(s, 'wave')
            s.run(f'click:{x+3},{y+1}')
            s.run('key:1')
            s.run('key:2')
            original = table(s, 'wave')[1]
            s.run(f'drag:{x+3},{y+1},{x+3},{y+3}')
            s.run('key:Ctrl-c')
            s.run(f'click:{x+3},{y+1}')
            for _ in range(rows - 1):
                s.run('key:DOWN')
            s.run('key:Ctrl-v')
            expected = original.copy()
            expected[-1] = original[0]
            self.assertEqual(table(s, 'wave')[1], expected)
