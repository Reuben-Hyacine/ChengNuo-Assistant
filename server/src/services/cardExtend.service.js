import { findAccount } from './accountStore.js';
import { getGroupView, extendGroupCardTime, computeExtendedTime } from './cardGroupStore.js';
import {
  createExtendRequest,
  listIncomingExtendRequests,
  consumeExtendRequest
} from './cardExtendStore.js';
import { pushNotice } from './noticeStore.js';
import { pushMail } from './mailboxStore.js';

// 卡片延期（服务 67 / 68 / 69 / 70）：与「卡片加入申请」同构的申请 → 审批闭环。
//  - 发起者（卡片组创建者）提交延期：立即改期（无需审批）。
//  - 被指定「完成权限」的参与者提交延期：生成申请交给发起者审批；同意才改期。
//  - 无论同意或拒绝，都把结果提示同时投递到申请者的「通知通道」与「收件箱」。

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function notFound(message) {
  const err = new Error(message);
  err.status = 404;
  return err;
}

function forbidden(message) {
  const err = new Error(message);
  err.status = 403;
  return err;
}

function conflict(message) {
  const err = new Error(message);
  err.status = 409;
  return err;
}

async function requireMe(account) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    throw badRequest('需要账号身份才能延期');
  }
  const me = await findAccount(name);
  if (!me) {
    throw badRequest('当前账号不存在，请重新登录');
  }
  return me;
}

// 结果提示：同时投递到「通知通道」（服务 71）与「收件箱」（服务 42）。
// 两处各自 try/catch，互不阻塞主流程；返回投递成功的通道数。
async function sendExtendNotice({ request, approver, approved, newTime }) {
  const event = request.event || '未命名日程';
  const title = approved ? '延期申请已同意' : '延期申请被拒绝';
  const body = approved
    ? `${approver} 同意了你的申请，「${event}」的时间已调整至 ${newTime}，请及时完成`
    : `${approver} 拒绝了你的申请，「${event}」的时间没有变化，请及时完成`;
  let noticeSent = 0;
  try {
    const notice = await pushNotice({
      toAccount: request.fromAccount,
      fromAccount: approver,
      kind: approved ? 'extend-approved' : 'extend-rejected',
      groupId: request.groupId,
      cardIndex: request.cardIndex,
      event,
      title,
      body
    });
    if (notice) {
      noticeSent += 1;
    }
  } catch {
    // 通知通道写入失败不影响主流程
  }
  try {
    const mail = await pushMail({ toAccount: request.fromAccount, fromAccount: approver, title, body });
    if (mail) {
      noticeSent += 1;
    }
  } catch {
    // 收件箱投递失败不影响主流程
  }
  return noticeSent;
}

// 服务 67 cards.extend：提交延期。服务端自行判定角色——
// 发起者立即改期；被指定完成权限的参与者生成延期申请（targetTime 存快照，审批时按快照改期）。
export async function applyCardExtend({ account, groupId, cardIndex, time, endTime = null } = {}) {
  const me = await requireMe(account);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  if (!Number.isInteger(cardIndex) || cardIndex < 1) {
    throw badRequest('cardIndex must be a positive integer');
  }
  const group = await getGroupView(groupId, me.account);
  const card = (group.cards || []).find(c => c.index === cardIndex);
  if (!card) {
    throw notFound('卡片不存在或你无权查看');
  }

  // 发起者：时间立即改变
  if (group.owner === me.account) {
    const applied = await extendGroupCardTime(groupId, cardIndex, me.account, { time, endTime });
    return { mode: 'applied', ...applied };
  }

  // 参与者：只有被指定「完成权限」的成员才能延期，且改为向发起者发出申请
  if (card.completableBy !== me.account) {
    throw forbidden('只有卡片组创建者或被指定完成权限的成员才能延期该卡片');
  }
  if (card.completedAt) {
    throw conflict('该卡片已完成，无法延期');
  }
  const computed = computeExtendedTime(card.content, { time, endTime });
  const owner = await findAccount(group.owner);
  if (!owner) {
    throw notFound('卡片组创建者账号不存在');
  }
  const { request, created } = await createExtendRequest({
    groupId,
    cardIndex,
    fromAccount: me.account,
    fromUserId: me.userId,
    toAccount: owner.account,
    toUserId: owner.userId,
    targetTime: computed.start,
    targetEndTime: computed.end,
    targetReminderTime: computed.reminderTime,
    event: card.content.event ?? null
  });
  // 除投递到发起者的「延期申请」通道外，同时抄送一封邮件到其「收件箱」（服务 42）；
  // 仅在真正新建申请时抄送，避免重复提交时重复投递
  if (created) {
    try {
      const event = card.content.event || '未命名日程';
      await pushMail({
        toAccount: owner.account,
        fromAccount: me.account,
        title: `延期申请：${event}`,
        body: `${me.account} 申请把卡片组「${group.name}」中的卡片 #${cardIndex}（${event}）的时间延期至 ${computed.time}，请到「延期申请」处理。`
      });
    } catch {
      // 收件箱投递失败不影响延期申请主流程
    }
  }
  return {
    mode: 'requested',
    request,
    message: `已向发起者 ${owner.account} 提交延期申请（目标时间 ${computed.time}），等待对方同意`
  };
}

// 服务 68 cards.extend-requests：我（作为卡片组创建者）收到的、仍有效的延期申请。
// 卡片已被删除或已完成的申请视为失效，读时直接过滤（不必给各组操作加清理钩子）。
export async function getCardExtendInbox({ account } = {}) {
  const me = await requireMe(account);
  const requests = await listIncomingExtendRequests(me.account);
  const alive = [];
  for (const request of requests) {
    try {
      const group = await getGroupView(request.groupId, me.account);
      const card = (group.cards || []).find(c => c.index === request.cardIndex);
      if (card && !card.completedAt) {
        alive.push(request);
      }
    } catch {
      // 组已不存在或不可见：视为失效申请，不再展示
    }
  }
  return { account: me.account, requests: alive };
}

// 取「发给我的、仍待处理」的申请（原子取删，重复处理第二次即 404）
async function requireIncomingExtend(me, requestId) {
  if (!Number.isInteger(requestId)) {
    throw badRequest('requestId must be an integer');
  }
  const consumed = await consumeExtendRequest(requestId, me.account);
  if (consumed.reason === 'not-found') {
    throw notFound('延期申请不存在或已被处理');
  }
  if (consumed.reason === 'forbidden') {
    throw forbidden('该延期申请不是发给你的（只有卡片组创建者可以处理）');
  }
  return consumed.request;
}

// 服务 69 cards.extend-approve：同意延期申请，按申请里的时间快照改期。
// 申请提交后卡片可能已被完成/删除，故此处二次校验（extendGroupCardTime 会拦）。
export async function approveCardExtend({ account, requestId } = {}) {
  const me = await requireMe(account);
  const request = await requireIncomingExtend(me, requestId);
  const applied = await extendGroupCardTime(request.groupId, request.cardIndex, me.account, {
    time: request.targetTime,
    endTime: request.targetEndTime
  });
  const noticeSent = await sendExtendNotice({
    request,
    approver: me.account,
    approved: true,
    newTime: applied.time
  });
  return {
    request: {
      id: request.id,
      groupId: request.groupId,
      cardIndex: request.cardIndex,
      fromAccount: request.fromAccount,
      status: 'approved'
    },
    group: applied.group,
    time: applied.time,
    reminderTime: applied.reminderTime,
    noticeSent,
    message: `已同意 ${request.fromAccount} 的延期申请，卡片 #${request.cardIndex} 的时间已调整至 ${applied.time}`
  };
}

// 服务 70 cards.extend-reject：拒绝延期申请，卡片时间不变，并回执告知申请者
export async function rejectCardExtend({ account, requestId } = {}) {
  const me = await requireMe(account);
  const request = await requireIncomingExtend(me, requestId);
  const noticeSent = await sendExtendNotice({
    request,
    approver: me.account,
    approved: false,
    newTime: null
  });
  return {
    request: {
      id: request.id,
      groupId: request.groupId,
      cardIndex: request.cardIndex,
      fromAccount: request.fromAccount,
      status: 'rejected'
    },
    noticeSent,
    message: `已拒绝 ${request.fromAccount} 的延期申请，卡片 #${request.cardIndex} 的时间没有变化`
  };
}