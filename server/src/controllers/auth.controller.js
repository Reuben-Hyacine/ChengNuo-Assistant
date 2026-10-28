import { ok, fail } from '../utils/response.js';
import { registerAccount, loginAccount, logoutAccount, deleteAccount, listSessions } from '../services/auth.service.js';

export async function register(req, res) {
  const { account, password } = req.body ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    return fail(res, 40001, '账号不能为空');
  }
  if (!password || typeof password !== 'string') {
    return fail(res, 40002, '密码不能为空');
  }
  try {
    ok(res, await registerAccount({ account, password }));
  } catch (err) {
    fail(res, err.status ?? 400, err.message ?? '注册失败', err.status ?? 400);
  }
}

export async function login(req, res) {
  const { account, password, ip, port } = req.body ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    return fail(res, 40001, '账号不能为空');
  }
  if (!password || typeof password !== 'string') {
    return fail(res, 40002, '密码不能为空');
  }
  try {
    ok(res, await loginAccount({ account, password, ip, port }));
  } catch (err) {
    fail(res, err.status ?? 400, err.message ?? '登录失败', err.status ?? 400);
  }
}

export function sessions(req, res) {
  ok(res, listSessions());
}

export function logout(req, res) {
  ok(res, logoutAccount(req.body ?? {}));
}

export async function deleteAccountHandler(req, res) {
  const { account, password } = req.body ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    return fail(res, 40001, '账号不能为空');
  }
  if (!password || typeof password !== 'string') {
    return fail(res, 40002, '密码不能为空');
  }
  try {
    ok(res, await deleteAccount({ account, password }));
  } catch (err) {
    fail(res, err.status ?? 400, err.message ?? '注销失败', err.status ?? 400);
  }
}
