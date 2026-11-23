"""tokenbar-cli.exe: a console program. No arguments prints the last 24 hours."""
import sys

from tokenbar.cli import run_cli

if __name__ == "__main__":
    sys.exit(run_cli(sys.argv[1:] or ["--window", "24h"]))
