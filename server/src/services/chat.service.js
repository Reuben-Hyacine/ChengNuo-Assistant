import { findAccount } from './accountStore.js';
import { areFriends, listFriendsOf } from './friend.service.js';
import { parseParticipants } from './cardStore.js';
import { applyToCard } from './cardApplication.service.js';
import { getGroupView, joinGroup, joinGroupCard } from './cardGroupStore.js';
import {
  pushMessage,
  listConversationsOf,
  listMessagesBetween,
  getMessage,
  markMessageAccepted,
  takeMessagesFor
} from './chatStore.js';

// 好友聊天业务：只允许好友之间互发消息（文字 / 卡片邀请 / 卡片组邀请）。
// 「发送卡片」= 把本人发起的公开卡片以快照形式发到聊天里，邀请对方加入；
// 「接受邀请」= 对方在聊天里点击接受，需要申请的卡片自动转为加入申请，否则直接写入参与人。
// 「发送卡片组」= 把本人创建的卡片组（大事件）发到聊天里邀请对方加入；
// 「接受卡片组邀请」= 对方加入卡片组（成员名单 + 自动加入组内未满的卡片）。
// 本地化改造后：服务器只做「短期中转、送达即删」——消息发送至此仅等待对方客户端拉取（服务 64 relay.pull），
// 拉取成功后立即从服务器删除；好友对话的长期保存由客户端负责（服务 45/46 由客户端本地应答）。

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

async function requireMe(account) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    throw badRequest('需要账号身份才能使用聊天');
  }
  const me = await findAccount(name);
  if (!me) {
    throw badRequest('当前账号不存在，请重新登录');
  }
  return me;
}

async function requireFriendTarget(me, toAccount) {
  const name = typeof toAccount === 'string' ? toAccount.trim() : '';
  if (name === '') {
    throw badRequest('需要指定对方账号（toAccount）');
  }
  const target = await findAccount(name);
  if (!target) {
    throw notFound('对方账号不存在');
  }
  if (target.userId === me.userId) {
    throw badRequest('不能和自己聊天');
  }
  if (!(await areFriends(me.userId, target.userId))) {
    throw conflict(`${target.account} 不是你的好友，只能与好友聊天`);
  }
  return target;
}

// 服务 45 chat.list：我的会话总览（全部好友都在列，没聊过的也可以发起会话；附最后一条消息与未读数）
export async function listMyChats({ account }) {
  const me = await requireMe(account);
  const friends = await listFriendsOf(me.account);
  const byPeer = new Map(friends.map(f => [f.account, {
    peer: f.account,
    userId: f.userId,
    unread: 0,
    total: 0,
    lastAt: null,
    lastFromMe: null,
    lastKind: null,
    lastSummary: null
  }]));
  const conversations = await listConversationsOf(me.account);
  for (const conv of conversations) {
    const item = byPeer.get(conv.peer);
    if (item) {
      Object.assign(item, conv);
    }
  }
  const list = [...byPeer.values()]
    .sort((a, b) => (b.lastAt ?? 0) - (a.lastAt ?? 0) || a.peer.localeCompare(b.peer));
  const unread = list.reduce((sum, c) => sum + c.unread, 0);
  return { account: me.account, total: list.length, unread, conversations: list };
}

// 服务 46 chat.messages：与某好友的聊天记录（按时间正序），拉取时把对方发来的未读消息标记为已读
export async function getChatMessages({ account, withAccount }) {
  const me = await requireMe(account);
  const target = await requireFriendTarget(me, withAccount);
  const messages = await listMessagesBetween(me.account, target.account);
  return { account: me.account, withAccount: target.account, total: messages.length, messages };
}

// 服务 47 chat.send-text：向好友发送文字消息
export async function sendChatText({ account, toAccount, text }) {
  const me = await requireMe(account);
  const target = await requireFriendTarget(me, toAccount);
  const content = typeof text === 'string' ? text.trim() : '';
  if (content === '') {
    throw badRequest('消息内容不能为空');
  }
  const sent = await pushMessage({
    fromAccount: me.account,
    toAccount: target.account,
    kind: 'text',
    text: content
  });
  return { sent, to: target.account, message: `已向 ${target.account} 发送消息` };
}

// 服务 48 chat.send-card：把一个公开卡片组里的某张卡片作为邀请发进聊天（卡片内容以发送时刻的快照保存）。
// 创建者发送自己组内的卡片（聊天页「发送卡片」）；非创建者可转发发现页看到的公开卡片（详情页「转发给好友」），
// 对方经 49 接受后走正常加入 / 需申请卡转申请的流程。
export async function sendChatCard({ account, toAccount, groupId, cardIndex }) {
  const me = await requireMe(account);
  const target = await requireFriendTarget(me, toAccount);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  if (!Number.isInteger(cardIndex) || cardIndex < 1) {
    throw badRequest('cardIndex must be a positive integer');
  }
  // 借 getGroupView 校验组存在（公开卡片组对所有登录用户可见可转发；私人组对非成员由 getGroupView 拦截）
  const group = await getGroupView(groupId, me.account);
  if (group.library !== 'public') {
    throw conflict('只能发送公开卡片组里的卡片；私人卡片组请先「转公开」');
  }
  const card = (group.cards || []).find(c => c.index === cardIndex);
  if (!card) {
    throw notFound('组内卡片不存在');
  }
  if (card.completedAt) {
    throw conflict('该卡片已完成，无需邀请');
  }
  if (parseParticipants(card.content.participant).includes(target.account)) {
    throw conflict(`${target.account} 已经是该卡片的参与者，无需邀请`);
  }
  const sent = await pushMessage({
    fromAccount: me.account,
    toAccount: target.account,
    kind: 'card',
    text: `邀请你加入卡片组「${group.name}」的卡片 #${cardIndex}：${card.content.purpose || '-'} / ${card.content.event}`,
    cardIndex,
    groupId: group.id,
    card: card.content
  });
  return {
    sent,
    to: target.account,
    message: `已把卡片组「${group.name}」的卡片 #${cardIndex} 发送给 ${target.account}，等待对方接受邀请`
  };
}

// 确定卡片后给「记日程时邀请的好友」自动补发聊天邀请：
// 这些好友已被写入卡片参与人文本，但尚未加入卡片组，看不到这张卡片；
// 补发一条可点「接受邀请」的消息，对方接受后即加入卡片组并可见。
// 与服务 48 的差异：不拒绝「已是参与人」（正是本场景）；已是组成员 / 非公开组 / 卡片缺失或已完成时静默跳过，不报错。
export async function sendCardInviteToParticipant({ account, toAccount, groupId, cardIndex }) {
  const me = await requireMe(account);
  const target = await requireFriendTarget(me, toAccount);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  if (!Number.isInteger(cardIndex) || cardIndex < 1) {
    throw badRequest('cardIndex must be a positive integer');
  }
  const group = await getGroupView(groupId, me.account);
  if (group.role !== 'owner') {
    throw conflict('只能发送自己创建的卡片组里的卡片');
  }
  if (group.library !== 'public') {
    return null; // 私人卡片组不走聊天邀请
  }
  const card = (group.cards || []).find(c => c.index === cardIndex);
  if (!card || card.completedAt) {
    return null; // 卡片不存在或已完成
  }
  if ((group.members || []).includes(target.account)) {
    return null; // 已是组成员，无需邀请
  }
  return await pushMessage({
    fromAccount: me.account,
    toAccount: target.account,
    kind: 'card',
    text: `邀请你加入卡片组「${group.name}」的卡片 #${cardIndex}：${card.content.purpose || '-'} / ${card.content.event}`,
    cardIndex,
    groupId: group.id,
    card: card.content
  });
}

// 服务 49 chat.accept-card：接受聊天里的卡片邀请
// 加入该卡片（同时成为卡片组成员）；卡片已设「需要申请」→ 自动向创建者发送加入申请
export async function acceptChatCard({ account, messageId }) {
  const me = await requireMe(account);
  if (!Number.isInteger(messageId)) {
    throw badRequest('messageId must be an integer');
  }
  const message = await getMessage(messageId);
  if (!message) {
    throw notFound('聊天消息不存在');
  }
  if (message.kind !== 'card') {
    throw badRequest('该消息不是卡片邀请');
  }
  if (message.toAccount !== me.account) {
    const err = new Error('这张卡片邀请不是发给你的');
    err.status = 403;
    throw err;
  }
  if (message.acceptedAt !== null) {
    throw conflict('你已经接受过这条卡片邀请了');
  }
  if (!Number.isInteger(message.groupId) || !Number.isInteger(message.cardIndex)) {
    throw notFound('卡片邀请缺少组号或卡号，无法加入');
  }
  // 校验卡片仍存在（组/卡可能已被创建者删除）；不在此处提前加入，交给下方加入/申请流程
  const group = await getGroupView(message.groupId, me.account);
  const card = (group.cards || []).find(c => c.index === message.cardIndex);
  if (!card || !card.content.event) {
    throw notFound('卡片已被创建者删除，无法加入');
  }
  let joined = null;
  let applied = null;
  if (card.content.needApproval === true) {
    applied = await applyToCard({ account: me.account, groupId: message.groupId, cardIndex: message.cardIndex });
  } else {
    joined = await joinGroupCard(message.groupId, message.cardIndex, me.account);
  }
  const updated = await markMessageAccepted(messageId);
  return {
    accepted: { id: updated.id, acceptedAt: updated.acceptedAt },
    group: joined ? { id: joined.id, name: joined.name, owner: joined.owner, cardIndex: message.cardIndex } : null,
    card: joined ? (joined.cards.find(c => c.index === message.cardIndex) ?? null) : null,
    applied: applied ? { request: applied.request } : null,
    needApproval: card.content.needApproval === true,
    message: applied
      ? `已向创建者 ${group.owner} 发送加入卡片 #${message.cardIndex} 的申请，等待对方同意`
      : `已加入卡片组「${group.name}」的卡片 #${message.cardIndex}，你已成为参与者`
  };
}

// 服务 59 chat.send-group：把我创建的一张卡片组（大事件）作为邀请发进聊天。
// 消息带发送时刻的组快照（组号 / 组名 / 卡片数）；只有组创建者能发送自己的卡片组
export async function sendChatGroup({ account, toAccount, groupId }) {
  const me = await requireMe(account);
  const target = await requireFriendTarget(me, toAccount);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  // 只有创建者可发送；同时借 getGroupView 校验组存在
  const group = await getGroupView(groupId, me.account);
  if (group.role !== 'owner') {
    const err = new Error('只有创建者才能发送这个卡片组');
    err.status = 403;
    throw err;
  }
  if (group.members.includes(target.account)) {
    throw conflict(`${target.account} 已经是该卡片组的成员，无需邀请`);
  }
  // 组人数上限（服务 98）：组满员时不再发出新邀请（接受侧 joinGroup 兜底拦截）
  if (group.memberCap !== null && group.memberCap !== undefined
    && 1 + group.memberCount + 1 > group.memberCap) {
    throw conflict(`该卡片组人数已满（上限 ${group.memberCap} 人，含创建者），无法邀请新成员`);
  }
  const sent = await pushMessage({
    fromAccount: me.account,
    toAccount: target.account,
    kind: 'group',
    text: `邀请你加入卡片组「${group.name}」（大事件，含 ${group.cardCount} 张卡片）`,
    groupId: group.id,
    group: { id: group.id, name: group.name, owner: group.owner, cardCount: group.cardCount }
  });
  return {
    sent,
    to: target.account,
    message: `已把卡片组「${group.name}」发送给 ${target.account}，等待对方接受邀请`
  };
}

// 服务 60 chat.accept-group：接受聊天里的卡片组邀请
// 加入卡片组：写入成员名单，并自动加入组内全部未满的卡片（人数已满的卡片跳过，不阻塞整组加入）
export async function acceptChatGroup({ account, messageId }) {
  const me = await requireMe(account);
  if (!Number.isInteger(messageId)) {
    throw badRequest('messageId must be an integer');
  }
  const message = await getMessage(messageId);
  if (!message) {
    throw notFound('聊天消息不存在');
  }
  if (message.kind !== 'group') {
    throw badRequest('该消息不是卡片组邀请');
  }
  if (message.toAccount !== me.account) {
    const err = new Error('这个卡片组邀请不是发给你的');
    err.status = 403;
    throw err;
  }
  if (message.acceptedAt !== null) {
    throw conflict('你已经接受过这个卡片组邀请了');
  }
  if (!Number.isInteger(message.groupId)) {
    throw notFound('卡片组邀请缺少组号，无法加入');
  }
  // 组可能已被创建者删除：joinGroup 内部会抛 404
  const joined = await joinGroup(message.groupId, me.account);
  const updated = await markMessageAccepted(messageId);
  const g = joined.group;
  return {
    accepted: { id: updated.id, acceptedAt: updated.acceptedAt },
    group: { id: g.id, name: g.name, owner: g.owner, cardCount: g.cardCount },
    joinedCards: joined.joinedCards,
    skippedCards: joined.skippedCards,
    message: joined.already
      ? `你已是卡片组「${g.name}」的成员；本次新加入 ${joined.joinedCards} 张卡片（${joined.skippedCards} 张已满或已加入，已跳过）`
      : `已加入卡片组「${g.name}」（含 ${g.cardCount} 张卡片），其中自动加入 ${joined.joinedCards} 张（${joined.skippedCards} 张已满或已加入，已跳过）`
  };
}

// 服务 64 relay.pull：拉取服务器中转箱里发给我的全部消息，拉取即删（服务器不长期保存好友对话）。
// 客户端拿到后合并进本地聊天记录，之后再以服务 45/46 本地应答 App 的轮询。
export async function pullRelayMessages({ account }) {
  const me = await requireMe(account);
  const taken = await takeMessagesFor(me.account);
  return { account: me.account, total: taken.messages.length, messages: taken.messages };
}
