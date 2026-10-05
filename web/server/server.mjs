import { createServer as createHttpServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { readFile, realpath, stat } from 'node:fs/promises';
import { dirname, extname, isAbsolute, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ApiError, CLASSES, createStore } from './store.mjs';
import { createBlizzardClient, MEDIA_HOSTS } from './blizzard.mjs';

const here = dirname(fileURLToPath(import.meta.url));
// The advertised addon version: ADDON_VERSION, else the TOC of the addon in
// this repository; never a literal that drifts from the addon.
function addonVersion() {
  const configured = process.env.ADDON_VERSION ?? '';
  if (/^\d+\.\d+\.\d+$/u.test(configured)) return configured;
  try {
    const toc = readFileSync(resolve(here, '../../ForeverDuel/ForeverDuel.toc'), 'utf8');
    return toc.match(/^## Version:\s*(\d+\.\d+\.\d+)\s*$/mu)?.[1] ?? null;
  } catch { return null; }
}
export const ADDON_VERSION = addonVersion();
const MAX_BODY = 2 * 1024 * 1024;
const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.ico': 'image/x-icon', '.woff2': 'font/woff2' };
const parseIntParam = (params, key, fallback, max) => {
  const raw = params.get(key);
  if (raw === null) return fallback;
  if (!/^[1-9][0-9]*$/u.test(raw) || !Number.isSafeInteger(Number(raw)) || Number(raw) > max) throw new ApiError(400, 'invalid_query', `Invalid ${key}`);
  return Number(raw);
};
function options(params, defaultLimit = 20, requireClass = false) {
  const bracket = params.get('bracket') ?? 'MAX_LEVEL';
  if (!['MAX_LEVEL', 'LEVELING'].includes(bracket)) throw new ApiError(400, 'invalid_query', 'Invalid bracket');
  const classFile = params.get('classFile') ?? '', realm = params.get('realm') ?? '', search = params.get('search') ?? '';
  const ranking = params.get('ranking') ?? 'OVERALL';
  if (!['OVERALL', 'CLASS'].includes(ranking) || requireClass && ranking === 'CLASS' && !classFile) throw new ApiError(400, 'invalid_query', 'CLASS ranking requires classFile');
  if ((classFile && !CLASSES.has(classFile)) || realm.length > 128 || search.length > 96) throw new ApiError(400, 'invalid_query');
  return { bracket, maxLevel: parseIntParam(params, 'maxLevel', 60, 255), page: parseIntParam(params, 'page', 1, 1000000),
    limit: parseIntParam(params, 'limit', defaultLimit, 100), classFile, realm, search, ranking };
}

async function bodyJSON(req) {
  if ((req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') throw new ApiError(415, 'json_required');
  if (req.headers['content-encoding'] && req.headers['content-encoding'] !== 'identity') throw new ApiError(415, 'encoding_not_supported');
  const advertised = Number(req.headers['content-length']);
  if (Number.isFinite(advertised) && advertised > MAX_BODY) throw new ApiError(413, 'body_too_large');
  const chunks = [];
  let bytes = 0;
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > MAX_BODY) throw new ApiError(413, 'body_too_large');
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new ApiError(400, 'invalid_json'); }
}
function bearer(req, store) {
  const match = /^Bearer ([A-Za-z0-9_-]+)$/u.exec(req.headers.authorization ?? '');
  if (!match) throw new ApiError(401, 'unauthorized');
  return store.authenticate(match[1]);
}

export function createServer({ store, publicDir = resolve(here, '../public'), logger = console, blizzard = createBlizzardClient() } = {}) {
  if (!store) throw new Error('A store is required');
  const root = resolve(publicDir), buckets = new Map();
  const json = (res, status, value) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
  function rate(req) {
    const now = Date.now(), ip = req.socket.remoteAddress ?? 'unknown';
    if (buckets.size >= 10000) for (const [key, value] of buckets) if (now - value.start > 60000) buckets.delete(key);
    if (buckets.size >= 10000 && !buckets.has(ip)) throw new ApiError(429, 'rate_limited');
    let bucket = buckets.get(ip);
    if (!bucket || now - bucket.start > 60000) { bucket = { start: now, count: 0, imports: 0 }; buckets.set(ip, bucket); }
    bucket.count++;
    if (req.method === 'POST') bucket.imports++;
    if (bucket.count > 300 || bucket.imports > 30) throw new ApiError(429, 'rate_limited');
  }
  const server = createHttpServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'same-origin');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    res.setHeader('Content-Security-Policy', `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: ${[...MEDIA_HOSTS].map((host) => `https://${host}`).join(' ')}; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`);
    try {
      rate(req);
      if (!req.url || req.url.length > 4096) throw new ApiError(414, 'uri_too_long');
      const url = new URL(req.url, 'http://localhost');
      const path = url.pathname;
      if (req.method === 'POST' && path === '/api/v1/import') {
        // Non-browser upload tools may omit Origin. Browser writes must be same-origin.
        if (req.headers.origin && req.headers.origin !== `http://${req.headers.host}` && req.headers.origin !== `https://${req.headers.host}`) throw new ApiError(403, 'origin_rejected');
        const guid = bearer(req, store);
        if (store.demo) throw new ApiError(403, 'demo_is_read_only');
        return json(res, 200, store.importReports(guid, await bodyJSON(req)));
      }
      if (req.method === 'GET') {
        if (path === '/health') return json(res, 200, { status: 'ok' });
        if (path === '/api/v1/config') return json(res, 200, { name: 'ForeverDuelersGuild', version: '0.1.0', addonVersion: ADDON_VERSION, demo: store.demo, initialRating: 1500, rulesetId: store.rulesetId });
        if (path === '/api/v1/stats') return json(res, 200, store.stats());
        if (path === '/api/v1/integrations/blizzard') return json(res, 200, blizzard.status());
        if (path === '/api/v1/ladder') return json(res, 200, store.ladder(options(url.searchParams, 20, true)));
        if (path === '/api/v1/class-comparisons') return json(res, 200, store.classComparisons({ maxLevel: parseIntParam(url.searchParams, 'maxLevel', 60, 255), requestedRuleset: url.searchParams.get('rulesetId') ?? store.rulesetId }));
        if (path === '/api/v1/matches') return json(res, 200, store.matches(options(url.searchParams, 10)));
        if (path === '/api/v1/me') return json(res, 200, { guid: bearer(req, store) });
        if (path.startsWith('/api/v1/players/')) {
          let guid;
          try { guid = decodeURIComponent(path.slice('/api/v1/players/'.length)); } catch { throw new ApiError(400, 'invalid_path'); }
          const profile = store.player(guid, options(url.searchParams));
          profile.character = store.demo ? { status: 'unavailable', source: 'blizzard', reason: 'synthetic_demo', summary: null, armoryUrl: null, media: null, equipment: [] }
            : await blizzard.character(store.characterMapping(guid), profile.player);
          return json(res, 200, profile);
        }
      }
      if (path.startsWith('/api/') || path === '/health') throw new ApiError(req.method === 'GET' ? 404 : 405, req.method === 'GET' ? 'not_found' : 'method_not_allowed');
      if (!['GET', 'HEAD'].includes(req.method)) throw new ApiError(405, 'method_not_allowed');
      let decoded;
      try { decoded = decodeURIComponent(path); } catch { throw new ApiError(400, 'invalid_path'); }
      if (decoded.includes('\0') || decoded.includes('\\') || decoded.split('/').some((part) => part.startsWith('.'))) throw new ApiError(404, 'not_found');
      const candidate = resolve(root, decoded === '/' ? 'index.html' : `.${decoded}`);
      const inside = (value) => { const rel = relative(root, value); return rel !== '..' && !rel.startsWith(`..\\`) && !rel.startsWith('../') && !isAbsolute(rel); };
      if (!inside(candidate) || !TYPES[extname(candidate).toLowerCase()]) throw new ApiError(404, 'not_found');
      let real, fileInfo;
      try { real = await realpath(candidate); fileInfo = await stat(real); } catch { throw new ApiError(404, 'not_found'); }
      if (!inside(real) || !fileInfo.isFile()) throw new ApiError(404, 'not_found');
      const content = await readFile(real);
      res.writeHead(200, { 'Content-Type': TYPES[extname(real).toLowerCase()], 'Content-Length': content.length, 'Cache-Control': 'no-cache' });
      res.end(req.method === 'HEAD' ? undefined : content);
    } catch (error) {
      if (res.headersSent) { res.destroy(); return; }
      const status = error instanceof ApiError ? error.status : 500;
      if (status === 429) res.setHeader('Retry-After', '60');
      if (status === 401) res.setHeader('WWW-Authenticate', 'Bearer');
      if (status === 500) logger.error('Request failed:', error.message);
      json(res, status, { error: { code: error instanceof ApiError ? error.code : 'internal_error', message: status === 500 ? 'Internal server error' : error.message } });
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 5000;
  server.maxHeadersCount = 60;
  return server;
}

export async function startServer({ demo = process.env.FD_DEMO === '1' } = {}) {
  const host = process.env.HOST || '127.0.0.1', port = Number(process.env.PORT || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be between 1 and 65535');
  const basePath = resolve(process.env.DB_PATH || resolve(here, '../data/foreverduel.sqlite'));
  // Demo mode always uses a separate database, even when DB_PATH is provided.
  const dbPath = demo ? `${basePath}.demo.sqlite` : basePath;
  const store = createStore({ path: dbPath, demo });
  try {
    if (demo) { const { seedDemo } = await import('./demo-data.mjs'); seedDemo(store); }
    const server = createServer({ store });
    await new Promise((done, reject) => { server.once('error', reject); server.listen(port, host, done); });
    console.log(`ForeverDuelersGuild ${demo ? '(synthetic demo)' : '(local)'}: http://${host}:${port}`);
    console.log(`Database: ${dbPath}`);
    const shutdown = () => { server.close(() => { store.close(); process.exit(0); }); server.closeIdleConnections(); };
    process.once('SIGINT', shutdown); process.once('SIGTERM', shutdown);
    return { server, store };
  } catch (error) { store.close(); throw error; }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  startServer().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
