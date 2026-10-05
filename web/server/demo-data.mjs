import { ratingTransfer } from './store.mjs';

export function makeReportPair(player, opponent, { index = 1, endedAt = 1791100800 + index * 300, winnerGuid = player.guid, ratingA = 1500, ratingB = 1500, protocolVersion = 2 } = {}) {
  const participants = [player.guid, opponent.guid].sort(), nonce = index.toString(16);
  const matchId = `FD${protocolVersion}:${participants[0]}:${nonce}.a:${participants[1]}:${nonce}.b`;
  const won = winnerGuid === player.guid;
  const transfer = won ? ratingTransfer(ratingA, ratingB, player.level, opponent.level) : ratingTransfer(ratingB, ratingA, opponent.level, player.level);
  const record = (local, peer, localWon, rating, peerRating) => ({ schemaVersion: 2, protocolVersion, addonVersion: protocolVersion === 3 ? '0.6.0' : '0.4.5',
    bracket: local.level === local.maxLevel ? 'MAX_LEVEL' : 'LEVELING', matchId, player: { ...local }, opponent: { ...peer },
    startedAt: endedAt - 65, endedAt, countdownAt: endedAt - 68, confirmedAt: endedAt - 72,
    startSource: 'localized-countdown-plus-timer', resultSource: 'synthetic-demo', winnerGUID: winnerGuid,
    loserGUID: won ? opponent.guid : player.guid, result: localWon ? 'WIN' : 'LOSS', ratingBefore: rating,
    opponentRatingBefore: peerRating, ratingDelta: localWon ? transfer : -transfer,
    ratingAfter: rating + (localWon ? transfer : -transfer), ratedConfirmed: true,
    evidence: { agreedBeforeStart: true, localResult: true, peerResult: true } });
  return [record(player, opponent, won, ratingA, ratingB), record(opponent, player, !won, ratingB, ratingA)];
}

export function seedDemo(store) {
  if (!store.demo) throw new Error('Synthetic records require a demo store');
  if (store.stats().confirmedMatches > 0) return;
  const roster = [
    ['Demo Aeloria', 'MAGE'], ['Demo Tharok', 'WARRIOR'], ['Demo Sylrien', 'ROGUE'], ['Demo Velindra', 'WARLOCK'],
    ['Demo Lunara', 'DRUID'], ['Demo Kaelith', 'PALADIN'], ['Demo Orvyn', 'PRIEST'], ['Demo Rhaegar', 'SHAMAN'],
    ['Demo Nymera', 'HUNTER'], ['Demo Vaelorn', 'WARRIOR'], ['Demo Sorya', 'MAGE'], ['Demo Duskweave', 'ROGUE'],
  ].map(([name, classFile], index) => ({ guid: `Player-DE00-${(index + 1).toString(16).padStart(8, '0')}`, name, realm: 'Demo Realm', classFile, level: 60, maxLevel: 60 }));
  let index = 0;
  function duel(a, b, winner) {
    const pair = makeReportPair(a, b, { index: ++index, winnerGuid: winner.guid });
    for (const report of pair) store.importReports(report.player.guid, { schemaVersion: 2, player: { guid: report.player.guid }, matches: [report] });
  }
  for (let round = 0; round < 6; round++) for (let position = 0; position < roster.length; position += 2) {
    const a = roster[(position + round) % roster.length], b = roster[(position + round + 1) % roster.length];
    duel(a, b, (position + round) % 3 === 0 ? b : a);
  }
  const leveling = roster.slice(0, 4).map((player, position) => ({ ...player, level: 34 + position }));
  for (let round = 0; round < 6; round++) duel(leveling[round % 4], leveling[(round + 1) % 4], leveling[round % 4]);
  const alternate = roster.slice(4, 8).map((player) => ({ ...player, level: 80, maxLevel: 80 }));
  for (let round = 0; round < 4; round++) duel(alternate[round % 4], alternate[(round + 1) % 4], alternate[round % 4]);
}
