"""9.0.2: the release hand-over scripts and workflows (the Mac side's release.sh, release-audit.sh, ci.yml, windows.yml).

New file only: it reuses the helpers of test_901 (a made-up repository with an origin, the audit runner, the workflow loader).
"""
import os
import re
import shutil
import subprocess
import sys

import pytest

import test_901 as t

REPO = t.REPO
SCRIPTS = os.path.join(REPO, "scripts")
needs_mac_tools = pytest.mark.skipif(sys.platform != "darwin" or shutil.which("lipo") is None or shutil.which("clang") is None,
                                     reason="lipo and clang (macOS command line tools)")
# The one shape of a release version, in every place that judges it: X.Y.Z, or X.Y.Z-pre.
VERSION_SHAPE = r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?"


def _read(*parts):
    path = os.path.join(REPO, *parts)
    if not os.path.exists(path):
        pytest.skip("not inside the repository")
    with open(path, encoding="utf-8") as f:
        return f.read()


# 6. one version rule: tag vX.Y.Z -> everything X.Y.Z; tag vX.Y.Z-pre -> the files say X.Y.Z, the zips are named from the tag ---
@t.needs_shell
def test_audit_stops_a_pre_release_whose_base_is_not_the_version_of_the_files(tmp_path):
    work = t._release_repo(tmp_path)                       # every file says 9.9.9
    r = t._audit(work, "9.9.10-rc1")
    assert r.returncode == 1 and "VERSION says '9.9.9', the release is 9.9.10" in r.stderr, (r.returncode, r.stderr)
    assert "windows/tokenbar/__init__.py says" in r.stderr and "pyproject.toml says" in r.stderr


@t.needs_shell
def test_audit_passes_a_pre_release_of_the_version_the_files_say(tmp_path):
    r = t._audit(t._release_repo(tmp_path), "9.9.9-rc1")
    assert r.returncode == 0 and "OK" in r.stdout, r.stderr


@t.needs_shell
@pytest.mark.parametrize("version", ["9.9", "9.9.9-", "v9.9.9", "9.9.9 rc", "9.9.9-rc1/../x"])
def test_audit_refuses_a_version_that_is_not_x_y_z_or_x_y_z_pre(tmp_path, version):
    r = t._audit(t._release_repo(tmp_path), version)
    assert r.returncode == 2 and "X.Y.Z" in r.stderr, (r.returncode, r.stderr)


def test_the_windows_workflow_and_the_audit_judge_a_tag_by_the_same_rule():
    doc = t._workflow("windows.yml")
    step = next(s for s in doc["jobs"]["build"]["steps"] if s.get("id") == "version")
    script = step["run"]
    pattern = re.search(r"-c?match '\^v\((.+?)\)(\(.+?\)\?)\$'", script)
    assert pattern, "the Version step must match the tag against ^vX.Y.Z(-pre)?$ and keep X.Y.Z"
    shape = pattern.group(1) + pattern.group(2)
    assert shape == VERSION_SHAPE and VERSION_SHAPE in _read("scripts", "release-audit.sh") and VERSION_SHAPE in _read("scripts", "release.sh")
    # X.Y.Z of the tag must be what tokenbar.__version__ says (it is VERSION, which the audit pins); the zips are named from the tag.
    assert "$base = $Matches[1]" in script and "$base -ne $v" in script and "throw" in script
    assert '"version=$release"' in script and '-like "*-*"' in script
    assert step["env"]["REF_NAME"] == "${{ github.ref_name }}" and "github.ref_name" not in script


def test_the_windows_zip_is_named_from_the_release_version_before_it_is_checksummed():
    doc = t._workflow("windows.yml")
    names = [s.get("name", "") for s in doc["jobs"]["build"]["steps"]]
    rename = next(s for s in doc["jobs"]["build"]["steps"] if "zip" in s.get("name", "").lower() and "name" in s.get("name", "").lower())
    assert "needs" not in rename and "TokenBar-Windows-$($env:RELEASE).zip" in rename["run"] and "Rename-Item" in rename["run"]
    assert rename["env"]["RELEASE"] == "${{ steps.version.outputs.version }}"
    assert names.index(rename["name"]) < names.index("Checksum")
    assert doc["jobs"]["build"]["outputs"]["version"] == "${{ steps.version.outputs.version }}"


# 5. a release zip is universal, and it is looked at ---------------------------------------------------------------
def test_release_script_builds_universal_by_default_and_checks_the_archs_before_zipping():
    text = _read("scripts", "release.sh")
    assert "UNIVERSAL=(--universal)" in text                       # no flag: still universal
    assert "--arm64" not in text and "--thin" not in text           # and no way to ship a thin zip
    build = text.index('scripts/build-app.sh --no-test')
    first = text.index("scripts/check-archs.sh", build)
    assert first < text.index('ditto -c -k --keepParent')           # the built app is looked at before it is zipped
    assert text.index("scripts/check-archs.sh", text.index('ditto -x -k "$ZIP"')) > text.index('ditto -x -k "$ZIP"')   # and the unpacked zip after


def _fat(tmp_path, *archs):
    src = tmp_path / "t.c"
    src.write_text("int main(void){return 0;}\n")
    out = tmp_path / ("bin-" + "-".join(archs))
    flags = [x for a in archs for x in ("-arch", a)]
    subprocess.run(["clang", *flags, "-o", str(out), str(src)], check=True, capture_output=True)
    return str(out)


@needs_mac_tools
def test_check_archs_passes_a_universal_binary_in_either_order_and_stops_a_thin_one(tmp_path):
    script = os.path.join(SCRIPTS, "check-archs.sh")
    both = _fat(tmp_path, "arm64", "x86_64")
    assert subprocess.run(["bash", script, both], capture_output=True, text=True).returncode == 0
    swapped = subprocess.run(["bash", script, both, "x86_64 arm64"], capture_output=True, text=True)
    assert swapped.returncode == 0, swapped.stderr                  # the order of the words is not the check
    for thin in ("arm64", "x86_64"):
        r = subprocess.run(["bash", script, _fat(tmp_path, thin)], capture_output=True, text=True)
        assert r.returncode == 1 and "arm64 x86_64" in r.stderr and thin in r.stderr, (thin, r.returncode, r.stderr)
    assert subprocess.run(["bash", script, str(tmp_path / "missing")], capture_output=True, text=True).returncode == 2


# 7. the release scripts' tests run in a CI job ---------------------------------------------------------------------
def test_the_macos_ci_job_runs_the_windows_directory_tests_including_the_release_script_ones():
    doc = t._workflow("ci.yml")
    job = doc["jobs"]["build-and-check"]
    step = next(s for s in job["steps"] if "pytest" in s.get("run", ""))
    run = step["run"]
    assert "-m pytest" in run and "pip install" in run and "pytest" in run
    assert "-k" not in run and "--deselect" not in run and "-m \"not" not in run     # release/audit tests are not left out
    assert "ci_no_tk" in run                                                           # headless: the window tests skip
    assert step.get("working-directory") == "windows" or "cd windows" in run
    assert doc["permissions"] == {"contents": "read"}
    assert all(s.get("with", {}).get("persist-credentials") is False for s in job["steps"] if "checkout" in s.get("uses", ""))
    assert all("secrets." not in str(s) for s in job["steps"])


def test_the_headless_plugin_turns_a_window_into_a_skip_not_a_crash():
    import importlib.util
    spec = importlib.util.spec_from_file_location("ci_no_tk", os.path.join(SCRIPTS, "ci_no_tk.py"))
    module = importlib.util.module_from_spec(spec)
    tk = pytest.importorskip("tkinter")
    real = tk.Tk
    try:
        spec.loader.exec_module(module)
        with pytest.raises(tk.TclError):
            tk.Tk()
    finally:
        tk.Tk = real


# 8. the audit looks at the remote for the tag too ---------------------------------------------------------------------
@t.needs_shell
def test_audit_stops_when_the_tag_exists_on_origin_but_not_here(tmp_path):
    work = t._release_repo(tmp_path)
    t._git(work, "tag", "v9.9.9")
    t._git(work, "push", "-q", "origin", "v9.9.9")
    t._git(work, "tag", "-d", "v9.9.9")                      # a clone that never fetched the tag
    r = t._audit(work)
    assert r.returncode == 1 and "already exists on origin" in r.stderr, (r.returncode, r.stderr)


@t.needs_shell
def test_audit_fails_and_does_not_claim_a_check_when_origin_cannot_be_reached(tmp_path):
    work = t._release_repo(tmp_path)
    t._git(work, "remote", "set-url", "origin", str(tmp_path / "nowhere.git"))
    t._git(work, "update-ref", "refs/remotes/origin/main", "HEAD")      # HEAD still counts as pushed (the last fetch)
    r = t._audit(work)
    assert "could not look at origin" in r.stderr and "NOT checked" in r.stderr, r.stderr
    # 9.0.4: no longer a pass with a warning ("a release is made once" cannot be vouched for without looking at origin)
    assert r.returncode == 1 and "OK" not in r.stdout, (r.returncode, r.stdout)


@t.needs_shell
def test_audit_passes_when_origin_has_no_such_tag(tmp_path):
    work = t._release_repo(tmp_path)
    t._git(work, "tag", "v9.9.8")
    t._git(work, "push", "-q", "origin", "v9.9.8")             # another tag is no reason to stop
    r = t._audit(work)
    assert r.returncode == 0 and "remote tag not checked" not in r.stdout, (r.returncode, r.stdout, r.stderr)
