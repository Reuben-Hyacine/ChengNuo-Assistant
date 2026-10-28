import { listNoticesOf, markNoticeRead, removeNotice } from './noticeStore.js';
import { findAccount } from './accountStore.js';

// 通知通道业务（新建通道）：延期申请被同意/拒绝后，服务器把结果同时投递到申请者的
// 「收件箱」（mailbox）与「通知通道」（noticeStore）；本模块只提供「查看 / 标记已读 / 删除」三个动作，
// 投递动作在 cardExtend.service 里完成。

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

async function requireMe(account) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    throw badRequest('需要账号身份才能操作通知');
  }
  const me = await findAccount(name);
  if (!me) {
    throw badRequest('当前账号不存在，请重新登录');
  }
  return me;
}

// 服务 71 notices.list：我的通知（最新在前，附未读数）
export async function listMyNotices({ account = null } = {}) {
  const me = await requireMe(account);
  return listNoticesOf(me.account);
}

// 服务 72 notices.read：标记已读（不传 id 或 all=true 时全部标记）
export async function markMyNoticeRead({ account = null, noticeId = null, id = null, all = false } = {}) {
  const me = await requireMe(account);
  const target = Number.isInteger(noticeId) ? noticeId : id;
  if (all !== true && !Number.isInteger(target)) {
    throw badRequest('需要通知 id，或传 all=true 标记全部已读');
  }
  return markNoticeRead(me.account, Number.isInteger(target) ? target : null, all === true);
}

// 服务 73 notices.remove：删除通知（不传 id 或 all=true 时清空通知通道）
export async function removeMyNotice({ account = null, noticeId = null, id = null, all = false } = {}) {
  const me = await requireMe(account);
  const target = Number.isInteger(noticeId) ? noticeId : id;
  if (all !== true && !Number.isInteger(target)) {
    throw badRequest('需要通知 id，或传 all=true 清空通知');
  }
  return removeNotice(me.account, Number.isInteger(target) ? target : null, all === true);
}