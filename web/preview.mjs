import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, extname, sep } from 'node:path';

// A static-only design preview: no tokens, database, uploads or live API.
const root = resolve(dirname(fileURLToPath(import.meta.url)), 'public');
const port = Number(process.env.PREVIEW_PORT || 8788);
const mime = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml'
};
const server = createServer(async (req, res) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Cache-Control', 'no-store');
  if (!['GET', 'HEAD'].includes(req.method)) {
    res.writeHead(405, { Allow: 'GET, HEAD' }); res.end(); return;
  }
  try {
    const url = new URL(req.url, `http://127.0.0.1:${port}`);
    if (url.pathname === '/') {
      res.writeHead(302, { Location: '/index.html?preview=1' }); res.end(); return;
    }
    if (url.pathname.startsWith('/api/')) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Static design preview. Open /?preview=1.' })); return;
    }
    const filename = resolve(root, '.' + decodeURIComponent(url.pathname));
    if (!filename.startsWith(root + sep) || !mime[extname(filename)]) {
      res.writeHead(404); res.end(); return;
    }
    const contents = await readFile(filename);
    res.writeHead(200, { 'Content-Type': mime[extname(filename)] });
    res.end(req.method === 'HEAD' ? undefined : contents);
  } catch {
    res.writeHead(404); res.end();
  }
});
server.listen(port, '127.0.0.1', () => {
  console.log(`Website design: http://127.0.0.1:${port}/?preview=1`);
});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close());
