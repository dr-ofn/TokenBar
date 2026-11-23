# PyInstaller recipe: `pyinstaller --noconfirm TokenBar.spec` (run on Windows; see build.py).
# One folder, two programs: TokenBar.exe (no console window, the tray app) and tokenbar-cli.exe (a console program).
import os

block_cipher = None
here = os.path.abspath(os.getcwd())
icon = os.path.join(here, "build", "tokenbar.ico")
# Each program names only what it imports at run time. `zstandard.backend_c` is the C backend `zstandard` picks while
# it loads: PyInstaller does not see it, and without it the .jsonl.zst and Zed readers fall back to a missing `zstd`.
gui_hidden = ["pystray._win32", "PIL._tkinter_finder", "zstandard.backend_c"]
cli_hidden = ["zstandard.backend_c"]
datas = [(os.path.join(here, "tokenbar", "data"), os.path.join("tokenbar", "data"))]

gui = Analysis(["entry_gui.py"], pathex=[here], datas=datas, hiddenimports=gui_hidden, excludes=["pytest", "yaml"], cipher=block_cipher)
cli = Analysis(["entry_cli.py"], pathex=[here], datas=datas, hiddenimports=cli_hidden, excludes=["pytest", "yaml", "tkinter", "pystray", "PIL"], cipher=block_cipher)
# No MERGE: one COLLECT takes both programs and keeps one copy of every file they share (MERGE is for separate
# folders and rewrites the shared files' paths, which a single folder does not need).

gui_pyz = PYZ(gui.pure, gui.zipped_data, cipher=block_cipher)
cli_pyz = PYZ(cli.pure, cli.zipped_data, cipher=block_cipher)

gui_exe = EXE(gui_pyz, gui.scripts, [], exclude_binaries=True, name="TokenBar", console=False,
              icon=icon if os.path.exists(icon) else None, upx=False)
cli_exe = EXE(cli_pyz, cli.scripts, [], exclude_binaries=True, name="tokenbar-cli", console=True,
              icon=icon if os.path.exists(icon) else None, upx=False)

COLLECT(gui_exe, gui.binaries, gui.zipfiles, gui.datas,
        cli_exe, cli.binaries, cli.zipfiles, cli.datas,
        strip=False, upx=False, name="TokenBar")
