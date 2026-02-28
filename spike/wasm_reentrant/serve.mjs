// Minimal static server with COOP/COEP headers for SharedArrayBuffer support.
// Usage: node serve.mjs [port]

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const webDir = join(__dirname, 'web');
const port = parseInt(process.argv[2] || '8080', 10);

const mimeTypes = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.mjs': 'application/javascript',
  '.wasm': 'application/wasm',
  '.css': 'text/css',
  '.json': 'application/json',
};

const server = createServer(async (req, res) => {
  const url = req.url === '/' ? '/index.html' : req.url;
  const filePath = join(webDir, url);

  // COOP/COEP headers — required for SharedArrayBuffer (WASM Workers)
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');

  try {
    const data = await readFile(filePath);
    const ext = extname(filePath);
    res.writeHead(200, { 'Content-Type': mimeTypes[ext] || 'application/octet-stream' });
    res.end(data);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('404 Not Found');
  }
});

server.listen(port, () => {
  console.log(`Serving ${webDir} at http://localhost:${port}`);
  console.log('COOP/COEP headers enabled for SharedArrayBuffer support.');
});
