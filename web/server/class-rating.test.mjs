import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { request } from 'node:http';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createStore, ApiError } from './store.mjs';
import { createServer } from './server.mjs';
import { makeReportPair } from './demo-data.mjs';
import { BASELINE, CLASS_ORDER, classTransfer, digest, stableJSON } from './class-model.mjs';
import { ANALYSIS_POLICY, BANDS } from './class-analysis.mjs';
import { manage } from './manage.mjs';

const warrior = { guid: 'Player-1-AAAA', name: 'Warrior A', realm: 'Forever', classFile: 'WARRIOR', level: 60, maxLevel: 60 };
const mage = { guid: 'Player-1-BBBB', name: 'Mage', realm: 'Forever', classFile: 'MAGE', level: 60, maxLevel: 60 };
const upload = (store, report) => store.importReports(report.player.guid, { schemaVersion: 2, player: { guid: report.player.guid }, matches: [report] });
const duel = (store, a, b, options) => { const pair = makeReportPair(a, b, options); pair.forEach((report) => upload(store, report)); return pair; };
const rejected = (call, code) => assert.throws(call, (error) => error instanceof ApiError && error.code === code);
const http = (url, { method = 'GET' } = {}) => new Promise((resolve, reject) => {
  const req = request(url, { method }, (res) => {
    const chunks = []; res.on('data', (chunk) => chunks.push(chunk));
    res.on('end', () => resolve({ status: res.statusCode, json: async () => JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
  }); req.on('error', reject); req.end();
});

test('approved manual probabilities match all 36 golden pairs, diagonals and complements', () => {
  const percentages = [
    [50,45,45,55,45,45,40,45,40], [55,50,50,55,45,50,45,40,50], [55,50,50,55,50,55,55,45,50],
    [45,45,45,50,50,55,50,45,40], [55,55,50,50,50,55,55,45,55], [55,50,45,45,45,50,45,40,50],
    [60,55,45,50,45,55,50,40,50], [55,60,55,55,55,60,60,50,55], [60,50,50,60,45,50,50,45,50],
  ];
  for (let i = 0; i < CLASS_ORDER.length; i++) for (let j = 0; j < CLASS_ORDER.length; j++) {
    const p = BASELINE.probabilities[CLASS_ORDER[i]][CLASS_ORDER[j]];
    assert.equal(p, percentages[i][j] / 100);
    assert.equal(p + BASELINE.probabilities[CLASS_ORDER[j]][CLASS_ORDER[i]], 1);
    if (i === j) assert.equal(p, .5);
  }
  assert.equal(BASELINE.effectiveFrom, 0); assert.equal(BASELINE.source, 'manual');
});

test('manual class projection rewards difficult matchups while overall Elo remains unchanged', () => {
  const store = createStore();
  try {
    duel(store, warrior, mage);
    const profile = store.player(warrior.guid);
    assert.equal(profile.player.rating, 1516);
    assert.equal(profile.player.classRating, 1519);
    assert.equal(profile.history[0].delta, 16);
    assert.equal(profile.classHistory[0].delta, 19);
    assert.equal(profile.classHistory[0].matchupProbability, 0.4);
    assert.equal(profile.classHistory[0].expectedWin, 0.4);
    assert.equal(profile.classSeries[0].modelId, BASELINE.id);
    assert.equal(store.player(mage.guid).player.classRating, 1481);
    assert.equal(classTransfer(1500, 1500, .5).transfer, 16);
    assert.equal(classTransfer(1500, 1500, .6).transfer, 13);
    assert.equal(store.matches().items[0].rulesetId, 'forever-v1');
    assert.equal(store.models().models[0].dataHash.length, 64);
    assert.throws(() => store.db.prepare('UPDATE class_models SET body_hash=?').run('tampered'), /immutable/u);
  } finally { store.close(); }
});

test('class and overall ranks stay stable across search, realm, pages and class filters', () => {
  const store = createStore();
  try {
    const other = { ...warrior, guid: 'Player-1-CCCC', name: 'Warrior B', realm: 'Second' };
    const rogue = { ...mage, guid: 'Player-1-DDDD', classFile: 'ROGUE' };
    duel(store, warrior, mage); duel(store, other, rogue, { index: 2 });
    const board = store.ladder({ ranking: 'CLASS', classFile: 'WARRIOR' });
    assert.deepEqual(board.items.map((row) => [row.name, row.rank, row.classRating]), [['Warrior A', 1, 1519], ['Warrior B', 2, 1514]]);
    const found = store.ladder({ ranking: 'CLASS', classFile: 'WARRIOR', search: 'Warrior B', realm: 'Second', page: 1, limit: 1 });
    assert.equal(found.items[0].rank, 2); assert.equal(found.items[0].overallRank, 2);
    assert.equal(store.ladder({ ranking: 'OVERALL', classFile: 'WARRIOR', search: 'Warrior B' }).items[0].rank, 2);
    assert.equal(store.matches({ classFile: 'MAGE' }).total, 1);
    assert.equal(store.matches({ classFile: 'SHAMAN' }).total, 0);
  } finally { store.close(); }
});

test('leveling and unsupported caps retain normal Elo with real class ranks', () => {
  const store = createStore();
  try {
    const a = { ...warrior, level: 55 }, b = { ...mage, level: 53 };
    duel(store, a, b);
    const board = store.ladder({ ranking: 'CLASS', classFile: 'WARRIOR', bracket: 'LEVELING' });
    assert.equal(board.ranking, 'CLASS'); assert.equal(board.items[0].rank, 1);
    assert.equal(board.items[0].classRank, 1); assert.equal(board.items[0].classRating, null);
    assert.equal(board.model.status, 'unweighted'); assert.equal(board.items[0].rating, 1514);
    assert.deepEqual(store.player(warrior.guid, { bracket: 'LEVELING' }).classSeries, []);
    duel(store, { ...warrior, level: 80, maxLevel: 80 }, { ...mage, level: 80, maxLevel: 80 }, { index: 2 });
    const unsupported = store.ladder({ ranking: 'CLASS', classFile: 'WARRIOR', maxLevel: 80 });
    assert.equal(unsupported.model.status, 'unsupported'); assert.equal(unsupported.items[0].rank, 1);
    assert.equal(unsupported.items[0].classRating, null); assert.equal(unsupported.items[0].rating, 1516);
  } finally { store.close(); }
});

test('first confirmed class lock is atomic; pending and provisioned identities cannot poison it', () => {
  const store = createStore();
  try {
    store.provision({ ...warrior, classFile: 'ROGUE' });
    const wrongPending = makeReportPair({ ...warrior, classFile: 'ROGUE' }, mage, { index: 1 }); upload(store, wrongPending[0]);
    duel(store, warrior, mage, { index: 2 });
    rejected(() => upload(store, wrongPending[1]), 'guid_class_conflict');
    assert.equal(store.stats().confirmedMatches, 1); assert.equal(store.stats().pendingMatches, 1);
    assert.equal(store.db.prepare('SELECT COUNT(*) AS n FROM reports WHERE match_id=?').get(wrongPending[0].matchId).n, 1);
    const first = makeReportPair(warrior, mage, { index: 3 })[1];
    rejected(() => store.importReports(mage.guid, { schemaVersion: 2, player: { guid: mage.guid }, matches: [first, wrongPending[1]] }), 'guid_class_conflict');
    assert.equal(store.stats().pendingMatches, 1); assert.equal(store.models().audit.conflicts.length, 0);
  } finally { store.close(); }
});

test('historical class replay is deterministic for late imports and equal timestamps', () => {
  const left = createStore(), right = createStore();
  try {
    const first = makeReportPair(warrior, mage, { index: 1, endedAt: 1791100800 });
    const second = makeReportPair(warrior, mage, { index: 2, endedAt: 1791100800, winnerGuid: mage.guid });
    [...first, ...second].forEach((report) => upload(left, report));
    [...second.toReversed(), ...first.toReversed()].forEach((report) => upload(right, report));
    assert.deepEqual(left.player(warrior.guid), right.player(warrior.guid));
    assert.deepEqual(left.matches(), right.matches());
  } finally { left.close(); right.close(); }
});

test('migration audits old inconsistent GUID classes, blocks weighting and preserves overall Elo', () => {
  const directory = mkdtempSync(join(tmpdir(), 'foreverduel-class-')), path = join(directory, 'store.sqlite');
  let store = createStore({ path });
  try {
    duel(store, warrior, mage);
    const pair = makeReportPair({ ...warrior, classFile: 'ROGUE' }, mage, { index: 2 });
    for (const report of pair) store.db.prepare('INSERT INTO reports VALUES(?,?,?,?,?)').run(report.matchId, report.player.guid, stableJSON(report), digest(report), new Date().toISOString());
    store.db.prepare('INSERT INTO matches(match_id,status,bracket,max_level,started_at,ended_at,ruleset_id) VALUES(?,?,?,?,?,?,?)').run(pair[0].matchId, 'confirmed', 'MAX_LEVEL', 60, pair[0].startedAt, pair[0].endedAt, 'forever-v1');
    store.close(); store = createStore({ path });
    assert.equal(store.stats().confirmedMatches, 2); assert.equal(store.modelStatus().status, 'blocked');
    assert.equal(store.models().audit.conflicts[0].guid, warrior.guid);
    assert.ok(store.ladder().items.every((row) => row.classRating === null && Number.isInteger(row.rating)));
    rejected(() => store.exportDataset(), 'guid_class_audit_failed');
    store.close(); store = null;
    assert.throws(() => createStore({ path, rulesetId: 'different-ruleset' }), /separate database/u);
  } finally { store?.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('dataset exports bind immutable known-at-cutoff snapshots, exclude pending and contain no tokens', () => {
  let clock = 1800000000000;
  const store = createStore({ now: () => clock });
  try {
    const token = store.provision(warrior);
    duel(store, warrior, mage, { endedAt: 1799999000 });
    const old = store.exportDataset({ dataCutoff: 1800000000 });
    assert.equal(old.matches.length, 1); assert.equal(old.matches[0].confirmedAt, 1800000000);
    assert.equal(old.datasetHash, digest({ rulesetId: old.rulesetId, maxLevel: old.maxLevel, dataCutoff: old.dataCutoff, activeModelId: old.activeModel.id, matches: old.matches }));
    assert.equal(stableJSON(old).includes(token), false);
    clock += 10000; duel(store, warrior, mage, { index: 2, endedAt: 1799998000 });
    assert.deepEqual(store.exportDataset({ dataCutoff: 1800000000 }), old);
    assert.equal(store.exportDataset().matches.length, 2);
    assert.throws(() => store.db.prepare('DELETE FROM dataset_exports').run(), /immutable/u);
    rejected(() => store.exportDataset({ dataCutoff: 1800000020 }), 'invalid_data_cutoff');
  } finally { store.close(); }
});

function calibrationFixture(store, cutoff = 1800000000) {
  const dataset = { ...store.exportDataset({ dataCutoff: cutoff }), matches: [] };
  const start = cutoff - 28 * 86400;
  for (let window = 0; window < 2; window++) for (let i = 0; i < 20; i++) for (let j = 0; j < 5; j++) {
    const a = { guid: `Player-1-${(4096 + i).toString(16)}`, classFile: 'WARRIOR', level: 55 };
    const b = { guid: `Player-1-${(8192 + (i + j) % 20).toString(16)}`, classFile: 'MAGE', level: 55 };
    dataset.matches.push({ matchId: `fixture-${window}-${i}-${j}`, bracket: 'LEVELING', endedAt: start + (window * 14 + 1) * 86400 + i * 10 + j,
      confirmedAt: cutoff, playerA: a, playerB: b, winnerGUID: a.guid });
  }
  dataset.datasetHash = digest({ rulesetId: dataset.rulesetId, maxLevel: dataset.maxLevel, dataCutoff: cutoff, activeModelId: dataset.activeModel.id, matches: dataset.matches });
  store.db.prepare('INSERT INTO dataset_exports VALUES(?,?,?)').run(dataset.datasetHash, stableJSON(dataset), new Date(cutoff * 1000).toISOString());
  const counts = (raw = 0) => ({ classA: 'WARRIOR', classB: 'MAGE', baselineProbability: .4, estimatedProbability: raw ? .55 : null,
    rawMatches: raw, weightedMatches: raw, uniqueA: raw ? 20 : 0, uniqueB: raw ? 20 : 0, uniquePairs: raw ? 100 : 0, ci95: raw ? [.48, .62] : null,
    fitSucceeded: true, bootstrapSuccessful: raw ? 500 : 0, bootstrapReplicates: raw ? 500 : 0 });
  const report = { schemaVersion: 1, kind: 'matchup-calibration-report', toolVersion: 'bt-v1', analysisId: 'bt-v1-fixture', rulesetId: dataset.rulesetId,
    maxLevel: 60, activeModelId: dataset.activeModel.id, datasetHash: dataset.datasetHash, dataCutoff: cutoff, generatedAt: new Date(cutoff * 1000).toISOString(),
    parameters: { ...ANALYSIS_POLICY },
    windows: [{ id: 'previous-14d', startAt: start, endAt: start + 14 * 86400 }, { id: 'latest-14d', startAt: start + 14 * 86400, endAt: cutoff }],
    bands: BANDS.map((band) => ({ ...band, pairs: [counts(band.id === 'levels-50-59' ? 200 : 0)] })), assumptions: ['Synthetic test fixture'],
    candidates: [{ classA: 'WARRIOR', classB: 'MAGE', baselineProbability: .4, proposedProbability: .45, pooledEstimate: .55, changePp: 5,
      eligible: true, blockingReasons: [], windows: ['previous-14d', 'latest-14d'].map((windowId) => ({ ...counts(100), windowId })), maxLevel: counts() }] };
  const probabilities = structuredClone(BASELINE.probabilities); probabilities.WARRIOR.MAGE = .45; probabilities.MAGE.WARRIOR = .55;
  const summaryPairs = (raw) => CLASS_ORDER.flatMap((a, i) => CLASS_ORDER.slice(i + 1).map((b) => ({ ...counts(a === 'WARRIOR' && b === 'MAGE' ? raw : 0),
    classA: a, classB: b, baselineProbability: BASELINE.probabilities[a][b] })));
  report.pooledHighLevel = { fitSucceeded: true, pairs: summaryPairs(200) };
  report.maxLevelComparison = { fitSucceeded: true, pairs: summaryPairs(0) };
  report.candidates[0].maxLevel = report.maxLevelComparison.pairs.find((pair) => pair.classA === 'WARRIOR' && pair.classB === 'MAGE');
  report.modelCandidate = { schemaVersion: 1, id: 'class-leveling-fixture', rulesetId: dataset.rulesetId, maxLevel: 60, source: 'leveling-supported',
    analysisId: report.analysisId, datasetHash: dataset.datasetHash, dataCutoff: cutoff, probabilities, validation: { reportIds: [report.analysisId] } };
  return { dataset, report, candidate: report.modelCandidate };
}

test('publication verifies real export counts and rejects forged eligibility, confidence and provenance', () => {
  const store = createStore({ now: () => 1800000000000 });
  try {
    const { report } = calibrationFixture(store);
    for (const mutate of [
      (r) => { r.datasetHash = 'a'.repeat(64); }, (r) => { r.candidates[0].windows[0].weightedMatches = 101; },
      (r) => { r.candidates[0].windows[0].ci95 = [.3, .6]; }, (r) => { r.candidates[0].windows[1].estimatedProbability = .3; },
      (r) => { r.parameters.bootstrapReplicates = 499; }, (r) => { r.candidates[0].windows[0].bootstrapSuccessful = 499; },
      (r) => { r.parameters.rawEloUsed = true; }, (r) => { r.parameters.skillPriorSd = 1000; }, (r) => { r.parameters.centering = 'Different assumption'; },
      (r) => { delete r.pooledHighLevel; }, (r) => { r.pooledHighLevel.fitSucceeded = false; },
      (r) => { r.pooledHighLevel.pairs.find((pair) => pair.classA === 'WARRIOR' && pair.classB === 'MAGE').estimatedProbability = .3; },
      (r) => { r.candidates[0].windows[0].estimatedProbability = .99; r.candidates[0].windows[0].ci95 = [.95, .99]; },
      (r) => { r.candidates[0].pooledEstimate = .42; }, (r) => { r.assumptions.push('Player-1-AAAA'); },
    ]) { const invalid = structuredClone(report); mutate(invalid); assert.throws(() => store.publishAnalysis(invalid), ApiError); }
    assert.equal(store.publishAnalysis(report).activated, false);
    assert.equal(store.models().models.length, 1);
    assert.equal(store.publishAnalysis(report).duplicate, true);
    const changed = structuredClone(report); changed.assumptions.push('Changed'); rejected(() => store.publishAnalysis(changed), 'immutable_analysis_conflict');
  } finally { store.close(); }
});

test('credible max-level contradictions and failed adequate uncertainty analyses block candidates', () => {
  const store = createStore({ now: () => 1800000000000 });
  try {
    const { dataset, report } = calibrationFixture(store);
    for (let i = 0; i < 10; i++) for (let j = 0; j < 5; j++) {
      const a = { guid: `Player-1-${(4096 + i).toString(16)}`, classFile: 'WARRIOR', level: 60 };
      const b = { guid: `Player-1-${(8192 + (i + j) % 10).toString(16)}`, classFile: 'MAGE', level: 60 };
      dataset.matches.push({ matchId: `maximum-${i}-${j}`, bracket: 'MAX_LEVEL', endedAt: dataset.dataCutoff - 5 * 86400 + i * 10 + j,
        confirmedAt: dataset.dataCutoff, playerA: a, playerB: b, winnerGUID: a.guid });
    }
    dataset.matches.sort((a, b) => a.endedAt - b.endedAt || a.matchId.localeCompare(b.matchId));
    dataset.datasetHash = digest({ rulesetId: dataset.rulesetId, maxLevel: dataset.maxLevel, dataCutoff: dataset.dataCutoff, activeModelId: dataset.activeModel.id, matches: dataset.matches });
    store.db.prepare('INSERT INTO dataset_exports VALUES(?,?,?)').run(dataset.datasetHash, stableJSON(dataset), new Date().toISOString());
    report.datasetHash = report.modelCandidate.datasetHash = dataset.datasetHash;
    const maximum = report.maxLevelComparison.pairs.find((pair) => pair.classA === 'WARRIOR' && pair.classB === 'MAGE');
    Object.assign(maximum, { rawMatches: 50, weightedMatches: 50, uniqueA: 10, uniqueB: 10, uniquePairs: 50,
      estimatedProbability: .35, ci95: [.3, .39], fitSucceeded: true, bootstrapSuccessful: 500, bootstrapReplicates: 500 });
    report.candidates[0].maxLevel = maximum;
    Object.assign(report.bands.find((band) => band.id === 'max-level').pairs[0], maximum);
    rejected(() => store.publishAnalysis(report), 'invalid_analysis');
    maximum.ci95 = [.35, .55]; maximum.estimatedProbability = .45;
    maximum.fitSucceeded = false; rejected(() => store.publishAnalysis(report), 'invalid_analysis');
    maximum.fitSucceeded = true; maximum.bootstrapSuccessful = 499; rejected(() => store.publishAnalysis(report), 'invalid_analysis');
    maximum.bootstrapSuccessful = 500; assert.equal(store.publishAnalysis(report).published, true);
  } finally { store.close(); }
});

test('approved future activation accepts missing max-level data, pins history and rejects stale reuse', () => {
  let clock = 1800000000000;
  const store = createStore({ now: () => clock });
  try {
    const { report, candidate } = calibrationFixture(store);
    duel(store, warrior, mage, { endedAt: 1799999990 });
    const oldProjection = store.matches().items[0];
    rejected(() => store.activateModel(candidate, { approve: 'yes', effectiveFrom: 1800000010 }), 'published_analysis_required');
    store.publishAnalysis(report);
    rejected(() => store.activateModel(candidate, { effectiveFrom: 1800000010 }), 'explicit_model_approval_required');
    rejected(() => store.activateModel(candidate, { approve: 'yes', effectiveFrom: 1800000000 }), 'model_effective_date_must_be_future');
    assert.equal(store.activateModel(candidate, { approve: 'yes', effectiveFrom: 1800000010 }).source, 'leveling-supported');
    assert.deepEqual(store.matches().items[0], oldProjection);
    assert.equal(store.modelStatus().id, BASELINE.id);
    clock = 1800000020000;
    duel(store, warrior, mage, { index: 2, endedAt: 1800000015 });
    assert.equal(store.matches().items[0].classProjection.modelId, candidate.id);
    duel(store, warrior, mage, { index: 3, endedAt: 1799999980 });
    assert.equal(store.matches().items.find((row) => row.endedAt === 1799999980).classProjection.modelId, BASELINE.id);
    assert.equal(store.modelStatus().id, candidate.id);
    assert.equal(store.classComparisons().analysis.stale, true);
    assert.equal(store.classComparisons().analysis.activeModelId, BASELINE.id);
    rejected(() => store.activateModel(candidate, { approve: 'yes', effectiveFrom: 1800000030 }), 'stale_model_candidate');
  } finally { store.close(); }
});

test('model CLI requires explicit approval and publishes analysis without activating it', () => {
  const store = createStore({ now: () => 1800000000000 });
  const directory = mkdtempSync(join(tmpdir(), 'foreverduel-cli-'));
  try {
    const { report, candidate } = calibrationFixture(store); const output = [];
    const reportFile = join(directory, 'report.json'), candidateFile = join(directory, 'candidate.json');
    writeFileSync(reportFile, JSON.stringify(report)); writeFileSync(candidateFile, JSON.stringify(candidate));
    manage(['analysis-publish', '--file', reportFile], { store, output: (text) => output.push(JSON.parse(text)) });
    manage(['models'], { store, output: (text) => output.push(JSON.parse(text)) });
    manage(['audit'], { store, output: (text) => output.push(JSON.parse(text)) });
    assert.equal(output[0].activated, false); assert.equal(output[1].models.length, 1); assert.equal(output[2].conflicts.length, 0);
    rejected(() => manage(['model-activate', '--approve', 'maybe', '--file', candidateFile, '--effectiveFrom', '1800000010'], { store }), 'explicit_model_approval_required');
    assert.equal(store.models().models.length, 1);
    manage(['model-activate', '--approve', 'yes', '--file', candidateFile, '--effectiveFrom', '1800000010'], { store, output: (text) => output.push(JSON.parse(text)) });
    assert.equal(output.at(-1).scheduled, true); assert.equal(store.models().models.length, 2);
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('comparison overview represents unequal-level and cross-band confirmed matches without identities', () => {
  const store = createStore();
  try {
    duel(store, { ...warrior, level: 53 }, { ...mage, level: 55 });
    duel(store, { ...warrior, level: 49 }, { ...mage, level: 50 }, { index: 2 });
    duel(store, warrior, mage, { index: 3 });
    const result = store.classComparisons();
    assert.equal(result.bands.length, 7); assert.equal(result.counts.confirmedMatches, 3);
    assert.equal(result.counts.crossBandMatches, 1);
    const overview = result.overview.pairs.find((pair) => pair.classA === 'WARRIOR' && pair.classB === 'MAGE');
    assert.equal(overview.rawMatches, 3); assert.equal(overview.sameLevelMatches, 1);
    assert.equal(result.bands.find((band) => band.id === 'levels-50-59').counts.matches, 1);
    assert.equal(result.bands.find((band) => band.id === 'levels-50-59').counts.sameLevelMatches, 0);
    assert.equal(stableJSON(result).includes(warrior.guid), false);
    const unsupported = store.classComparisons({ maxLevel: 80 });
    assert.deepEqual(unsupported.bands, []); assert.equal(unsupported.model.status, 'unsupported'); assert.equal(unsupported.analysis, null);
  } finally { store.close(); }
});

test('HTTP exposes aggregated comparisons and requires a class for CLASS ladder', async () => {
  const store = createStore(), server = createServer({ store }); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}`;
  try {
    duel(store, warrior, mage);
    assert.equal((await http(`${url}/api/v1/ladder?ranking=CLASS`)).status, 400);
    assert.equal((await http(`${url}/api/v1/ladder?ranking=BAD&classFile=MAGE`)).status, 400);
    const response = await http(`${url}/api/v1/ladder?ranking=CLASS&classFile=WARRIOR`);
    assert.equal(response.status, 200); assert.equal((await response.json()).items[0].classRating, 1519);
    const comparison = await http(`${url}/api/v1/class-comparisons`); assert.equal(comparison.status, 200);
    assert.equal((await comparison.json()).bands.length, 7);
    assert.equal((await http(`${url}/api/v1/class-comparisons?rulesetId=other`)).status, 400);
    assert.equal((await http(`${url}/api/v1/model-activate`, { method: 'POST' })).status, 405);
  } finally { await new Promise((done) => server.close(done)); store.close(); }
});
