import { CLASS_ORDER, CLASS_SET, offsetForProbability, stableJSON, validateModel } from './class-model.mjs';

export const BANDS = Object.freeze([
  { id: 'levels-1-9', minLevel: 1, maxLevel: 9 }, { id: 'levels-10-19', minLevel: 10, maxLevel: 19 },
  { id: 'levels-20-29', minLevel: 20, maxLevel: 29 }, { id: 'levels-30-39', minLevel: 30, maxLevel: 39 },
  { id: 'levels-40-49', minLevel: 40, maxLevel: 49 }, { id: 'levels-50-59', minLevel: 50, maxLevel: 59 },
  { id: 'max-level', minLevel: 60, maxLevel: 60 },
]);
export const ANALYSIS_POLICY = Object.freeze({ skillPriorSd: 400, pairPriorSd: 75, offsetBound: 150, bootstrapReplicates: 500,
  seed: 20261004, windowDays: 14, maxChangePp: 5, repeatDayCap: 1, repeatWindowCap: 5,
  minimumWeightedMatches: 100, minimumCharactersPerSide: 20, minimumCharacterPairs: 30,
  maxCounterevidenceMinimumWeightedMatches: 50, maxCounterevidenceMinimumCharactersPerSide: 10, maxCounterevidenceMinimumCharacterPairs: 20,
  centering: 'equal mean character strength within each class and level band',
  bootstrapMethod: 'stratified character-cluster multinomial bootstrap; refit centered model', rawEloUsed: false });
const finiteProbability = (p) => typeof p === 'number' && Number.isFinite(p) && p >= 0 && p <= 1;
const identifier = (s) => typeof s === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$/u.test(s);
function validatePublicData(value, depth = 0, budget = { count: 0 }) {
  if (++budget.count > 100000 || depth > 14) throw new Error('Analysis is too complex');
  if (typeof value === 'string' && (value.length > 2048 || /Player-[0-9a-f]+-[0-9a-f]+/iu.test(value))) throw new Error('Analysis must contain aggregates only');
  if (typeof value === 'number' && !Number.isFinite(value)) throw new Error('Invalid analysis number');
  if (value && typeof value === 'object') for (const [key, child] of Object.entries(value)) {
    if (/guid|token|secret|password/iu.test(key)) throw new Error('Analysis must contain no identities or secrets');
    validatePublicData(child, depth + 1, budget);
  }
}
function pairStatistics(pair, probabilities) {
  if (!pair || !CLASS_SET.has(pair.classA) || !CLASS_SET.has(pair.classB) || pair.classA === pair.classB
    || !finiteProbability(pair.baselineProbability) || Math.abs(pair.baselineProbability - probabilities[pair.classA][pair.classB]) > 1e-8) throw new Error('Invalid analysis class pair');
  if (pair.estimatedProbability !== null && !finiteProbability(pair.estimatedProbability)) throw new Error('Invalid estimated probability');
  if (pair.estimatedProbability !== null && Math.abs(offsetForProbability(pair.estimatedProbability)) > 150 + 1e-6) throw new Error('Estimated probability exceeds the fitted offset bound');
  for (const key of ['rawMatches', 'uniqueA', 'uniqueB', 'uniquePairs']) if (!Number.isSafeInteger(pair[key]) || pair[key] < 0) throw new Error('Invalid aggregate count');
  if (!Number.isFinite(pair.weightedMatches) || pair.weightedMatches < 0 || pair.weightedMatches > pair.rawMatches + 1e-8) throw new Error('Invalid weighted match count');
  if (pair.ci95 !== null && (!Array.isArray(pair.ci95) || pair.ci95.length !== 2 || !pair.ci95.every(finiteProbability) || pair.ci95[0] > pair.ci95[1])) throw new Error('Invalid confidence interval');
  if (pair.ci95?.some((p) => Math.abs(offsetForProbability(p)) > 150 + 1e-6)) throw new Error('Confidence interval exceeds the fitted offset bound');
}
function verifyCounts(pair, matches, capWeights = true) {
  const rows = matches.filter((match) => new Set([match.playerA.classFile, match.playerB.classFile]).size === 2
    && [match.playerA.classFile, match.playerB.classFile].includes(pair.classA) && [match.playerA.classFile, match.playerB.classFile].includes(pair.classB));
  const own = new Set(), other = new Set(), days = new Map(); let winsA = 0;
  for (const match of rows) {
    const a = match.playerA.classFile === pair.classA ? match.playerA : match.playerB, b = match.playerA.classFile === pair.classB ? match.playerA : match.playerB;
    own.add(a.guid); other.add(b.guid);
    if (match.winnerGUID === a.guid) winsA++;
    const key = `${match.playerA.guid}:${match.playerB.guid}`;
    if (!days.has(key)) days.set(key, new Set()); days.get(key).add(Math.floor(match.endedAt / 86400));
  }
  const weighted = capWeights ? [...days.values()].reduce((sum, set) => sum + Math.min(5, set.size), 0) : rows.length;
  if (pair.rawMatches !== rows.length || pair.uniqueA !== own.size || pair.uniqueB !== other.size || pair.uniquePairs !== days.size
    || Math.abs(pair.weightedMatches - weighted) > 1e-7) throw new Error('Analysis counts do not match the registered dataset');
  if (pair.winsA !== undefined && pair.winsA !== winsA || pair.winsB !== undefined && pair.winsB !== rows.length - winsA
    || pair.observedWinRate !== undefined && (rows.length ? Math.abs(pair.observedWinRate - winsA / rows.length) > 1e-8 : pair.observedWinRate !== null)) throw new Error('Analysis observed results do not match the registered dataset');
}
export function validateAnalysis(report, dataset) {
  validatePublicData(report);
  if (Object.entries(ANALYSIS_POLICY).some(([key, value]) => report?.parameters?.[key] !== value)) throw new Error('Analysis parameters differ from the approved calibration policy');
  if (!report || report.schemaVersion !== 1 || report.kind !== 'matchup-calibration-report' || report.toolVersion !== 'bt-v1'
    || !identifier(report.analysisId) || report.datasetHash !== dataset.datasetHash || report.rulesetId !== dataset.rulesetId
    || report.maxLevel !== dataset.maxLevel || report.dataCutoff !== dataset.dataCutoff || report.activeModelId !== dataset.activeModel.id
    || !Number.isFinite(Date.parse(report.generatedAt)) || !Array.isArray(report.windows) || report.windows.length !== 2
    || !Array.isArray(report.bands) || report.bands.length !== BANDS.length || !Array.isArray(report.candidates) || report.candidates.length > 36
    || !Array.isArray(report.assumptions) || report.assumptions.length > 30) throw new Error('Invalid calibration report envelope or dataset provenance');
  const start = dataset.dataCutoff - 28 * 86400;
  for (let i = 0; i < 2; i++) {
    const window = report.windows[i];
    if (!identifier(window.id) || window.startAt !== start + i * 14 * 86400 || window.endAt !== start + (i + 1) * 14 * 86400) throw new Error('Two adjacent 14-day validation windows are required');
  }
  if (report.windows[0].id === report.windows[1].id) throw new Error('Duplicate validation window');
  const seen = new Set();
  for (const band of report.bands) {
    const spec = BANDS.find((value) => value.id === band.id);
    if (!spec || seen.has(band.id) || band.minLevel !== spec.minLevel || band.maxLevel !== spec.maxLevel || !Array.isArray(band.pairs) || band.pairs.length > 36) throw new Error('Invalid analysis band');
    seen.add(band.id);
    const bandMatches = dataset.matches.filter((match) => match.endedAt < dataset.dataCutoff && match.playerA.level === match.playerB.level && match.playerA.level >= spec.minLevel && match.playerA.level <= spec.maxLevel);
    for (const pair of band.pairs) {
      pairStatistics(pair, dataset.activeModel.probabilities); verifyCounts(pair, bandMatches);
      if (pair.allConfirmed) verifyCounts(pair.allConfirmed, dataset.matches.filter((match) => match.endedAt < dataset.dataCutoff
        && match.playerA.level >= spec.minLevel && match.playerA.level <= spec.maxLevel && match.playerB.level >= spec.minLevel && match.playerB.level <= spec.maxLevel), false);
    }
  }
  const pooledMatches = dataset.matches.filter((match) => match.playerA.level === match.playerB.level && match.playerA.level >= 50 && match.playerA.level <= 59
    && match.endedAt >= start && match.endedAt < dataset.dataCutoff);
  const maximumMatches = dataset.matches.filter((match) => match.playerA.level === 60 && match.playerB.level === 60 && match.endedAt >= start && match.endedAt < dataset.dataCutoff);
  for (const [summary, rows] of [[report.pooledHighLevel, pooledMatches], [report.maxLevelComparison, maximumMatches]]) {
    if (!summary || typeof summary.fitSucceeded !== 'boolean' || !Array.isArray(summary.pairs) || summary.pairs.length !== 36) throw new Error('Complete pooled and max-level summaries are required');
    const seenPairs = new Set();
    for (const pair of summary.pairs) {
      const key = [pair.classA, pair.classB].sort().join(':');
      if (seenPairs.has(key)) throw new Error('Duplicate summary class pair'); seenPairs.add(key);
      pairStatistics(pair, dataset.activeModel.probabilities); verifyCounts(pair, rows);
    }
  }
  seen.clear();
  for (const candidate of report.candidates) {
    const key = [candidate.classA, candidate.classB].sort().join(':');
    if (seen.has(key) || typeof candidate.eligible !== 'boolean' || !Array.isArray(candidate.blockingReasons)
      || !finiteProbability(candidate.proposedProbability) || !finiteProbability(candidate.baselineProbability)
      || candidate.classA === candidate.classB || !CLASS_SET.has(candidate.classA) || !CLASS_SET.has(candidate.classB)
      || Math.abs(candidate.baselineProbability - dataset.activeModel.probabilities[candidate.classA][candidate.classB]) > 1e-8
      || !Array.isArray(candidate.windows) || candidate.windows.length !== 2 || !candidate.maxLevel) throw new Error('Invalid model candidate diagnostics');
    seen.add(key);
    for (const window of candidate.windows) {
      if (!report.windows.some((value) => value.id === window.windowId)) throw new Error('Unknown candidate window');
      pairStatistics({ ...window, classA: candidate.classA, classB: candidate.classB }, dataset.activeModel.probabilities);
      const spec = report.windows.find((value) => value.id === window.windowId);
      verifyCounts({ ...window, classA: candidate.classA, classB: candidate.classB }, dataset.matches.filter((match) => match.playerA.level === match.playerB.level
        && match.playerA.level >= 50 && match.playerA.level <= 59 && match.endedAt >= spec.startAt && match.endedAt < spec.endAt));
    }
    pairStatistics({ ...candidate.maxLevel, classA: candidate.classA, classB: candidate.classB }, dataset.activeModel.probabilities);
    verifyCounts({ ...candidate.maxLevel, classA: candidate.classA, classB: candidate.classB }, maximumMatches);
    const pooled = report.pooledHighLevel.pairs.find((pair) => pair.classA === candidate.classA && pair.classB === candidate.classB);
    const maximum = report.maxLevelComparison.pairs.find((pair) => pair.classA === candidate.classA && pair.classB === candidate.classB);
    if (!pooled || !maximum || candidate.pooledEstimate !== pooled.estimatedProbability || stableJSON(candidate.maxLevel) !== stableJSON(maximum)) throw new Error('Candidate must match its joint pooled and max-level summaries');
    if (candidate.eligible) {
      if (!report.pooledHighLevel.fitSucceeded || pooled.fitSucceeded !== true) throw new Error('An eligible candidate requires a successful joint pooled fit');
      if (report.windows[0].startAt < dataset.activeModel.dataCutoff) throw new Error('Eligible candidates require fresh windows after the prior model cutoff');
      validateEvidence(candidate, report);
    }
  }
  if (report.modelCandidate) validateCandidate(report.modelCandidate, report, dataset);
  return JSON.parse(stableJSON(report));
}
function validateEvidence(evidence, report) {
  const params = report.parameters;
  if (params?.bootstrapReplicates !== 500 || params.seed !== 20261004 || params.windowDays !== 14 || params.maxChangePp !== 5
    || params.repeatDayCap !== 1 || params.repeatWindowCap !== 5) throw new Error('Calibration policy parameters do not match the approved policy');
  const before = evidence.baselineProbability, after = evidence.proposedProbability, direction = Math.sign(after - before);
  const windows = evidence.windows;
  if (!direction || Math.abs(after - before) > 0.05 + 1e-8 || evidence.blockingReasons.length
    || new Set(windows.map((window) => window.windowId)).size !== 2
    || windows.some((window) => window.weightedMatches < 100 || window.uniqueA < 20 || window.uniqueB < 20 || window.uniquePairs < 30
      || !window.ci95 || !(direction > 0 ? window.ci95[0] > before : window.ci95[1] < before)
      || window.fitSucceeded !== true || window.bootstrapSuccessful !== 500 || window.bootstrapReplicates !== 500
      || !finiteProbability(window.estimatedProbability)
      || Math.sign(window.estimatedProbability - before) !== direction)) throw new Error('Changed pair lacks consistent independent validation windows');
  const pooled = evidence.pooledEstimate;
  if (!finiteProbability(pooled)) throw new Error('A joint pooled estimate is required');
  if (Math.sign(pooled - before) !== direction || Math.abs(after - before) > Math.abs(pooled - before) + 1e-8) throw new Error('Candidate must move toward the pooled estimate');
  const max = evidence.maxLevel;
  if (max.weightedMatches >= 50 && max.uniqueA >= 10 && max.uniqueB >= 10 && max.uniquePairs >= 20) {
    if (max.fitSucceeded !== true || max.bootstrapSuccessful !== 500 || max.bootstrapReplicates !== 500 || !max.ci95) throw new Error('Adequate max-level evidence requires successful uncertainty analysis');
    if (direction > 0 ? max.ci95[1] < before : max.ci95[0] > before) throw new Error('Credible max-level counter-evidence blocks the candidate');
  }
}
export function validateCandidate(candidate, report, dataset) {
  validateModel(candidate);
  if (candidate.source !== 'leveling-supported' || candidate.rulesetId !== dataset.rulesetId || candidate.maxLevel !== dataset.maxLevel
    || candidate.dataCutoff !== dataset.dataCutoff || candidate.datasetHash !== dataset.datasetHash || candidate.analysisId !== report.analysisId
    || !Array.isArray(candidate.validation?.reportIds) || !candidate.validation.reportIds.includes(report.analysisId)
    || report.windows[0].startAt < dataset.activeModel.dataCutoff) throw new Error('Candidate needs fresh validation and matching published provenance');
  let changes = 0;
  for (let i = 0; i < CLASS_ORDER.length; i++) for (let j = i + 1; j < CLASS_ORDER.length; j++) {
    const a = CLASS_ORDER[i], b = CLASS_ORDER[j], before = dataset.activeModel.probabilities[a][b], after = candidate.probabilities[a][b];
    if (Math.abs(after - before) < 1e-8) continue;
    changes++;
    const evidence = report.candidates.find((pair) => pair.classA === a && pair.classB === b || pair.classA === b && pair.classB === a);
    const proposed = evidence?.classA === a ? evidence.proposedProbability : 1 - evidence?.proposedProbability;
    if (!evidence?.eligible || Math.abs(after - proposed) > 1e-8) throw new Error('Changed pair lacks required window evidence');
    validateEvidence(evidence, report);
  }
  if (!changes) throw new Error('Candidate contains no eligible changes');
  return candidate;
}
