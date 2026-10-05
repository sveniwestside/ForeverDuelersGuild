export const CLASS_FILES = ['WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'SHAMAN', 'MAGE', 'WARLOCK', 'DRUID'];

export function readView(search) {
  const params = new URLSearchParams(search);
  const selectedClass = params.get('classFile') || '';
  const ranking = params.get('ranking') === 'CLASS' && CLASS_FILES.includes(selectedClass) ? 'CLASS' : 'OVERALL';
  const cap = Number(params.get('maxLevel') || 60);
  const page = Number(params.get('page') || 1);
  return { bracket: params.get('bracket') === 'LEVELING' ? 'LEVELING' : 'MAX_LEVEL',
    maxLevel: Number.isInteger(cap) && cap > 0 && cap <= 255 ? cap : 60,
    ranking, classFile: ranking === 'CLASS' ? selectedClass : '',
    search: (params.get('search') || '').trim().slice(0, 80),
    page: Number.isInteger(page) && page > 0 && page <= 1000000 ? page : 1, limit: 8 };
}

export function viewUrl(href, state) {
  const url = new URL(href);
  for (const key of ['ranking', 'classFile', 'bracket', 'maxLevel', 'search', 'page']) {
    const value = state[key];
    if (((key === 'classFile' || key === 'search') && !value) || (key === 'page' && value === 1)) url.searchParams.delete(key);
    else url.searchParams.set(key, String(value));
  }
  return url.href;
}

export function profileRecords(data, metric) {
  const classMetric = metric === 'CLASS';
  return { series: Array.isArray(data[classMetric ? 'classSeries' : 'series']) ? data[classMetric ? 'classSeries' : 'series'] : [],
    history: Array.isArray(data[classMetric ? 'classHistory' : 'history']) ? data[classMetric ? 'classHistory' : 'history'] : [] };
}

export function opponentMix(history) {
  const groups = new Map();
  for (const match of history || []) {
    const classFile = match.opponent?.classFile;
    const result = String(match.result).toUpperCase();
    if (!CLASS_FILES.includes(classFile) || !['WIN', 'LOSS'].includes(result)) continue;
    if (!groups.has(classFile)) groups.set(classFile, { classFile, wins: 0, losses: 0, duels: 0, opponents: new Set() });
    const group = groups.get(classFile);
    group.duels += 1;
    group[result === 'WIN' ? 'wins' : 'losses'] += 1;
    if (match.opponent?.guid) group.opponents.add(match.opponent.guid);
  }
  return [...groups.values()].map(({ opponents, ...group }) => ({ ...group, distinctOpponents: opponents.size }))
    .sort((a, b) => b.duels - a.duels || CLASS_FILES.indexOf(a.classFile) - CLASS_FILES.indexOf(b.classFile));
}

export function orientPair(pair, classFile) {
  if (!pair || ![pair.classA, pair.classB].includes(classFile)) return null;
  if (pair.classA === classFile) return { ...pair };
  return { ...pair, classA: pair.classB, classB: pair.classA,
    baselineProbability: Number.isFinite(pair.baselineProbability) ? 1 - pair.baselineProbability : null,
    observedWinRate: Number.isFinite(pair.observedWinRate) ? 1 - pair.observedWinRate : null,
    estimatedProbability: Number.isFinite(pair.estimatedProbability) ? 1 - pair.estimatedProbability : null,
    proposedProbability: Number.isFinite(pair.proposedProbability) ? 1 - pair.proposedProbability : null,
    pooledEstimate: Number.isFinite(pair.pooledEstimate) ? 1 - pair.pooledEstimate : null,
    ci95: Array.isArray(pair.ci95) && pair.ci95.length === 2 && pair.ci95.every(Number.isFinite) ? [1 - pair.ci95[1], 1 - pair.ci95[0]] : null,
    changePp: Number.isFinite(pair.changePp) ? -pair.changePp : null,
    winsA: pair.winsB, winsB: pair.winsA, uniqueA: pair.uniqueB, uniqueB: pair.uniqueA };
}

export function selectedBandEstimate(data, bandId, classFile, opponentClass) {
  const band = data?.analysis?.bands?.find(value => value.id === bandId);
  const pair = band?.pairs?.find(value => value.classA === classFile && value.classB === opponentClass || value.classA === opponentClass && value.classB === classFile);
  return orientPair(pair, classFile);
}

export function matchupProposal(data, classFile, opponentClass) {
  const candidate = data?.analysis?.candidates?.find(pair =>
    pair.classA === classFile && pair.classB === opponentClass || pair.classA === opponentClass && pair.classB === classFile);
  if (!candidate) return { status: 'insufficient', probability: null, reasons: [], candidate: null };
  const current = data.analysis.stale !== true && (!data.analysis.activeModelId || data.analysis.activeModelId === data.model?.id);
  const eligible = candidate.eligible === true && current && !candidate.blockingReasons?.length && Number.isFinite(candidate.proposedProbability);
  const reverse = candidate.classA !== classFile;
  const probability = Number.isFinite(candidate.proposedProbability) ? reverse ? 1 - candidate.proposedProbability : candidate.proposedProbability : null;
  return { status: !current ? 'historical' : eligible ? 'provisional' : candidate.blockingReasons?.includes('max_level_contradiction') ? 'blocked' : 'insufficient',
    probability: eligible ? reverse ? 1 - candidate.proposedProbability : candidate.proposedProbability : null,
    archivedProbability: !current && candidate.eligible === true ? probability : null,
    reasons: current ? candidate.blockingReasons || [] : ['model_changed'], candidate };
}
