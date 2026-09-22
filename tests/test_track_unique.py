"""Make-unique through both track views and the real Track dropdown."""
import re
import unittest

from tests.ccdriver_session import CCDriverSession


def tracks(s):
    return re.findall(r'^trk v\d+:(.*)$', s.run('tracks'), re.M)


def sequence(s, number):
    return re.search(r'rows=.*', s.run(f'seqdump:{number}')).group()


def geometry(s):
    return tuple(map(int, re.search(r'x=(\d+) y=(\d+)', s.run('trackgeometry')).groups()))


def select_two(s, view):
    if view == 'bottom':
        x, y = geometry(s)
        s.run(f'drag:{x+4},{y+2},{x+4},{y+1}')  # reversed drag
    else:
        for key in ('F5', 'Ctrl-b', 'DOWN', 'Ctrl-Shift-b'):
            s.run('key:' + key)


def menu_unique(s):
    rows = dict((int(y), text) for y, text in re.findall(r'^screen(\d+):(.*)$', s.run('screendump'), re.M))
    s.run(f'click:{rows[0].index("Track")+1},0')
    rows = re.findall(r'^screen(\d+):(.*)$', s.run('screendump'), re.M)
    y, text = next((int(y), text) for y, text in rows if 'Make unique' in text)
    s.run(f'click:{text.index("Make unique")},{y}')


class TrackUniqueTests(unittest.TestCase):
    def test_menu_copies_each_occurrence_in_order_and_undo_restores_slots(self):
        for view in ('bottom', 'F5'):
            with self.subTest(view=view), CCDriverSession('key:ESC', 'uniquefixture:normal') as s:
                before = tracks(s)
                originals = [sequence(s, n) for n in range(11)]
                select_two(s, view)
                menu_unique(s)
                self.assertEqual(tracks(s), [' a203 a504', *before[1:]])
                for n in (3, 4):
                    self.assertEqual(sequence(s, n), originals[10])
                for n in (0, 1, 2, 10):
                    self.assertEqual(sequence(s, n), originals[n])
                self.assertIn('undo: depth=1', s.run('undostate'))
                s.run('key:Ctrl-z')
                self.assertEqual(tracks(s), before)
                self.assertEqual([sequence(s, n) for n in range(11)], originals)
                s.run('key:Ctrl-y')
                self.assertEqual(tracks(s), [' a203 a504', *before[1:]])
                for n in (3, 4):
                    self.assertEqual(sequence(s, n), originals[10])

    def test_no_capacity_is_atomic_in_both_views(self):
        for view in ('bottom', 'F5'):
            with self.subTest(view=view), CCDriverSession('key:ESC', 'uniquefixture:full') as s:
                before = tracks(s)
                free = sequence(s, 3)
                select_two(s, view)
                s.run('key:Ctrl-u')
                self.assertEqual(tracks(s), before)
                self.assertEqual(sequence(s, 3), free)
                self.assertIn('undo: depth=0', s.run('undostate'))
                self.assertIn('Not enough empty sequences', s.run('screendump'))

    def test_click_clears_block_and_shortcut_copies_only_cursor(self):
        with CCDriverSession('key:ESC', 'uniquefixture:normal') as s:
            select_two(s, 'bottom')
            x, y = geometry(s)
            s.run(f'click:{x+4},{y+2}')
            self.assertIn('action=trk_make_unique invoked=true', s.run('keyprobe:Ctrl-u'))
            self.assertEqual(tracks(s)[0], ' a20a a503')

    def test_bottom_multivoice_selection_skips_gaps_and_loop(self):
        with CCDriverSession('key:ESC', 'uniquefixture:normal') as s:
            x, y = geometry(s)
            s.run(f'click:{x+4},{y+1}')
            s.run(f'shiftclick:{x+9},{y+3}')
            s.run('key:Ctrl-u')
            # Row-major allocation: voice 0 then voice 1 at offset 0, then
            # voice 0 at offset 2. Voice 1's gap and both LOOP cells are skipped.
            self.assertEqual(tracks(s), [' a203 a505', ' a004', ' a000'])
            self.assertEqual(sequence(s, 4), sequence(s, 0))
            self.assertEqual(sequence(s, 3), sequence(s, 10))
            self.assertEqual(sequence(s, 5), sequence(s, 10))

    def test_f5_multivoice_selection(self):
        with CCDriverSession('key:ESC', 'uniquefixture:normal') as s:
            for key in ('F5', 'Ctrl-b', 'Alt-2', 'Ctrl-Shift-b', 'Ctrl-u'):
                s.run('key:' + key)
            self.assertEqual(tracks(s), [' a203 a50a', ' a004', ' a000'])

    def test_bottom_selection_replaces_pattern_selection_and_clears_visually(self):
        with CCDriverSession('key:ESC', 'uniquefixture:normal') as s:
            s.run('key:F6')
            s.run('key:Ctrl-b')
            self.assertIn('pattern selection: true', s.run('selectionstate'))
            x, y = geometry(s)
            select_two(s, 'bottom')
            self.assertIn('pattern selection: false', s.run('selectionstate'))
            s.run('key:F6')
            s.run('key:Ctrl-b')
            self.assertIn('bg=0', s.run(f'cellstate:{x+4},{y+2}'))

    def test_loop_pointer_does_not_reserve_an_empty_sequence(self):
        with CCDriverSession('key:ESC', 'uniquefixture:loop') as s:
            select_two(s, 'bottom')
            s.run('key:Ctrl-u')
            self.assertEqual(tracks(s)[0], ' a202 a503')

    def test_loop_cursor_does_nothing(self):
        with CCDriverSession('key:ESC', 'uniquefixture:normal') as s:
            x, y = geometry(s)
            before = tracks(s)
            s.run(f'click:{x+4},{y+3}')
            s.run('key:Ctrl-u')
            self.assertEqual(tracks(s), before)
            self.assertIn('undo: depth=0', s.run('undostate'))
