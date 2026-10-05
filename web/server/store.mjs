import { DatabaseSync } from 'node:sqlite';
import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { validateMapping } from './blizzard.mjs';
import { BASELINE, CLASS_ORDER, CLASS_SET, classTransfer, digest, stableJSON, validateModel, validRuleset } from './class-model.mjs';
import { BANDS, validateAnalysis, validateCandidate } from './class-analysis.mjs';

export const CLASSES = new Set(['WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'DEATHKNIGHT', 'SHAMAN', 'MAGE', 'WARLOCK', 'MONK', 'DRUID', 'DEMONHUNTER', 'EVOKER']);
export const INITIAL_RATING = 1500;
export class ApiError extends Error {
  constructor(status, code, message = code) { super(message); this.status = status; this.code = code; }
}
const fail = (code, message) => { throw new ApiError(400, code, message); };
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const integer = (value, min, max) => Number.isSafeInteger(value) && value >= min && value <= max;
const textField = (value, max) => typeof value === 'string' && value.trim() !== '' && value.length <= max && !/[\u0000-\u001f\u007f]/u.test(value);
export const validGuid = (value) => typeof value === 'string' && value.length <= 64 && /^Player-[0-9a-fA-F]+-[0-9a-fA-F]+$/u.test(value);
const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const stable = (value) => Array.isArray(value) ? value.map(stable) : isObject(value) ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])])) : value;
const canonicalJSON = (value) => JSON.stringify(stable(value));
const identityFields = ['guid', 'name', 'realm', 'classFile', 'level', 'maxLevel'];
const publicIdentity = (value) => Object.fromEntries(identityFields.map((key) => [key, value[key]]));

export function validateIdentity(identity) {
  if (!isObject(identity) || !validGuid(identity.guid) || !textField(identity.name, 96) || !textField(identity.realm, 128)
    || !CLASSES.has(identity.classFile) || !integer(identity.maxLevel, 1, 255) || !integer(identity.level, 1, identity.maxLevel)) fail('invalid_identity');
  return publicIdentity(identity);
}

export function ratingTransfer(winnerRating, loserRating, winnerLevel, loserLevel) {
  const expected = 1 / (1 + 10 ** ((loserRating + loserLevel * 20 - winnerRating - winnerLevel * 20) / 400));
  return Math.floor(32 * (1 - expected) + 0.5);
}

function validateSerializable(value, depth = 0, budget = { remaining: 3000 }) {
  if (--budget.remaining < 0 || depth > 16) fail('record_too_complex');
  if (typeof value === 'number' && !Number.isFinite(value)) fail('invalid_number');
  if (typeof value === 'string' && value.length > 1024) fail('record_field_too_long');
  if (value === null || ['boolean', 'number', 'string'].includes(typeof value)) return;
  if (!Array.isArray(value) && !isObject(value)) fail('invalid_record_value');
  for (const [key, child] of Object.entries(value)) {
    if (key.length > 128) fail('record_field_too_long');
    validateSerializable(child, depth + 1, budget);
  }
}

export function validateRecord(record, guid) {
  if (!isObject(record) || record.schemaVersion !== 2 || record.protocolVersion !== 2) fail('unsupported_record_version');
  validateSerializable(record);
  const player = validateIdentity(record.player), opponent = validateIdentity(record.opponent);
  if (player.guid !== guid || player.guid === opponent.guid) fail('invalid_reporter');
  const parts = typeof record.matchId === 'string' ? record.matchId.split(':') : [];
  const participants = [player.guid, opponent.guid].sort();
  const validNonce = (value) => typeof value === 'string' && value.length >= 1 && value.length <= 48 && /^[a-f0-9.-]+$/u.test(value) && /[a-f0-9]/u.test(value);
  if (parts.length !== 5 || parts[0] !== 'FD2' || parts[1] !== participants[0] || parts[3] !== participants[1] || !validNonce(parts[2]) || !validNonce(parts[4])) fail('invalid_match_id');
  const bracket = player.level === player.maxLevel ? 'MAX_LEVEL' : 'LEVELING';
  if (player.maxLevel !== opponent.maxLevel || (opponent.level === opponent.maxLevel ? 'MAX_LEVEL' : 'LEVELING') !== bracket
    || record.bracket !== bracket || Math.abs(player.level - opponent.level) > 5) fail('ineligible_bracket');
  if (!integer(record.startedAt, 0, 253402300799) || !integer(record.endedAt, record.startedAt, 253402300799)) fail('invalid_record_time');
  for (const field of ['confirmedAt', 'countdownAt']) if (record[field] !== undefined && !integer(record[field], 0, record.startedAt)) fail('invalid_record_time');
  if (record.confirmedAt !== undefined && record.countdownAt !== undefined && record.confirmedAt > record.countdownAt) fail('invalid_record_time');
  for (const field of ['addonVersion', 'startSource', 'resultSource']) if (record[field] !== undefined && !textField(record[field], 96)) fail('invalid_record_metadata');
  if (!['WIN', 'LOSS'].includes(record.result)) fail('invalid_result');
  const won = record.result === 'WIN';
  if (record.winnerGUID !== (won ? player.guid : opponent.guid) || record.loserGUID !== (won ? opponent.guid : player.guid)) fail('contradictory_result');
  // Client evidence is required for compatibility; it cannot prove native game events.
  if (record.ratedConfirmed !== true || !isObject(record.evidence) || record.evidence.agreedBeforeStart !== true
    || record.evidence.localResult !== true || record.evidence.peerResult !== true) fail('unconfirmed_client_record');
  if (!integer(record.ratingBefore, -100000, 100000) || !integer(record.opponentRatingBefore, -100000, 100000)
    || !integer(record.ratingAfter, -100032, 100032) || !integer(record.ratingDelta, -32, 32)) fail('invalid_local_rating');
  const transfer = won ? ratingTransfer(record.ratingBefore, record.opponentRatingBefore, player.level, opponent.level)
    : ratingTransfer(record.opponentRatingBefore, record.ratingBefore, opponent.level, player.level);
  const delta = won ? transfer : -transfer;
  if (record.ratingDelta !== delta || record.ratingAfter !== record.ratingBefore + delta) fail('inconsistent_local_rating');
  const allowed = ['schemaVersion', 'protocolVersion', 'addonVersion', 'bracket', 'matchId', 'startedAt', 'endedAt',
    'countdownAt', 'confirmedAt', 'startSource', 'resultSource', 'winnerGUID', 'loserGUID', 'result',
    'ratingBefore', 'opponentRatingBefore', 'ratingAfter', 'ratingDelta', 'ratedConfirmed'];
  const normalized = Object.fromEntries(allowed.filter((key) => record[key] !== undefined).map((key) => [key, record[key]]));
  normalized.player = player;
  normalized.opponent = opponent;
  normalized.evidence = { agreedBeforeStart: true, localResult: true, peerResult: true };
  return JSON.parse(canonicalJSON(normalized));
}

function matchingReports(a, b) {
  return a.player.guid === b.opponent.guid && a.opponent.guid === b.player.guid
    && identityFields.every((key) => a.player[key] === b.opponent[key] && a.opponent[key] === b.player[key])
    && a.winnerGUID === b.winnerGUID && a.loserGUID === b.loserGUID && a.bracket === b.bracket
    && a.ratingBefore === b.opponentRatingBefore && a.opponentRatingBefore === b.ratingBefore
    && a.result !== b.result && Math.abs(a.startedAt - b.startedAt) <= 10 && Math.abs(a.endedAt - b.endedAt) <= 10;
}

export function createStore({ path = ':memory:', demo = false, rulesetId = process.env.FD_RULESET_ID || 'forever-v1', now = () => Date.now() } = {}) {
  if (!validRuleset(rulesetId)) throw new Error('Invalid FD_RULESET_ID');
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
    CREATE TABLE IF NOT EXISTS accounts(guid TEXT PRIMARY KEY, identity_json TEXT NOT NULL, token_hash TEXT UNIQUE, provisioned_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS reports(match_id TEXT NOT NULL, reporter_guid TEXT NOT NULL, body_json TEXT NOT NULL, body_hash TEXT NOT NULL,
      received_at TEXT NOT NULL, PRIMARY KEY(match_id,reporter_guid));
    CREATE TABLE IF NOT EXISTS matches(match_id TEXT PRIMARY KEY, status TEXT NOT NULL CHECK(status IN ('pending','confirmed','disputed')),
      bracket TEXT NOT NULL, max_level INTEGER NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL, projection_json TEXT);
    CREATE TABLE IF NOT EXISTS ratings(guid TEXT NOT NULL, bracket TEXT NOT NULL, max_level INTEGER NOT NULL,
      identity_json TEXT NOT NULL, rating INTEGER NOT NULL, wins INTEGER NOT NULL, losses INTEGER NOT NULL, last_played INTEGER NOT NULL,
      PRIMARY KEY(guid,bracket,max_level));
    CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS character_mappings(guid TEXT PRIMARY KEY,mapping_json TEXT NOT NULL,linked_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS class_models(id TEXT PRIMARY KEY,ruleset_id TEXT NOT NULL,max_level INTEGER NOT NULL,effective_from INTEGER NOT NULL,body_json TEXT NOT NULL,body_hash TEXT NOT NULL,created_at TEXT NOT NULL,UNIQUE(ruleset_id,max_level,effective_from));
    CREATE TABLE IF NOT EXISTS class_locks(guid TEXT PRIMARY KEY,class_file TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS class_ratings(guid TEXT NOT NULL,bracket TEXT NOT NULL,max_level INTEGER NOT NULL,ruleset_id TEXT NOT NULL,rating INTEGER NOT NULL,model_id TEXT NOT NULL,PRIMARY KEY(guid,bracket,max_level,ruleset_id));
    CREATE TABLE IF NOT EXISTS dataset_exports(dataset_hash TEXT PRIMARY KEY,body_json TEXT NOT NULL,created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS matchup_analyses(analysis_id TEXT PRIMARY KEY,dataset_hash TEXT NOT NULL,body_json TEXT NOT NULL,body_hash TEXT NOT NULL,published_at TEXT NOT NULL);
    CREATE TRIGGER IF NOT EXISTS class_models_no_update BEFORE UPDATE ON class_models BEGIN SELECT RAISE(ABORT,'Class models are immutable'); END;
    CREATE TRIGGER IF NOT EXISTS class_models_no_delete BEFORE DELETE ON class_models BEGIN SELECT RAISE(ABORT,'Class models are immutable'); END;
    CREATE TRIGGER IF NOT EXISTS dataset_exports_no_update BEFORE UPDATE ON dataset_exports BEGIN SELECT RAISE(ABORT,'Dataset exports are immutable'); END;
    CREATE TRIGGER IF NOT EXISTS dataset_exports_no_delete BEFORE DELETE ON dataset_exports BEGIN SELECT RAISE(ABORT,'Dataset exports are immutable'); END;
    CREATE TRIGGER IF NOT EXISTS matchup_analyses_no_update BEFORE UPDATE ON matchup_analyses BEGIN SELECT RAISE(ABORT,'Published analyses are immutable'); END;
    CREATE TRIGGER IF NOT EXISTS matchup_analyses_no_delete BEFORE DELETE ON matchup_analyses BEGIN SELECT RAISE(ABORT,'Published analyses are immutable'); END;
    CREATE INDEX IF NOT EXISTS matches_public ON matches(status,bracket,max_level,ended_at);
    CREATE INDEX IF NOT EXISTS reports_match ON reports(match_id);
  `);
  const transaction = (callback) => { db.exec('BEGIN IMMEDIATE'); try { const value = callback(); db.exec('COMMIT'); return value; } catch (error) { db.exec('ROLLBACK'); throw error; } };
  const query = (sql, ...args) => db.prepare(sql).all(...args);
  const get = (sql, ...args) => db.prepare(sql).get(...args);
  const run = (sql, ...args) => db.prepare(sql).run(...args);

  try {
    transaction(() => {
      const context = get("SELECT value FROM metadata WHERE key='rulesetId'");
      if (context && context.value !== rulesetId) throw new Error(`Database ruleset is ${context.value}; use a separate database for ${rulesetId}`);
      run("INSERT OR IGNORE INTO metadata VALUES('rulesetId',?)", rulesetId);
      const columns = new Set(query('PRAGMA table_info(matches)').map((column) => column.name));
      if (!columns.has('ruleset_id')) db.exec('ALTER TABLE matches ADD COLUMN ruleset_id TEXT');
      if (!columns.has('class_model_id')) db.exec('ALTER TABLE matches ADD COLUMN class_model_id TEXT');
      run('UPDATE matches SET ruleset_id=? WHERE ruleset_id IS NULL', rulesetId);
      const prior = get('SELECT body_hash FROM class_models WHERE id=?', BASELINE.id);
      if (prior && prior.body_hash !== digest(BASELINE)) throw new Error('Stored baseline differs from immutable baseline configuration');
      if (!prior) run('INSERT INTO class_models VALUES(?,?,?,?,?,?,?)', BASELINE.id, BASELINE.rulesetId, BASELINE.maxLevel, BASELINE.effectiveFrom, stableJSON(BASELINE), digest(BASELINE), new Date(now()).toISOString());
      for (const row of query("SELECT match_id,ended_at,bracket,max_level,ruleset_id FROM matches WHERE status='confirmed' AND class_model_id IS NULL")) {
        const model = modelAt(row.ruleset_id, row.max_level, row.ended_at);
        if (row.bracket === 'MAX_LEVEL' && model) run('UPDATE matches SET class_model_id=? WHERE match_id=?', model.id, row.match_id);
      }
      const audit = classAudit();
      for (const [guid, classes] of audit.classes) if (classes.size === 1) run('INSERT OR IGNORE INTO class_locks VALUES(?,?)', guid, [...classes][0]);
      recompute();
    });
  } catch (error) { db.close(); throw error; }

  function modelAt(context, maxLevel, endedAt = Math.floor(now() / 1000)) {
    const row = get('SELECT body_json FROM class_models WHERE ruleset_id=? AND max_level=? AND effective_from<=? ORDER BY effective_from DESC LIMIT 1', context, maxLevel, endedAt);
    return row ? JSON.parse(row.body_json) : null;
  }
  function classAudit() {
    const classes = new Map();
    for (const row of query("SELECT r.body_json FROM reports r JOIN matches m ON m.match_id=r.match_id WHERE m.status='confirmed'")) {
      const report = JSON.parse(row.body_json);
      for (const identity of [report.player, report.opponent]) {
        if (!classes.has(identity.guid)) classes.set(identity.guid, new Set());
        classes.get(identity.guid).add(identity.classFile);
      }
    }
    return { classes, conflicts: [...classes].filter(([, values]) => values.size > 1).map(([guid, values]) => ({ guid, classes: [...values].sort() })) };
  }
  function modelStatus({ bracket = 'MAX_LEVEL', maxLevel = 60 } = {}) {
    const model = modelAt(rulesetId, maxLevel), blocked = classAudit().conflicts.length > 0;
    return { status: bracket === 'LEVELING' ? 'unweighted' : !model ? 'unsupported' : blocked ? 'blocked' : 'available',
      id: model?.id ?? null, source: model?.source ?? null, rulesetId, maxLevel,
      effectiveFrom: model?.effectiveFrom ?? null, dataCutoff: model?.dataCutoff ?? null,
      dataHash: model?.dataHash ?? null,
      classOrder: CLASS_ORDER, probabilities: model?.probabilities ?? null };
  }

  function recompute() {
    const pools = new Map();
    const classPools = new Map(), weightedEnabled = classAudit().conflicts.length === 0;
    const takeRating = (identity, bracket) => {
      const key = `${identity.guid}:${bracket}:${identity.maxLevel}`;
      if (!pools.has(key)) pools.set(key, { ...publicIdentity(identity), bracket, rating: INITIAL_RATING, wins: 0, losses: 0, lastPlayed: 0 });
      const rating = pools.get(key);
      Object.assign(rating, publicIdentity(identity));
      return rating;
    };
    for (const row of query("SELECT * FROM matches WHERE status='confirmed' ORDER BY ended_at ASC,match_id ASC")) {
      // Lowest reporter GUID supplies the canonical time; upload order cannot change replay order.
      const report = JSON.parse(get('SELECT body_json FROM reports WHERE match_id=? ORDER BY reporter_guid LIMIT 1', row.match_id).body_json);
      const winnerIdentity = report.player.guid === report.winnerGUID ? report.player : report.opponent;
      const loserIdentity = report.player.guid === report.loserGUID ? report.player : report.opponent;
      const winner = takeRating(winnerIdentity, report.bracket), loser = takeRating(loserIdentity, report.bracket);
      const transfer = ratingTransfer(winner.rating, loser.rating, winner.level, loser.level);
      const participant = (value, delta) => ({ ...publicIdentity(value), ratingBefore: value.rating, ratingAfter: value.rating + delta, delta });
      const projection = { matchId: row.match_id, bracket: report.bracket, maxLevel: winner.maxLevel,
        startedAt: report.startedAt, endedAt: report.endedAt, winner: participant(winner, transfer), loser: participant(loser, -transfer), status: 'confirmed', rulesetId: row.ruleset_id, classProjection: null };
      if (weightedEnabled && row.class_model_id && CLASS_SET.has(winner.classFile) && CLASS_SET.has(loser.classFile)) {
        const model = JSON.parse(get('SELECT body_json FROM class_models WHERE id=?', row.class_model_id).body_json);
        const takeClass = (identity) => {
          const key = `${row.ruleset_id}:${identity.maxLevel}:${identity.guid}`;
          if (!classPools.has(key)) classPools.set(key, { guid: identity.guid, maxLevel: identity.maxLevel, rulesetId: row.ruleset_id, rating: INITIAL_RATING, modelId: model.id });
          return classPools.get(key);
        };
        const cw = takeClass(winner), cl = takeClass(loser), adjustment = classTransfer(cw.rating, cl.rating, model.probabilities[winner.classFile][loser.classFile]);
        const local = (value, delta) => ({ ratingBefore: value.rating, ratingAfter: value.rating + delta, delta });
        projection.classProjection = { modelId: model.id, expectedWinner: adjustment.expectedWinner, matchupProbability: adjustment.matchupProbability,
          offsetElo: adjustment.offsetElo, winner: local(cw, adjustment.transfer), loser: local(cl, -adjustment.transfer) };
        cw.rating += adjustment.transfer; cl.rating -= adjustment.transfer; cw.modelId = cl.modelId = model.id;
      }
      winner.rating += transfer; loser.rating -= transfer; winner.wins++; loser.losses++;
      winner.lastPlayed = loser.lastPlayed = report.endedAt;
      run('UPDATE matches SET projection_json=? WHERE match_id=?', JSON.stringify(projection), row.match_id);
    }
    run('DELETE FROM ratings');
    for (const value of pools.values()) run('INSERT INTO ratings VALUES(?,?,?,?,?,?,?,?)', value.guid, value.bracket, value.maxLevel,
      JSON.stringify(publicIdentity(value)), value.rating, value.wins, value.losses, value.lastPlayed);
    run('DELETE FROM class_ratings');
    for (const value of classPools.values()) run('INSERT INTO class_ratings VALUES(?,?,?,?,?,?)', value.guid, 'MAX_LEVEL', value.maxLevel, value.rulesetId, value.rating, value.modelId);
  }

  function importReports(guid, body) {
    if (!isObject(body) || body.schemaVersion !== 2 || !isObject(body.player) || body.player.guid !== guid
      || !Array.isArray(body.matches) || body.matches.length > 200) fail('invalid_import');
    const records = body.matches.map((record) => validateRecord(record, guid));
    return transaction(() => {
      let accepted = 0, duplicates = 0;
      const results = [];
      for (const record of records) {
        const json = canonicalJSON(record), hash = sha256(json);
        const prior = get('SELECT body_hash FROM reports WHERE match_id=? AND reporter_guid=?', record.matchId, guid);
        if (prior) {
          if (prior.body_hash !== hash) throw new ApiError(409, 'immutable_report_conflict', `Existing report cannot be changed: ${record.matchId}`);
          duplicates++; results.push({ matchId: record.matchId, duplicate: true }); continue;
        }
        run('INSERT INTO reports VALUES(?,?,?,?,?)', record.matchId, guid, json, hash, new Date(now()).toISOString());
        const counterpart = get('SELECT body_json FROM reports WHERE match_id=? AND reporter_guid<>?', record.matchId, guid);
        let status = 'pending', canonical = record;
        if (counterpart) {
          const other = JSON.parse(counterpart.body_json);
          status = matchingReports(record, other) ? 'confirmed' : 'disputed';
          canonical = record.player.guid < other.player.guid ? record : other;
        }
        if (status === 'confirmed') for (const identity of [canonical.player, canonical.opponent]) {
          const lock = get('SELECT class_file FROM class_locks WHERE guid=?', identity.guid);
          if (lock && lock.class_file !== identity.classFile) throw new ApiError(409, 'guid_class_conflict', `Confirmed GUID class is immutable: ${identity.guid}`);
          run('INSERT OR IGNORE INTO class_locks VALUES(?,?)', identity.guid, identity.classFile);
        }
        const assignedModel = status === 'confirmed' && canonical.bracket === 'MAX_LEVEL' ? modelAt(rulesetId, canonical.player.maxLevel, canonical.endedAt) : null;
        run(`INSERT INTO matches(match_id,status,bracket,max_level,started_at,ended_at,projection_json,ruleset_id,class_model_id) VALUES(?,?,?,?,?,?,NULL,?,?) ON CONFLICT(match_id) DO UPDATE SET status=excluded.status,
          started_at=excluded.started_at,ended_at=excluded.ended_at,projection_json=NULL,class_model_id=excluded.class_model_id`, record.matchId, status, canonical.bracket,
        canonical.player.maxLevel, canonical.startedAt, canonical.endedAt, rulesetId, assignedModel?.id ?? null);
        accepted++; results.push({ matchId: record.matchId, duplicate: false });
      }
      if (accepted > 0) {
        recompute();
        run('INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', 'lastUpdated', new Date().toISOString());
      }
      for (const result of results) result.status = get('SELECT status FROM matches WHERE match_id=?', result.matchId).status;
      return { results, accepted, duplicates };
    });
  }

  function provision(identity) {
    const validated = validateIdentity(identity), token = randomBytes(32).toString('base64url');
    run(`INSERT INTO accounts VALUES(?,?,?,?) ON CONFLICT(guid) DO UPDATE SET identity_json=excluded.identity_json,
      token_hash=excluded.token_hash,provisioned_at=excluded.provisioned_at`, validated.guid, JSON.stringify(validated), sha256(token), new Date().toISOString());
    return token;
  }

  function authenticate(token) {
    if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/u.test(token)) throw new ApiError(401, 'unauthorized');
    const account = get('SELECT guid FROM accounts WHERE token_hash=?', sha256(token));
    if (!account) throw new ApiError(401, 'unauthorized');
    return account.guid;
  }
  function revoke(guid) { if (!validGuid(guid)) fail('invalid_guid'); return Number(run('UPDATE accounts SET token_hash=NULL WHERE guid=?', guid).changes); }
  function stats() {
    const counts = Object.fromEntries(query('SELECT status,COUNT(*) AS count FROM matches GROUP BY status').map((row) => [row.status, row.count]));
    return { players: get('SELECT COUNT(DISTINCT guid) AS count FROM ratings').count, confirmedMatches: counts.confirmed ?? 0,
      pendingMatches: counts.pending ?? 0, disputedMatches: counts.disputed ?? 0, lastUpdated: get("SELECT value FROM metadata WHERE key='lastUpdated'")?.value ?? null };
  }
  function ladder({ bracket = 'MAX_LEVEL', maxLevel = 60, search = '', classFile = '', realm = '', page = 1, limit = 20, ranking = 'OVERALL' } = {}) {
    if (!['OVERALL', 'CLASS'].includes(ranking)) fail('invalid_ranking');
    const model = modelStatus({ bracket, maxLevel });
    const adjusted = new Map(query('SELECT * FROM class_ratings WHERE bracket=? AND max_level=? AND ruleset_id=?', bracket, maxLevel, rulesetId).map((row) => [row.guid, row]));
    const ranked = query('SELECT * FROM ratings WHERE bracket=? AND max_level=? ORDER BY rating DESC,wins DESC,guid ASC', bracket, maxLevel)
      .map((row, index) => ({ rank: index + 1, overallRank: index + 1, ...JSON.parse(row.identity_json), bracket: row.bracket, rating: row.rating,
        overallRating: row.rating, classRating: adjusted.get(row.guid)?.rating ?? null, classRank: null, ranking,
        classRatingStatus: model.status === 'available' && !adjusted.has(row.guid) ? 'unsupported' : model.status, modelId: adjusted.get(row.guid)?.model_id ?? null,
        wins: row.wins, losses: row.losses, winRate: row.wins / (row.wins + row.losses) * 100, lastPlayed: row.last_played }));
    const lexical = (a, b) => a < b ? -1 : a > b ? 1 : 0;
    const classPosition = (value) => CLASS_ORDER.includes(value) ? CLASS_ORDER.indexOf(value) : CLASS_ORDER.length;
    const byClass = [...ranked].sort((a, b) => classPosition(a.classFile) - classPosition(b.classFile) || lexical(a.classFile, b.classFile)
      || (b.classRating ?? b.rating) - (a.classRating ?? a.rating) || b.wins - a.wins || lexical(a.guid, b.guid));
    let priorClass = '', classRank = 0;
    for (const item of byClass) { if (item.classFile !== priorClass) { priorClass = item.classFile; classRank = 0; } item.classRank = ++classRank; }
    if (ranking === 'CLASS') for (const item of ranked) item.rank = item.classRank;
    const needle = search.toLocaleLowerCase();
    const filtered = (ranking === 'CLASS' ? byClass : ranked).filter((row) => (!needle || `${row.name} ${row.realm}`.toLocaleLowerCase().includes(needle))
      && (!classFile || row.classFile === classFile) && (!realm || row.realm === realm));
    return { items: filtered.slice((page - 1) * limit, page * limit), total: filtered.length, page, limit, ranking, model, bracket, maxLevel };
  }
  function matches({ bracket = 'MAX_LEVEL', maxLevel = 60, page = 1, limit = 10, classFile = '' } = {}) {
    const condition = "status='confirmed' AND bracket=? AND max_level=? AND (?='' OR json_extract(projection_json,'$.winner.classFile')=? OR json_extract(projection_json,'$.loser.classFile')=?)";
    const args = [bracket, maxLevel, classFile, classFile, classFile];
    const total = get(`SELECT COUNT(*) AS count FROM matches WHERE ${condition}`, ...args).count;
    const items = query(`SELECT projection_json FROM matches WHERE ${condition} ORDER BY ended_at DESC,match_id ASC LIMIT ? OFFSET ?`, ...args, limit, (page - 1) * limit).map((row) => JSON.parse(row.projection_json));
    return { items, total, page, limit };
  }
  function player(guid, { bracket = 'MAX_LEVEL', maxLevel = 60, ranking = 'OVERALL' } = {}) {
    if (!validGuid(guid)) throw new ApiError(404, 'player_not_found');
    const playerItem = ladder({ bracket, maxLevel, ranking, limit: Number.MAX_SAFE_INTEGER }).items.find((item) => item.guid === guid);
    if (!playerItem) throw new ApiError(404, 'player_not_found');
    const ratings = query('SELECT bracket,max_level AS maxLevel,rating,wins,losses FROM ratings WHERE guid=? ORDER BY max_level,bracket', guid).map((row) => ({ ...row }));
    const chronological = query("SELECT m.projection_json FROM matches m JOIN reports r ON r.match_id=m.match_id WHERE m.status='confirmed' AND r.reporter_guid=? AND m.bracket=? AND m.max_level=? ORDER BY m.ended_at ASC,m.match_id ASC", guid, bracket, maxLevel).map((row) => JSON.parse(row.projection_json));
    const history = chronological.map((match) => {
      const won = match.winner.guid === guid, local = won ? match.winner : match.loser, opponent = won ? match.loser : match.winner;
      return { matchId: match.matchId, endedAt: match.endedAt, result: won ? 'WIN' : 'LOSS', opponent: { guid: opponent.guid, name: opponent.name, classFile: opponent.classFile },
        ratingBefore: local.ratingBefore, ratingAfter: local.ratingAfter, delta: local.delta };
    });
    const classHistory = chronological.filter((match) => match.classProjection).map((match) => {
      const won = match.winner.guid === guid, local = won ? match.classProjection.winner : match.classProjection.loser, opponent = won ? match.loser : match.winner;
      return { matchId: match.matchId, endedAt: match.endedAt, result: won ? 'WIN' : 'LOSS', opponent: { guid: opponent.guid, name: opponent.name, classFile: opponent.classFile },
        ...local, modelId: match.classProjection.modelId, expectedWin: won ? match.classProjection.expectedWinner : 1 - match.classProjection.expectedWinner,
        matchupProbability: won ? match.classProjection.matchupProbability : 1 - match.classProjection.matchupProbability,
        offsetElo: won ? match.classProjection.offsetElo : -match.classProjection.offsetElo };
    });
    return { player: playerItem, ratings, model: modelStatus({ bracket, maxLevel }), history: history.toReversed(), series: history.map((row) => ({ endedAt: row.endedAt, rating: row.ratingAfter, matchId: row.matchId })),
      classHistory: classHistory.toReversed(), classSeries: classHistory.map((row) => ({ endedAt: row.endedAt, rating: row.ratingAfter, matchId: row.matchId, modelId: row.modelId })) };
  }
  function canonicalMatches(maxLevel, dataCutoff = Number.MAX_SAFE_INTEGER) {
    return query("SELECT m.*,MAX(r.received_at) AS received_at FROM matches m JOIN reports r ON r.match_id=m.match_id WHERE m.status='confirmed' AND m.ruleset_id=? AND m.max_level=? GROUP BY m.match_id ORDER BY m.ended_at ASC,m.match_id ASC", rulesetId, maxLevel)
      .map((row) => {
        const report = JSON.parse(get('SELECT body_json FROM reports WHERE match_id=? ORDER BY reporter_guid LIMIT 1', row.match_id).body_json);
        const [a, b] = [report.player, report.opponent].sort((left, right) => left.guid < right.guid ? -1 : 1);
        const participant = (value) => ({ guid: value.guid, classFile: value.classFile, level: value.level });
        return { matchId: row.match_id, bracket: row.bracket, endedAt: row.ended_at, confirmedAt: Math.floor(Date.parse(row.received_at) / 1000),
          playerA: participant(a), playerB: participant(b), winnerGUID: report.winnerGUID };
      }).filter((match) => match.endedAt <= dataCutoff && match.confirmedAt <= dataCutoff);
  }
  function exportDataset({ maxLevel = 60, dataCutoff = Math.floor(now() / 1000) } = {}) {
    if (!integer(dataCutoff, 0, Math.floor(now() / 1000))) fail('invalid_data_cutoff');
    const model = modelAt(rulesetId, maxLevel, dataCutoff);
    if (!model) fail('unsupported_model');
    if (classAudit().conflicts.length) throw new ApiError(409, 'guid_class_audit_failed');
    const matches = canonicalMatches(maxLevel, dataCutoff).filter((match) => CLASS_SET.has(match.playerA.classFile) && CLASS_SET.has(match.playerB.classFile));
    const core = { rulesetId, maxLevel, dataCutoff, activeModelId: model.id, matches };
    const dataset = { schemaVersion: 1, rulesetId, maxLevel, generatedAt: new Date(now()).toISOString(), dataCutoff,
      datasetHash: digest(core), activeModel: { id: model.id, dataCutoff: model.dataCutoff, classOrder: CLASS_ORDER, probabilities: model.probabilities }, matches };
    const prior = get('SELECT body_json FROM dataset_exports WHERE dataset_hash=?', dataset.datasetHash);
    if (prior) return JSON.parse(prior.body_json);
    run('INSERT INTO dataset_exports VALUES(?,?,?)', dataset.datasetHash, stableJSON(dataset), new Date(now()).toISOString());
    return dataset;
  }
  function publishAnalysis(report) {
    const exported = typeof report?.datasetHash === 'string' && get('SELECT body_json FROM dataset_exports WHERE dataset_hash=?', report.datasetHash);
    if (!exported) fail('unknown_dataset_export');
    let normalized;
    try { normalized = validateAnalysis(report, JSON.parse(exported.body_json)); } catch (error) { throw new ApiError(400, 'invalid_analysis', error.message); }
    const hash = digest(normalized), prior = get('SELECT body_hash FROM matchup_analyses WHERE analysis_id=?', normalized.analysisId);
    if (prior && prior.body_hash !== hash) throw new ApiError(409, 'immutable_analysis_conflict');
    if (!prior) run('INSERT INTO matchup_analyses VALUES(?,?,?,?,?)', normalized.analysisId, normalized.datasetHash, stableJSON(normalized), hash, new Date(now()).toISOString());
    return { analysisId: normalized.analysisId, datasetHash: normalized.datasetHash, published: true, duplicate: Boolean(prior), activated: false };
  }
  function activateModel(candidate, { approve, effectiveFrom } = {}) {
    if (approve !== 'yes') fail('explicit_model_approval_required');
    if (!integer(effectiveFrom, Math.floor(now() / 1000) + 1, 253402300799)) fail('model_effective_date_must_be_future');
    return transaction(() => {
      const publication = typeof candidate?.analysisId === 'string' && get('SELECT body_json FROM matchup_analyses WHERE analysis_id=?', candidate.analysisId);
      if (!publication) fail('published_analysis_required');
      const report = JSON.parse(publication.body_json), exported = get('SELECT body_json FROM dataset_exports WHERE dataset_hash=?', report.datasetHash);
      const dataset = JSON.parse(exported.body_json), active = modelAt(rulesetId, candidate.maxLevel);
      if (!active || candidate.rulesetId !== rulesetId || dataset.activeModel.id !== active.id) throw new ApiError(409, 'stale_model_candidate');
      if (stableJSON(report.modelCandidate) !== stableJSON(candidate)) fail('candidate_must_match_published_analysis');
      try { validateCandidate(candidate, report, dataset); } catch (error) { throw new ApiError(400, 'invalid_model_candidate', error.message); }
      const latestEnded = get("SELECT MAX(ended_at) AS ended FROM matches WHERE status='confirmed' AND ruleset_id=? AND max_level=?", rulesetId, candidate.maxLevel).ended ?? 0;
      if (effectiveFrom <= candidate.dataCutoff || effectiveFrom <= latestEnded) fail('effective_date_overlaps_existing_history');
      if (get('SELECT id FROM class_models WHERE ruleset_id=? AND max_level=? AND effective_from>?', rulesetId, candidate.maxLevel, Math.floor(now() / 1000))) throw new ApiError(409, 'scheduled_model_exists');
      const model = validateModel({ ...candidate, classOrder: CLASS_ORDER, dataHash: candidate.datasetHash, effectiveFrom });
      if (get('SELECT id FROM class_models WHERE id=?', model.id)) throw new ApiError(409, 'immutable_model_conflict');
      run('INSERT INTO class_models VALUES(?,?,?,?,?,?,?)', model.id, rulesetId, model.maxLevel, effectiveFrom, stableJSON(model), digest(model), new Date(now()).toISOString());
      return { activated: true, scheduled: true, id: model.id, effectiveFrom, source: model.source, dataHash: model.dataHash };
    });
  }
  function classComparisons({ maxLevel = 60, requestedRuleset = rulesetId } = {}) {
    if (requestedRuleset !== rulesetId) fail('ruleset_mismatch');
    const model = modelStatus({ maxLevel }), matches = canonicalMatches(maxLevel, Math.floor(now() / 1000));
    function pairAggregates(selected) {
      const pairs = [];
      for (let i = 0; i < CLASS_ORDER.length; i++) for (let j = i + 1; j < CLASS_ORDER.length; j++) {
        const a = CLASS_ORDER[i], b = CLASS_ORDER[j], rows = selected.filter((match) => [match.playerA.classFile, match.playerB.classFile].includes(a) && [match.playerA.classFile, match.playerB.classFile].includes(b));
        const participantsA = new Set(), participantsB = new Set(), combinations = new Set(); let winsA = 0;
        for (const match of rows) {
          const pa = match.playerA.classFile === a ? match.playerA : match.playerB, pb = match.playerA.classFile === b ? match.playerA : match.playerB;
          participantsA.add(pa.guid); participantsB.add(pb.guid); combinations.add(`${pa.guid}:${pb.guid}`); if (match.winnerGUID === pa.guid) winsA++;
        }
        pairs.push({ classA: a, classB: b, baselineProbability: model.probabilities?.[a]?.[b] ?? null,
          observedWinRate: rows.length ? winsA / rows.length : null, rawMatches: rows.length, winsA, winsB: rows.length - winsA,
          sameLevelMatches: rows.filter((match) => match.playerA.level === match.playerB.level).length,
          uniqueA: participantsA.size, uniqueB: participantsB.size, uniquePairs: combinations.size });
      }
      return pairs;
    }
    const bands = (maxLevel === 60 ? BANDS : []).map((band) => {
      const selected = matches.filter((match) => match.playerA.level >= band.minLevel && match.playerA.level <= band.maxLevel && match.playerB.level >= band.minLevel && match.playerB.level <= band.maxLevel);
      return { ...band, counts: { matches: selected.length, sameLevelMatches: selected.filter((match) => match.playerA.level === match.playerB.level).length }, pairs: pairAggregates(selected) };
    });
    const latest = get("SELECT body_json FROM matchup_analyses WHERE json_extract(body_json,'$.rulesetId')=? AND json_extract(body_json,'$.maxLevel')=? ORDER BY published_at DESC,analysis_id DESC LIMIT 1", rulesetId, maxLevel);
    const report = latest ? JSON.parse(latest.body_json) : null;
    return { rulesetId, maxLevel, model, counts: { confirmedMatches: matches.length, sameLevelMatches: matches.filter((match) => match.playerA.level === match.playerB.level).length,
      excludedUnequalLevels: matches.filter((match) => match.playerA.level !== match.playerB.level).length,
      crossBandMatches: maxLevel === 60 ? matches.length - bands.reduce((sum, band) => sum + band.counts.matches, 0) : 0,
      sameClassMatches: matches.filter((match) => match.playerA.classFile === match.playerB.classFile).length }, overview: { pairs: pairAggregates(matches),
        sameClass: CLASS_ORDER.map((classFile) => {
          const rows = matches.filter((match) => match.playerA.classFile === classFile && match.playerB.classFile === classFile);
          return { classFile, rawMatches: rows.length, sameLevelMatches: rows.filter((match) => match.playerA.level === match.playerB.level).length,
            uniquePlayers: new Set(rows.flatMap((match) => [match.playerA.guid, match.playerB.guid])).size };
        }) }, bands, manualBaseline: rulesetId === BASELINE.rulesetId && maxLevel === BASELINE.maxLevel ? { id: BASELINE.id, source: 'manual', effectiveFrom: 0, dataHash: BASELINE.dataHash, probabilities: BASELINE.probabilities } : null,
      analysis: maxLevel === 60 && report && report.rulesetId === rulesetId && report.maxLevel === maxLevel ? { analysisId: report.analysisId, activeModelId: report.activeModelId,
        stale: report.activeModelId !== model.id, generatedAt: report.generatedAt, dataCutoff: report.dataCutoff, bands: report.bands, candidates: report.candidates, assumptions: report.assumptions } : null };
  }
  function models() { return { rulesetId, models: query('SELECT body_json,body_hash AS bodyHash FROM class_models WHERE ruleset_id=? ORDER BY effective_from', rulesetId).map((row) => ({ ...JSON.parse(row.body_json), bodyHash: row.bodyHash })), audit: { conflicts: classAudit().conflicts } }; }
  function linkCharacter(value) {
    let mapping;
    try { mapping = validateMapping(value); } catch (error) { throw new ApiError(400, 'invalid_character_mapping', error.message); }
    if (!get('SELECT guid FROM accounts WHERE guid=?', mapping.guid) && !get('SELECT guid FROM ratings WHERE guid=? LIMIT 1', mapping.guid)) throw new ApiError(404, 'player_not_found');
    run('INSERT INTO character_mappings VALUES(?,?,?) ON CONFLICT(guid) DO UPDATE SET mapping_json=excluded.mapping_json,linked_at=excluded.linked_at', mapping.guid, JSON.stringify(mapping), new Date().toISOString());
    return mapping;
  }
  function characterMapping(guid) { const row = get('SELECT mapping_json FROM character_mappings WHERE guid=?', guid); return row ? JSON.parse(row.mapping_json) : null; }
  function unlinkCharacter(guid) { if (!validGuid(guid)) fail('invalid_guid'); return Number(run('DELETE FROM character_mappings WHERE guid=?', guid).changes); }
  return { db, path, demo, rulesetId, close: () => db.close(), importReports, provision, authenticate, revoke, stats, ladder, matches, player, linkCharacter, characterMapping, unlinkCharacter,
    modelStatus, classComparisons, exportDataset, publishAnalysis, activateModel, models };
}
