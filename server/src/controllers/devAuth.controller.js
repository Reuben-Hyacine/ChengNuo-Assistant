import { ok, fail } from '../utils/response.js';
import {
  DEV_COOKIE, createDevSession, destroyDevSession, isDevAuthed, readDevCookie
} from '../services/devAuth.service.js';

// 开发者登录/登出/状态：管理台入口。凭据文件仅存服务器（dev-auth.json），
// 会话以 HttpOnly + Secure + SameSite=Lax Cookie 下发，仅经 HTTPS 域名生效。

export function devLogin(req, res) {
  const { user, password } = req.body ?? {};
  if (typeof user !== 'string' || user === '' || typeof password !== 'string' || password === '') {
    return fail(res, 40001, '账号或密码不能为空');
  }
  try {
    const session = createDevSession({ user, password, ip: req.ip });
    const maxAge = Math.floor(session.ttlMs / 1000);
    res.setHeader(
      'Set-Cookie',
      `${DEV_COOKIE}=${session.token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`
    );
    return ok(res, { user: session.user, maxAge });
  } catch (err) {
    return fail(res, err.code ?? 40102, err.message ?? '登录失败', err.status ?? 401);
  }
}

export function devLogout(req, res) {
  destroyDevSession(readDevCookie(req));
  res.setHeader('Set-Cookie', `${DEV_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`);
  return ok(res, { loggedOut: true });
}

export function devCheck(req, res) {
  return ok(res, { authed: isDevAuthed(req) });
}
