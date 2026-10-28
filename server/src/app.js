import path from 'node:path';
import express from 'express';
import { config } from './config.js';
import { registerRoutes } from './routes/index.js';
import { requestLogger } from './middleware/requestLogger.js';
import { requireDevAuthPage } from './middleware/requireDevAuth.js';
import { notFound } from './middleware/notFound.js';
import { errorHandler } from './middleware/errorHandler.js';

export function createApp() {
  const app = express();

  app.disable('x-powered-by');
  // nginx（ourchengnuo.cn 80/443 → 127.0.0.1:3000）反代后，公网请求的 socket 地址恒为回环；
  // 必须信任首跳代理头，req.ip 才是真实客户端 IP——否则 requireDevAuth 的回环放行会被公网流量绕过
  app.set('trust proxy', 1);
  // 个人空间头像以 base64 随 profile.update（91）上送，放宽 JSON 请求体上限（默认 100kb 会 413）
  app.use(express.json({ limit: '2mb' }));
  app.use(express.urlencoded({ extended: true }));
  app.use(requestLogger);
  app.use(express.static(config.publicDir));

  // 开发者控制台页面：置于 publicDir 之外，未登录一律 302 到登录页
  app.get('/console', requireDevAuthPage, (req, res) => {
    res.sendFile(path.join(config.consoleDir, 'index.html'));
  });
  app.get('/console/reports', requireDevAuthPage, (req, res) => {
    res.sendFile(path.join(config.consoleDir, 'reports.html'));
  });

  registerRoutes(app);

  app.use(notFound);
  app.use(errorHandler);

  return app;
}
