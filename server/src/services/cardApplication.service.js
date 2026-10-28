import { findAccount, findAccountByUserId } from './accountStore.js';
import { parseParticipants } from './cardStore.js';
import { getGroupView, joinGroupCardByApproval } from './cardGroupStore.js';
import {
  createCardRequest,
  listIncomingCardRequests,
  listOutgoingCardRequests,
  getCardRequest,
  removeCardRequest
} from './cardRequestStore.js';
import { pushMail } from './mailboxStore.js';

// 卡片加入申请（重做后）：申请定位到「某卡片组内的一张卡片」（groupId + cardIndex）。
// 「需要申请」的组内卡片，他人点「+」先向组创建者发出申请，暂不写入参与人；
// 创建者同意后申请者写入该卡参与人并成为组成员（服务 25 / 26 / 27 / 28）。

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

function conflict(message) {
  const err = new Error(message);
  err.status = 409;
  return err;
}

function forbidden(message) {
  const err = new Error(message);
  err.status = 403;
  return err;
}

async function requireMe(account) {
  const me = await findAccount(account);
  if (!me) {
    throw badRequest('当前账号不存在，请重新登录');
  }
  return me;
}

// 取「发给我的、仍待处理」的申请；不存在/不是发给我的都直接报错
async function requireIncomingRequest(me, requestId) {
  if (!Number.isInteger(requestId)) {
    throw badRequest('requestId must be an integer');
  }
  const request = await getCardRequest(requestId);
  if (!request) {
    throw notFound('加入申请不存在');
  }
  if (request.toAccount !== me.account) {
    throw forbidden('该加入申请不是发给你的（只有卡片组创建者可以处理）');
  }
  return request;
}

// 发起加入申请：卡片「需要申请」时，他人点「+」先向组创建者发出申请，暂不写入参与人
export async function applyToCard({ account, groupId, cardIndex }) {
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
  if (group.owner === me.account) {
    throw badRequest('不能申请加入自己创建的卡片');
  }
  if (card.completedAt) {
    throw conflict('该卡片已完成，无法申请加入');
  }
  if (parseParticipants(card.content.participant).includes(me.account)) {
    throw conflict('你已经是该卡片的参与者');
  }
  if (card.content.needApproval !== true) {
    throw badRequest('该卡片无需申请，可直接加入');
  }
  if ((card.content.count ?? 1) >= card.content.capacity) {
    throw conflict(`人数已达上限（${card.content.capacity} 人），无法申请`);
  }
  const owner = await findAccount(group.owner);
  if (!owner) {
    throw notFound('卡片组创建者账号不存在');
  }
  const { request, created } = await createCardRequest({
    groupId,
    cardIndex,
    fromAccount: me.account,
    fromUserId: me.userId,
    toAccount: owner.account,
    toUserId: owner.userId
  });
  // 仅在真正新建申请时抄送收件箱，避免重复申请时重复投递
  if (created) {
    try {
      const event = card.content.event || '未命名日程';
      await pushMail({
        toAccount: owner.account,
        fromAccount: me.account,
        title: `卡片加入申请：${group.name} 卡片 #${cardIndex}`,
        body: `${me.account} 申请加入你创建的卡片组「${group.name}」中的卡片 #${cardIndex}（${event}），请到「卡片申请」处理。`
      });
    } catch {
      // 收件箱投递失败不影响加入申请主流程
    }
  }
  return { request, message: `已向创建者 ${owner.account} 发送加入申请，等待对方同意` };
}

// 卡片申请收件箱：别人申请加入我创建的卡片组内的卡片（待处理申请）
export async function getCardRequestInbox({ account }) {
  const me = await requireMe(account);
  return {
    account: me.account,
    requests: await listIncomingCardRequests(me.account)
  };
}

// 同意加入申请：把申请人写入该卡参与人（并成为组成员），并把申请从申请库删除
export async function approveCardRequest({ account, requestId }) {
  const me = await requireMe(account);
  const request = await requireIncomingRequest(me, requestId);
  const group = await getGroupView(request.groupId, me.account);
  if (group.owner !== me.account) {
    throw forbidden('只有卡片组创建者可以同意加入申请');
  }
  const card = (group.cards || []).find(c => c.index === request.cardIndex);
  if (!card) {
    throw notFound('卡片不存在或已被删除');
  }
  // 加入成功后才删除申请；人数已满等失败情况保留申请，便于创建者改选拒绝
  const joined = await joinGroupCardByApproval(request.groupId, request.cardIndex, request.fromAccount);
  await removeCardRequest(request.id);
  return {
    request: { id: request.id, groupId: request.groupId, cardIndex: request.cardIndex, fromAccount: request.fromAccount, status: 'approved' },
    group: joined,
    message: `已同意 ${request.fromAccount} 加入卡片组「${joined.name}」的卡片 #${request.cardIndex}`
  };
}

// 拒绝加入申请：不写入参与人，直接把申请从申请库删除（对方之后可再次申请）
export async function rejectCardRequest({ account, requestId }) {
  const me = await requireMe(account);
  const request = await requireIncomingRequest(me, requestId);
  await removeCardRequest(request.id);
  return {
    request: { id: request.id, groupId: request.groupId, cardIndex: request.cardIndex, fromAccount: request.fromAccount, status: 'rejected' },
    message: `已拒绝 ${request.fromAccount} 加入卡片 #${request.cardIndex} 的申请`
  };
}

// 我发出的未处理加入申请（「组号:组内编号」字符串集合）：供公开卡片组库标记「已申请」状态
export async function listAppliedCardKeys(account) {
  if (typeof account !== 'string' || account.trim() === '') {
    return [];
  }
  const outgoing = await listOutgoingCardRequests(account.trim());
  return outgoing.filter(r => r.status === 'pending').map(r => `${r.groupId}:${r.cardIndex}`);
}
