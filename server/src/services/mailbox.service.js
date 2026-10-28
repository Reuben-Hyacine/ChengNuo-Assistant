import { listMailsOf, markMailRead, removeMail } from './mailboxStore.js';
import { findAccount } from './accountStore.js';

// 收件箱业务（站内邮件）：本人的日程提醒到点时，服务器自动把提醒邮件投递到其收件箱；
// 本模块只提供「查看 / 标记已读 / 删除」三个动作，投递动作在 reminderService 里完成。

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

async function requireMe(account) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    throw badRequest('需要账号身份才能操作收件箱');
  }
  const me = await findAccount(name);
  if (!me) {
    throw badRequest('当前账号不存在，请重新登录');
  }
  return me;
}

// 服务 42 mailbox.list：我的收件箱（新邮件在前，附未读数）
export async function listMyMails({ account = null } = {}) {
  const me = await requireMe(account);
  return listMailsOf(me.account);
}

// 服务 43 mailbox.read：标记已读（不传 id 或 all=true 时全部标记）
export async function markMyMailRead({ account = null, id = null, all = false } = {}) {
  const me = await requireMe(account);
  if (all !== true && !Number.isInteger(id)) {
    throw badRequest('需要邮件 id，或传 all=true 标记全部已读');
  }
  return markMailRead(me.account, Number.isInteger(id) ? id : null, all === true);
}

// 服务 44 mailbox.remove：删除邮件（不传 id 或 all=true 时清空收件箱）
export async function removeMyMail({ account = null, id = null, all = false } = {}) {
  const me = await requireMe(account);
  if (all !== true && !Number.isInteger(id)) {
    throw badRequest('需要邮件 id，或传 all=true 清空收件箱');
  }
  return removeMail(me.account, Number.isInteger(id) ? id : null, all === true);
}
