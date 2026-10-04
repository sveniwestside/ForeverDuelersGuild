"""Prepare a local CurseForge upload directory. Uses only the standard library.

Run from any directory: python tools/prepare-curseforge.py
Never contacts CurseForge, uploads files, or changes the installable addon.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import struct
from pathlib import Path, PurePosixPath
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "ForeverDuel"
DOCS = ROOT / "docs" / "curseforge"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    manifest_path = ADDON / "ForeverDuel.toc"
    manifest = manifest_path.read_text(encoding="utf-8")
    headers = dict(re.findall(r"^##\s*([^:]+):\s*(.*?)\s*$", manifest, re.MULTILINE))
    version = headers.get("Version", "")
    require(bool(re.fullmatch(r"\d+\.\d+\.\d+", version)), "Invalid addon version")
    constants = (ADDON / "Constants.lua").read_text(encoding="utf-8")
    require(f'VERSION = "{version}"' in constants, "Constants/TOC versions differ")
    worksheet = json.loads((DOCS / "project.json").read_text(encoding="utf-8"))
    project = worksheet["project"]
    release = worksheet["file"]
    require(project["name"] == headers.get("Title"), "Project/TOC names differ")
    require(release["version"] == version, "Update the publication worksheet for this version")
    require(str(release["interface"]) == headers.get("Interface"), "Interface metadata differs")
    require(release["uploadFile"] == f'{project["name"]}-{version}.zip', "Unexpected archive name")
    require(release["changelogFile"] == f"changelog-{version}.txt", "Unexpected changelog name")
    require((ROOT / "LICENSE").read_bytes() == (ADDON / "LICENSE").read_bytes(), "Licenses differ")

    modules = [line.strip().replace("\\", "/") for line in manifest.splitlines()
               if line.strip() and not line.lstrip().startswith("#")]
    require(len(modules) == len(set(modules)), "Duplicate TOC module")
    for module in modules:
        parts = PurePosixPath(module)
        require(not parts.is_absolute() and ".." not in parts.parts and ":" not in module,
                "Unsafe TOC path")
        require(module.endswith(".lua") and (ADDON / module).is_file(), f"Missing Lua module: {module}")

    files = sorted(path for path in ADDON.rglob("*") if path.is_file())
    allowed = {"ForeverDuel.toc", "LICENSE", *modules}
    for path in files:
        require(not path.is_symlink(), f"Unexpected symlink: {path}")
        relative = path.relative_to(ADDON).as_posix()
        require(relative in allowed or (
            relative.startswith("Media/") and path.suffix.lower() in {".tga", ".blp", ".png", ".jpg"}
        ), f"Unlisted addon file; review before packaging: {relative}")
    icon = headers.get("IconTexture", "").replace("\\", "/")
    prefix = "Interface/AddOns/ForeverDuel/"
    require(icon.startswith(prefix) and (ADDON / icon[len(prefix):]).is_file(), "Missing runtime icon")

    text_files = ["summary.txt", "description.txt", "description.html", release["changelogFile"],
                  "project.json", "UPLOAD_GUIDE.md"]
    for name in text_files:
        text = (DOCS / name).read_text(encoding="utf-8")
        require(bool(text.strip()), f"Empty publication file: {name}")
        require("\ufffd" not in text, f"Invalid replacement character in {name}")
    summary = (DOCS / "summary.txt").read_text(encoding="utf-8").strip()
    require("\n" not in summary and len(summary) <= 255, "Keep summary to one compact line")

    master = ROOT / "assets" / "branding" / "foreverduel-icon.png"
    png = master.read_bytes()
    require(png[:8] == b"\x89PNG\r\n\x1a\n" and png[12:16] == b"IHDR", "Invalid logo PNG")
    width, height = struct.unpack(">II", png[16:24])
    require(width == height and width >= 400, "Project logo must be square and at least 400px")

    output = ROOT / "dist" / f"curseforge-{version}"
    output.mkdir(parents=True, exist_ok=True)
    require(output.resolve().is_relative_to(ROOT), "Output directory escapes workspace")
    archive = output / release["uploadFile"]
    # Fixed ZIP timestamps/permissions make identical source produce identical bytes.
    with ZipFile(archive, "w", compression=ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in files:
            name = path.relative_to(ROOT).as_posix()
            entry = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            bundle.writestr(entry, path.read_bytes(), compress_type=ZIP_DEFLATED, compresslevel=9)

    expected = {path.relative_to(ROOT).as_posix(): path for path in files}
    with ZipFile(archive) as bundle:
        require(bundle.testzip() is None, "ZIP integrity failed")
        require(len(bundle.namelist()) == len(expected) and set(bundle.namelist()) == set(expected),
                "ZIP contains missing, extra or duplicate entries")
        for name, path in expected.items():
            require(bundle.read(name) == path.read_bytes(), f"ZIP differs from source: {name}")

    for name in text_files:
        shutil.copyfile(DOCS / name, output / name)
    require(bool(re.fullmatch(r"[a-z0-9-]+\.png", project["logoFile"])), "Unsafe logo filename")
    logo = output / project["logoFile"]
    shutil.copyfile(master, logo)
    require(digest(master) == digest(logo), "Logo copy differs from the original")

    publication = worksheet.get("publication", {})
    remaining_steps = []
    if not project.get("projectId"):
        remaining_steps.extend(["Account login and project creation", "Confirm form metadata"])
    if not publication.get("fileId"):
        remaining_steps.append("Upload and moderation")
    elif not publication.get("published"):
        remaining_steps.append("Moderation and manual publication")
    if not publication.get("installationVerified"):
        remaining_steps.append("Verify installation of the published file" if publication.get("downloadVerified")
                               else "Verify published download and installation")

    report = {
        "projectName": project["name"],
        "version": version,
        "status": "local package verified; publication status recorded separately",
        "archive": archive.name,
        "archiveSha256": digest(archive),
        "archiveBytes": archive.stat().st_size,
        "archiveEntries": len(files),
        "luaModules": len(modules),
        "topLevelDirectory": "ForeverDuel",
        "sourceBytesVerified": True,
        "zipIntegrityVerified": True,
        "license": "MIT",
        "licenseMatchesRepository": True,
        "interface": headers["Interface"],
        "logo": {"file": logo.name, "width": width, "height": height,
                 "originalCopiedWithoutModification": True, "sha256": digest(logo)},
        "fileReleaseType": release["releaseType"],
        "validation": worksheet.get("validation", {}),
        "publication": {"recordedStatus": worksheet["status"],
                        "projectId": project.get("projectId"),
                        "authorsUrl": project.get("authorsUrl"), **publication},
        "remainingExternalSteps": remaining_steps,
    }
    report_path = output / "build-report.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    artifacts = [archive, logo, report_path, *(output / name for name in text_files)]
    sums = "".join(f"{digest(path)}  {path.name}\n" for path in sorted(artifacts))
    (output / "SHA256SUMS.txt").write_text(sums, encoding="utf-8")
    print(f"Prepared {output.relative_to(ROOT)}")
    print(f"Verified {len(files)} ZIP entries, {len(modules)} Lua modules, version {version}, MIT license")
    print(f"Original logo: {width}x{height}; SHA-256: {digest(archive)}")
    print("No network requests performed by this builder; see the recorded publication status.")


if __name__ == "__main__":
    main()
