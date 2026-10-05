#!/usr/bin/env python3
"""Offline, review-only matchup calibration of a server-exported dataset.

python tools/analyze-matchups.py dataset.json --output report.json
Optional --candidate candidate.json writes a proposed matrix when eligible.
Neither output activates a rating model. Requires requirements-analysis.txt.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile

import numpy as np
from scipy.optimize import minimize
from scipy.special import expit


TOOL_VERSION = "bt-v1"
DAY = 86400
SCALE = math.log(10) / 400
SKILL_SD = 400
PAIR_SD = 75
BOUND = 150
BOOTSTRAPS = 500
SEED = 20261004
CLASSES = {"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"}
BANDS = [("levels-1-9", 1, 9), ("levels-10-19", 10, 19), ("levels-20-29", 20, 29),
         ("levels-30-39", 30, 39), ("levels-40-49", 40, 49), ("levels-50-59", 50, 59), ("max-level", 60, 60)]
PARAMETERS = {
    "skillPriorSd": SKILL_SD, "pairPriorSd": PAIR_SD, "offsetBound": BOUND,
    "bootstrapReplicates": BOOTSTRAPS, "seed": SEED, "windowDays": 14,
    "maxChangePp": 5, "repeatDayCap": 1, "repeatWindowCap": 5,
    "minimumWeightedMatches": 100, "minimumCharactersPerSide": 20, "minimumCharacterPairs": 30,
    "maxCounterevidenceMinimumWeightedMatches": 50, "maxCounterevidenceMinimumCharactersPerSide": 10,
    "maxCounterevidenceMinimumCharacterPairs": 20,
    "centering": "equal mean character strength within each class and level band",
    "bootstrapMethod": "stratified character-cluster multinomial bootstrap; refit centered model",
    "rawEloUsed": False,
}


class AnalysisError(ValueError):
    pass


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def dataset_hash(dataset):
    return digest({"rulesetId": dataset["rulesetId"], "maxLevel": dataset["maxLevel"],
                   "dataCutoff": dataset["dataCutoff"], "activeModelId": dataset["activeModel"]["id"], "matches": dataset["matches"]})


def integer(value, label, minimum=0, maximum=253402300799):
    if type(value) is not int or not minimum <= value <= maximum:
        raise AnalysisError(f"{label} must be an integer in [{minimum}, {maximum}]")
    return value


def text(value, label):
    if not isinstance(value, str) or not value or len(value) > 256 or any(ord(c) < 32 for c in value):
        raise AnalysisError(f"Invalid {label}")
    return value


def validate_dataset(data):
    if not isinstance(data, dict) or type(data.get("schemaVersion")) is not int or data.get("schemaVersion") != 1:
        raise AnalysisError("Expected schemaVersion 1 analysis dataset")
    text(data.get("rulesetId"), "rulesetId")
    if integer(data.get("maxLevel"), "maxLevel", 1, 255) != 60:
        raise AnalysisError("bt-v1 supports only the accepted level-cap-60 bands")
    cutoff = integer(data.get("dataCutoff"), "dataCutoff")
    model = data.get("activeModel")
    if not isinstance(model, dict):
        raise AnalysisError("Missing activeModel")
    text(model.get("id"), "activeModel.id")
    order = model.get("classOrder")
    if not isinstance(order, list) or len(order) != 9 or any(not isinstance(c, str) for c in order) or set(order) != CLASSES:
        raise AnalysisError("activeModel.classOrder must contain the nine Classic classes once")
    previous_cutoff = integer(model.get("dataCutoff", 0), "activeModel.dataCutoff")
    if previous_cutoff > cutoff:
        raise AnalysisError("Model cutoff exceeds dataset cutoff")
    matrix = model.get("probabilities")
    if not isinstance(matrix, dict) or set(matrix) != CLASSES:
        raise AnalysisError("Missing complete active probability matrix")
    lower, upper = float(expit(-SCALE * BOUND)), float(expit(SCALE * BOUND))
    for a in order:
        if not isinstance(matrix[a], dict) or set(matrix[a]) != CLASSES:
            raise AnalysisError("Missing probability matrix row")
        for b in order:
            value = matrix[a][b]
            if type(value) not in (int, float) or not math.isfinite(value) or not lower - 1e-12 <= value <= upper + 1e-12:
                raise AnalysisError("Probability matrix exceeds +/-150 Elo bounds")
            other = matrix[b].get(a) if isinstance(matrix.get(b), dict) else None
            if type(other) not in (int, float) or abs(value + other - 1) > 1e-9 or (a == b and abs(value - .5) > 1e-12):
                raise AnalysisError("Probability matrix must be complementary with neutral mirrors")
    matches = data.get("matches")
    if not isinstance(matches, list) or len(matches) > 100_000:
        raise AnalysisError("Expected at most 100000 canonical matches")
    seen, identities = set(), {}
    for match in matches:
        if not isinstance(match, dict):
            raise AnalysisError("Invalid match")
        match_id = text(match.get("matchId"), "matchId")
        if match_id in seen:
            raise AnalysisError("Duplicate matchId; bilateral reports must count once")
        seen.add(match_id)
        if match.get("status", "confirmed") != "confirmed" or match.get("rulesetId", data["rulesetId"]) != data["rulesetId"]:
            raise AnalysisError("Only same-ruleset confirmed matches are accepted")
        integer(match.get("endedAt"), "endedAt")
        integer(match.get("confirmedAt"), "confirmedAt")
        players = []
        for field in ("playerA", "playerB"):
            player = match.get(field)
            if not isinstance(player, dict):
                raise AnalysisError("Missing canonical participants")
            guid = text(player.get("guid"), "guid")
            if not re.fullmatch(r"Player-[0-9a-fA-F]+-[0-9a-fA-F]+", guid):
                raise AnalysisError("Invalid character GUID")
            if player.get("classFile") not in CLASSES:
                raise AnalysisError("Unknown class")
            integer(player.get("level"), "level", 1, 60)
            if player.get("maxLevel", 60) != 60:
                raise AnalysisError("Mixed level caps are not accepted")
            if guid in identities and identities[guid] != player["classFile"]:
                raise AnalysisError("Character class changes within dataset")
            identities[guid] = player["classFile"]
            players.append(player)
        a, b = players
        if a["guid"] >= b["guid"]:
            raise AnalysisError("Canonical participants must have ascending distinct GUIDs")
        if match.get("winnerGUID") not in (a["guid"], b["guid"]):
            raise AnalysisError("Invalid winnerGUID")
        bracket = "MAX_LEVEL" if a["level"] == b["level"] == 60 else "LEVELING"
        if match.get("bracket") != bracket or (a["level"] == 60) != (b["level"] == 60) or abs(a["level"] - b["level"]) > 5:
            raise AnalysisError("Invalid bracket or level pair")
    if matches != sorted(matches, key=lambda item: (item["endedAt"], item["matchId"])):
        raise AnalysisError("Canonical matches must be sorted by endedAt, matchId")
    if data.get("datasetHash") != dataset_hash(data):
        raise AnalysisError("Dataset hash mismatch")
    return data


def repeat_weights(matches):
    """One unit per unordered character pair/UTC day; <=5 units per window."""
    groups, days = {}, {}
    for match in matches:
        pair = (match["playerA"]["guid"], match["playerB"]["guid"])
        day = match["endedAt"] // DAY
        key = (pair, day)
        groups[key] = groups.get(key, 0) + 1
        days.setdefault(pair, set()).add(day)
    return np.array([min(1., 5. / len(days[(m["playerA"]["guid"], m["playerB"]["guid"])])) /
                     groups[((m["playerA"]["guid"], m["playerB"]["guid"]), m["endedAt"] // DAY)] for m in matches], dtype=float)


class BradleyTerry:
    """Convex MAP fit. Centering fixes the assumed equal class-mean skill gauge."""

    def __init__(self, matches, model):
        self.matches = matches
        self.classes = model["classOrder"]
        self.pairs = [(a, b) for i, a in enumerate(self.classes) for b in self.classes[i + 1:]]
        self.prior = np.array([math.log(model["probabilities"][a][b] / (1 - model["probabilities"][a][b])) for a, b in self.pairs])
        self.guids = sorted({m[field]["guid"] for m in matches for field in ("playerA", "playerB")})
        index = {guid: i for i, guid in enumerate(self.guids)}
        class_indices = {name: i for i, name in enumerate(self.classes)}
        guid_classes = {m[field]["guid"]: m[field]["classFile"] for m in matches for field in ("playerA", "playerB")}
        self.groups = np.array([class_indices[guid_classes[guid]] for guid in self.guids], dtype=int)
        self.a = np.array([index[m["playerA"]["guid"]] for m in matches], dtype=int)
        self.b = np.array([index[m["playerB"]["guid"]] for m in matches], dtype=int)
        self.y = np.array([float(m["winnerGUID"] == m["playerA"]["guid"]) for m in matches])
        pair_indices = {pair: i for i, pair in enumerate(self.pairs)}
        positions, signs = [], []
        for m in matches:
            a, b = m["playerA"]["classFile"], m["playerB"]["classFile"]
            if a == b:
                positions.append(0); signs.append(0.)
            elif (a, b) in pair_indices:
                positions.append(pair_indices[a, b]); signs.append(1.)
            else:
                positions.append(pair_indices[b, a]); signs.append(-1.)
        self.positions = np.array(positions, dtype=int)
        self.signs = np.array(signs)
        self.weights = repeat_weights(matches)
        self.group_members = [np.flatnonzero(self.groups == index) for index in range(9)]

    def centered(self, raw, multiplicity):
        totals = np.bincount(self.groups, weights=multiplicity, minlength=9)
        sums = np.bincount(self.groups, weights=multiplicity * raw, minlength=9)
        means = np.divide(sums, totals, out=np.zeros(9), where=totals > 0)
        return raw - means[self.groups], totals

    def objective(self, x, multiplicity):
        n = len(self.guids)
        raw, offsets = x[:n], x[n:]
        skill, totals = self.centered(raw, multiplicity)
        weights = self.weights * multiplicity[self.a] * multiplicity[self.b]
        z = skill[self.a] - skill[self.b] + self.signs * offsets[self.positions]
        residual = weights * (expit(z) - self.y)
        loss = np.sum(weights * (np.logaddexp(0, z) - self.y * z))
        loss += np.sum(multiplicity * raw * raw) / (2 * (SKILL_SD * SCALE) ** 2)
        loss += np.sum((offsets - self.prior) ** 2) / (2 * (PAIR_SD * SCALE) ** 2)
        gs = np.bincount(self.a, weights=residual, minlength=n) - np.bincount(self.b, weights=residual, minlength=n)
        class_gradient = np.bincount(self.groups, weights=gs, minlength=9)
        correction = np.divide(class_gradient, totals, out=np.zeros(9), where=totals > 0)
        gt = gs - multiplicity * correction[self.groups] + multiplicity * raw / (SKILL_SD * SCALE) ** 2
        gb = np.bincount(self.positions, weights=residual * self.signs, minlength=36) + (offsets - self.prior) / (PAIR_SD * SCALE) ** 2
        return float(loss), np.concatenate((gt, gb))

    def fit(self, multiplicity=None, initial=None):
        n = len(self.guids)
        multiplicity = np.ones(n) if multiplicity is None else multiplicity
        if not len(self.matches):
            return {"x": self.prior.copy(), "probabilities": expit(self.prior), "skills": np.zeros(0), "success": True, "iterations": 0}
        initial = np.concatenate((np.zeros(n), self.prior)) if initial is None else initial.copy()
        initial[:n][multiplicity == 0] = 0
        result = minimize(self.objective, initial, args=(multiplicity,), jac=True, method="L-BFGS-B",
                          bounds=[(None, None)] * n + [(-BOUND * SCALE, BOUND * SCALE)] * 36,
                          options={"maxiter": 400, "ftol": 1e-10, "gtol": 1e-6})
        return {"x": result.x, "probabilities": expit(result.x[n:]), "skills": self.centered(result.x[:n], multiplicity)[0],
                "success": bool(result.success), "iterations": int(result.nit)}

    def bootstrap(self, fitted, replicates=BOOTSTRAPS, seed=SEED):
        rng = np.random.default_rng(seed)
        estimates = []
        for _ in range(replicates):
            multiplicity = np.zeros(len(self.guids))
            for members in self.group_members:
                if len(members):
                    draws = rng.choice(members, size=len(members), replace=True)
                    multiplicity += np.bincount(draws, minlength=len(self.guids))
            result = self.fit(multiplicity, fitted["x"])
            if result["success"]:
                estimates.append(result["probabilities"])
        if len(estimates) != replicates or replicates < 1:
            return None, len(estimates)
        return np.quantile(np.array(estimates), [.025, .975], axis=0), len(estimates)


def pair_counts(matches, weights, pairs):
    result = []
    for a, b in pairs:
        rows = [(m, w) for m, w in zip(matches, weights) if {m["playerA"]["classFile"], m["playerB"]["classFile"]} == {a, b}]
        own, other, distinct, wins = set(), set(), set(), 0
        for m, _ in rows:
            participants = [m["playerA"], m["playerB"]]
            own.add(next(p["guid"] for p in participants if p["classFile"] == a))
            other.add(next(p["guid"] for p in participants if p["classFile"] == b))
            distinct.add((m["playerA"]["guid"], m["playerB"]["guid"]))
            wins += int(next(p["classFile"] for p in participants if p["guid"] == m["winnerGUID"]) == a)
        result.append({"classA": a, "classB": b, "rawMatches": len(rows), "weightedMatches": round(sum(w for m, w in rows), 8),
                       "uniqueA": len(own), "uniqueB": len(other), "uniquePairs": len(distinct),
                       "winsA": wins, "winsB": len(rows) - wins, "observedWinRate": wins / len(rows) if rows else None})
    return result


def sufficient(pair, minimum=(100, 20, 30)):
    matches, characters, pairs = minimum
    return pair["weightedMatches"] >= matches - 1e-7 and min(pair["uniqueA"], pair["uniqueB"]) >= characters and pair["uniquePairs"] >= pairs


def summarize(matches, model, bootstrap=False, minimum=(100, 20, 30), replicates=BOOTSTRAPS, seed=SEED):
    fit = BradleyTerry(matches, model)
    point = fit.fit()
    counts = pair_counts(matches, fit.weights, fit.pairs)
    intervals, successful = None, 0
    if bootstrap and point["success"] and any(sufficient(pair, minimum) for pair in counts):
        intervals, successful = fit.bootstrap(point, replicates, seed)
    pairs = []
    for index, count in enumerate(counts):
        a, b = count["classA"], count["classB"]
        pairs.append({**count, "baselineProbability": float(model["probabilities"][a][b]),
                      "estimatedProbability": float(point["probabilities"][index]) if sufficient(count, minimum) and point["success"] else None,
                      "ci95": None if intervals is None else [float(intervals[0, index]), float(intervals[1, index])],
                      "fitSucceeded": point["success"], "bootstrapSuccessful": successful,
                      "bootstrapReplicates": replicates if successful else 0,
                      "status": "diagnostic-only" if sufficient(count, minimum) and point["success"] else "insufficient-data"})
    return {"rawMatches": len(matches), "weightedMatches": round(float(np.sum(fit.weights)), 8),
            "fitSucceeded": point["success"], "pairs": pairs}


def direction(pair):
    if pair.get("ci95") is None:
        return 0
    low, high = pair["ci95"]
    baseline = pair["baselineProbability"]
    return 1 if low > baseline else -1 if high < baseline else 0


def evaluate_candidate(first, second, maximum, pooled, fresh=True, replicates=BOOTSTRAPS):
    reasons = []
    for name, window in (("previous", first), ("latest", second)):
        if not sufficient(window): reasons.append(f"{name}_window_insufficient_data")
        if not window["fitSucceeded"]: reasons.append(f"{name}_window_fit_failed")
        if window.get("bootstrapSuccessful") != BOOTSTRAPS or replicates != BOOTSTRAPS: reasons.append(f"{name}_window_bootstrap_incomplete")
        if direction(window) == 0: reasons.append(f"{name}_window_interval_contains_baseline")
    signal = direction(first)
    if signal and direction(second) and signal != direction(second): reasons.append("window_directions_disagree")
    pooled_estimate = pooled.get("estimatedProbability")
    if not pooled["fitSucceeded"] or pooled_estimate is None:
        reasons.append("pooled_estimate_unavailable")
    elif signal and (pooled_estimate - first["baselineProbability"]) * signal <= 0:
        reasons.append("pooled_direction_disagrees")
    if not fresh: reasons.append("fresh_validation_required")
    if sufficient(maximum, (50, 10, 20)):
        if not maximum["fitSucceeded"] or maximum.get("bootstrapSuccessful") != BOOTSTRAPS:
            reasons.append("max_level_uncertainty_unresolved")
        elif signal and direction(maximum) == -signal:
            reasons.append("max_level_contradiction")
    baseline = first["baselineProbability"]
    proposal = baseline
    if not reasons:
        amount = min(.05, abs(pooled_estimate - baseline))
        proposal = float(np.clip(baseline + signal * amount, expit(-SCALE * BOUND), expit(SCALE * BOUND)))
        if abs(proposal - baseline) < 1e-10: reasons.append("no_change")
    return {"classA": first["classA"], "classB": first["classB"], "baselineProbability": baseline,
            "pooledEstimate": pooled_estimate,
            "proposedProbability": proposal, "changePp": 100 * (proposal - baseline), "eligible": not reasons,
            "blockingReasons": reasons, "windows": [first, second], "maxLevel": maximum, "requiresFreshValidation": True}


def analyze(data, replicates=BOOTSTRAPS):
    validate_dataset(data)
    cutoff, model = data["dataCutoff"], data["activeModel"]
    known = [m for m in data["matches"] if m["confirmedAt"] <= cutoff and m["endedAt"] < cutoff]
    equal = [m for m in known if m["playerA"]["level"] == m["playerB"]["level"]]
    bands = []
    for label, low, high in BANDS:
        records = [m for m in equal if low <= m["playerA"]["level"] <= high]
        all_records = [m for m in known if low <= m["playerA"]["level"] <= high and low <= m["playerB"]["level"] <= high]
        result = summarize(records, model)
        all_counts = pair_counts(all_records, np.ones(len(all_records)), [(p["classA"], p["classB"]) for p in result["pairs"]])
        for pair, count in zip(result["pairs"], all_counts):
            pair["allConfirmed"] = count
        bands.append({"id": label, "minLevel": low, "maxLevel": high, "allConfirmedMatches": len(all_records), **result})
    windows = [{"id": "previous-14d", "startAt": cutoff - 28 * DAY, "endAt": cutoff - 14 * DAY},
               {"id": "latest-14d", "startAt": cutoff - 14 * DAY, "endAt": cutoff}]
    window_pairs = []
    for index, window in enumerate(windows):
        records = [m for m in equal if 50 <= m["playerA"]["level"] <= 59 and window["startAt"] <= m["endedAt"] < window["endAt"]]
        result = summarize(records, model, bootstrap=True, replicates=replicates, seed=SEED + index)
        window_pairs.append([{**pair, "windowId": window["id"]} for pair in result["pairs"]])
    # Counterevidence uses the same recent 28 days, not obsolete Max-Level data.
    maximum = [m for m in equal if m["playerA"]["level"] == 60 and windows[0]["startAt"] <= m["endedAt"] < cutoff]
    max_summary = summarize(maximum, model, bootstrap=True, minimum=(50, 10, 20), replicates=replicates, seed=SEED + 2)
    pooled_records = [m for m in equal if 50 <= m["playerA"]["level"] <= 59 and windows[0]["startAt"] <= m["endedAt"] < cutoff]
    pooled_summary = summarize(pooled_records, model)
    fresh = windows[0]["startAt"] >= model.get("dataCutoff", 0)
    candidates = [evaluate_candidate(first, second, maximum, pooled, fresh, replicates)
                  for first, second, maximum, pooled in zip(window_pairs[0], window_pairs[1], max_summary["pairs"], pooled_summary["pairs"])]
    report = {
        "schemaVersion": 1, "kind": "matchup-calibration-report", "toolVersion": TOOL_VERSION,
        "rulesetId": data["rulesetId"], "maxLevel": 60, "activeModelId": model["id"],
        "datasetHash": data["datasetHash"], "dataCutoff": cutoff,
        "validationAfter": model.get("dataCutoff", 0), "parameters": {**PARAMETERS, "bootstrapReplicates": replicates},
        "windows": windows, "bands": bands, "maxLevelComparison": max_summary, "pooledHighLevel": pooled_summary,
        "excluded": {"unknownAtCutoffOrFuture": len(data["matches"]) - len(known), "unequalLevel": len(known) - len(equal)},
        "candidates": candidates, "requiresFreshValidation": True,
        "assumptions": ["Equal average character skill within each class and band is assumed, not demonstrated.",
                        "Class offsets can absorb unobserved gear, specialization, population skill and level-unlock differences.",
                        "Leveling evidence supports provisional manual review; it does not causally prove Max-Level balance.",
                        "Confirmed reports and repetition caps do not prove honest play or distinct human participants.",
                        "All-history band estimates are descriptive; release evidence uses two fresh 14-day high-level windows.",
                        "No model is activated by this tool; approval and prospective effective time remain administrator actions."],
    }
    identifier = digest(report)
    report["analysisId"] = f"bt-v1-{identifier[:24]}"
    matrix = {a: dict(row) for a, row in model["probabilities"].items()}
    eligible = [candidate for candidate in candidates if candidate["eligible"]]
    for candidate in eligible:
        a, b = candidate["classA"], candidate["classB"]
        matrix[a][b] = candidate["proposedProbability"]
        matrix[b][a] = 1 - matrix[a][b]
    report["modelCandidate"] = None if not eligible else {
        "schemaVersion": 1, "id": f"class-calibrated-{identifier[:16]}", "rulesetId": data["rulesetId"], "maxLevel": 60,
        "source": "leveling-supported", "analysisId": report["analysisId"], "datasetHash": data["datasetHash"], "dataCutoff": cutoff,
        "probabilities": matrix, "validation": {"reportIds": [report["analysisId"]]},
    }
    report["generatedAt"] = datetime.now(timezone.utc).isoformat()
    return report


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise AnalysisError("Duplicate JSON key")
        result[key] = value
    return result


def read_dataset(path):
    with Path(path).open("rb") as stream:
        raw = stream.read(64 * 1024 * 1024 + 1)
    if len(raw) > 64 * 1024 * 1024: raise AnalysisError("Dataset exceeds 64 MiB")
    try:
        return json.loads(raw.decode("utf-8-sig"), object_pairs_hook=unique_object,
                          parse_constant=lambda value: (_ for _ in ()).throw(AnalysisError("Non-finite JSON value")))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AnalysisError("Invalid UTF-8 JSON dataset") from error


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(payload, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n"); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists(): temporary.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--candidate", type=Path)
    args = parser.parse_args(argv)
    try:
        source, output = args.dataset.resolve(), args.output.resolve()
        targets = [output] + ([args.candidate.resolve()] if args.candidate else [])
        if len(set(targets)) != len(targets) or any(target == source or (target.exists() and os.path.samefile(target, source)) for target in targets):
            raise AnalysisError("Outputs must be distinct and must not overwrite dataset")
        report = analyze(read_dataset(source))
        # Never leave a misleading old candidate at a requested path.
        if args.candidate and report["modelCandidate"] is None and args.candidate.exists():
            raise AnalysisError("No eligible candidate; existing candidate file was preserved. Choose a new path.")
        write_json(output, report)
        if args.candidate and report["modelCandidate"] is not None:
            write_json(args.candidate.resolve(), report["modelCandidate"])
        print(f"Review-only report: {output}; {sum(c['eligible'] for c in report['candidates'])} eligible pair changes; no activation")
    except (AnalysisError, OSError, ValueError) as error:
        parser.exit(2, f"analyze-matchups: error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
