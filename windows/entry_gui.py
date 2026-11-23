"""TokenBar.exe: the tray app; with a command-line flag (--json, --window ...) the same exe answers on the console."""
import sys

from tokenbar.cli import main

if __name__ == "__main__":
    sys.exit(main())
