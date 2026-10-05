// Fictional content is loaded only by the explicitly labelled ?preview=1 design.
const maxPlayers = [
  ['Vaelora', 'MAGE', 1842, 42, 13], ['Ashwarden', 'WARRIOR', 1796, 37, 14],
  ['Nightveil', 'ROGUE', 1773, 31, 12], ['Thornwild', 'DRUID', 1729, 29, 16],
  ['Solstice', 'PALADIN', 1708, 28, 17], ['Stormcaller', 'SHAMAN', 1683, 25, 18],
  ['Everlight', 'PRIEST', 1645, 23, 19], ['Duskweaver', 'WARLOCK', 1612, 21, 19],
  ['Falconreach', 'HUNTER', 1586, 19, 19], ['Ironheart', 'WARRIOR', 1554, 17, 20],
  ['Frostbloom', 'MAGE', 1528, 15, 21], ['Willowshade', 'DRUID', 1506, 14, 21],
];
const levelingPlayers = [
  ['Emberlyn', 'WARLOCK', 1716, 24, 10], ['Silverpine', 'HUNTER', 1692, 23, 12],
  ['Runeveil', 'MAGE', 1668, 21, 12], ['Oakheart', 'DRUID', 1624, 18, 14],
  ['Dawncrest', 'PALADIN', 1585, 16, 14], ['Quietstep', 'ROGUE', 1567, 14, 13],
  ['Stoneguard', 'WARRIOR', 1536, 13, 14], ['Cloudsong', 'SHAMAN', 1518, 11, 13],
];
const makePlayers = (rows, bracket) => rows.map(([name, classFile, rating, wins, losses], i) => ({
  rank: i + 1, guid: `preview-${bracket}-${i + 1}`, name, realm: i % 4 === 3 ? 'Everlook' : 'Firemaw',
  classFile, level: bracket === 'MAX_LEVEL' ? 60 : 42 + i, maxLevel: 60, bracket,
  rating, wins, losses, winRate: wins / (wins + losses), lastPlayed: '2026-10-04T11:40:00Z',
}));
export const players = [...makePlayers(maxPlayers, 'MAX_LEVEL'), ...makePlayers(levelingPlayers, 'LEVELING')];
for (const [index, player] of players.entries()) {
  player.overallRank = player.rank;
  player.overallRating = player.rating;
  player.classRating = player.bracket === 'MAX_LEVEL' ? player.rating + [12, -43, -21, 16, -17, 25, 10, -8][index % 8] : null;
  player.classRatingStatus = player.bracket === 'MAX_LEVEL' ? 'available' : 'unweighted';
  player.modelId = player.classRating !== null ? 'preview-manual-v1' : null;
}
for (const player of players) {
  const peers = players.filter(peer => peer.bracket === player.bracket && peer.classFile === player.classFile)
    .sort((a, b) => (b.classRating ?? b.rating) - (a.classRating ?? a.rating) || b.wins - a.wins || a.guid.localeCompare(b.guid));
  player.classRank = peers.findIndex(peer => peer.guid === player.guid) + 1;
}
export const config = { name: 'ForeverDuelersGuild', version: 'Design preview', addonVersion: '0.4.5', demo: false, initialRating: 1500 };
export const stats = { players: 20, confirmedMatches: 182, pendingMatches: 4, disputedMatches: 0, lastUpdated: '2026-10-04T11:40:00Z' };
const buildMatches = (bracket) => {
  const list = players.filter(p => p.bracket === bracket);
  return [[0, 2], [3, 1], [5, 4], [6, 7], [1, 0], [2, 3]].map(([a, b], i) => {
    const delta = 14 + i % 3;
    return { matchId: `preview-match-${bracket}-${i}`, bracket, maxLevel: 60, status: 'confirmed',
      startedAt: `2026-10-04T${String(11 - i).padStart(2, '0')}:30:00Z`,
      endedAt: `2026-10-04T${String(11 - i).padStart(2, '0')}:40:00Z`,
      winner: { ...list[a], ratingBefore: list[a].rating - delta, ratingAfter: list[a].rating, delta },
      loser: { ...list[b], ratingBefore: list[b].rating + delta, ratingAfter: list[b].rating, delta: -delta },
    };
  });
};
export const matches = [...buildMatches('MAX_LEVEL'), ...buildMatches('LEVELING')];
export function ladder({ bracket = 'MAX_LEVEL', maxLevel = 60, ranking = 'OVERALL', classFile = '', search = '', page = 1, limit = 8 }) {
  const model = { status: bracket === 'MAX_LEVEL' && maxLevel === 60 ? 'available' : bracket === 'LEVELING' ? 'unweighted' : 'unsupported',
    id: bracket === 'MAX_LEVEL' && maxLevel === 60 ? 'preview-manual-v1' : null, source: maxLevel === 60 ? 'manual' : null, maxLevel, rulesetId: 'forever-v1' };
  const pool = players.filter(player => player.bracket === bracket && player.maxLevel === maxLevel)
    .sort((a, b) => ranking === 'CLASS' ? a.classRank - b.classRank : a.overallRank - b.overallRank);
  const filtered = pool.filter(player => (!classFile || player.classFile === classFile) && `${player.name} ${player.realm}`.toLowerCase().includes(search.toLowerCase()));
  return { items: filtered.slice((page - 1) * limit, page * limit).map(player => ({ ...player, ranking, rank: ranking === 'CLASS' ? player.classRank : player.overallRank })),
    total: filtered.length, page, limit, ranking, model, bracket, maxLevel };
}
export function recentMatches({ bracket = 'MAX_LEVEL', maxLevel = 60, classFile = '', page = 1, limit = 4 }) {
  const filtered = matches.filter(match => match.bracket === bracket && match.maxLevel === maxLevel &&
    (!classFile || match.winner.classFile === classFile || match.loser.classFile === classFile));
  return { items: filtered.slice((page - 1) * limit, page * limit), total: filtered.length, page, limit };
}
export function profile(guid) {
  const player = players.find(p => p.guid === guid);
  if (!player) throw new Error('This sample profile is not available.');
  const offsets = [-159, -144, -125, -139, -121, -105, -87, -101, -82, -68, -54, -69, -52, -37, -20, 0];
  const series = offsets.map((offset, i) => ({ endedAt: new Date(Date.UTC(2026, 8, 19 + i, 11)).toISOString(), rating: player.rating + offset, matchId: `preview-history-${i}` }));
  const peers = players.filter(p => p.bracket === player.bracket && p.guid !== player.guid);
  const history = series.slice(-5).reverse().map((point, i) => ({ ...point, result: i === 2 ? 'loss' : 'win', opponent: peers[i % peers.length], ratingBefore: point.rating - (i === 2 ? -14 : 16), ratingAfter: point.rating, delta: i === 2 ? -14 : 16 }));
  const difference = player.classRating !== null ? player.classRating - player.rating : 0;
  const classSeries = player.classRating !== null ? series.map(point => ({ ...point, rating: point.rating + difference, modelId: player.modelId })) : [];
  const classHistory = player.classRating !== null ? history.map(match => ({ ...match, ratingBefore: match.ratingBefore + difference, ratingAfter: match.ratingAfter + difference, modelId: player.modelId })) : [];
  return { player: { ...player }, ratings: [{ ...player }], series, history, classSeries, classHistory };
}
export function comparisons(maxLevel = 60) {
  const classOrder = ['WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'SHAMAN', 'MAGE', 'WARLOCK', 'DRUID'];
  // These assumptions are the approved manual baseline; only the duel evidence is fictional.
  const probabilityRows = [
    [.50,.45,.45,.55,.45,.45,.40,.45,.40], [.55,.50,.50,.55,.45,.50,.45,.40,.50],
    [.55,.50,.50,.55,.50,.55,.55,.45,.50], [.45,.45,.45,.50,.50,.55,.50,.45,.40],
    [.55,.55,.50,.50,.50,.55,.55,.45,.55], [.55,.50,.45,.45,.45,.50,.45,.40,.50],
    [.60,.55,.45,.50,.45,.55,.50,.40,.50], [.55,.60,.55,.55,.55,.60,.60,.50,.55],
    [.60,.50,.50,.60,.45,.50,.50,.45,.50],
  ];
  const probabilities = Object.fromEntries(classOrder.map((a, i) => [a, Object.fromEntries(classOrder.map((b, j) => [b, probabilityRows[i][j]]))]));
  const pairs = classOrder.flatMap((classA, a) => classOrder.slice(a + 1).map(classB => ({ classA, classB, baselineProbability: probabilities[classA][classB],
    observedWinRate: null, rawMatches: 0, sameLevelMatches: 0, winsA: 0, winsB: 0, uniqueA: 0, uniqueB: 0, uniquePairs: 0 })));
  const definitions = [[1, 9], [10, 19], [20, 29], [30, 39], [40, 49], [50, 59], [60, 60]];
  const bands = definitions.map(([minLevel, upper]) => ({ id: minLevel === 60 ? 'max-level' : `levels-${minLevel}-${upper}`, minLevel, maxLevel: upper, counts: { matches: 0, sameLevelMatches: 0 }, pairs: pairs.map(pair => ({ ...pair })) }));
  const sample = bands[5].pairs.find(pair => pair.classA === 'WARRIOR' && pair.classB === 'MAGE');
  Object.assign(sample, { observedWinRate: .4, rawMatches: 5, sameLevelMatches: 5, winsA: 2, winsB: 3, uniqueA: 3, uniqueB: 3, uniquePairs: 4 });
  bands[5].counts.matches = 5;
  bands[5].counts.sameLevelMatches = 5;
  return { rulesetId: 'forever-v1', maxLevel, model: { status: maxLevel === 60 ? 'available' : 'unsupported', id: maxLevel === 60 ? 'preview-manual-v1' : null, source: maxLevel === 60 ? 'manual' : null,
    effectiveFrom: '2026-10-01T00:00:00Z', classOrder, probabilities: maxLevel === 60 ? probabilities : null },
    manualBaseline: maxLevel === 60 ? { id: 'forever-v1-cap60-manual-v1', source: 'manual', effectiveFrom: 0, probabilities } : null,
    counts: { confirmedMatches: maxLevel === 60 ? 5 : 0, sameLevelMatches: maxLevel === 60 ? 5 : 0, excludedUnequalLevels: 0, crossBandMatches: 0, sameClassMatches: 0 },
    overview: { pairs: maxLevel === 60 ? bands[5].pairs.map(pair => ({ ...pair })) : [], sameClass: [] }, bands: maxLevel === 60 ? bands : [], analysis: null };
}
