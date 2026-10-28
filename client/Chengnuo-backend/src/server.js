import { createApp } from './app.js';
import { config } from './config.js';
import { appendFileSync } from 'node:fs';

const app = createApp();

const server = app.listen(config.port, config.host, () => {
  console.log(`[client:${config.env}] test-bench listening on http://${config.host}:${config.port}`);
  console.log(`[client] will connect to server at http://${config.serverIp}:${config.serverPort}`);
  console.log(`[client] page entry: http://localhost:${config.port}/  (仅需本机浏览器访问，服务器不反向连入)`);
});

function shutdown(signal) {
  console.log(`received ${signal}, shutting down...`);
  server.close(() => {
    console.log('client closed');
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000).unref();
}

// bun on OHOS/musl may treat a listening socket as non-blocking for the event
// loop and auto-exit(0) right after startup; hold the loop explicitly.
setInterval(() => {}, 600000);

// device-side liveness heartbeat (host-side /proc probes are unreliable on OHOS)
const hbPath = process.env.HB_PATH || '/data/local/tmp/client_heartbeat.txt';
setInterval(() => {
  try { appendFileSync(hbPath, `${Date.now()}\n`); } catch {}
}, 5000);

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));