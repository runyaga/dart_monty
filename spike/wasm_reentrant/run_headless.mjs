// Headless Chrome runner — captures console output from the spike.
// Usage: node run_headless.mjs [url] [timeout_seconds]

import { execFile } from 'node:child_process';
import { createConnection } from 'node:net';

const url = process.argv[2] || 'http://localhost:8090';
const timeoutSec = parseInt(process.argv[3] || '60', 10);

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const DEBUG_PORT = 9333;

// Launch Chrome headless with remote debugging.
const chrome = execFile(CHROME, [
  '--headless=new',
  '--disable-gpu',
  '--no-sandbox',
  '--disable-extensions',
  `--remote-debugging-port=${DEBUG_PORT}`,
  '--remote-allow-origins=*',
  url,
], { timeout: timeoutSec * 1000 });

chrome.on('error', (err) => {
  console.error('Chrome launch error:', err.message);
  process.exit(1);
});

// Wait for Chrome's debug port to be ready.
async function waitForPort(port, retries = 30) {
  for (let i = 0; i < retries; i++) {
    try {
      await new Promise((resolve, reject) => {
        const sock = createConnection({ port }, () => {
          sock.destroy();
          resolve();
        });
        sock.on('error', reject);
      });
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  throw new Error(`Port ${port} not ready after ${retries} attempts`);
}

// Connect to CDP via WebSocket.
async function getWsUrl() {
  const resp = await fetch(`http://127.0.0.1:${DEBUG_PORT}/json`);
  const tabs = await resp.json();
  const page = tabs.find((t) => t.type === 'page');
  if (!page) throw new Error('No page tab found');
  return page.webSocketDebuggerUrl;
}

async function run() {
  await waitForPort(DEBUG_PORT);
  await new Promise((r) => setTimeout(r, 1000)); // extra settle time

  const wsUrl = await getWsUrl();

  // Use raw WebSocket (Node 22+ has built-in WebSocket)
  const ws = new WebSocket(wsUrl);

  let msgId = 1;
  const send = (method, params = {}) => {
    const id = msgId++;
    ws.send(JSON.stringify({ id, method, params }));
    return id;
  };

  const done = new Promise((resolve) => {
    const timeout = setTimeout(() => {
      console.log('\n[runner] Timeout reached — stopping.');
      resolve();
    }, (timeoutSec - 5) * 1000);

    ws.onopen = () => {
      send('Runtime.enable');
      send('Console.enable');
    };

    ws.onmessage = (evt) => {
      const msg = JSON.parse(evt.data);

      // Console API messages
      if (msg.method === 'Runtime.consoleAPICalled') {
        const text = msg.params.args
          .map((a) => a.value ?? a.description ?? '')
          .join(' ');
        console.log(text);

        // Detect completion
        if (text.includes('============') && text.includes('VERDICT')) {
          // Give a moment for any trailing output
          setTimeout(() => { clearTimeout(timeout); resolve(); }, 2000);
        }
      }

      // Runtime exceptions
      if (msg.method === 'Runtime.exceptionThrown') {
        const desc = msg.params.exceptionDetails?.text ?? 'unknown';
        console.error('[JS Exception]', desc);
      }
    };
  });

  await done;
  ws.close();
  chrome.kill();
}

run().catch((err) => {
  console.error('Runner error:', err.message);
  chrome.kill();
  process.exit(1);
});
