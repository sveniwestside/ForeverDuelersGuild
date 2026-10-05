"""Offline release upload tests. All HTTP requests use an in-memory mock."""

import contextlib
from email.parser import BytesParser
from email.policy import default
import hashlib
from http.client import IncompleteRead
import importlib.util
from io import BytesIO, StringIO
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from zipfile import ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("curseforge_upload", ROOT / "tools" / "curseforge_upload.py")
UPLOADER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPLOADER)
SECRET = "never-log-this-test-secret"
FOREVER_VERSION = {"id": 55555, "gameVersionTypeID": 88568, "name": "1.60.1"}


class Response:
    def __init__(self, data, status=200):
        self.data = json.dumps(data).encode("utf-8")
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def getcode(self):
        return self.status

    def read(self, limit):
        return self.data[:limit]


class Opener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        if not self.responses:
            raise AssertionError("Unexpected HTTP call")
        result = self.responses.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = self.directory / "automation.json"
        self.write_json(self.config, {"apiBaseUrl": UPLOADER.API_BASE, "gameVersionTypeId": 88568,
                                      "publishAutomaticallyAfterApproval": True})
        self.worksheet = {"project": {"name": "ForeverDuelersGuild", "projectId": 1726452},
                          "file": {"version": "0.4.6", "displayName": "ForeverDuelersGuild 0.4.6",
                                   "uploadFile": "ForeverDuelersGuild-0.4.6.zip", "releaseType": "Beta",
                                   "gameFlavor": "Forever", "gameVersion": "1.60.1", "interface": 16001,
                                   "changelogFile": "changelog-0.4.6.txt", "requiredDependencies": []},
                          "publication": {"published": False},
                          "validation": {"userReportedTesting": {"status": "passed", "version": "0.4.6"}}}
        self.write_json(self.directory / "project.json", self.worksheet)
        (self.directory / "changelog-0.4.6.txt").write_text("New beta fixes.\n", encoding="utf-8")
        self.make_archive()

    def write_json(self, path, value):
        path.write_text(json.dumps(value), encoding="utf-8")

    def make_archive(self, extra_path=None):
        archive = self.directory / "ForeverDuelersGuild-0.4.6.zip"
        with ZipFile(archive, "w") as bundle:
            bundle.writestr("ForeverDuel/ForeverDuel.toc", "## Title: ForeverDuelersGuild\n## Version: 0.4.6\n## Interface: 16001\nConstants.lua\n")
            bundle.writestr("ForeverDuel/Constants.lua", 'local VERSION = "0.4.6"\n')
            if extra_path:
                entry = ZipInfo()
                entry.filename = extra_path  # Preserve deliberately unsafe backslashes on Windows.
                bundle.writestr(entry, "bad")
        data = archive.read_bytes()
        self.report = {"projectName": "ForeverDuelersGuild", "version": "0.4.6", "fileReleaseType": "Beta",
                       "archive": archive.name, "archiveSha256": hashlib.sha256(data).hexdigest(),
                       "archiveBytes": len(data), "archiveEntries": 3 if extra_path else 2,
                       "sourceBytesVerified": True, "zipIntegrityVerified": True, "publication": {}}
        self.write_json(self.directory / "build-report.json", self.report)

    def upload(self, opener):
        return UPLOADER.upload_package(self.directory, self.config, token=SECRET, opener=opener)

    def test_default_plan_is_offline_and_needs_no_token(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(UPLOADER, "build_opener") as network:
            plan = UPLOADER.plan_package(self.directory, self.config)
        network.assert_not_called()
        self.assertTrue(plan["uploadAllowed"])
        self.assertEqual(plan["gameVersionTypeId"], 88568)
        self.assertTrue(plan["publishAutomaticallyAfterApproval"])
        self.assertFalse((self.directory / "upload-attempt.json").exists())

    def test_read_only_preflight_accepts_published_package_gets_version_without_artifacts(self):
        self.worksheet["publication"] = {"fileId": 9058783, "published": True, "submitted": True}
        self.write_json(self.directory / "project.json", self.worksheet)
        opener = Opener(Response([FOREVER_VERSION]))
        result = UPLOADER.check_api(self.directory, self.config, token=SECRET, opener=opener)
        self.assertTrue(result["apiReady"])
        self.assertTrue(result["noUpload"])
        self.assertEqual(result["gameVersionId"], 55555)
        self.assertEqual(len(opener.requests), 1)
        self.assertEqual(opener.requests[0].get_method(), "GET")
        self.assertNotIn(SECRET, json.dumps(result))
        self.assertFalse((self.directory / "upload-attempt.json").exists())
        self.assertFalse((self.directory / "upload-receipt.json").exists())

    def test_read_only_preflight_missing_token_fails_without_network_or_artifacts(self):
        opener = Opener()
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(UPLOADER.UploadError, "CF_API_TOKEN"):
            UPLOADER.check_api(self.directory, self.config, opener=opener)
        self.assertEqual(opener.requests, [])
        self.assertFalse((self.directory / "upload-attempt.json").exists())
        self.assertFalse((self.directory / "upload-receipt.json").exists())

    def test_cli_read_only_preflight_uses_get_only_with_redirects_disabled(self):
        opener = Opener(Response([FOREVER_VERSION]))
        stdout, stderr = StringIO(), StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), \
                patch.dict(os.environ, {"CF_API_TOKEN": SECRET}), \
                patch.object(UPLOADER, "build_opener", return_value=opener) as builder:
            code = UPLOADER.main(["--package-dir", str(self.directory), "--config", str(self.config), "--check-api"])
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(stdout.getvalue())["noUpload"])
        self.assertIsInstance(builder.call_args.args[0], UPLOADER.NoRedirects)
        self.assertEqual([request.get_method() for request in opener.requests], ["GET"])
        self.assertEqual(stderr.getvalue(), "")

    def test_success_uses_exact_forever_metadata_and_records_submission(self):
        opener = Opener(Response([FOREVER_VERSION, {"id": 9, "gameVersionTypeID": 1, "name": "1.60.1"}]),
                        Response({"id": 9059999}))
        receipt = self.upload(opener)
        self.assertEqual(len(opener.requests), 2)
        get, post = opener.requests
        self.assertEqual(get.full_url, "https://wow.curseforge.com/api/game/versions")
        self.assertEqual(post.full_url, "https://wow.curseforge.com/api/projects/1726452/upload-file")
        self.assertEqual(post.get_method(), "POST")
        self.assertEqual(post.get_header("X-api-token"), SECRET)
        message = BytesParser(policy=default).parsebytes(
            ("Content-Type: " + post.get_header("Content-type") + "\r\nMIME-Version: 1.0\r\n\r\n").encode("ascii") + post.data)
        parts = list(message.iter_parts())
        self.assertEqual(len(parts), 2)
        metadata = json.loads(parts[0].get_payload(decode=True))
        self.assertEqual(metadata["gameVersions"], [55555])
        self.assertEqual(metadata["releaseType"], "beta")
        self.assertIs(metadata["isMarkedForManualRelease"], False)
        self.assertEqual(metadata["changelogType"], "text")
        self.assertEqual(metadata["changelog"], "New beta fixes.\n")
        self.assertEqual(parts[1].get_filename(), "ForeverDuelersGuild-0.4.6.zip")
        self.assertEqual(parts[1].get_payload(decode=True), (self.directory / parts[1].get_filename()).read_bytes())
        self.assertEqual(receipt["fileId"], 9059999)
        self.assertEqual(receipt["status"], "submitted; moderation pending")
        self.assertNotIn("published", receipt)
        self.assertNotIn(SECRET, (self.directory / "upload-receipt.json").read_text())
        self.assertNotIn(SECRET, (self.directory / "upload-attempt.json").read_text())

    def test_missing_or_ambiguous_forever_version_never_posts(self):
        for versions in ([{"id": 1, "gameVersionTypeID": 1, "name": "1.60.1"}],
                         [FOREVER_VERSION, dict(FOREVER_VERSION, id=2)],
                         [dict(FOREVER_VERSION, id=True)]):
            with self.subTest(versions=versions):
                opener = Opener(Response(versions))
                with self.assertRaisesRegex(UPLOADER.UploadError, "missing, ambiguous or invalid"):
                    self.upload(opener)
                self.assertEqual(len(opener.requests), 1)
                self.assertFalse((self.directory / "upload-attempt.json").exists())

    def test_successful_receipt_is_idempotent_and_conflicting_receipt_blocks(self):
        receipt = self.upload(Opener(Response([FOREVER_VERSION]), Response({"id": 9})))
        edited_receipt = dict(receipt, privateToken=SECRET)
        self.write_json(self.directory / "upload-receipt.json", edited_receipt)
        no_network = Opener()
        self.assertEqual(self.upload(no_network), receipt)
        self.assertEqual(no_network.requests, [])
        receipt["archiveSha256"] = "wrong"
        self.write_json(self.directory / "upload-receipt.json", receipt)
        with self.assertRaisesRegex(UPLOADER.UploadError, "conflicts"):
            self.upload(no_network)

    def test_incomplete_http_body_never_reaches_error_output(self):
        opener = Opener(Response([FOREVER_VERSION]), IncompleteRead(SECRET.encode(), 100))
        with self.assertRaises(UPLOADER.UploadError) as caught:
            self.upload(opener)
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertTrue((self.directory / "upload-attempt.json").exists())
        self.assertFalse((self.directory / "upload-receipt.json").exists())

    def test_existing_attempt_blocks_repeated_post_after_network_failure(self):
        opener = Opener(Response([FOREVER_VERSION]), URLError(SECRET))
        with self.assertRaisesRegex(UPLOADER.UploadError, "outcome must be reconciled") as caught:
            self.upload(opener)
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertTrue((self.directory / "upload-attempt.json").exists())
        no_network = Opener()
        with self.assertRaisesRegex(UPLOADER.UploadError, "prior upload attempt"):
            self.upload(no_network)
        self.assertEqual(no_network.requests, [])

    def test_already_published_or_submitted_packages_are_not_reuploaded(self):
        for state in ({"published": True}, {"fileId": 9058783}, {"submitted": True}):
            with self.subTest(state=state):
                self.worksheet["publication"] = state
                self.write_json(self.directory / "project.json", self.worksheet)
                self.assertFalse(UPLOADER.plan_package(self.directory, self.config)["uploadAllowed"])
                opener = Opener()
                with self.assertRaisesRegex(UPLOADER.UploadError, "already records"):
                    self.upload(opener)
                self.assertEqual(opener.requests, [])

    def test_upload_requires_a_passed_live_test_of_this_version(self):
        for tested in ({"status": "not supplied for this version", "version": "0.4.6"},
                       {"status": "passed", "version": "0.4.5"}, None):
            with self.subTest(tested=tested):
                self.worksheet["validation"] = {"userReportedTesting": tested} if tested else {}
                self.write_json(self.directory / "project.json", self.worksheet)
                plan = UPLOADER.plan_package(self.directory, self.config)
                self.assertFalse(plan["uploadAllowed"])
                self.assertFalse(plan["userTested"])
                opener = Opener()
                with self.assertRaisesRegex(UPLOADER.UploadError, "live test"):
                    self.upload(opener)
                self.assertEqual(opener.requests, [])
                self.assertFalse((self.directory / "upload-attempt.json").exists())

    def test_stale_build_report_publication_also_blocks_upload(self):
        self.report["publication"] = {"fileId": 9058783}
        self.write_json(self.directory / "build-report.json", self.report)
        with self.assertRaisesRegex(UPLOADER.UploadError, "already records"):
            self.upload(Opener())

    def test_archive_hash_mismatch_stops_before_network(self):
        (self.directory / "ForeverDuelersGuild-0.4.6.zip").write_bytes(b"changed after build")
        opener = Opener()
        with self.assertRaisesRegex(UPLOADER.UploadError, "SHA-256"):
            self.upload(opener)
        self.assertEqual(opener.requests, [])

    def test_unsafe_archive_entries_and_artifact_names_are_rejected(self):
        for name in ("ForeverDuel/../evil.lua", "/evil.lua", "ForeverDuel/C:evil.lua", "ForeverDuel\\evil.lua"):
            with self.subTest(name=name):
                self.make_archive(name)
                with self.assertRaisesRegex(UPLOADER.UploadError, "unsafe path"):
                    UPLOADER.plan_package(self.directory, self.config)
        for name in ("../outside.zip", "subdir/file.zip", "C:outside.zip", "bad\r\nname.zip"):
            with self.subTest(name=name):
                with self.assertRaises(UPLOADER.UploadError):
                    UPLOADER.artifact_path(self.directory, name)

    def test_wrong_project_host_or_version_group_stops_before_network(self):
        configurations = (
            {"apiBaseUrl": "https://example.com", "gameVersionTypeId": 88568, "publishAutomaticallyAfterApproval": True},
            {"apiBaseUrl": UPLOADER.API_BASE, "gameVersionTypeId": 1, "publishAutomaticallyAfterApproval": True},
            {"apiBaseUrl": UPLOADER.API_BASE, "gameVersionTypeId": 88568, "publishAutomaticallyAfterApproval": False},
        )
        for config in configurations:
            with self.subTest(config=config):
                self.write_json(self.config, config)
                with self.assertRaises(UPLOADER.UploadError):
                    self.upload(Opener())

    def test_redirect_and_http_error_messages_never_contain_secret(self):
        for status in (302, 401, 500):
            opener = Opener(HTTPError(UPLOADER.API_BASE + "?token=" + SECRET, status, SECRET, {"Location": SECRET}, BytesIO(SECRET.encode())))
            with self.subTest(status=status), self.assertRaises(UPLOADER.UploadError) as caught:
                self.upload(opener)
            self.assertNotIn(SECRET, str(caught.exception))
            self.assertIn(f"HTTP {status}", str(caught.exception))
            self.assertEqual(len(opener.requests), 1)
            self.assertFalse((self.directory / "upload-attempt.json").exists())
        self.assertIsNone(UPLOADER.NoRedirects().redirect_request(None, None, 302, "Found", {}, "https://example.com"))

    def test_post_http_failure_or_invalid_id_records_attempt_without_false_success(self):
        for result in (HTTPError(UPLOADER.API_BASE, 500, SECRET, {}, BytesIO(SECRET.encode())), Response({"id": True})):
            with self.subTest(result=type(result).__name__):
                attempt = self.directory / "upload-attempt.json"
                if attempt.exists():
                    attempt.unlink()
                with self.assertRaises(UPLOADER.UploadError) as caught:
                    self.upload(Opener(Response([FOREVER_VERSION]), result))
                self.assertNotIn(SECRET, str(caught.exception))
                self.assertTrue(attempt.exists())
                self.assertFalse((self.directory / "upload-receipt.json").exists())

    def test_cli_errors_are_safe_and_default_never_opens_network(self):
        stdout, stderr = StringIO(), StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), patch.object(UPLOADER, "build_opener") as network:
            code = UPLOADER.main(["--package-dir", str(self.directory), "--config", str(self.config)])
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(stdout.getvalue())["uploadAllowed"])
        network.assert_not_called()
        stdout, stderr = StringIO(), StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), patch.dict(os.environ, {}, clear=True):
            code = UPLOADER.main(["--package-dir", str(self.directory), "--config", str(self.config), "--upload"])
        self.assertEqual(code, 1)
        self.assertIn("CF_API_TOKEN", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
