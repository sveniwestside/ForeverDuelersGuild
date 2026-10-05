import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createStore, ApiError } from './store.mjs';
import { createServer } from './server.mjs';
import { makeReportPair, seedDemo } from './demo-data.mjs';

const a = { guid: 'Player-1-AAAA', name: 'Aloria', realm: 'Forever', classFile: 'MAGE', level: 60, maxLevel: 60 };
const b = { guid: 'Player-1-BBBB', name: 'Tharok', realm: 'Forever', classFile: 'WARRIOR', level: 60, maxLevel: 60 };
const upload = (store, record) => store.importReports(record.player.guid, { schemaVersion: 2, player: { guid: record.player.guid }, matches: [record] });
const rejected = (callback, status) => assert.throws(callback, (error) => error instanceof ApiError && error.status === status);

test('bilateral reports count once and local snapshots never become canonical authority', () => {
  const store = createStore();
  try {
    const [left, right] = makeReportPair(a, b, { ratingA: 2800, ratingB: 1000 });
    assert.equal(upload(store, left).results[0].status, 'pending');
    assert.equal(store.stats().players, 0);
    rejected(() => store.player(a.guid), 404);
    assert.equal(upload(store, right).results[0].status, 'confirmed');
    assert.equal(store.ladder().items[0].rating, 1516);
    assert.equal(store.ladder().items[1].rating, 1484);
    assert.deepEqual(upload(store, left), { results: [{ matchId: left.matchId, status: 'confirmed', duplicate: true }], accepted: 0, duplicates: 1 });
    const reordered = { ...left, player: { ...left.player, specId: 63, fullName: 'Aloria-Forever' }, ignoredAddonMetadata: 'ignored' };
    assert.equal(upload(store, reordered).duplicates, 1);
    assert.equal(store.stats().confirmedMatches, 1);
    const profile = store.player(a.guid);
    assert.equal(profile.history[0].delta, 16);
    assert.equal(profile.series[0].rating, 1516);
  } finally { store.close(); }
});

test('mismatched counterpart is disputed and cannot publish player profiles', () => {
  for (const change of [
    (r) => { r.opponent.name = 'Wrong'; }, (r) => { r.player.realm = 'Wrong'; },
    (r) => { r.endedAt += 11; }, (r) => { r.player.classFile = 'ROGUE'; },
  ]) {
    const store = createStore();
    try {
      const [left, right] = makeReportPair(a, b); change(right);
      upload(store, left); assert.equal(upload(store, right).results[0].status, 'disputed');
      assert.equal(store.stats().disputedMatches, 1);
      assert.equal(store.ladder().total, 0); assert.equal(store.matches().total, 0);
    } finally { store.close(); }
  }
});

test('timestamp tolerance and canonical chronological replay ignore upload ordering', () => {
  const store = createStore(), ordered = createStore();
  try {
    const earlier = makeReportPair(a, b, { index: 1, winnerGuid: a.guid });
    const later = makeReportPair(a, b, { index: 2, winnerGuid: b.guid });
    later[1].endedAt += 10; later[1].startedAt += 10;
    for (const report of [...later.toReversed(), ...earlier.toReversed()]) upload(store, report);
    for (const report of [...earlier, ...later]) upload(ordered, report);
    assert.deepEqual(store.matches(), ordered.matches());
    assert.deepEqual(store.ladder(), ordered.ladder());
    assert.equal(store.ladder().items.find((p) => p.guid === a.guid).rating, 1499);
    assert.equal(store.player(a.guid).history[0].matchId, later[0].matchId);
  } finally { store.close(); ordered.close(); }
});

test('equal timestamp replay uses match ID; pools remain separated by bracket and cap', () => {
  const store = createStore();
  try {
    const pairs = [makeReportPair(a, b), makeReportPair({ ...a, maxLevel: 80 }, { ...b, level: 58, maxLevel: 80 }, { index: 2 }),
      makeReportPair({ ...a, level: 80, maxLevel: 80 }, { ...b, level: 80, maxLevel: 80 }, { index: 3 })];
    for (const pair of pairs) for (const report of pair) upload(store, report);
    assert.equal(store.ladder({ bracket: 'MAX_LEVEL', maxLevel: 60 }).items[0].rating, 1516);
    assert.equal(store.ladder({ bracket: 'MAX_LEVEL', maxLevel: 80 }).items[0].rating, 1516);
    assert.equal(store.ladder({ bracket: 'LEVELING', maxLevel: 80 }).items[0].rating, 1514);
    assert.equal(store.player(a.guid).ratings.length, 3);
  } finally { store.close(); }
});

test('same-time matches replay by match ID and all mirrored snapshots must agree', () => {
  const ordered = createStore(), reversed = createStore(), disputed = createStore();
  try {
    const first = makeReportPair(a, b, { index: 1, endedAt: 1791101000 });
    const second = makeReportPair(a, b, { index: 2, endedAt: 1791101000, winnerGuid: b.guid });
    for (const report of [...first, ...second]) upload(ordered, report);
    for (const report of [...second.toReversed(), ...first.toReversed()]) upload(reversed, report);
    assert.deepEqual(ordered.ladder(), reversed.ladder());
    assert.deepEqual(ordered.matches(), reversed.matches());
    upload(disputed, first[0]);
    const differentSnapshot = makeReportPair(a, b, { index: 1, endedAt: 1791101000, ratingA: 1600, ratingB: 1400 })[1];
    assert.equal(upload(disputed, differentSnapshot).results[0].status, 'disputed');
    assert.equal(disputed.stats().players, 0);
  } finally { ordered.close(); reversed.close(); disputed.close(); }
});

test('0.6 records (protocol 3, FD3 match IDs) import like 0.5 records', () => {
  const store = createStore();
  try {
    const [left, right] = makeReportPair(a, b, { protocolVersion: 3 });
    assert.ok(left.matchId.startsWith('FD3:'));
    assert.equal(upload(store, left).results[0].status, 'pending');
    assert.equal(upload(store, right).results[0].status, 'confirmed');
    for (const change of [(r) => { r.matchId = r.matchId.replace(/^FD3:/u, 'FD2:'); }, (r) => { r.protocolVersion = 4; },
      (r) => { r.protocolVersion = '3'; }]) {
      const record = makeReportPair(a, b, { protocolVersion: 3, index: 2 })[0]; change(record); rejected(() => upload(store, record), 400);
    }
  } finally { store.close(); }
});

test('client evidence, versions, match identity and eligible levels are required', () => {
  const store = createStore();
  try {
    for (const change of [
      (r) => { r.evidence.peerResult = false; }, (r) => { r.ratedConfirmed = false; },
      (r) => { r.schemaVersion = 1; }, (r) => { r.protocolVersion = 1; },
      (r) => { r.matchId = 'arbitrary'; }, (r) => { r.opponent.maxLevel = 80; },
      (r) => { r.player.level = 50; }, (r) => { r.winnerGUID = r.loserGUID; },
      (r) => { r.endedAt = r.startedAt - 1; }, (r) => { r.player.classFile = 'UNRECOGNIZED'; },
    ]) {
      const record = makeReportPair(a, b)[0]; change(record); rejected(() => upload(store, record), 400);
    }
    assert.equal(store.stats().pendingMatches, 0);
  } finally { store.close(); }
});

test('full upload validation and immutable conflicts roll back the entire batch', () => {
  const store = createStore();
  try {
    const first = makeReportPair(a, b)[0], second = makeReportPair(a, b, { index: 2 })[0];
    const invalid = structuredClone(second); invalid.ratingDelta++;
    rejected(() => store.importReports(a.guid, { schemaVersion: 2, player: { guid: a.guid }, matches: [first, invalid] }), 400);
    assert.equal(store.stats().pendingMatches, 0);
    upload(store, first);
    const changed = structuredClone(first); changed.player.name = 'Changed';
    rejected(() => store.importReports(a.guid, { schemaVersion: 2, player: { guid: a.guid }, matches: [second, changed] }), 409);
    assert.equal(store.stats().pendingMatches, 1);
    rejected(() => store.importReports(b.guid, { schemaVersion: 2, player: { guid: b.guid }, matches: [first] }), 400);
    rejected(() => store.importReports(a.guid, { schemaVersion: 2, player: { guid: a.guid }, matches: Array(201).fill(first) }), 400);
  } finally { store.close(); }
});

test('tokens are hashed, character bound, rotated, revoked, and survive restart', () => {
  const directory = mkdtempSync(join(tmpdir(), 'foreverduel-test-')), path = join(directory, 'store.sqlite');
  let store = createStore({ path });
  try {
    const token = store.provision(a); assert.equal(token.length, 43);
    assert.equal(store.authenticate(token), a.guid);
    assert.notEqual(store.db.prepare('SELECT token_hash FROM accounts').get().token_hash, token);
    store.close(); store = createStore({ path }); assert.equal(store.authenticate(token), a.guid);
    const rotated = store.provision(a); rejected(() => store.authenticate(token), 401);
    assert.equal(store.authenticate(rotated), a.guid);
    assert.equal(store.revoke(a.guid), 1); rejected(() => store.authenticate(rotated), 401);
    const pair = makeReportPair(a, b); for (const report of pair) upload(store, report);
    store.close(); store = createStore({ path }); assert.equal(store.stats().confirmedMatches, 1);
    assert.equal(store.ladder().items[0].rating, 1516);
    assert.equal(readFileSync(path).includes(Buffer.from(token)), false);
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});

test('HTTP API protects uploads, validates queries, returns JSON errors and security headers', async () => {
  const store = createStore(), token = store.provision(a), tokenB = store.provision(b), server = createServer({ store });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (body, bearer = token, headers = {}) => fetch(`${base}/api/v1/import`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${bearer}`, ...headers }, body: JSON.stringify(body) });
  try {
    const config = await fetch(`${base}/api/v1/config`); assert.equal(config.status, 200);
    const configBody = await config.json(); assert.equal(configBody.demo, false);
    const toc = readFileSync(new URL('../../ForeverDuel/ForeverDuel.toc', import.meta.url), 'utf8');
    assert.equal(configBody.addonVersion, toc.match(/^## Version:\s*(\S+)/mu)[1], 'the site advertises the addon version of this repository');
    assert.ok(config.headers.get('content-security-policy').includes("script-src 'self'"));
    assert.equal(config.headers.get('access-control-allow-origin'), null);
    assert.deepEqual(await (await fetch(`${base}/health`)).json(), { status: 'ok' });
    assert.equal((await fetch(`${base}/api/v1/ladder?limit=101`)).status, 400);
    assert.equal((await fetch(`${base}/api/v1/ladder?bracket=LEGACY`)).status, 400);
    assert.equal((await fetch(`${base}/api/v1/me`)).status, 401);
    assert.deepEqual(await (await fetch(`${base}/api/v1/me`, { headers: { Authorization: `Bearer ${token}` } })).json(), { guid: a.guid });
    const pair = makeReportPair(a, b), payload = (r) => ({ schemaVersion: 2, player: { guid: r.player.guid }, matches: [r] });
    assert.equal((await post(payload(pair[0]), 'wrong')).status, 401);
    assert.equal((await post(payload(pair[0]), token, { Origin: 'https://evil.example' })).status, 403);
    assert.equal((await post(payload(pair[0]), token, { 'Content-Type': 'text/plain' })).status, 415);
    assert.equal((await post(payload(pair[1]), token)).status, 400);
    assert.equal((await post(payload(pair[0]))).status, 200);
    assert.equal((await post(payload(pair[1]), tokenB)).status, 200);
    assert.equal((await (await fetch(`${base}/api/v1/ladder`)).json()).items.length, 2);
    assert.equal((await (await fetch(`${base}/api/v1/players/${a.guid}`)).json()).history.length, 1);
    assert.equal((await fetch(`${base}/api/v1/matches?page=0`)).status, 400);
    assert.equal((await fetch(`${base}/%2e%2e%2fserver%2fstore.mjs`)).status, 404);
    assert.equal((await fetch(`${base}/.env`)).status, 404);
    const unknown = await fetch(`${base}/api/missing`); assert.equal(unknown.status, 404); assert.ok((await unknown.json()).error.code);
  } finally { await new Promise((done) => server.close(done)); store.close(); }
});

test('demo seed is explicit, separated and idempotent', () => {
  const live = createStore(), demo = createStore({ demo: true });
  try {
    assert.throws(() => seedDemo(live)); seedDemo(demo); const count = demo.stats().confirmedMatches; seedDemo(demo);
    assert.equal(demo.stats().confirmedMatches, count); assert.equal(count, 46);
    assert.equal(live.stats().players, 0);
    assert.ok(demo.ladder().items.every((p) => p.name.startsWith('Demo ') && p.realm === 'Demo Realm'));
  } finally { live.close(); demo.close(); }
});
