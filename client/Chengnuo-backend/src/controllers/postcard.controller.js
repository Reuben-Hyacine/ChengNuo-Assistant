import { ok, fail } from '../utils/response.js';
import { resolveSession } from '../store/sessionStore.js';
import { listForAccount, removePostcard } from '../store/postcardStore.js';

// 明信片列表（本机控制台用）：明信片只存在客户端本地文本文件，需按登录 token 反解账号后再读。
export async function listMyPostcards(req, res) {
  const token = typeof req.query.token === 'string' ? req.query.token : '';
  const session = await resolveSession(token);
  if (!session) {
    return fail(res, 40101, '未登录：请先在客户端登录账号', 401);
  }
  const postcards = await listForAccount(session.account);
  return ok(res, { account: session.account, total: postcards.length, postcards });
}

// 删除一张明信片（控制台「明信片」库的删除按钮）：只删本客户端本地文本文件里的记录，且仅限本账号。
export async function removeMyPostcard(req, res) {
  const token = typeof req.query.token === 'string' ? req.query.token : '';
  const session = await resolveSession(token);
  if (!session) {
    return fail(res, 40101, '未登录：请先在客户端登录账号', 401);
  }
  const id = Number(req.params?.id ?? req.body?.id ?? req.query?.id);
  if (!Number.isInteger(id) || id < 1) {
    return fail(res, 40001, 'id 必须是正整数', 400);
  }
  const removed = await removePostcard(session.account, id);
  if (!removed.removed) {
    return fail(res, 40401, '明信片不存在或不属于当前账号', 404);
  }
  return ok(res, { account: session.account, id, removed: true, message: `已删除明信片 #${id}` });
}