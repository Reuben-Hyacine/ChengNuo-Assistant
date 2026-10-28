import { fail } from '../utils/response.js';

// 仅本机可访问：用于管理/调试类接口（管理台、AI 直调、会话列表、路由 IP 库等）。
// 这些接口没有面向普通客户端的登录凭据，放到局域网/公网后必须限制来源，避免被匿名滥用。
const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

function isLoopback(ip) {
  return typeof ip === 'string' && LOOPBACK.has(ip.trim());
}

export function localOnly(req, res, next) {
  if (isLoopback(req.ip)) {
    return next();
  }
  return fail(res, 40301, '仅允许在服务器本机访问该接口', 403);
}
