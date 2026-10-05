"""Test, build and optionally upload the current addon version to CurseForge."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from prepare_release import VERSION_PATTERN

ROOT = Path(__file__).resolve().parents[1]


def git_dirty(root: Path) -> list[str]:
    """Paths with uncommitted changes, or [] when git is unavailable (e.g. a source ZIP)."""
    try:
        result = subprocess.run(["git", "status", "--porcelain"], cwd=root, check=True,
                                capture_output=True, text=True, encoding="utf-8")
    except (OSError, subprocess.CalledProcessError):
        return []
    return [line[3:] for line in result.stdout.splitlines() if line.strip()]


def validate_tag(root: Path, tag: str | None) -> str:
    worksheet = json.loads((root / "docs/curseforge/project.json").read_text(encoding="utf-8"))
    version = worksheet["file"]["version"]
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("Invalid worksheet version.")
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"Release tag must be v{version}; got {tag}.")
    return version


def run_pipeline(root: Path, tag: str | None = None, upload: bool = False) -> None:
    version = validate_tag(root, tag)
    if upload:
        worksheet = json.loads((root / "docs/curseforge/project.json").read_text(encoding="utf-8"))
        if worksheet.get("publication", {}).get("fileId") or worksheet.get("publication", {}).get("published"):
            raise ValueError("This version was already submitted. Prepare a new version before uploading.")
        if not os.environ.get("CF_API_TOKEN", "").strip():
            raise ValueError("Set CF_API_TOKEN privately before uploading.")
        dirty = git_dirty(root)
        if dirty:
            raise ValueError("Refusing to upload from a working tree with uncommitted changes: " + ", ".join(dirty[:5]))
    safe_env = os.environ.copy()
    safe_env.pop("CF_API_TOKEN", None)
    subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"],
                   cwd=root, env=safe_env, check=True)
    if (root / "tools/tests").is_dir():
        subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tools/tests", "-p", "test_*.py"],
                       cwd=root, env=safe_env, check=True)
    lua = subprocess.run([sys.executable, "tests/run.py"], cwd=root, env=safe_env,
                         check=False, capture_output=True, text=True, encoding="utf-8")
    print(lua.stdout, end="", flush=True)
    if lua.stderr:
        print(lua.stderr, end="", file=sys.stderr)
    if lua.returncode:
        raise subprocess.CalledProcessError(lua.returncode, lua.args)
    compiled = re.search(r"Lua 5\.1: compiled (\d+) files", lua.stdout)
    passed = re.search(r"PASS (\d+) suites, (\d+) assertions", lua.stdout)
    if not compiled or not passed:
        raise ValueError("Lua runner did not produce its successful test summary.")
    metadata_path = root / "docs/curseforge/project.json"
    worksheet = json.loads(metadata_path.read_text(encoding="utf-8"))
    if not worksheet.get("publication", {}).get("submitted") and not worksheet.get("publication", {}).get("fileId"):
        worksheet.setdefault("validation", {})["automated"] = {
            "status": "passed", "version": version,
            "executedOn": datetime.now(timezone.utc).date().isoformat(),
            "command": "python tests/run.py", "runtime": "Lua 5.1",
            "compiledLuaFiles": int(compiled[1]), "suites": int(passed[1]), "assertions": int(passed[2]),
            "pythonTests": "passed in the same pipeline run"
        }
        worksheet["status"] = "automated tests passed; upload and moderation pending"
        metadata_path.write_text(json.dumps(worksheet, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    subprocess.run([sys.executable, "tools/prepare-curseforge.py"], cwd=root, env=safe_env, check=True)
    command = [sys.executable, "tools/curseforge_upload.py", "--package-dir", f"dist/curseforge-{version}"]
    if upload:
        command.append("--upload")
    subprocess.run(command, cwd=root, env=os.environ.copy() if upload else safe_env, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Validate the release tag against the addon version, e.g. v0.4.6")
    parser.add_argument("--upload", action="store_true", help="Upload after all checks pass (default: offline checks)")
    args = parser.parse_args()
    try:
        run_pipeline(ROOT, args.tag, args.upload)
    except (ValueError, OSError, KeyError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    except subprocess.CalledProcessError:
        print("Release stopped because a check or upload failed.", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
