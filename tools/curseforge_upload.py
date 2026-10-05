"""Plan or upload a verified ForeverDuelersGuild package to CurseForge.

The default command is entirely offline. --check-api checks authentication and
Forever version mapping with one GET request. Upload needs --upload and CF_API_TOKEN.
POST is never retried: upload-attempt.json prevents a duplicate after an uncertain
response, and upload-receipt.json records submission, never moderator approval.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import re
import secrets
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener
from zipfile import BadZipFile, ZipFile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "docs" / "curseforge" / "automation.json"
API_BASE = "https://wow.curseforge.com"
PROJECT_ID = 1726452
FOREVER_VERSION_TYPE = 88568
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_ARCHIVE_BYTES = 50 * 1024 * 1024


class UploadError(Exception):
    """An intentionally credential-free error suitable for displaying in CI."""


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # In particular, never forward X-Api-Token to a redirect destination.
        return None


def require(condition: bool, message: str) -> None:
    if not condition:
        raise UploadError(message)


def positive_integer(value: Any) -> bool:
    return type(value) is int and value > 0


def read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        raise UploadError(f"Cannot read valid {label} JSON.") from None
    require(isinstance(result, dict), f"Invalid {label} JSON object.")
    return result


def artifact_path(package_dir: Path, filename: Any) -> Path:
    require(isinstance(filename, str) and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", filename)),
            "Unsafe package artifact filename.")
    require(filename not in {".", ".."}, "Unsafe package artifact filename.")
    path = package_dir / filename
    require(not path.is_symlink() and path.resolve().parent == package_dir,
            "Package artifact must stay inside its directory without symlinks.")
    return path


def read_package(package_dir: Path, config_path: Path | None = None) -> dict[str, Any]:
    package_dir = Path(package_dir).resolve()
    require(package_dir.is_dir(), "Package directory does not exist.")
    worksheet = read_json(artifact_path(package_dir, "project.json"), "package metadata")
    report = read_json(artifact_path(package_dir, "build-report.json"), "build report")
    config = read_json(Path(config_path) if config_path else DEFAULT_CONFIG, "automation config")
    require(config.get("apiBaseUrl") == API_BASE, "Unexpected CurseForge API base URL.")
    require(config.get("gameVersionTypeId") == FOREVER_VERSION_TYPE,
            "Automation must select the Forever game-version group.")
    require(config.get("publishAutomaticallyAfterApproval") is True,
            "Automatic release after moderation must be enabled in automation config.")
    project = worksheet.get("project", {})
    release = worksheet.get("file", {})
    require(isinstance(project, dict) and isinstance(release, dict), "Invalid project or file metadata.")
    require(type(project.get("projectId")) is int and project["projectId"] == PROJECT_ID,
            "This uploader is restricted to CurseForge project 1726452.")
    require(project.get("name") == "ForeverDuelersGuild", "Unexpected project name.")
    version = release.get("version", "")
    require(isinstance(version, str) and bool(re.fullmatch(r"\d+\.\d+\.\d+", version)),
            "Invalid addon release version.")
    require(report.get("version") == version and report.get("projectName") == project["name"],
            "Build report and release metadata differ.")
    expected_name = f"ForeverDuelersGuild-{version}.zip"
    require(release.get("uploadFile") == expected_name and report.get("archive") == expected_name,
            "Archive name does not match release metadata.")
    require(release.get("changelogFile") == f"changelog-{version}.txt", "Unexpected changelog filename.")
    require(release.get("gameFlavor") == "Forever" and release.get("interface") == 16001,
            "Release must target the Forever client.")
    require(isinstance(release.get("gameVersion"), str) and bool(release["gameVersion"].strip()),
            "Missing exact Forever game version.")
    release_type = release.get("releaseType", "")
    require(isinstance(release_type, str) and release_type.lower() in {"alpha", "beta", "release"},
            "Invalid CurseForge release type.")
    require(report.get("fileReleaseType") == release_type, "Build report release type differs.")
    require(report.get("sourceBytesVerified") is True and report.get("zipIntegrityVerified") is True,
            "Package has no successful builder verification.")
    require(not release.get("requiredDependencies"), "Dependency metadata is not supported by this uploader.")
    display_name = release.get("displayName")
    require(isinstance(display_name, str) and 0 < len(display_name) <= 255 and
            not any(ord(c) < 32 for c in display_name), "Invalid file display name.")
    archive_path = artifact_path(package_dir, expected_name)
    try:
        require(archive_path.stat().st_size <= MAX_ARCHIVE_BYTES, "Archive exceeds the upload size limit.")
        archive_bytes = archive_path.read_bytes()
        changelog = artifact_path(package_dir, release["changelogFile"]).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        raise UploadError("Cannot read archive or changelog.") from None
    require(bool(changelog.strip()), "Changelog is empty.")
    archive_hash = hashlib.sha256(archive_bytes).hexdigest()
    require(archive_hash == report.get("archiveSha256"), "Archive SHA-256 differs from the build report.")
    require(len(archive_bytes) == report.get("archiveBytes"), "Archive size differs from the build report.")
    try:
        with ZipFile(BytesIO(archive_bytes)) as archive:
            # orig_filename retains backslashes that ZipInfo normalizes on Windows.
            names = [entry.orig_filename for entry in archive.infolist()]
            require(len(names) == report.get("archiveEntries") and len(names) == len(set(names)) and
                    len(names) == len(set(archive.namelist())),
                    "Archive entry count differs from the build report or includes duplicates.")
            require(sum(entry.file_size for entry in archive.infolist()) <= 100 * 1024 * 1024,
                    "Archive decompressed size exceeds the validation limit.")
            require(all(name.startswith("ForeverDuel/") and "\\" not in name and ":" not in name and
                        all(part not in {"", ".", ".."} for part in name.split("/"))
                        for name in names), "Archive includes an unsafe path or unexpected folder.")
            require(archive.testzip() is None, "Archive CRC validation failed.")
            manifest = archive.read("ForeverDuel/ForeverDuel.toc").decode("utf-8")
            headers = dict(re.findall(r"^##\s*([^:]+):\s*(.*?)\s*$", manifest, re.MULTILINE))
            require(headers.get("Version") == version and headers.get("Title") == project["name"] and
                    headers.get("Interface") == "16001", "Archive manifest differs from release metadata.")
    except (OSError, BadZipFile, KeyError, UnicodeError):
        raise UploadError("Cannot validate release ZIP.") from None
    publication = worksheet.get("publication", {})
    build_publication = report.get("publication", {})
    require(isinstance(publication, dict) and isinstance(build_publication, dict), "Invalid publication metadata.")
    already_submitted = any(state.get("fileId") or state.get("published") or state.get("submitted")
                            for state in (publication, build_publication))
    # Publication follows a recorded passed live test of exactly this version.
    validation = worksheet.get("validation", {})
    tested = validation.get("userReportedTesting", {}) if isinstance(validation, dict) else {}
    user_tested = isinstance(tested, dict) and tested.get("status") == "passed" and tested.get("version") == version
    return {"directory": package_dir, "projectId": PROJECT_ID, "version": version,
            "displayName": display_name, "archive": expected_name, "archiveSha256": archive_hash,
            "archiveBytes": archive_bytes, "gameVersion": release["gameVersion"],
            "releaseType": release_type.lower(), "changelog": changelog,
            "alreadySubmitted": bool(already_submitted), "userTested": user_tested}


def plan_package(package_dir: Path, config_path: Path | None = None) -> dict[str, Any]:
    package = read_package(package_dir, config_path)
    attempt = artifact_path(package["directory"], "upload-attempt.json")
    receipt = artifact_path(package["directory"], "upload-receipt.json")
    return {"mode": "offline plan; no network requests", "projectId": package["projectId"],
            "version": package["version"], "displayName": package["displayName"],
            "archive": package["archive"], "archiveSha256": package["archiveSha256"],
            "gameFlavor": "Forever", "gameVersionTypeId": FOREVER_VERSION_TYPE,
            "gameVersion": package["gameVersion"], "releaseType": package["releaseType"],
            "publishAutomaticallyAfterApproval": True,
            "uploadAllowed": package["userTested"] and not package["alreadySubmitted"]
                and not attempt.exists() and not receipt.exists(),
            "alreadySubmitted": package["alreadySubmitted"], "userTested": package["userTested"],
            "existingAttempt": attempt.exists(), "existingReceipt": receipt.exists()}


def api_json(opener: Any, request: Request) -> Any:
    try:
        with opener.open(request, timeout=60) as response:
            status = response.getcode()
            require(type(status) is int and 200 <= status < 300, "CurseForge API returned a non-success status.")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
        require(len(payload) <= MAX_RESPONSE_BYTES, "CurseForge API response exceeds the size limit.")
        return json.loads(payload.decode("utf-8"))
    except HTTPError as error:
        # Never include reason, headers, URL, redirect target or response body.
        raise UploadError(f"CurseForge API returned HTTP {error.code}.") from None
    except UploadError:
        raise
    except (URLError, OSError, ValueError, UnicodeError):
        raise UploadError("CurseForge API request failed or returned invalid JSON.") from None
    except Exception:
        # HTTP parsers can also raise errors such as IncompleteRead carrying a
        # response fragment. Do not let those bodies reach CI tracebacks.
        raise UploadError("CurseForge API request did not complete safely.") from None


def resolve_game_version(opener: Any, token: str, name: str) -> int:
    request = Request(f"{API_BASE}/api/game/versions", headers={"X-Api-Token": token, "Accept": "application/json"})
    versions = api_json(opener, request)
    require(isinstance(versions, list), "Unexpected CurseForge game-version response.")
    matches = [item for item in versions if isinstance(item, dict) and
               item.get("gameVersionTypeID") == FOREVER_VERSION_TYPE and item.get("name") == name]
    require(len(matches) == 1 and positive_integer(matches[0].get("id")),
            "Exact Forever game version is missing, ambiguous or invalid; no upload was attempted.")
    return matches[0]["id"]


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def authentication_token(token: str | None = None) -> str:
    token = token if token is not None else os.environ.get("CF_API_TOKEN", "")
    require(isinstance(token, str) and bool(token.strip()) and not any(ord(c) < 32 for c in token),
            "Set a valid CF_API_TOKEN environment variable before checking the API or uploading.")
    return token


def check_api(package_dir: Path, config_path: Path | None = None, token: str | None = None,
              opener: Any = None) -> dict[str, Any]:
    """Read-only authentication/version preflight, including published packages."""
    package = read_package(package_dir, config_path)
    token = authentication_token(token)
    opener = opener if opener is not None else build_opener(NoRedirects())
    game_version_id = resolve_game_version(opener, token, package["gameVersion"])
    return {"mode": "read-only API preflight", "apiReady": True, "noUpload": True,
            "projectId": PROJECT_ID, "version": package["version"],
            "gameFlavor": "Forever", "gameVersionTypeId": FOREVER_VERSION_TYPE,
            "gameVersion": package["gameVersion"], "gameVersionId": game_version_id}


def write_exclusive_json(path: Path, value: dict[str, Any], label: str) -> None:
    try:
        with path.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
    except FileExistsError:
        raise UploadError(f"An {label} already exists; refusing a duplicate upload.") from None
    except OSError:
        raise UploadError(f"Cannot write {label}; no further upload attempt is safe.") from None


def multipart(package: dict[str, Any], metadata: dict[str, Any]) -> tuple[bytes, str]:
    boundary = "foreverduel-" + secrets.token_hex(24)
    # Names and the filename are fixed/validated; no user strings enter headers.
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"metadata\"\r\n"
        "Content-Type: application/json; charset=utf-8\r\n\r\n"
    ).encode("ascii") + json.dumps(metadata, ensure_ascii=False).encode("utf-8") + (
        f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"{package['archive']}\"\r\nContent-Type: application/zip\r\n\r\n"
    ).encode("ascii") + package["archiveBytes"] + f"\r\n--{boundary}--\r\n".encode("ascii")
    return body, boundary


def upload_package(package_dir: Path, config_path: Path | None = None, token: str | None = None,
                   opener: Any = None) -> dict[str, Any]:
    package = read_package(package_dir, config_path)
    require(not package["alreadySubmitted"], "Package metadata already records a submitted or published file; refusing a duplicate.")
    receipt_path = artifact_path(package["directory"], "upload-receipt.json")
    if receipt_path.exists():
        receipt = read_json(receipt_path, "upload receipt")
        require(receipt.get("projectId") == PROJECT_ID and receipt.get("version") == package["version"] and
                receipt.get("archiveSha256") == package["archiveSha256"] and positive_integer(receipt.get("fileId")),
                "Existing upload receipt conflicts with this package; refusing another upload.")
        # Do not echo arbitrary extra fields from an edited/imported receipt.
        return {key: receipt[key] for key in (
            "projectId", "version", "fileId", "archiveSha256", "displayName", "gameVersions",
            "releaseType", "publishAutomaticallyAfterApproval", "submittedAt", "status"
        ) if key in receipt}  # Identical repeated commands are idempotent.
    require(package["userTested"],
            "No passed live test is recorded for this version (validation.userReportedTesting "
            "with status 'passed' and this version); refusing to upload.")
    attempt_path = artifact_path(package["directory"], "upload-attempt.json")
    require(not attempt_path.exists(),
            "A prior upload attempt has no receipt. Reconcile its outcome in CurseForge before any retry.")
    token = authentication_token(token)
    opener = opener if opener is not None else build_opener(NoRedirects())
    game_version_id = resolve_game_version(opener, token, package["gameVersion"])
    metadata = {"changelog": package["changelog"], "changelogType": "text",
                "displayName": package["displayName"], "gameVersions": [game_version_id],
                "releaseType": package["releaseType"], "isMarkedForManualRelease": False}
    body, boundary = multipart(package, metadata)
    attempt = {"projectId": PROJECT_ID, "version": package["version"],
               "archiveSha256": package["archiveSha256"], "displayName": package["displayName"],
               "attemptedAt": timestamp(), "status": "in-flight; reconcile outcome before retry"}
    write_exclusive_json(attempt_path, attempt, "upload attempt")
    request = Request(f"{API_BASE}/api/projects/{PROJECT_ID}/upload-file", data=body, method="POST",
                      headers={"X-Api-Token": token, "Accept": "application/json",
                               "Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        result = api_json(opener, request)
        require(isinstance(result, dict) and positive_integer(result.get("id")),
                "Upload response has no valid file ID.")
    except UploadError as error:
        raise UploadError(f"{error} Submission outcome must be reconciled in CurseForge; POST will not be retried.") from None
    receipt = {"projectId": PROJECT_ID, "version": package["version"], "fileId": result["id"],
               "archiveSha256": package["archiveSha256"], "displayName": package["displayName"],
               "gameVersions": [game_version_id], "releaseType": package["releaseType"],
               "publishAutomaticallyAfterApproval": True, "submittedAt": timestamp(),
               "status": "submitted; moderation pending"}
    write_exclusive_json(receipt_path, receipt, "upload receipt")
    return receipt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-dir", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=None)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--upload", action="store_true", help="Submit once using CF_API_TOKEN.")
    mode.add_argument("--dry-run", action="store_true", help="Print an offline plan (the default).")
    mode.add_argument("--check-api", action="store_true", help="Check token and Forever version via GET; never upload.")
    args = parser.parse_args(argv)
    try:
        if args.upload:
            result = upload_package(args.package_dir, args.config)
        elif args.check_api:
            result = check_api(args.package_dir, args.config)
        else:
            result = plan_package(args.package_dir, args.config)
    except UploadError as error:
        print(f"Release upload stopped: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
