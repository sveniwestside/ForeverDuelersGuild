"""Statistical simulation and safety tests; no client, server, or network access."""

import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import time
import unittest

import numpy as np
from scipy.special import expit


SPEC = importlib.util.spec_from_file_location("analyze_matchups", Path(__file__).resolve().parents[1] / "analyze-matchups.py")
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)
CUTOFF = 1800000000
ORDER = sorted(TOOL.CLASSES)


def model():
    return {"id": "manual-v1", "dataCutoff": 0, "classOrder": ORDER,
            "probabilities": {a: {b: .5 for b in ORDER} for a in ORDER}}


def match(index, a_index, b_index, won=True, level=55, ended=None, other_level=None):
    a = {"guid": f"Player-1-{1024 + a_index:08X}", "classFile": "MAGE", "level": level}
    b = {"guid": f"Player-1-{4096 + b_index:08X}", "classFile": "WARRIOR", "level": level if other_level is None else other_level}
    return {"matchId": f"match-{index:06d}", "bracket": "MAX_LEVEL" if level == b["level"] == 60 else "LEVELING",
            "endedAt": CUTOFF - TOOL.DAY if ended is None else ended, "confirmedAt": CUTOFF - 1,
            "playerA": a, "playerB": b, "winnerGUID": a["guid"] if won else b["guid"]}


def dataset(matches=None, active=None):
    result = {"schemaVersion": 1, "rulesetId": "forever-v1", "maxLevel": 60,
              "generatedAt": "2026-10-04T10:00:00Z", "dataCutoff": CUTOFF,
              "activeModel": model() if active is None else active,
              "matches": sorted(matches or [], key=lambda m: (m["endedAt"], m["matchId"]))}
    result["datasetHash"] = TOOL.dataset_hash(result)
    return result


def simulation(window=0, offset=120, class_mean_difference=0, seed=19, level=55):
    rng = np.random.default_rng(seed)
    skill_a = np.linspace(-100, 100, 20) + class_mean_difference / 2
    skill_b = np.linspace(100, -100, 20) - class_mean_difference / 2
    records = []
    for a in range(20):
        for b in range(20):
            probability = expit(TOOL.SCALE * (skill_a[a] - skill_b[b] + offset))
            records.append(match(window * 1000 + a * 20 + b, a, b, rng.random() < probability,
                                 level=level, ended=CUTOFF - (21 if window == 0 else 7) * TOOL.DAY + a * 20 + b))
    return records


def pair(summary, a="MAGE", b="WARRIOR"):
    return next(row for row in summary["pairs"] if row["classA"] == a and row["classB"] == b)


def evidence(estimate=.65, interval=(.59, .70), baseline=.5):
    return {"classA": "MAGE", "classB": "WARRIOR", "baselineProbability": baseline,
            "estimatedProbability": estimate, "ci95": list(interval), "rawMatches": 120,
            "weightedMatches": 120., "uniqueA": 20, "uniqueB": 20, "uniquePairs": 40,
            "fitSucceeded": True, "bootstrapSuccessful": 500}


class EstimationTests(unittest.TestCase):
    def test_joint_fit_recovers_effect_and_individual_skill(self):
        fit = TOOL.BradleyTerry(simulation(offset=120), model())
        result = fit.fit()
        index = fit.pairs.index(("MAGE", "WARRIOR"))
        self.assertTrue(result["success"])
        estimated = np.log(result["probabilities"][index] / (1 - result["probabilities"][index])) / TOOL.SCALE
        self.assertLess(abs(estimated - 120), 45)
        for members in fit.group_members:
            if len(members): self.assertAlmostEqual(np.mean(result["skills"][members]), 0, places=10)
        mage_skills = result["skills"][fit.groups == ORDER.index("MAGE")]
        self.assertGreater(np.corrcoef(mage_skills, np.linspace(-100, 100, 20))[0, 1], .55)

    def test_centering_cannot_distinguish_unequal_class_population_skill(self):
        # There is NO real class effect; Mage players happen to be better.
        fit = TOOL.BradleyTerry(simulation(offset=0, class_mean_difference=180, seed=32), model())
        result = fit.fit()
        estimated = result["probabilities"][fit.pairs.index(("MAGE", "WARRIOR"))]
        self.assertTrue(result["success"])
        self.assertGreater(estimated, .62)
        # An apparent offset is expected under the explicitly stated centering assumption.

    def test_gradient_matches_finite_difference(self):
        records = [match(i, i % 3, (i + 1) % 3, won=i % 2 == 0) for i in range(9)]
        fit = TOOL.BradleyTerry(records, model())
        x = np.concatenate((np.linspace(-.2, .2, len(fit.guids)), fit.prior + .05))
        multiplicity = np.ones(len(fit.guids))
        _, gradient = fit.objective(x, multiplicity)
        for index in range(len(x)):
            left, right = x.copy(), x.copy()
            left[index] -= 1e-6; right[index] += 1e-6
            numeric = (fit.objective(right, multiplicity)[0] - fit.objective(left, multiplicity)[0]) / 2e-6
            self.assertAlmostEqual(numeric, gradient[index], places=5)

    def test_bootstrap_reproducible_and_stratified_centering(self):
        fit = TOOL.BradleyTerry(simulation(), model())
        fitted = fit.fit()
        first, count = fit.bootstrap(fitted, replicates=8, seed=42)
        second, other = fit.bootstrap(fitted, replicates=8, seed=42)
        self.assertEqual((count, other), (8, 8))
        np.testing.assert_array_equal(first, second)
        mult = np.tile([0., 1., 2., 1.], 10)
        skills, _ = fit.centered(np.linspace(-1, 1, 40), mult)
        for members in fit.group_members:
            if len(members): self.assertAlmostEqual(np.average(skills[members], weights=mult[members]), 0)

    def test_manual_prior_preserved_without_data_and_offset_bound(self):
        active = model()
        active["probabilities"]["MAGE"]["WARRIOR"] = .6
        active["probabilities"]["WARRIOR"]["MAGE"] = .4
        empty = TOOL.BradleyTerry([], active)
        self.assertAlmostEqual(empty.fit()["probabilities"][empty.pairs.index(("MAGE", "WARRIOR"))], .6)
        fit = TOOL.BradleyTerry([match(i, i % 20, (i // 20) % 20) for i in range(400)], active)
        self.assertLessEqual(fit.fit()["probabilities"].max(), expit(TOOL.SCALE * 150) + 1e-12)


class SafetyTests(unittest.TestCase):
    def test_repeat_daily_and_window_caps(self):
        same_day = [match(i, 0, 0) for i in range(20)]
        self.assertAlmostEqual(TOOL.repeat_weights(same_day).sum(), 1)
        many_days = [match(i, 0, 0, ended=CUTOFF - (i + 1) * TOOL.DAY) for i in range(20)]
        self.assertAlmostEqual(TOOL.repeat_weights(many_days).sum(), 5)

    def test_duplicate_nonconfirmed_mixed_cap_and_ruleset_rejected(self):
        valid = dataset([match(0, 0, 0)])
        cases = []
        duplicate = copy.deepcopy(valid); duplicate["matches"] *= 2; cases.append(duplicate)
        for field, value in (("status", "pending"), ("rulesetId", "other"), ("winnerGUID", "Player-1-FFFF")):
            changed = copy.deepcopy(valid); changed["matches"][0][field] = value; cases.append(changed)
        cap = copy.deepcopy(valid); cap["matches"][0]["playerA"]["maxLevel"] = 70; cases.append(cap)
        matrix = copy.deepcopy(valid); matrix["activeModel"]["probabilities"]["MAGE"]["WARRIOR"] = .8; cases.append(matrix)
        schema = copy.deepcopy(valid); schema["schemaVersion"] = True; cases.append(schema)
        for data in cases:
            data["datasetHash"] = TOOL.dataset_hash(data)
            with self.subTest(data=data), self.assertRaises(TOOL.AnalysisError): TOOL.validate_dataset(data)

    def test_hash_tampering_and_class_changes_rejected(self):
        data = dataset([match(0, 0, 0)])
        data["matches"][0]["winnerGUID"] = data["matches"][0]["playerB"]["guid"]
        with self.assertRaisesRegex(TOOL.AnalysisError, "hash"): TOOL.validate_dataset(data)
        second = match(1, 0, 1)
        second["playerA"]["classFile"] = "PRIEST"
        with self.assertRaisesRegex(TOOL.AnalysisError, "class changes"):
            TOOL.validate_dataset(dataset([match(0, 0, 0), second]))

    def test_seven_bands_unequal_level_and_late_confirmation(self):
        unequal = match(0, 0, 0, other_level=54)
        late = match(1, 1, 1); late["confirmedAt"] = CUTOFF + 1
        report = TOOL.analyze(dataset([unequal, late]))
        self.assertEqual([(band["minLevel"], band["maxLevel"]) for band in report["bands"]],
                         [(1,9),(10,19),(20,29),(30,39),(40,49),(50,59),(60,60)])
        high = report["bands"][5]
        self.assertEqual((high["rawMatches"], high["allConfirmedMatches"]), (0, 1))
        self.assertEqual(pair(high)["allConfirmed"]["winsA"], 1)
        self.assertEqual(report["excluded"], {"unknownAtCutoffOrFuture": 1, "unequalLevel": 1})
        self.assertIsNone(pair(high)["estimatedProbability"])
        self.assertEqual(pair(high)["status"], "insufficient-data")

    def test_missing_max_allows_manual_candidate_with_pooled_target(self):
        first, second = evidence(.57, (.52,.63)), evidence(.68, (.61,.73))
        empty = {**evidence(), "rawMatches": 0, "weightedMatches": 0., "uniqueA": 0, "uniqueB": 0, "uniquePairs": 0, "ci95": None, "bootstrapSuccessful": 0}
        candidate = TOOL.evaluate_candidate(first, second, empty, evidence(.64))
        self.assertTrue(candidate["eligible"])
        self.assertAlmostEqual(candidate["proposedProbability"], .55)  # pooled target, not weaker .57 window
        candidate = TOOL.evaluate_candidate(first, second, empty, evidence(.53))
        self.assertAlmostEqual(candidate["proposedProbability"], .53)

    def test_opposing_windows_max_contradiction_and_freshness_block(self):
        first = evidence()
        opposite = evidence(.35, (.3,.41))
        for second, maximum, pooled, fresh, reason in (
            (opposite, first, first, True, "window_directions_disagree"),
            (first, opposite, first, True, "max_level_contradiction"),
            (first, first, first, False, "fresh_validation_required"),
            (first, first, opposite, True, "pooled_direction_disagrees"),
        ):
            result = TOOL.evaluate_candidate(first, second, maximum, pooled, fresh)
            self.assertFalse(result["eligible"]); self.assertIn(reason, result["blockingReasons"])

    def test_small_samples_incomplete_bootstrap_and_baseline_ci_block(self):
        for changed, reason in (
            ({"weightedMatches": 99}, "previous_window_insufficient_data"),
            ({"uniqueA": 19}, "previous_window_insufficient_data"),
            ({"uniquePairs": 29}, "previous_window_insufficient_data"),
            ({"bootstrapSuccessful": 499}, "previous_window_bootstrap_incomplete"),
            ({"ci95": [.45,.65]}, "previous_window_interval_contains_baseline"),
        ):
            result = TOOL.evaluate_candidate({**evidence(), **changed}, evidence(), evidence(), evidence())
            self.assertFalse(result["eligible"]); self.assertIn(reason, result["blockingReasons"])

    def test_cli_no_activation_no_source_overwrite_no_stale_candidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source, output, candidate = root / "data.json", root / "report.json", root / "candidate.json"
            source.write_text(json.dumps(dataset()))
            before = source.read_bytes()
            with contextlib.redirect_stdout(io.StringIO()): TOOL.main([str(source), "--output", str(output), "--candidate", str(candidate)])
            self.assertEqual(source.read_bytes(), before); self.assertFalse(candidate.exists())
            self.assertIsNone(json.loads(output.read_text())["modelCandidate"])
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                TOOL.main([str(source), "--output", str(source)])
            candidate.write_text("keep")
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                TOOL.main([str(source), "--output", str(output), "--candidate", str(candidate)])
            self.assertEqual(candidate.read_text(), "keep")

    def test_duplicate_json_and_nonfinite_input_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.json"
            for payload in ('{"schemaVersion":1,"schemaVersion":1}', '{"value":NaN}'):
                path.write_text(payload)
                with self.assertRaises(TOOL.AnalysisError): TOOL.read_dataset(path)


class FullBootstrapTests(unittest.TestCase):
    def test_real_500_bootstraps_generate_provisional_candidate_without_max_data(self):
        started = time.monotonic()
        data = dataset(simulation(window=0, offset=135, seed=71) + simulation(window=1, offset=135, seed=81))
        report = TOOL.analyze(data)  # real fixed-500 path; never mock its fits or confidence intervals
        candidate = next(c for c in report["candidates"] if (c["classA"], c["classB"]) == ("MAGE", "WARRIOR"))
        self.assertTrue(candidate["eligible"], candidate["blockingReasons"])
        for window in candidate["windows"]:
            self.assertEqual(window["bootstrapSuccessful"], 500)
            self.assertGreater(window["ci95"][0], .5)
        self.assertEqual(candidate["maxLevel"]["rawMatches"], 0)
        self.assertGreater(candidate["pooledEstimate"], .5)
        self.assertLessEqual(candidate["changePp"], 5 + 1e-8)
        proposal = report["modelCandidate"]
        self.assertEqual(proposal["source"], "leveling-supported")
        self.assertAlmostEqual(proposal["probabilities"]["MAGE"]["WARRIOR"] + proposal["probabilities"]["WARRIOR"]["MAGE"], 1)
        self.assertTrue(report["requiresFreshValidation"])
        self.assertNotIn("Player-", json.dumps(report))
        print(f"\nReal 2x500 bootstrap simulation: {time.monotonic() - started:.2f}s")


if __name__ == "__main__":
    unittest.main()
