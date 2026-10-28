import { createApp } from './app.js';
import { config } from './config.js';
import { appendFileSync } from 'node:fs';

const app = createApp();

const server = app.listen(config.port, config.host, () => {
  console.log(`[${config.env}] server listening on http://${config.host}:${config.port}`);
});

function shutdown(signal) {
  console.log(`received ${signal}, shutting down...`);
  server.close(() => {
    console.log('server closed');
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000).unref();
}

// bun on OHOS/musl may treat a listening socket as non-blocking for the event
// loop and auto-exit(0) right after startup; hold the loop explicitly.
setInterval(() => {}, 600000);

// device-side liveness heartbeat (host-side /proc probes are unreliable on OHOS)
const hbPath = process.env.HB_PATH || '/data/local/tmp/server_heartbeat.txt';
setInterval(() => {
  try { appendFileSync(hbPath, `${Date.now()}\n`); } catch {}
}, 5000);

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

// 非托管异步错误（express 之外的 fire-and-forget、后台任务）默认会让 Node 直接退出，
// 测试中的服务器表现为「突然死掉且无任何日志」。改为记录到 stderr（随启动重定向落到
// server-err.log）并保活，保证问题可追溯、测试不被中断。
process.on('unhandledRejection', (reason) => {
  console.error(`[unhandledRejection] ${new Date().toISOString()}`, reason);
});
process.on('uncaughtException', (err) => {
  console.error(`[uncaughtException] ${new Date().toISOString()}`, err);
});
