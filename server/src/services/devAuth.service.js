import fs from 'node:fs';
import crypto from 'node:crypto';
import { config } from '../config.js';

// 开发者登录：管理台（/console 页面与受保护接口）的准入控制。
// 凭据存服务器本地 dev-auth.json（与 ai-api-key.txt 同惯例，不进仓库）：
//   { "user": "admin", "salt": "<hex>", "hash": "sha256(salt + ':' + password)" }
// 会话仅存内存：服务器重启后需重新登录；连续失败按 IP 限流锁定，防公网爆破。

const SESSION_TTL_MS = 12 * 60 * 60 * 1000;
const MAX_FAILURES = 5;
const LOCK_MS = 15 * 60 * 1000;
export const DEV_COOKIE = 'dev_session';

const sessions = new Map();
const failures = new Map();

function configError(message, code) {
  const err = new Error(message);
  err.status = 503;
  err.code = code;
  return err;
}

function loadCredentials() {
  let text;
  try {
    text = fs.readFileSync(config.devAuthFile, 'utf8');
  } catch {
    throw configError('开发者登录未配置（服务器缺少 dev-auth.json）', 50301);
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw configError('dev-auth.json 格式错误', 50302);
  }
  if (!parsed.user || typeof parsed.user !== 'string'
    || !/^[0-9a-f]{32}$/.test(parsed.salt ?? '')
    || !/^[0-9a-f]{64}$/.test(parsed.hash ?? '')) {
    throw configError('dev-auth.json 缺少合法的 user/salt/hash 字段', 50303);
  }
  return parsed;
}

function hashPassword(salt, password) {
  return crypto.createHash('sha256').update(`${salt}:${password}`).digest('hex');
}

function registerFailure(ip) {
  const entry = failures.get(ip) ?? { count: 0, lockedUntil: 0 };
  entry.count += 1;
  if (entry.count >= MAX_FAILURES) {
    entry.lockedUntil = Date.now() + LOCK_MS;
    entry.count = 0;
  }
  failures.set(ip, entry);
}

function isLocked(ip) {
  const entry = failures.get(ip);
  if (!entry) {
    return false;
  }
  if (entry.lockedUntil > Date.now()) {
    return true;
  }
  if (entry.lockedUntil !== 0) {
    failures.delete(ip);
  }
  return false;
}

function sweepSessions() {
  const now = Date.now();
  for (const [token, session] of sessions) {
    if (session.expiresAt <= now) {
      sessions.delete(token);
    }
  }
}

export function createDevSession({ user, password, ip }) {
  if (isLocked(ip)) {
    const err = new Error('失败次数过多，请 15 分钟后再试');
    err.status = 429;
    err.code = 42901;
    throw err;
  }
  const credentials = loadCredentials();
  const passHash = Buffer.from(hashPassword(credentials.salt, password ?? ''), 'hex');
  const storedHash = Buffer.from(credentials.hash, 'hex');
  const userMatches = user === credentials.user;
  const passMatches = crypto.timingSafeEqual(passHash, storedHash);
  if (!userMatches || !passMatches) {
    registerFailure(ip);
    const err = new Error('账号或密码错误');
    err.status = 401;
    err.code = 40101;
    throw err;
  }
  failures.delete(ip);
  sweepSessions();
  const token = crypto.randomBytes(32).toString('hex');
  const session = { user: credentials.user, expiresAt: Date.now() + SESSION_TTL_MS };
  sessions.set(token, session);
  return { token, user: session.user, ttlMs: SESSION_TTL_MS };
}

export function resolveDevSession(token) {
  if (typeof token !== 'string' || token === '') {
    return null;
  }
  const session = sessions.get(token);
  if (!session) {
    return null;
  }
  if (session.expiresAt <= Date.now()) {
    sessions.delete(token);
    return null;
  }
  return session;
}

export function destroyDevSession(token) {
  sessions.delete(token);
}

export function readDevCookie(req) {
  const header = req.headers.cookie;
  if (typeof header !== 'string' || header === '') {
    return '';
  }
  for (const part of header.split(';')) {
    const eq = part.indexOf('=');
    if (eq === -1) {
      continue;
    }
    if (part.slice(0, eq).trim() === DEV_COOKIE) {
      return part.slice(eq + 1).trim();
    }
  }
  return '';
}

export function isDevAuthed(req) {
  return resolveDevSession(readDevCookie(req)) !== null;
}
