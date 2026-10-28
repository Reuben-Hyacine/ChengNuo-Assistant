import { ok } from '../utils/response.js';

export function getHealth(req, res) {
  ok(res, {
    status: 'up',
    env: process.env.NODE_ENV ?? 'development',
    uptime: Math.floor(process.uptime()),
    timestamp: new Date().toISOString()
  });
}
