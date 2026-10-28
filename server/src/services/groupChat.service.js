import { findAccount } from './accountStore.js';
import { getGroupView } from './cardGroupStore.js';
import { fanoutGroupMessage, takeGroupMessagesFor } from './groupChatStore.js';

// 卡片组群聊业务：一个公开/私人卡片组对应一个群聊会话，成员 = 组创建者（发起者）+ 组成员
// （加入任一组内卡片即成为组成员），故「此卡片组卡片的所有参与者和发起者」天然都在群聊里。
// 服务器只做「短期中转、送达即删」（groupChatStore）：发送消息时按当前花名册 fan-out 到
// 每个其他成员的中转副本，各成员客户端拉取（102）后合并进自己的本地群聊记录；
// 群聊记录的长期保存完全由客户端负责，服务器不存历史。
// 「发送卡片」= 把本人创建的公开卡片组里的某张卡片以快照分享到群里，
// 其他成员点「加入」走原加入链路（cards.join 14 / 需申请的卡走 cards.apply 25），由客户端直接调用。

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
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    throw badRequest('需要账号身份才能使用群聊');
  }
  const me = await findAccount(name);
  if (!me) {
    throw badRequest('当前账号不存在，请重新登录');
  }
  return me;
}

/** 校验我是该卡片组成员（创建者或成员），返回组视图（含实时花名册） */
async function requireMemberGroup(account, groupId) {
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  const group = await getGroupView(groupId, account);
  if (group.role === null) {
    throw forbidden('只有卡片组成员才能进入群聊，先加入该卡片组吧');
  }
  return group;
}

/** 花名册：创建者 + 全部成员（去重） */
function rosterOf(group) {
  const roster = [group.owner];
  for (const member of group.members || []) {
    if (!roster.includes(member)) {
      roster.push(member);
    }
  }
  return roster;
}

// 服务 100 group-chat.send-text：向群聊发送文字消息（fan-out 到其他成员的中转箱）
export async function sendGroupChatText({ account, groupId, text }) {
  const me = await requireMe(account);
  const group = await requireMemberGroup(me.account, groupId);
  const content = typeof text === 'string' ? text.trim() : '';
  if (content === '') {
    throw badRequest('消息内容不能为空');
  }
  const roster = rosterOf(group).filter(name => name !== me.account);
  const sent = await fanoutGroupMessage({
    groupId: group.id,
    fromAccount: me.account,
    kind: 'text',
    text: content
  }, roster);
  return {
    sent,
    groupId: group.id,
    message: `已向「${group.name}」群聊发送消息`
  };
}

// 服务 101 group-chat.send-card：把本人创建的公开卡片组里的某张卡片作为快照分享进群聊
// （卡片内容以发送时刻快照保存；其他成员在聊天里点「加入」走 14/25 原加入链路）
export async function sendGroupChatCard({ account, groupId, cardGroupId, cardIndex }) {
  const me = await requireMe(account);
  const group = await requireMemberGroup(me.account, groupId);
  if (!Number.isInteger(cardGroupId) || cardGroupId < 1) {
    throw badRequest('cardGroupId must be a positive integer');
  }
  if (!Number.isInteger(cardIndex) || cardIndex < 1) {
    throw badRequest('cardIndex must be a positive integer');
  }
  // 只有卡片所在组的创建者可分享自己的卡片；同时借 getGroupView 校验组存在
  const source = await getGroupView(cardGroupId, me.account);
  if (source.role !== 'owner') {
    throw conflict('只能分享自己创建的卡片组里的卡片');
  }
  if (source.library !== 'public') {
    throw conflict('只能分享公开卡片组里的卡片；私人卡片组请先「转公开」');
  }
  const card = (source.cards || []).find(c => c.index === cardIndex);
  if (!card) {
    throw notFound('组内卡片不存在');
  }
  if (card.completedAt) {
    throw conflict('该卡片已完成，无需分享');
  }
  const roster = rosterOf(group).filter(name => name !== me.account);
  const sent = await fanoutGroupMessage({
    groupId: group.id,
    fromAccount: me.account,
    kind: 'card',
    text: `分享了卡片组「${source.name}」的卡片 #${cardIndex}：${card.content.purpose || '-'} / ${card.content.event}`,
    cardIndex,
    cardGroupId: source.id,
    card: card.content
  }, roster);
  return {
    sent,
    groupId: group.id,
    message: `已把「${source.name}」的卡片 #${cardIndex} 分享到「${group.name}」群聊`
  };
}

// 服务 102 group-chat.messages：拉取我在该群的中转消息（拉取即删），同时带回组花名册
// （创建者 + 成员）供群聊页展示成员数；群聊历史由客户端本地记录，本服务只分发新消息。
export async function pullGroupChatMessages({ account, groupId }) {
  const me = await requireMe(account);
  const group = await requireMemberGroup(me.account, groupId);
  const taken = await takeGroupMessagesFor(me.account, group.id);
  return {
    account: me.account,
    groupId: group.id,
    group: {
      id: group.id,
      name: group.name,
      owner: group.owner,
      library: group.library,
      members: group.members,
      memberCount: group.memberCount
    },
    total: taken.messages.length,
    messages: taken.messages
  };
}
