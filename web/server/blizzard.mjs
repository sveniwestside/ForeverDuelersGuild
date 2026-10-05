// Public character enrichment only. This adapter never authenticates a WoW owner
// and never supplies rating authority. Forever support has not been verified.
export const REGIONS = new Set(['eu', 'us', 'kr', 'tw']);
export const MEDIA_HOSTS = new Set(['render.worldofwarcraft.com', ...[...REGIONS].map((region) => `render-${region}.worldofwarcraft.com`)]);
const LOCALES = new Set(['de_DE', 'en_US', 'en_GB', 'fr_FR', 'es_ES', 'es_MX', 'it_IT', 'pt_BR', 'pt_PT', 'ru_RU', 'ko_KR', 'zh_TW']);
const CLASS_IDS = { 1: 'WARRIOR', 2: 'PALADIN', 3: 'HUNTER', 4: 'ROGUE', 5: 'PRIEST', 6: 'DEATHKNIGHT', 7: 'SHAMAN', 8: 'MAGE', 9: 'WARLOCK', 10: 'MONK', 11: 'DRUID', 12: 'DEMONHUNTER', 13: 'EVOKER' };
const integer = (value) => Number.isSafeInteger(value) && value > 0;
const clean = (value, max = 128) => typeof value === 'string' && value.length <= max && !/[\u0000-\u001f\u007f]/u.test(value) ? value : null;
const nameKey = (value) => typeof value === 'string' ? value.normalize('NFC').toLocaleLowerCase('en-US') : null;
const namespaceGame = (namespace, region) => namespace === `profile-${region}` ? 'retail'
  : namespace === `profile-classic-${region}` ? 'classic' : namespace === `profile-classic1x-${region}` ? 'classic-era' : null;

export function validateMapping(value) {
  if (!value || typeof value !== 'object' || !REGIONS.has(value.region)) throw new Error('Region must be eu, us, kr or tw');
  const guid = /^Player-([0-9a-fA-F]+)-([0-9a-fA-F]+)$/u.exec(value.guid ?? '');
  if (!guid || value.guid.length > 64) throw new Error('Invalid character GUID');
  const game = namespaceGame(value.namespace, value.region);
  if (!game) throw new Error('Namespace must be an explicit supported profile namespace for the selected region; Forever has no verified namespace');
  // The operator supplies API route segments. No name/surname or realm slug inference.
  if (!clean(value.realmSlug, 96) || !/^[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*$/u.test(value.realmSlug)) throw new Error('Invalid explicit API realm slug');
  if (!clean(value.characterName, 96) || !/^[\p{L}\p{M}]+(?:[ '\u2019-][\p{L}\p{M}]+)*$/u.test(value.characterName)) throw new Error('Invalid explicit full API character name');
  // Native GUID segments are not documented as API IDs for Forever. Both API
  // IDs must therefore be provided explicitly; neither is derived from a GUID.
  const characterId = value.characterId, realmId = value.realmId;
  if (!integer(characterId) || !integer(realmId)) throw new Error('Safe numeric realmId and characterId are required');
  return { guid: value.guid, region: value.region, namespace: value.namespace, game,
    realmSlug: value.realmSlug, characterName: value.characterName, realmId, characterId };
}

function safeMedia(value) {
  if (typeof value !== 'string' || value.length > 1024) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || !MEDIA_HOSTS.has(url.hostname) || url.username || url.password || url.port || url.search || url.hash) return null;
    if (!/\.(?:png|jpe?g|webp)$/iu.test(url.pathname)) return null;
    return url.href;
  } catch { return null; }
}
function absent(status, reason) { return { status, source: 'blizzard', reason, summary: null, armoryUrl: null, media: null, equipment: [] }; }

export function createBlizzardClient({ env = process.env, fetchImpl = globalThis.fetch, now = Date.now, ttlMs = 300000, failureTtlMs = 30000 } = {}) {
  const game = ['forever', 'retail', 'classic', 'classic-era'].includes(env.BLIZZARD_GAME) ? env.BLIZZARD_GAME : 'forever';
  const clientId = env.BLIZZARD_CLIENT_ID, clientSecret = env.BLIZZARD_CLIENT_SECRET;
  const configured = typeof clientId === 'string' && clientId.length > 0 && typeof clientSecret === 'string' && clientSecret.length > 0;
  const locale = LOCALES.has(env.BLIZZARD_LOCALE) ? env.BLIZZARD_LOCALE : 'en_GB';
  const cache = new Map(), pending = new Map();
  let token = null, tokenPending = null, tokenFailureUntil = 0;
  const status = () => ({ source: 'blizzard', status: game === 'forever' ? 'unsupported' : configured ? 'configured' : 'not_configured',
    configured, game, locale, requiresMapping: true, armorySupported: game === 'retail',
    reason: game === 'forever' ? 'forever_not_documented' : configured ? 'explicit_character_mapping_required' : 'credentials_missing' });

  async function fetchJSON(url, init) {
    const response = await fetchImpl(url, { ...init, redirect: 'error', signal: AbortSignal.timeout(4000) });
    if (!response.ok) { const error = new Error('Blizzard request unavailable'); error.httpStatus = response.status; throw error; }
    const maxBytes = 2 * 1024 * 1024;
    if (Number(response.headers.get('content-length')) > maxBytes) throw new Error('Blizzard response too large');
    const reader = response.body?.getReader();
    if (!reader) throw new Error('Blizzard response is empty');
    const chunks = [];
    let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        size += value.byteLength;
        if (size > maxBytes) { await reader.cancel(); throw new Error('Blizzard response too large'); }
        chunks.push(Buffer.from(value));
      }
    } finally { reader.releaseLock(); }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  }
  async function accessToken() {
    if (token && token.expires > now()) return token.value;
    if (tokenPending) return tokenPending;
    if (tokenFailureUntil > now()) throw new Error('Blizzard token temporarily unavailable');
    tokenPending = (async () => {
      try {
        const data = await fetchJSON('https://oauth.battle.net/token', { method: 'POST', headers: {
          Authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString('base64')}`, 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'grant_type=client_credentials' });
        if (!clean(data.access_token, 4096) || !Number.isFinite(data.expires_in) || data.expires_in <= 0 || data.token_type?.toLowerCase() !== 'bearer') throw new Error('Invalid Blizzard token response');
        token = { value: data.access_token, expires: now() + Math.max(0, data.expires_in * 1000 - 30000) };
        tokenFailureUntil = 0;
        return token.value;
      } catch (error) { tokenFailureUntil = now() + failureTtlMs; throw error; }
      finally { tokenPending = null; }
    })();
    return tokenPending;
  }
  async function api(mapping, endpoint = '') {
    const url = new URL(`https://${mapping.region}.api.blizzard.com/profile/wow/character/${encodeURIComponent(mapping.realmSlug)}/${encodeURIComponent(nameKey(mapping.characterName))}${endpoint}`);
    url.searchParams.set('namespace', mapping.namespace); url.searchParams.set('locale', locale);
    const initialToken = await accessToken();
    try { return await fetchJSON(url, { headers: { Authorization: `Bearer ${initialToken}` } }); }
    catch (error) {
      if (error.httpStatus !== 401) throw error;
      if (token?.value === initialToken) token = null;
      return fetchJSON(url, { headers: { Authorization: `Bearer ${await accessToken()}` } });
    }
  }
  const subresourceMatches = (data, mapping) => data?.character?.id === mapping.characterId && data.character.realm?.id === mapping.realmId;
  async function load(mapping, player) {
    try {
      const data = await api(mapping);
      if (data.id !== mapping.characterId || data.realm?.id !== mapping.realmId || nameKey(data.realm?.slug) !== nameKey(mapping.realmSlug)
        || nameKey(data.name) !== nameKey(mapping.characterName) || CLASS_IDS[data.character_class?.id] !== player.classFile) return absent('unavailable', 'identity_mismatch');
      if (!integer(data.level) || data.level > 255 || !clean(data.name) || !clean(data.realm?.name)) return absent('unavailable', 'invalid_profile');
      const [mediaResponse, equipmentResponse] = await Promise.allSettled([api(mapping, '/character-media'), api(mapping, '/equipment')]);
      let media = null;
      if (mediaResponse.status === 'fulfilled' && subresourceMatches(mediaResponse.value, mapping)) {
        const assets = Array.isArray(mediaResponse.value.assets) ? mediaResponse.value.assets : [];
        const avatar = safeMedia(assets.find((asset) => asset.key === 'avatar')?.value);
        const main = safeMedia(assets.find((asset) => asset.key === 'main')?.value) ?? safeMedia(assets.find((asset) => asset.key === 'main-raw')?.value);
        if (avatar || main) media = { avatar, main };
      }
      let equipment = [];
      if (equipmentResponse.status === 'fulfilled' && subresourceMatches(equipmentResponse.value, mapping) && Array.isArray(equipmentResponse.value.equipped_items)) {
        equipment = equipmentResponse.value.equipped_items.slice(0, 24).filter((item) => integer(item.item?.id) && clean(item.name, 256)).map((item) => ({
          id: item.item.id, name: clean(item.name, 256), slot: clean(item.slot?.name), quality: clean(item.quality?.name),
          itemLevel: integer(item.level?.value) ? item.level.value : null }));
      }
      const summary = { id: data.id, name: data.name, level: data.level, race: clean(data.race?.name), class: clean(data.character_class?.name),
        classFile: CLASS_IDS[data.character_class.id], faction: clean(data.faction?.name), guild: clean(data.guild?.name),
        spec: clean(data.active_spec?.name), itemLevel: integer(data.equipped_item_level) ? data.equipped_item_level : null,
        realm: data.realm.name, realmId: data.realm.id, region: mapping.region, namespace: mapping.namespace, game };
      // Public retail Armory supports this route. Classic and Forever must never be routed there.
      const armoryUrl = game === 'retail' ? `https://worldofwarcraft.blizzard.com/en-us/character/${mapping.region}/${encodeURIComponent(mapping.realmSlug)}/${encodeURIComponent(nameKey(mapping.characterName))}` : null;
      return { status: 'available', source: 'blizzard', game, summary, armoryUrl, media, equipment, updatedAt: new Date(now()).toISOString() };
    } catch { return absent('unavailable', 'upstream_unavailable'); }
  }
  async function character(mappingValue, player) {
    const empty = (state, reason) => ({ ...absent(state, reason), game, linkedGame: mappingValue?.game ?? null });
    if (game === 'forever') return empty('unsupported', 'forever_not_documented');
    if (!configured) return empty('not_configured', 'credentials_missing');
    if (!mappingValue) return empty('unavailable', 'unmapped');
    let mapping;
    try { mapping = validateMapping(mappingValue); } catch { return empty('unavailable', 'invalid_mapping'); }
    if (mapping.guid !== player.guid || mapping.game !== game) return empty('unsupported', 'mapping_game_mismatch');
    const key = JSON.stringify({ mapping, classFile: player.classFile });
    const prior = cache.get(key);
    if (prior && prior.until > now()) return structuredClone(prior.value);
    if (pending.has(key)) return structuredClone(await pending.get(key));
    if (pending.size >= 10) return empty('unavailable', 'temporarily_busy');
    const promise = load(mapping, player).then((loaded) => {
      const value = { ...loaded, game, linkedGame: mapping.game };
      if (cache.size >= 1000) cache.delete(cache.keys().next().value);
      cache.set(key, { value, until: now() + (value.status === 'available' ? ttlMs : failureTtlMs) });
      return value;
    }).finally(() => pending.delete(key));
    pending.set(key, promise);
    return structuredClone(await promise);
  }
  return { status, character };
}
