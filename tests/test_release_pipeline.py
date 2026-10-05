"""Release gates and version preparation; no network or real workspace edits."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
from prepare_release import prepare_release
from release import run_pipeline, validate_tag


class ReleasePipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.docs = self.root / "docs/curseforge"
        self.docs.mkdir(parents=True)
        (self.root / "ForeverDuel").mkdir()
        self.project = {
            "project": {"name": "ForeverDuelersGuild"},
            "file": {"version": "0.4.5", "gameFlavor": "Forever", "gameVersion": "1.60.1", "interface": 16001},
            "publication": {"fileId": 9058783, "published": True, "approved": True},
            "validation": {"automated": {"status": "passed"}},
        }
        self.previous = json.dumps(self.project)
        (self.docs / "project.json").write_text(self.previous, encoding="utf-8")
        (self.root / "ForeverDuel/ForeverDuel.toc").write_text('## Version: 0.4.5\n', encoding="utf-8")
        (self.root / "ForeverDuel/Constants.lua").write_text('VERSION = "0.4.5", PROTOCOL_VERSION = 2\n', encoding="utf-8")
        self.notes = self.root / "notes.txt"
        self.notes.write_text("Fix repeated duel requests.", encoding="utf-8")

    def test_prepare_resets_evidence_and_keeps_previous_release(self):
        prepare_release(self.root, "0.4.6", self.notes)
        new = json.loads((self.docs / "project.json").read_text(encoding="utf-8"))
        self.assertEqual(new["file"]["version"], "0.4.6")
        self.assertEqual(new["file"]["releaseType"], "Beta")
        self.assertTrue(new["file"]["publishAutomaticallyAfterApproval"])
        self.assertIsNone(new["publication"]["fileId"])
        self.assertFalse(new["publication"]["published"])
        self.assertEqual(new["validation"]["automated"]["status"], "not run for this version")
        self.assertEqual((self.docs / "releases/0.4.5.json").read_text(encoding="utf-8"), self.previous)
        self.assertIn('VERSION = "0.4.6", PROTOCOL_VERSION = 2', (self.root / "ForeverDuel/Constants.lua").read_text())
        self.assertIn("ForeverDuelersGuild 0.4.6 - Beta", (self.docs / "changelog-0.4.6.txt").read_text())

    def test_non_increasing_and_invalid_versions_do_not_change_files(self):
        for version in ("0.4.5", "0.4.4", "v0.4.6", "00.4.6", "0.4.6-beta"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                prepare_release(self.root, version, self.notes)
        self.assertEqual((self.docs / "project.json").read_text(), self.previous)

    def test_conflicting_manifest_stops_before_changes(self):
        (self.root / "ForeverDuel/Constants.lua").write_text('VERSION = "0.4.4"')
        with self.assertRaises(ValueError):
            prepare_release(self.root, "0.4.6", self.notes)
        self.assertFalse((self.docs / "changelog-0.4.6.txt").exists())

    def test_wrong_tag_stops_before_tests_or_network(self):
        with patch("release.subprocess.run") as run, self.assertRaises(ValueError):
            run_pipeline(self.root, "v0.4.6")
        run.assert_not_called()

    def test_tests_fail_before_build_or_upload(self):
        import subprocess
        with patch("release.subprocess.run", side_effect=subprocess.CalledProcessError(1, "tests")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                run_pipeline(self.root, "v0.4.5")
        self.assertEqual(run.call_count, 1)

    def test_existing_publication_cannot_be_uploaded(self):
        with patch("release.subprocess.run") as run, self.assertRaises(ValueError):
            run_pipeline(self.root, "v0.4.5", upload=True)
        run.assert_not_called()

    def test_upload_refuses_uncommitted_changes(self):
        import subprocess
        self.project["publication"] = {"fileId": None, "published": False}
        (self.docs / "project.json").write_text(json.dumps(self.project), encoding="utf-8")
        status = subprocess.CompletedProcess(["git"], 0, stdout=" M ForeverDuel/Duel.lua\n", stderr="")
        with patch.dict("os.environ", {"CF_API_TOKEN": "private-test-token"}), \
                patch("release.subprocess.run", return_value=status) as run, self.assertRaises(ValueError) as caught:
            run_pipeline(self.root, "v0.4.5", upload=True)
        self.assertIn("uncommitted", str(caught.exception))
        self.assertEqual(run.call_count, 1, "only the git status check ran; no tests, build or upload")

    def test_offline_checks_do_not_inherit_upload_token(self):
        import subprocess
        with patch.dict("os.environ", {"CF_API_TOKEN": "private-test-token"}), patch("release.subprocess.run") as run, patch("release.print"):
            run.return_value = subprocess.CompletedProcess([], 0, stdout="Lua 5.1: compiled 33 files\nPASS 14 suites, 4551 assertions\n", stderr="")
            run_pipeline(self.root, "v0.4.5")
        self.assertEqual(run.call_count, 4)
        for call in run.call_args_list:
            self.assertNotIn("CF_API_TOKEN", call.kwargs["env"])
        self.assertNotIn("--upload", run.call_args_list[-1].args[0])

    def test_new_version_records_only_its_own_automated_results(self):
        import subprocess
        prepare_release(self.root, "0.4.6", self.notes)
        with patch("release.subprocess.run") as run, patch("release.print"):
            run.return_value = subprocess.CompletedProcess([], 0, stdout="Lua 5.1: compiled 33 files\nPASS 14 suites, 4551 assertions\n", stderr="")
            run_pipeline(self.root, "v0.4.6")
        new = json.loads((self.docs / "project.json").read_text())
        self.assertEqual(new["validation"]["automated"]["version"], "0.4.6")
        self.assertEqual(new["validation"]["automated"]["status"], "passed")
        self.assertEqual(new["validation"]["userReportedTesting"]["status"], "not supplied for this version")
        self.assertFalse(new["publication"]["published"])


if __name__ == "__main__":
    unittest.main()
