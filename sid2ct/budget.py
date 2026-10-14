"""One wall-clock budget for a whole conversion, checked inside inner loops.

A `Budget` is created once per conversion (see `EFFORTS`). Every stage runs
under `activate(budget)`, which makes it the ambient budget of the process;
inner loops call the module level `check()`, which raises `BudgetExpired` once
the deadline has passed. Stages that must always finish (the first candidate,
which guarantees an output) run inside `shield()`. Worker processes rebuild a
budget from the seconds the parent had left when it handed them a task.
"""
from contextlib import contextmanager
import math
import time

# name: (seconds for a full detected-loop song, reference song length in seconds)
EFFORTS = {'default': 600.0, 'high': 3600.0}
REFERENCE_SECONDS = 300.0       # a song at least this long gets the whole effort budget
MINIMUM_SHARE = 0.5             # a short capture still gets this share: solver and effect fitting costs do not shrink with it
DIAGNOSTICS_SHARE = 0.12        # reserved for the voice and window diagnostics and writing outputs


class BudgetExpired(Exception):
    """The wall budget ended inside a stage; the stage's partial work is dropped."""


class Budget:
    def __init__(self, seconds, clock=time.monotonic):
        if not (isinstance(seconds, (int, float)) and seconds >= 0) or math.isnan(seconds):
            raise ValueError('Budget seconds must be nonnegative.')
        self.clock = clock
        self.started = clock()
        self.total = float(seconds)
        self.stages = {}            # stage name -> wall seconds (shared with children)

    def elapsed(self):
        return self.clock() - self.started

    def remaining(self):
        return self.total - self.elapsed()

    def expired(self):
        return self.remaining() <= 0

    def set_total(self, seconds):
        """Change the total; time already spent still counts."""
        self.total = float(seconds)

    def check(self):
        if _shielded == 0 and self.expired():
            raise BudgetExpired(f'time budget of {self.total:.0f} s ended')

    def child(self, reserve=0.0):
        """A budget that ends `reserve` seconds before this one and shares its stage table."""
        child = Budget(max(0.0, self.remaining() - reserve), self.clock)
        child.stages = self.stages
        return child

    def add(self, name, seconds):
        self.stages[name] = self.stages.get(name, 0.0) + seconds

    @contextmanager
    def stage(self, name):
        began = self.clock()
        try:
            yield self
        finally:
            self.add(name, self.clock() - began)

    def report(self):
        return dict(total_seconds=round(self.total, 1), elapsed_seconds=round(self.elapsed(), 1),
                    stage_seconds={k: round(v, 2) for k, v in self.stages.items()})


def effort_seconds(effort, duration=None):
    """Wall budget for an effort profile; short captures get a proportional share (never below half)."""
    total = EFFORTS[effort]
    if duration is None:
        return total
    return total * min(1.0, max(MINIMUM_SHARE, duration / REFERENCE_SECONDS))


_current = None
_shielded = 0


@contextmanager
def activate(budget):
    """Make `budget` the process's ambient budget for check() calls."""
    global _current
    previous, _current = _current, budget
    try:
        yield budget
    finally:
        _current = previous


def install(budget):
    """Set the ambient budget for the rest of this process (pool workers, which have no enclosing block)."""
    global _current
    _current = budget


@contextmanager
def shield():
    """Inside this block check() never raises: the work must finish whatever the budget says."""
    global _shielded
    _shielded += 1
    try:
        yield
    finally:
        _shielded -= 1


def check():
    """Raise BudgetExpired when the ambient budget has ended (no-op without one)."""
    if _current is not None:
        _current.check()


def remaining():
    """Seconds left in the ambient budget (infinite without one)."""
    return math.inf if _current is None else _current.remaining()
