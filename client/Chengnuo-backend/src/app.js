import express from 'express';
import { config } from './config.js';
import { registerRoutes } from './routes/index.js';
import { requestLogger } from './middleware/requestLogger.js';
import { notFound } from './middleware/notFound.js';
import { errorHandler } from './middleware/errorHandler.js';

export function createApp() {
  const app = express();

  app.disable('x-powered-by');
  app.use(express.json());
  app.use(express.urlencoded({ extended: true }));
  app.use(requestLogger);
  app.use(express.static(config.publicDir, {
    setHeaders(res, filePath) {
      // 页面不缓存：避免改动后仍需手动强刷才能看到新界面
      if (filePath.endsWith('.html')) {
        res.setHeader('Cache-Control', 'no-store, must-revalidate');
      }
    }
  }));

  registerRoutes(app);

  app.use(notFound);
  app.use(errorHandler);

  return app;
}