"""A pytest plugin for CI jobs that have no window server (`python -m pytest -p ci_no_tk`, with scripts/ on PYTHONPATH).

The tests of TokenBar for Windows open real tkinter windows; where there is no display Tk can abort the whole run instead
of raising. With this plugin `tkinter.Tk()` raises `TclError`, which those tests already turn into a skip ("no display").
The windows themselves are tested on the Windows runner (.github/workflows/windows.yml).
"""
try:
    import tkinter
except ImportError:                      # no tkinter at all: the tests skip on their own
    tkinter = None

if tkinter is not None:
    def _no_display(*args, **kwargs):
        raise tkinter.TclError("no display (headless CI job)")

    tkinter.Tk = _no_display
