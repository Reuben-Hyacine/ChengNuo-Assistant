import { fail } from '../utils/response.js';
import { isDevAuthed } from '../services/devAuth.service.js';

// 管理接口守卫：本机回环（SSH 隧道访问）直接放行；公网访问必须携带开发者会话 Cookie。
// 是 localOnly 的超集：公网请求经 nginx 反代 + trust proxy 后 req.ip 为真实客户端 IP，
// 不再形如 127.0.0.1，回环放行不会被公网流量绕过。
const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

function isLoopback(ip) {
  return typeof ip === 'string' && LOOPBACK.has(ip.trim());
}

export function requireDevAuth(req, res, next) {
  if (isLoopback(req.ip) || isDevAuthed(req)) {
    return next();
  }
  return fail(res, 40302, '需要开发者登录', 403);
}

// 页面版守卫：未登录 302 到登录页而不是回 JSON（/console、/console/reports 使用）
export function requireDevAuthPage(req, res, next) {
  if (isLoopback(req.ip) || isDevAuthed(req)) {
    return next();
  }
  return res.redirect('/login.html');
}
