import test from 'node:test';
import assert from 'node:assert/strict';
import { BASELINE, CLASS_ORDER, classTransfer, offsetForProbability } from '../server/class-model.mjs';
import { createStore } from '../server/store.mjs';
import { makeReportPair } from '../server/demo-data.mjs';
import { comparisons } from '../public/assets/design-preview.js';

const approvedPercentages = [
  [50,45,45,55,45,45,40,45,40], [55,50,50,55,45,50,45,40,50],
  [55,50,50,55,50,55,55,45,50], [45,45,45,50,50,55,50,45,40],
  [55,55,50,50,50,55,55,45,55], [55,50,45,45,45,50,45,40,50],
  [60,55,45,50,45,55,50,40,50], [55,60,55,55,55,60,60,50,55],
  [60,50,50,60,45,50,50,45,50],
];

test('all approved baseline cells, reverse offsets and neutral mirrors match the plan', () => {
  for (const [i, a] of CLASS_ORDER.entries()) for (const [j, b] of CLASS_ORDER.entries()) {
    const p = BASELINE.probabilities[a][b], inverse = BASELINE.probabilities[b][a];
    assert.equal(p, approvedPercentages[i][j] / 100, `${a}/${b}`);
    assert.ok(Math.abs(p + inverse - 1) < 1e-12);
    assert.ok(Math.abs(offsetForProbability(p) + offsetForProbability(inverse)) < 1e-10);
    assert.ok(Math.abs(classTransfer(1500, 1500, p).expectedWinner - p) < 1e-12);
    if (a === b) assert.equal(classTransfer(1500, 1500, p).transfer, 16);
  }
});

test('the design preview uses the approved assumptions and never invents another-cap matrix', () => {
  const preview = comparisons(60);
  assert.equal(preview.overview.pairs.length, 36);
  for (const pair of preview.overview.pairs)
    assert.equal(pair.baselineProbability, BASELINE.probabilities[pair.classA][pair.classB]);
  assert.deepEqual(comparisons(80).bands, []);
  assert.equal(comparisons(80).model.probabilities, null);
});

test('each of 36 matchups and nine mirrors conserves class and overall rating independently', () => {
  const store = createStore();
  let index = 0;
  try {
    for (const [i, a] of CLASS_ORDER.entries()) for (let j = i; j < CLASS_ORDER.length; j++) {
      const b = CLASS_ORDER[j];
      index++;
      const player = (side, classFile) => ({ guid: `Player-ABCD-${(index * 2 + side).toString(16).padStart(8, '0')}`,
        name: `${classFile} ${index} ${side}`, realm: 'Matrix test', classFile, level: 60, maxLevel: 60 });
      const first = player(0, a), second = player(1, b);
      for (const report of makeReportPair(first, second, { index }))
        store.importReports(report.player.guid, { schemaVersion: 2, player: { guid: report.player.guid }, matches: [report] });
      const match = store.matches({ limit: 100 }).items.find(row => row.winner.guid === first.guid);
      const expected = classTransfer(1500, 1500, approvedPercentages[i][j] / 100).transfer;
      assert.equal(match.classProjection.winner.delta, expected, `${a}/${b}`);
      assert.equal(match.classProjection.loser.delta, -expected);
      assert.equal(match.classProjection.winner.ratingAfter + match.classProjection.loser.ratingAfter, 3000);
      assert.equal(match.winner.ratingAfter, 1516);
      assert.equal(match.loser.ratingAfter, 1484);
    }
    assert.equal(index, 45);
    const all = store.ladder({ limit: 100 }).items;
    assert.equal(all.reduce((total, p) => total + p.classRating, 0), 45 * 3000);
    assert.equal(all.reduce((total, p) => total + p.rating, 0), 45 * 3000);
  } finally { store.close(); }
});
