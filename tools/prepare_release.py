"""Prepare version metadata and changelog without building or uploading anything."""
from __future__ import annotations

import argparse
from datetime import date
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"


def prepare_release(root: Path, version: str, changelog: Path, release_type: str = "beta") -> None:
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("Use a version such as 0.4.6 (no v prefix or prerelease suffix).")
    if release_type not in {"alpha", "beta", "release"}:
        raise ValueError("Invalid release type.")
    docs = root / "docs/curseforge"
    worksheet_path = docs / "project.json"
    worksheet = json.loads(worksheet_path.read_text(encoding="utf-8"))
    old = worksheet["file"]["version"]
    if tuple(map(int, version.split("."))) <= tuple(map(int, old.split("."))):
        raise ValueError(f"New version must be greater than {old}.")
    notes = changelog.read_text(encoding="utf-8").strip()
    if not notes or "\ufffd" in notes:
        raise ValueError("Provide non-empty UTF-8 release notes.")
    toc_path = root / "ForeverDuel/ForeverDuel.toc"
    constants_path = root / "ForeverDuel/Constants.lua"
    toc = toc_path.read_text(encoding="utf-8")
    constants = constants_path.read_text(encoding="utf-8")
    # The addon may already carry the new version (bumped during development);
    # then TOC and Constants must both name it and stay as they are.
    bumped = (len(re.findall(rf"(?m)^## Version: {re.escape(version)}$", toc)) == 1
              and len(re.findall(rf'\bVERSION = "{re.escape(version)}"', constants)) == 1)
    if not bumped:
        toc, toc_count = re.subn(rf"(?m)^## Version: {re.escape(old)}$", f"## Version: {version}", toc)
        constants, constant_count = re.subn(rf'\bVERSION = "{re.escape(old)}"', f'VERSION = "{version}"', constants)
        if toc_count != 1 or constant_count != 1:
            raise ValueError("TOC and Constants must both carry the worksheet version or both the new version.")
    target = docs / f"changelog-{version}.txt"
    if target.exists():
        raise ValueError(f"Changelog already exists: {target.name}")
    history_path = docs / "releases" / f"{old}.json"
    previous = worksheet_path.read_text(encoding="utf-8")
    if history_path.exists() and history_path.read_text(encoding="utf-8") != previous:
        raise ValueError("Previous release snapshot exists with different metadata; review it first.")
    today = date.today().isoformat()
    worksheet["preparedOn"] = today
    worksheet["status"] = "new version prepared; tests, upload and moderation pending"
    release = worksheet["file"]
    release.update(version=version, displayName=f'{worksheet["project"]["name"]} {version}',
                   uploadFile=f'{worksheet["project"]["name"]}-{version}.zip',
                   changelogFile=target.name, releaseType=release_type.title(),
                   publishAutomaticallyAfterApproval=True)
    worksheet["publication"] = {
        "submitted": False, "fileId": None, "fileStatus": "Not uploaded",
        "approved": False, "published": False, "downloadVerified": False,
        "installationVerified": False, "recordSource": "local release preparation"
    }
    worksheet["validation"] = {
        "userReportedTesting": {"status": "not supplied for this version", "version": version},
        "automated": {"status": "not run for this version", "version": version}
    }
    generated_notes = (f'{worksheet["project"]["name"]} {version} - {release_type.title()}\n'
                       f'Target client: WoW: {release["gameFlavor"]} {release["gameVersion"]} '
                       f'(interface {release["interface"]})\n\n{notes}\n')
    # Validate all inputs before writing. Retain the previous publication evidence.
    history_path.parent.mkdir(parents=True, exist_ok=True)
    if not history_path.exists():
        history_path.write_text(previous, encoding="utf-8")
    toc_path.write_text(toc, encoding="utf-8", newline="\n")
    constants_path.write_text(constants, encoding="utf-8", newline="\n")
    target.write_text(generated_notes, encoding="utf-8", newline="\n")
    worksheet_path.write_text(json.dumps(worksheet, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--changelog", type=Path, required=True, help="UTF-8 file containing the new changes")
    parser.add_argument("--release-type", choices=["alpha", "beta", "release"], default="beta")
    args = parser.parse_args()
    try:
        prepare_release(ROOT, args.version, args.changelog, args.release_type)
    except (ValueError, OSError, KeyError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"Prepared {args.version}; review the changes, then run python tools/release.py.")
    print("The existing CurseForge project description is managed separately from file uploads.")


if __name__ == "__main__":
    main()
