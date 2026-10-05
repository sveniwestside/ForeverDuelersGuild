import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

export const CLASS_ORDER = Object.freeze(['WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'SHAMAN', 'MAGE', 'WARLOCK', 'DRUID']);
export const CLASS_SET = new Set(CLASS_ORDER);
export const stableJSON = (value) => JSON.stringify(stable(value));
function stable(value) {
  return Array.isArray(value) ? value.map(stable) : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])])) : value;
}
export const digest = (value) => createHash('sha256').update(typeof value === 'string' ? value : stableJSON(value), 'utf8').digest('hex');
export const offsetForProbability = (probability) => 400 * Math.log10(probability / (1 - probability));
export function classTransfer(winnerRating, loserRating, probability) {
  const offsetElo = offsetForProbability(probability);
  const expectedWinner = 1 / (1 + 10 ** ((loserRating - winnerRating - offsetElo) / 400));
  return { transfer: Math.floor(32 * (1 - expectedWinner) + 0.5), expectedWinner, matchupProbability: probability, offsetElo };
}
const id = (value) => typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$/u.test(value);
export function validateModel(value) {
  if (!value || value.schemaVersion !== 1 || !id(value.id) || !id(value.rulesetId) || value.maxLevel !== 60
    || !['manual', 'leveling-supported'].includes(value.source) || !Number.isSafeInteger(value.dataCutoff) || value.dataCutoff < 0) throw new Error('Invalid class model metadata');
  if (value.classOrder !== undefined && stableJSON(value.classOrder) !== stableJSON(CLASS_ORDER)) throw new Error('Invalid model class order');
  if (value.effectiveFrom !== undefined && (!Number.isSafeInteger(value.effectiveFrom) || value.effectiveFrom < 0)) throw new Error('Invalid model effective date');
  if (value.dataHash !== undefined && !/^[a-f0-9]{64}$/u.test(value.dataHash)) throw new Error('Invalid model data hash');
  const matrix = value.probabilities;
  if (!matrix || Object.keys(matrix).length !== CLASS_ORDER.length) throw new Error('A class model requires all nine classes');
  for (const a of CLASS_ORDER) {
    if (!matrix[a] || Object.keys(matrix[a]).length !== CLASS_ORDER.length) throw new Error('Incomplete class probability matrix');
    for (const b of CLASS_ORDER) {
      const p = matrix[a][b], inverse = matrix[b]?.[a];
      if (typeof p !== 'number' || !Number.isFinite(p) || !(p > 0 && p < 1)
        || Math.abs(offsetForProbability(p)) > 150 + 1e-8 || Math.abs(p + inverse - 1) > 1e-8 || (a === b && p !== 0.5)) throw new Error('Invalid class probability, symmetry or offset bound');
    }
  }
  return JSON.parse(stableJSON(value));
}
const rawBaseline = JSON.parse(readFileSync(new URL('../config/class-baseline.json', import.meta.url), 'utf8'));
const { probabilityRows, ...metadata } = rawBaseline;
export const BASELINE = validateModel({ ...metadata, dataHash: digest({ classOrder: CLASS_ORDER, probabilityRows }), probabilities: Object.fromEntries(CLASS_ORDER.map((a, i) => [a,
  Object.fromEntries(CLASS_ORDER.map((b, j) => [b, probabilityRows[i][j]]))])) });
export const validRuleset = id;
