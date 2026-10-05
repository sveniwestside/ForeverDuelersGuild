import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createBlizzardClient, validateMapping } from './blizzard.mjs';
import { createStore } from './store.mjs';
import { createServer } from './server.mjs';
import { manage } from './manage.mjs';
import { makeReportPair } from './demo-data.mjs';

const player = { guid: 'Player-1-AAAA', name: 'Gala Nightwind', realm: 'Forever', classFile: 'MAGE', level: 60, maxLevel: 60 };
const peer = { ...player, guid: 'Player-1-BBBB', name: 'Other', classFile: 'WARRIOR' };
const mapping = { guid: player.guid, region: 'eu', namespace: 'profile-eu', realmSlug: 'silvermoon', characterName: 'Gala Nightwind', realmId: 3391, characterId: 123456 };
const env = { BLIZZARD_GAME: 'retail', BLIZZARD_CLIENT_ID: 'fake-test-client', BLIZZARD_CLIENT_SECRET: 'fake-test-secret', BLIZZARD_LOCALE: 'de_DE' };
const summary = { id: 123456, name: 'Gala Nightwind', level: 80, realm: { id: 3391, slug: 'silvermoon', name: 'Silvermoon' },
  race: { name: 'Human' }, character_class: { id: 8, name: 'Mage' }, faction: { name: 'Alliance' }, guild: { name: 'Test Guild' },
  active_spec: { name: 'Frost' }, equipped_item_level: 615, secretField: 'must not escape' };
const reference = { id: 123456, realm: { id: 3391 } };
const media = { character: reference, assets: [
  { key: 'avatar', value: 'https://render.worldofwarcraft.com/eu/character/avatar.jpg' },
  { key: 'main', value: 'https://render-eu.worldofwarcraft.com/character/main.png' },
] };
const equipment = { character: reference, equipped_items: [{ item: { id: 123 }, name: 'Test robe', slot: { name: 'Chest' }, quality: { name: 'Epic' }, level: { value: 615 }, secretField: 'omit' }] };
const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
function upstream({ changeSummary, changeMedia, failSummary = false, failExtras = false, expire = 3600, unauthorizedOnce = false } = {}) {
  const calls = []; let tokens = 0, summaryCalls = 0;
  const fetchImpl = async (urlValue, init) => {
    const url = new URL(urlValue); calls.push({ url: url.href, init });
    assert.equal(init.redirect, 'error'); assert.ok(init.signal);
    if (url.hostname === 'oauth.battle.net') {
      assert.equal(url.href, 'https://oauth.battle.net/token'); assert.equal(init.method, 'POST');
      assert.equal(init.body, 'grant_type=client_credentials'); assert.ok(init.headers.Authorization.startsWith('Basic '));
      return json({ access_token: `fake-token-${++tokens}`, token_type: 'bearer', expires_in: expire });
    }
    assert.equal(url.hostname, 'eu.api.blizzard.com');
    assert.equal(url.searchParams.get('locale'), 'de_DE'); assert.equal(url.searchParams.get('namespace'), 'profile-eu');
    assert.equal(url.searchParams.has('access_token'), false); assert.ok(init.headers.Authorization.startsWith('Bearer '));
    assert.ok(url.pathname.includes('gala%20nightwind'));
    if (url.pathname.endsWith('/character-media')) return failExtras ? json({}, 404) : json(changeMedia ? changeMedia(structuredClone(media)) : media);
    if (url.pathname.endsWith('/equipment')) return failExtras ? json({}, 404) : json(equipment);
    summaryCalls++;
    if (unauthorizedOnce && summaryCalls === 1) return json({}, 401);
    if (failSummary) return json({ error: 'ignored upstream response' }, 503);
    return json(changeSummary ? changeSummary(structuredClone(summary)) : summary);
  };
  return { fetchImpl, calls, tokens: () => tokens };
}

test('Forever is unverified and makes no requests; missing credentials and missing mappings are explicit', async () => {
  const unexpected = async () => { throw new Error('Unexpected network request'); };
  const forever = createBlizzardClient({ env: {}, fetchImpl: unexpected });
  assert.equal(forever.status().status, 'unsupported'); assert.equal(forever.status().configured, false);
  const result = await forever.character(mapping, player); assert.equal(result.reason, 'forever_not_documented'); assert.equal(result.armoryUrl, null);
  const missing = createBlizzardClient({ env: { BLIZZARD_GAME: 'retail' }, fetchImpl: unexpected });
  assert.equal((await missing.character(mapping, player)).status, 'not_configured');
  const configured = createBlizzardClient({ env, fetchImpl: unexpected });
  assert.equal(configured.status().status, 'configured'); assert.equal((await configured.character(null, player)).reason, 'unmapped');
  const publicStatus = JSON.stringify(configured.status()); assert.equal(publicStatus.includes(env.BLIZZARD_CLIENT_ID), false); assert.equal(publicStatus.includes(env.BLIZZARD_CLIENT_SECRET), false);
});

test('verified character uses full explicit name, sanitized media/equipment and finite cached summaries', async () => {
  let clock = 100000;
  const mock = upstream(), client = createBlizzardClient({ env, fetchImpl: mock.fetchImpl, now: () => clock });
  const result = await client.character(mapping, player);
  assert.equal(result.status, 'available'); assert.equal(result.summary.classFile, 'MAGE'); assert.equal(result.summary.game, 'retail');
  assert.equal(result.armoryUrl, 'https://worldofwarcraft.blizzard.com/en-us/character/eu/silvermoon/gala%20nightwind');
  assert.equal(result.media.avatar, media.assets[0].value); assert.equal(result.equipment.length, 1);
  assert.equal(result.summary.secretField, undefined); assert.equal(result.equipment[0].secretField, undefined);
  assert.equal(mock.calls.length, 4); result.summary.name = 'Mutated';
  assert.equal((await client.character(mapping, player)).summary.name, 'Gala Nightwind'); assert.equal(mock.calls.length, 4);
  clock += 300001; await client.character(mapping, player); assert.equal(mock.calls.length, 7);
});

test('tokens refresh after expiry and once after unauthorized; concurrent loads deduplicate', async () => {
  let clock = 100000;
  const mock = upstream({ expire: 60 }), client = createBlizzardClient({ env, fetchImpl: mock.fetchImpl, now: () => clock, ttlMs: 1000 });
  await Promise.all([client.character(mapping, player), client.character(mapping, player)]); assert.equal(mock.tokens(), 1); assert.equal(mock.calls.length, 4);
  clock += 31000; await client.character(mapping, player); assert.equal(mock.tokens(), 2);
  const unauthorized = upstream({ unauthorizedOnce: true }), retrying = createBlizzardClient({ env, fetchImpl: unauthorized.fetchImpl });
  assert.equal((await retrying.character(mapping, player)).status, 'available'); assert.equal(unauthorized.tokens(), 2);
});

test('API and Armory names use lowercase NFC while preserving full explicit mapped identity', async () => {
  const fullName = 'A\u0308loria Nightwind';
  const selected = { ...mapping, characterName: fullName };
  const paths = [];
  const client = createBlizzardClient({ env, fetchImpl: async (urlValue) => {
    const url = new URL(urlValue);
    if (url.hostname === 'oauth.battle.net') return json({ access_token: 'fake-token', token_type: 'bearer', expires_in: 3600 });
    paths.push(url.pathname);
    assert.ok(url.pathname.includes('/silvermoon/%C3%A4loria%20nightwind'));
    if (url.pathname.endsWith('/character-media')) return json(media);
    if (url.pathname.endsWith('/equipment')) return json(equipment);
    return json({ ...summary, name: '\u00c4loria Nightwind' });
  } });
  const result = await client.character(selected, player);
  assert.equal(result.status, 'available');
  assert.equal(paths.length, 3);
  assert.equal(selected.characterName, fullName);
  assert.equal(result.summary.name, '\u00c4loria Nightwind');
  assert.equal(result.armoryUrl, 'https://worldofwarcraft.blizzard.com/en-us/character/eu/silvermoon/%C3%A4loria%20nightwind');
});

test('upstream failures have finite negative cache; optional failures preserve validated summary', async () => {
  let clock = 100000;
  const mock = upstream({ failSummary: true }), client = createBlizzardClient({ env, fetchImpl: mock.fetchImpl, now: () => clock });
  assert.equal((await client.character(mapping, player)).reason, 'upstream_unavailable'); assert.equal(mock.calls.length, 2);
  await client.character(mapping, player); assert.equal(mock.calls.length, 2);
  clock += 30001; await client.character(mapping, player); assert.equal(mock.calls.length, 3);
  const optional = upstream({ failExtras: true }), partial = createBlizzardClient({ env, fetchImpl: optional.fetchImpl });
  const result = await partial.character(mapping, player); assert.equal(result.status, 'available'); assert.equal(result.media, null); assert.deepEqual(result.equipment, []);
});

test('OAuth failure is bounded across different mappings and retries after its negative cache', async () => {
  let clock = 100000, tokenCalls = 0;
  const client = createBlizzardClient({ env, now: () => clock, fetchImpl: async (url) => {
    assert.equal(new URL(url).href, 'https://oauth.battle.net/token'); tokenCalls++;
    return json({ error: 'invalid_client', secret: 'must not escape' }, 401);
  } });
  const result = await client.character(mapping, player); assert.equal(result.reason, 'upstream_unavailable');
  assert.equal(JSON.stringify(result).includes('invalid_client'), false);
  const another = { ...mapping, characterName: 'Other' };
  await client.character(another, player); assert.equal(tokenCalls, 1);
  clock += 30001; await client.character(mapping, player); assert.equal(tokenCalls, 2);
});

test('oversized upstream JSON is refused and unvalidated body URLs are never followed', async () => {
  let requests = 0;
  const client = createBlizzardClient({ env, fetchImpl: async (url) => {
    requests++;
    if (new URL(url).hostname === 'oauth.battle.net') return json({ access_token: 'fake-token', token_type: 'bearer', expires_in: 3600 });
    return new Response(JSON.stringify({ ...summary, _links: { self: { href: 'https://evil.example/ssrf' } } }), {
      status: 200, headers: { 'Content-Length': String(3 * 1024 * 1024), 'Content-Type': 'application/json' } });
  } });
  assert.equal((await client.character(mapping, player)).reason, 'upstream_unavailable'); assert.equal(requests, 2);
});

test('wrong numeric identity, realm, full name or class cannot produce enrichment or Armory', async () => {
  for (const changeSummary of [
    (r) => ({ ...r, id: 987 }), (r) => ({ ...r, realm: { ...r.realm, id: 987 } }),
    (r) => ({ ...r, realm: { ...r.realm, slug: 'wrong' } }), (r) => ({ ...r, name: 'Gala' }),
    (r) => ({ ...r, character_class: { id: 1, name: 'Warrior' } }),
  ]) {
    const mock = upstream({ changeSummary }), client = createBlizzardClient({ env, fetchImpl: mock.fetchImpl });
    const result = await client.character(mapping, player); assert.equal(result.reason, 'identity_mismatch');
    assert.equal(result.armoryUrl, null); assert.equal(result.summary, null); assert.equal(mock.calls.length, 2);
  }
});

test('media URL exact host allowlist rejects credentials, redirects and untrusted origins', async () => {
  for (const value of ['https://evil.example/avatar.jpg', 'http://render.worldofwarcraft.com/avatar.jpg',
    'https://render.worldofwarcraft.com.evil.example/avatar.jpg', 'https://user:secret@render.worldofwarcraft.com/avatar.jpg',
    'https://render.worldofwarcraft.com:8443/avatar.jpg', 'https://render.worldofwarcraft.com/avatar.svg',
    'https://render.worldofwarcraft.com/avatar.jpg?token=secret', 'javascript:alert(1)', 'https://127.0.0.1/avatar.jpg']) {
    const mock = upstream({ changeMedia: (r) => ({ ...r, assets: [{ key: 'avatar', value }] }) });
    const result = await createBlizzardClient({ env, fetchImpl: mock.fetchImpl }).character(mapping, player);
    assert.equal(result.status, 'available'); assert.equal(result.media, null);
  }
  const wrongCharacter = upstream({ changeMedia: (r) => ({ ...r, character: { ...r.character, id: 987 } }) });
  assert.equal((await createBlizzardClient({ env, fetchImpl: wrongCharacter.fetchImpl }).character(mapping, player)).media, null);
});

test('explicit mappings require numeric API IDs and prevent arbitrary upstream route inputs', async () => {
  for (const changed of [
    { ...mapping, realmId: undefined }, { ...mapping, characterId: undefined }, { ...mapping, region: 'cn' },
    { ...mapping, namespace: 'profile-us' }, { ...mapping, namespace: 'profile-forever-eu' },
    { ...mapping, realmSlug: '../../other' }, { ...mapping, realmSlug: 'https://evil.example' },
    { ...mapping, characterName: 'Gala?access_token=x' }, { ...mapping, characterName: '../user' },
    { ...mapping, characterId: Number.MAX_SAFE_INTEGER + 1 },
  ]) assert.throws(() => validateMapping(changed));
  // Explicit API realm and character IDs are neither inferred nor overridden by native GUID segments.
  assert.equal(validateMapping(mapping).realmId, 3391); assert.equal(validateMapping(mapping).characterId, 123456);
  const client = createBlizzardClient({ env, fetchImpl: async () => { throw new Error('Unexpected call'); } });
  assert.equal((await client.character({ ...mapping, namespace: 'profile-us' }, player)).reason, 'invalid_mapping');
  assert.equal((await client.character({ ...mapping, namespace: 'profile-classic-eu' }, player)).reason, 'mapping_game_mismatch');
});

test('Classic mapped responses can enrich but never produce a retail Armory URL', async () => {
  for (const [game, namespace] of [['classic', 'profile-classic-eu'], ['classic-era', 'profile-classic1x-eu']]) {
    const mock = upstream();
    const fetchImpl = (url, init) => {
      const adjusted = new URL(url);
      if (adjusted.hostname !== 'oauth.battle.net') adjusted.searchParams.set('namespace', 'profile-eu');
      return mock.fetchImpl(adjusted, init);
    };
    const result = await createBlizzardClient({ env: { ...env, BLIZZARD_GAME: game }, fetchImpl }).character({ ...mapping, namespace }, player);
    assert.equal(result.status, 'available'); assert.equal(result.summary.game, game); assert.equal(result.armoryUrl, null);
  }
});

test('linking is administrator CLI only; persisted mappings do not change ratings or public player identity', async () => {
  const store = createStore(), output = [];
  const pair = makeReportPair(player, peer);
  for (const record of pair) store.importReports(record.player.guid, { schemaVersion: 2, player: { guid: record.player.guid }, matches: [record] });
  const before = store.player(player.guid);
  manage(['link-character', '--guid', player.guid, '--region', 'eu', '--namespace', 'profile-eu', '--realmSlug', 'silvermoon',
    '--characterName', 'Gala Nightwind', '--realmId', '3391', '--characterId', '123456'], { store, output: (value) => output.push(value) });
  assert.equal(store.characterMapping(player.guid).characterName, 'Gala Nightwind'); assert.equal(output.length, 1);
  assert.deepEqual(store.player(player.guid), before);
  const mock = upstream(), blizzard = createBlizzardClient({ env, fetchImpl: mock.fetchImpl }), server = createServer({ store, blizzard });
  server.listen(0, '127.0.0.1'); await once(server, 'listening'); const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const profile = await (await fetch(`${base}/api/v1/players/${player.guid}`)).json();
    assert.equal(profile.character.status, 'available'); assert.equal(profile.player.realm, 'Forever'); assert.equal(profile.player.rating, 1516);
    assert.equal((await fetch(`${base}/api/v1/characters/link`, { method: 'POST' })).status, 405);
    const status = await (await fetch(`${base}/api/v1/integrations/blizzard`)).json(); assert.equal(status.status, 'configured');
    assert.equal(JSON.stringify(status).includes(env.BLIZZARD_CLIENT_SECRET), false);
    manage(['unlink-character', '--guid', player.guid], { store, output: () => {} }); assert.equal(store.characterMapping(player.guid), null);
  } finally { await new Promise((done) => server.close(done)); store.close(); }
});
