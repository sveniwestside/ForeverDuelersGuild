import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { readView, viewUrl, profileRecords, opponentMix, orientPair, selectedBandEstimate, matchupProposal } from '../public/ladder-view.mjs';
import * as preview from '../public/assets/design-preview.js';

test('a shared class view preserves mode, cap, search and page, and retains explicit preview mode', () => {
  const state = readView('?preview=1&ranking=CLASS&classFile=MAGE&bracket=LEVELING&maxLevel=60&search=Rune%20veil&page=3');
  assert.deepEqual(state, { bracket: 'LEVELING', maxLevel: 60, ranking: 'CLASS', classFile: 'MAGE', search: 'Rune veil', page: 3, limit: 8 });
  const url = viewUrl('http://localhost:8788/?preview=1#rangliste', state);
  assert.equal(new URL(url).searchParams.get('preview'), '1');
  assert.equal(new URL(url).hash, '#rangliste');
  assert.deepEqual(readView(new URL(url).search), state);
});

test('returning to a historical URL restores its view rather than the last selected class', () => {
  const first = readView('?ranking=CLASS&classFile=WARRIOR&bracket=LEVELING&page=2&search=Stone');
  const next = { ...first, ranking: 'CLASS', classFile: 'MAGE', bracket: 'MAX_LEVEL', search: '', page: 1 };
  const previousUrl = viewUrl('https://example.test/?preview=1', first);
  const nextUrl = viewUrl(previousUrl, next);
  assert.notEqual(previousUrl, nextUrl);
  Object.assign(next, readView(new URL(previousUrl).search));
  assert.deepEqual(next, first);
});

test('invalid share-link classes and numeric filters cannot produce an invalid CLASS request', () => {
  assert.equal(readView('?ranking=CLASS&classFile=INVALID').ranking, 'OVERALL');
  assert.equal(readView('?ranking=CLASS').classFile, '');
  const malformed = readView('?maxLevel=-1&page=NaN&bracket=bad');
  assert.equal(malformed.maxLevel, 60);
  assert.equal(malformed.page, 1);
  assert.equal(malformed.bracket, 'MAX_LEVEL');
  const url = viewUrl('https://example.test/?ranking=CLASS&classFile=MAGE&search=old&page=4', readView(''));
  assert.equal(new URL(url).searchParams.has('classFile'), false);
  assert.equal(new URL(url).searchParams.has('search'), false);
  assert.equal(new URL(url).searchParams.has('page'), false);
});

test('class ranks are assigned before search and pagination, while overall Elo stays available', () => {
  const query = { ranking: 'CLASS', classFile: 'MAGE', bracket: 'MAX_LEVEL', maxLevel: 60, page: 2, limit: 1 };
  const second = preview.ladder(query).items[0];
  assert.equal(second.classRank, 2);
  assert.equal(second.rank, 2);
  assert.notEqual(second.overallRank, second.classRank);
  assert.equal(second.rating, second.overallRating);
  const searched = preview.ladder({ ...query, page: 1, search: second.name }).items[0];
  assert.equal(searched.rank, 2);
  assert.equal(searched.classRating, second.classRating);
});

test('leveling class ladders keep actual own-class ranks with unweighted overall Elo', () => {
  const result = preview.ladder({ ranking: 'CLASS', classFile: 'MAGE', bracket: 'LEVELING', maxLevel: 60 });
  assert.equal(result.ranking, 'CLASS');
  assert.equal(result.items[0].classRating, null);
  assert.equal(result.items[0].classRatingStatus, 'unweighted');
  assert.equal(result.items[0].rank, result.items[0].classRank);
  assert.equal(result.items[0].classRank, 1);
  assert.equal(result.items[0].overallRank, 3);
});

test('profile histories and graphs end at their respective rating and never mix metrics', () => {
  const player = preview.players.find(value => value.classFile === 'MAGE' && value.bracket === 'MAX_LEVEL');
  const data = preview.profile(player.guid);
  const overall = profileRecords(data, 'OVERALL');
  const classMetric = profileRecords(data, 'CLASS');
  assert.equal(overall.series.at(-1).rating, player.rating);
  assert.equal(classMetric.series.at(-1).rating, player.classRating);
  assert.equal(overall.history[0].ratingAfter, player.rating);
  assert.equal(classMetric.history[0].ratingAfter, player.classRating);
  assert.notEqual(classMetric.history[0].ratingAfter, overall.history[0].ratingAfter);
  assert.deepEqual(profileRecords({ series: data.series, history: data.history }, 'CLASS'), { series: [], history: [] });
});

test('pair orientation reverses probabilities and confidence-interval endpoints as well as populations', () => {
  const reversed = orientPair({ classA: 'WARRIOR', classB: 'MAGE', baselineProbability: .4, observedWinRate: .3,
    estimatedProbability: .32, ci95: [.2, .44], proposedProbability: .35, changePp: -5, winsA: 3, winsB: 7, uniqueA: 2, uniqueB: 4 }, 'MAGE');
  assert.equal(reversed.classA, 'MAGE');
  assert.equal(reversed.baselineProbability, .6);
  assert.equal(reversed.estimatedProbability, 1 - .32);
  assert.deepEqual(reversed.ci95, [1 - .44, 1 - .2]);
  assert.equal(reversed.winsA, 7);
  assert.equal(reversed.uniqueA, 4);
  assert.equal(reversed.changePp, 5);
});

test('a selected band estimate comes from that band, independently of the candidate proposal', () => {
  const data = { analysis: { bands: [
    { id: 'levels-10-19', pairs: [{ classA: 'WARRIOR', classB: 'MAGE', estimatedProbability: .42, ci95: null }] },
    { id: 'levels-50-59', pairs: [{ classA: 'WARRIOR', classB: 'MAGE', estimatedProbability: .31, ci95: [.21, .39] }] },
  ], candidates: [{ classA: 'WARRIOR', classB: 'MAGE', proposedProbability: .35 }] } };
  assert.equal(selectedBandEstimate(data, 'levels-10-19', 'MAGE', 'WARRIOR').estimatedProbability, 1 - .42);
  assert.deepEqual(selectedBandEstimate(data, 'levels-50-59', 'MAGE', 'WARRIOR').ci95, [1 - .39, 1 - .21]);
  assert.equal(selectedBandEstimate(data, 'max-level', 'MAGE', 'WARRIOR'), null);
});

const candidate = { classA: 'WARRIOR', classB: 'MAGE', baselineProbability: .4, proposedProbability: .35,
  eligible: true, blockingReasons: [], maxLevel: { rawMatches: 0, estimatedProbability: null, ci95: null } };
const report = value => ({ model: { id: 'manual-v1' }, analysis: { activeModelId: 'manual-v1', candidates: [value] } });

test('raw volume does not qualify a proposal and missing max-level data does not reject an eligible one', () => {
  assert.equal(matchupProposal({ overview: { pairs: [{ rawMatches: 100000 }] } }, 'MAGE', 'WARRIOR').status, 'insufficient');
  assert.equal(matchupProposal(report(candidate), 'WARRIOR', 'MAGE').status, 'provisional');
  assert.equal(matchupProposal(report(candidate), 'MAGE', 'WARRIOR').probability, .65);
  const insufficient = matchupProposal(report({ ...candidate, eligible: false, blockingReasons: ['latest_window_insufficient_data'] }), 'MAGE', 'WARRIOR');
  assert.equal(insufficient.status, 'insufficient');
  assert.equal(insufficient.probability, null);
});

test('actual contradictory max-level evidence blocks a proposal without publishing its estimate', () => {
  const result = matchupProposal(report({ ...candidate, eligible: false, blockingReasons: ['max_level_contradiction'] }), 'MAGE', 'WARRIOR');
  assert.equal(result.status, 'blocked');
  assert.equal(result.probability, null);
  assert.deepEqual(result.reasons, ['max_level_contradiction']);
});

test('an eligible analysis from a previous model is historical and cannot appear currently approvable', () => {
  const data = report(candidate);
  data.model.id = 'approved-v2';
  const result = matchupProposal(data, 'MAGE', 'WARRIOR');
  assert.equal(result.status, 'historical');
  assert.equal(result.probability, null);
  assert.equal(result.archivedProbability, .65);
  assert.deepEqual(result.reasons, ['model_changed']);
  const explicitlyStale = report(candidate);
  explicitlyStale.analysis.stale = true;
  assert.equal(matchupProposal(explicitlyStale, 'MAGE', 'WARRIOR').status, 'historical');
});

test('opponent mix counts recorded outcomes, including a win with zero Elo change, and unique opponents', () => {
  const history = [{ result: 'WIN', delta: 0, opponent: { classFile: 'MAGE', guid: 'one' } },
    { result: 'loss', delta: -16, opponent: { classFile: 'MAGE', guid: 'one' } },
    { result: 'WIN', delta: 16, opponent: { classFile: 'MAGE', guid: 'two' } },
    { result: 'unknown', opponent: { classFile: 'MAGE', guid: 'three' } }];
  assert.deepEqual(opponentMix(history), [{ classFile: 'MAGE', wins: 2, losses: 1, duels: 3, distinctOpponents: 2 }]);
});

test('preview uses the approved manual matrix and seven exact bands, and never invents validated evidence', () => {
  const data = preview.comparisons();
  const baseline = JSON.parse(readFileSync(new URL('../config/class-baseline.json', import.meta.url), 'utf8'));
  assert.deepEqual(data.bands.map(band => [band.minLevel, band.maxLevel]), [[1, 9], [10, 19], [20, 29], [30, 39], [40, 49], [50, 59], [60, 60]]);
  assert.equal(data.analysis, null);
  for (const pair of data.bands[0].pairs) {
    const a = baseline.classOrder.indexOf(pair.classA), b = baseline.classOrder.indexOf(pair.classB);
    assert.equal(pair.baselineProbability, baseline.probabilityRows[a][b]);
    assert.equal(data.manualBaseline.probabilities[pair.classA][pair.classB], baseline.probabilityRows[a][b]);
  }
  assert.equal(data.bands[5].counts.matches, 5);
  assert.equal(data.bands[5].counts.sameLevelMatches, 5);
  assert.equal(data.overview.pairs.find(pair => pair.classA === 'WARRIOR' && pair.classB === 'MAGE').rawMatches, 5);
  assert.equal(data.counts.crossBandMatches, 0);
  assert.equal(matchupProposal(data, 'MAGE', 'WARRIOR').status, 'insufficient');
  assert.equal(preview.comparisons(70).manualBaseline, null);
  assert.equal(preview.comparisons(70).counts.confirmedMatches, 0);
});
