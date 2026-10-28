import { listAccounts, findAccount, findAccountByUserId } from './accountStore.js';
import { getRelation, getUserRelations, setRelation, clearRelation, MAX_USERS } from './userRelationStore.js';
import {
  createRequest,
  listIncoming,
  listOutgoing,
  getRequest,
  removeRequest
} from './friendRequestStore.js';
import { pushMail } from './mailboxStore.js';
import { getProfileOf } from './profileStore.js';

// 关系库中标记好友关系的内容值
const FRIEND = 'friend';

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
  const me = await findAccount(account);
  if (!me) {
    throw badRequest('当前账号不存在，请重新登录');
  }
  return me;
}

function assertRelationCapacity(userId) {
  if (!Number.isInteger(userId) || userId < 1 || userId > MAX_USERS) {
    throw badRequest(`关系库仅支持编号 1-${MAX_USERS} 的用户`);
  }
}

async function isFriend(userId, targetId) {
  const rel = await getRelation(userId, targetId);
  return !!(rel && rel.content === FRIEND);
}

// 供卡片邀请判断：两个账号是否为好友关系（双向记录，单向查到即可）
export async function areFriends(userId, targetId) {
  if (!Number.isInteger(userId) || !Number.isInteger(targetId)) {
    return false;
  }
  return isFriend(userId, targetId);
}

// 关系库中该账号的好友列表（双向记录，取 content=friend 的槽位）
async function listFriends(userId) {
  const { relations } = await getUserRelations(userId);
  const friends = [];
  for (const rel of relations) {
    if (rel.userId === rel.targetId || rel.content !== FRIEND) {
      continue;
    }
    const target = await findAccountByUserId(rel.targetId);
    if (target) {
      friends.push({ userId: target.userId, account: target.account, since: rel.updatedAt });
    }
  }
  return friends;
}

// 供聊天业务使用：某账号的好友列表（userId + account）
export async function listFriendsOf(account) {
  const me = await requireMe(account);
  return listFriends(me.userId);
}

// 供 AI 邀请使用：账号列表 + 与当前账号的关系状态（invitable=true 才可邀请）
export async function listInvitableAccounts(account) {
  const me = await requireMe(account);
  const all = await listAccounts();
  const friends = new Set((await listFriends(me.userId)).map(f => f.userId));
  return all
    .filter(u => u.userId !== me.userId)
    .map(u => ({
      account: u.account,
      userId: u.userId,
      state: friends.has(u.userId) ? 'friend' : 'none',
      invitable: friends.has(u.userId)
    }));
}

// 用户列表（支持关键词搜索：账号或 UID，UID 支持原值 / 5 位补零两种输入如 1 或 00001）：
// 带上「与当前账号的关系状态」，供客户端渲染与按钮状态
export async function listUsersFor({ account, keyword }) {
  const me = await requireMe(account);
  const kw = typeof keyword === 'string' ? keyword.trim().toLowerCase() : '';
  const all = await listAccounts();
  const outgoing = await listOutgoing(me.account);
  const incoming = await listIncoming(me.account);
  const friends = await listFriends(me.userId);

  const users = [];
  for (const u of all) {
    if (u.userId === me.userId) {
      continue; // 用户列表中不展示自己
    }
    const uidRaw = String(u.userId);
    const uidPadded = uidRaw.padStart(5, '0');
    if (kw && !u.account.toLowerCase().includes(kw) && kw !== uidRaw && kw !== uidPadded) {
      continue;
    }
    let state = 'none';
    if (friends.some(f => f.userId === u.userId)) {
      state = 'friend';
    } else if (outgoing.some(r => r.toUserId === u.userId && r.status === 'pending')) {
      state = 'requested';
    } else if (incoming.some(r => r.fromUserId === u.userId)) {
      state = 'incoming';
    }
    users.push({ userId: u.userId, account: u.account, state });
  }
  return { account: me.account, keyword: kw, total: users.length, users };
}

// 点击「+」发送好友申请：申请写入服务器申请库，等待对方登录后在收件箱处理。
// 除投递到对方的「好友收件箱」通道外，同时抄送一封邮件到对方「收件箱」（服务 42）。
export async function sendFriendRequest({ account, toAccount, toUserId }) {
  const me = await requireMe(account);
  let target = null;
  if (Number.isInteger(toUserId)) {
    target = await findAccountByUserId(toUserId);
  } else if (typeof toAccount === 'string' && toAccount.trim() !== '') {
    target = await findAccount(toAccount.trim());
  }
  if (!target) {
    throw notFound('目标用户不存在');
  }
  if (target.userId === me.userId) {
    throw badRequest('不能添加自己为好友');
  }
  assertRelationCapacity(target.userId);
  if (await isFriend(me.userId, target.userId)) {
    throw conflict(`${target.account} 已经是你的好友`);
  }
  const { request, created } = await createRequest({
    fromAccount: me.account,
    fromUserId: me.userId,
    toAccount: target.account,
    toUserId: target.userId
  });
  // 仅在真正新建申请时抄送收件箱，避免重复点「+」时重复投递
  if (created) {
    try {
      await pushMail({
        toAccount: target.account,
        fromAccount: me.account,
        title: `好友申请：${me.account}`,
        body: `${me.account} 请求添加你为好友，请到「好友收件箱」处理。`
      });
    } catch {
      // 收件箱投递失败不影响好友申请主流程
    }
  }
  return { request, message: `已向 ${target.account} 发送好友申请` };
}

// 删除好友：无需申请，直接解除双方关系（关系库中双向清空）
export async function removeFriend({ account, toAccount, toUserId }) {
  const me = await requireMe(account);
  let target = null;
  if (Number.isInteger(toUserId)) {
    target = await findAccountByUserId(toUserId);
  } else if (typeof toAccount === 'string' && toAccount.trim() !== '') {
    target = await findAccount(toAccount.trim());
  }
  if (!target) {
    throw notFound('目标用户不存在');
  }
  if (target.userId === me.userId) {
    throw badRequest('不能删除自己');
  }
  assertRelationCapacity(target.userId);
  if (!(await isFriend(me.userId, target.userId))) {
    throw conflict(`${target.account} 不是你的好友`);
  }
  // 双方关系一并解除
  await clearRelation(me.userId, target.userId);
  await clearRelation(target.userId, me.userId);
  return {
    removed: { userId: me.userId, targetId: target.userId, account: target.account },
    message: `已解除与 ${target.account} 的好友关系（双方关系已直接解除）`
  };
}

// 卡片可见性：带「仅好友」字段的卡片，只有发起者本人、以及与发起者为好友关系的账号可以查看；
// 其余账号看到的该槽位内容置空（保持 20 槽位结构不变）
export async function filterVisibleCards(slots, account) {
  const list = Array.isArray(slots) ? slots : [];
  if (!list.some(s => s && s.content && s.content.friendOnly === true)) {
    return list;
  }
  const me = (typeof account === 'string' && account.trim() !== '') ? await findAccount(account.trim()) : null;
  const friendIds = new Set();
  if (me) {
    const { relations } = await getUserRelations(me.userId);
    for (const rel of relations) {
      if (rel.content === FRIEND) {
        friendIds.add(rel.targetId);
      }
    }
  }
  const accounts = await listAccounts();
  const userIdByAccount = new Map(accounts.map(u => [u.account, u.userId]));
  return list.map(s => {
    const c = s && s.content;
    if (!c || c.friendOnly !== true) {
      return s;
    }
    const initiator = typeof c.initiator === 'string' ? c.initiator : '';
    if (me && initiator === me.account) {
      return s; // 发起者本人始终可见
    }
    const ownerId = userIdByAccount.get(initiator);
    if (ownerId !== undefined && friendIds.has(ownerId)) {
      return s; // 与发起者是好友关系
    }
    return { ...s, content: null };
  });
}

// 收件箱：待处理的好友申请 + 已有好友（好友来自关系库）
export async function getInbox({ account }) {
  const me = await requireMe(account);
  const friends = await listFriends(me.userId);
  // 好友头像摘要：hasAvatar / avatarUpdatedAt 供客户端决定是否拉取头像（92 profile.avatar）
  for (const friend of friends) {
    const found = await getProfileOf(friend.account);
    friend.hasAvatar = found.profile !== null && found.profile.hasAvatar === true;
    friend.avatarUpdatedAt = found.profile !== null && typeof found.profile.updatedAt === 'string'
      ? found.profile.updatedAt
      : null;
  }
  return {
    account: me.account,
    requests: await listIncoming(me.account),
    friends
  };
}

// 取出「发给我的、仍待处理」的申请；不存在/不是发给我的/已处理都直接报错
async function requireIncomingRequest(me, requestId) {
  if (!Number.isInteger(requestId)) {
    throw badRequest('requestId must be an integer');
  }
  const request = await getRequest(requestId);
  if (!request) {
    throw notFound('好友申请不存在');
  }
  if (request.toUserId !== me.userId) {
    const err = new Error('该好友申请不是发给你的');
    err.status = 403;
    throw err;
  }
  if (request.status !== 'pending') {
    throw conflict('该好友申请已处理');
  }
  return request;
}

// 同意好友申请：在关系库中双向记录好友关系，随后把申请从申请库删除
export async function acceptFriendRequest({ account, requestId }) {
  const me = await requireMe(account);
  const request = await requireIncomingRequest(me, requestId);
  assertRelationCapacity(request.fromUserId);
  await setRelation(request.fromUserId, request.toUserId, FRIEND);
  await setRelation(request.toUserId, request.fromUserId, FRIEND);
  // 已处理：申请从申请库删除，不再保留
  await removeRequest(request.id);
  return {
    request: { id: request.id, fromAccount: request.fromAccount, status: 'accepted' },
    relation: { userId: request.fromUserId, targetId: request.toUserId, content: FRIEND },
    message: `已同意 ${request.fromAccount} 的好友申请，关系已写入关系库`
  };
}

// 拒绝好友申请：不写关系库，直接把申请从申请库删除（对方之后可再次发起申请）
export async function rejectFriendRequest({ account, requestId }) {
  const me = await requireMe(account);
  const request = await requireIncomingRequest(me, requestId);
  await removeRequest(request.id);
  return {
    request: { id: request.id, fromAccount: request.fromAccount, status: 'rejected' },
    message: `已拒绝 ${request.fromAccount} 的好友申请`
  };
}
