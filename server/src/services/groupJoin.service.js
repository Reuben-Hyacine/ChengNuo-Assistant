import { findAccount } from './accountStore.js';
import { getGroupView, joinGroup, setGroupJoinMode, setGroupMemberCap } from './cardGroupStore.js';
import {
  createGroupJoinRequest,
  listIncomingGroupJoins,
  listGroupJoinRequestsByGroup,
  listOutgoingGroupJoins,
  getGroupJoinRequest,
  removeGroupJoinRequest
} from './groupJoinStore.js';
import { pushMail } from './mailboxStore.js';
import { checkText, moderationPrefix } from './moderation.service.js';

// 组加入审核（二期）：卡片组创建者可把组设为「审核加入」（106）——
// 其他人加入整组（65 / 60）与直接加入组内卡片（14 / 49）都会被服务器拦截，
// 须先提交入组申请（107，可附 ≤200 字陈述），由创建者同意（109）或拒绝（110），
// 申请人也可在处理前撤回（111）；创建者切回「自由加入」时，存量待处理申请自动通过。
// 组内卡片级别的「需要申请」（25-28）不受影响：卡片申请由创建者逐卡审批，视为组级默许。

const MAX_STATEMENT_LEN = 200;

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

// 取「发给我的、仍待处理」的入组申请；不存在/不是发给我的都直接报错
async function requireIncomingJoin(me, requestId) {
  if (!Number.isInteger(requestId)) {
    throw badRequest('requestId must be an integer');
  }
  const request = await getGroupJoinRequest(requestId);
  if (!request) {
    throw notFound('入组申请不存在');
  }
  if (request.toAccount !== me.account) {
    throw forbidden('该入组申请不是发给你的（只有卡片组创建者可以处理）');
  }
  return request;
}

// 设置组加入模式（106 groups.set-join-mode）：open=自由加入 / review=审核加入，仅创建者可改。
// 切回 open 时存量待处理申请自动通过（逐个加入并回执）；切 review 不处理存量。
export async function setGroupJoinModeOf({ account, groupId, joinMode }) {
  const me = await requireMe(account);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  if (joinMode !== 'open' && joinMode !== 'review') {
    throw badRequest('joinMode must be "open" or "review"');
  }
  const group = await setGroupJoinMode(groupId, me.account, joinMode);
  let autoApproved = 0;
  if (joinMode === 'open') {
    const pending = await listGroupJoinRequestsByGroup(group.id);
    for (const req of pending) {
      // 申请人已注销：清除申请，不投递
      const applicant = await findAccount(req.fromAccount);
      if (!applicant) {
        await removeGroupJoinRequest(req.id);
        continue;
      }
      try {
        await joinGroup(req.groupId, req.fromAccount, { viaApproval: true });
        await removeGroupJoinRequest(req.id);
        autoApproved += 1;
        try {
          await pushMail({
            toAccount: req.fromAccount,
            fromAccount: me.account,
            title: `入组申请已通过：${req.groupName}`,
            body: `${me.account} 已把卡片组「${req.groupName}」切换为自由加入，并自动通过了你的入组申请，你已成为该组成员。`
          });
        } catch {
          // 回执投递失败不影响自动通过主流程
        }
      } catch {
        // 加入失败（人数已满等极端情况）：仍移除申请，避免悬挂
        await removeGroupJoinRequest(req.id);
      }
    }
  }
  return {
    group,
    autoApproved,
    message: joinMode === 'review'
      ? '已开启审核加入：新成员加入须先提交申请，由你审批'
      : (autoApproved > 0 ? `已切换为自由加入，自动通过了 ${autoApproved} 个待处理申请` : '已切换为自由加入')
  };
}

// 组人数上限（98 groups.set-member-cap）：创建者限制卡片组总人数（含创建者），
// 2~99 整数，null / 0 = 不限；不得低于当前组内总人数。加入整组 / 组内卡片 /
// 接受聊天组邀请的成员名单增长点统一拦截，审核通过路径同样受限。
export async function setGroupMemberCapOf({ account, groupId, memberCap }) {
  const me = await requireMe(account);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  const group = await setGroupMemberCap(groupId, me.account, memberCap);
  return {
    group,
    message: group.memberCap === null
      ? '已取消组人数上限'
      : `组人数上限已设为 ${group.memberCap} 人（含创建者）`
  };
}

// 提交入组申请（107 groups.apply）：仅公开 + 审核加入的卡片组；申请人须非创建者、非成员；
// 陈述可选（≤200 字，非空须过智能审核）；同一申请人对同一组的未处理申请去重。
export async function applyToJoinGroup({ account, groupId, statement }) {
  const me = await requireMe(account);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  const group = await getGroupView(groupId, me.account);
  if (group.library !== 'public') {
    throw badRequest('私人卡片组不能申请加入，需由创建者通过聊天邀请');
  }
  if (group.owner === me.account) {
    throw badRequest('不能申请加入自己创建的卡片组');
  }
  if (group.role === 'member') {
    throw conflict('你已是该卡片组的成员，无需申请');
  }
  if (group.joinMode !== 'review') {
    throw badRequest('该卡片组未开启审核加入，可直接加入');
  }
  const text = typeof statement === 'string' ? statement.trim() : '';
  if (text.length > MAX_STATEMENT_LEN) {
    throw badRequest(`申请陈述最长 ${MAX_STATEMENT_LEN} 字`);
  }
  if (text !== '') {
    const moderation = checkText(text);
    if (!moderation.pass) {
      throw conflict(`${moderationPrefix(moderation)}，申请未提交`);
    }
  }
  const owner = await findAccount(group.owner);
  if (!owner) {
    throw notFound('卡片组创建者账号不存在');
  }
  const { request, created } = await createGroupJoinRequest({
    groupId: group.id,
    groupName: group.name,
    fromAccount: me.account,
    fromUserId: me.userId,
    toAccount: owner.account,
    toUserId: owner.userId,
    statement: text
  });
  // 仅在真正新建申请时抄送收件箱，避免重复申请时重复投递
  if (created) {
    try {
      await pushMail({
        toAccount: owner.account,
        fromAccount: me.account,
        title: `入组申请：${group.name}`,
        body: `${me.account} 申请加入你创建的卡片组「${group.name}」${text === '' ? '' : `，附言：${text}`}，请到「入组申请」处理。`
      });
    } catch {
      // 收件箱投递失败不影响申请主流程
    }
  }
  return {
    request,
    message: created ? `已提交入组申请，等待创建者 ${owner.account} 同意` : '已提交过入组申请，请等待创建者处理'
  };
}

// 入组申请收件箱（108 groups.join-requests）：别人申请加入我创建的卡片组（待处理申请）
export async function getGroupJoinInbox({ account }) {
  const me = await requireMe(account);
  return {
    account: me.account,
    requests: await listIncomingGroupJoins(me.account)
  };
}

// 同意入组申请（109 groups.join-approve）：申请人加入整组（自动加入组内未满且未完成的卡片），
// 并把申请从申请库删除；申请者收件箱收到通过回执。
export async function approveGroupJoin({ account, requestId }) {
  const me = await requireMe(account);
  const request = await requireIncomingJoin(me, requestId);
  // 申请人已注销：清除申请并报错，避免把已注销账号名写进成员名单
  const applicant = await findAccount(request.fromAccount);
  if (!applicant) {
    await removeGroupJoinRequest(request.id);
    throw notFound('申请人账号已注销，该申请已清除');
  }
  const joined = await joinGroup(request.groupId, request.fromAccount, { viaApproval: true });
  await removeGroupJoinRequest(request.id);
  try {
    await pushMail({
      toAccount: request.fromAccount,
      fromAccount: me.account,
      title: `入组申请已通过：${joined.group.name}`,
      body: `${me.account} 已同意你加入卡片组「${joined.group.name}」，你已成为该组成员，组内卡片已自动加入（已满或已完成的除外）。`
    });
  } catch {
    // 回执投递失败不影响审批主流程
  }
  return {
    request: { id: request.id, groupId: request.groupId, groupName: request.groupName, fromAccount: request.fromAccount, status: 'approved' },
    group: joined.group,
    message: `已同意 ${request.fromAccount} 加入卡片组「${joined.group.name}」`
  };
}

// 拒绝入组申请（110 groups.join-reject）：不写入成员，直接把申请从申请库删除；申请者收件箱收到回执
export async function rejectGroupJoin({ account, requestId }) {
  const me = await requireMe(account);
  const request = await requireIncomingJoin(me, requestId);
  await removeGroupJoinRequest(request.id);
  try {
    await pushMail({
      toAccount: request.fromAccount,
      fromAccount: me.account,
      title: `入组申请未通过：${request.groupName}`,
      body: `${me.account} 拒绝了你加入卡片组「${request.groupName}」的申请。`
    });
  } catch {
    // 回执投递失败不影响拒绝主流程
  }
  return {
    request: { id: request.id, groupId: request.groupId, groupName: request.groupName, fromAccount: request.fromAccount, status: 'rejected' },
    message: `已拒绝 ${request.fromAccount} 加入卡片组「${request.groupName}」的申请`
  };
}

// 撤回入组申请（111 groups.join-cancel）：申请人处理前反悔，静默撤回（创建者不收到通知）
export async function cancelGroupJoin({ account, requestId }) {
  const me = await requireMe(account);
  if (!Number.isInteger(requestId)) {
    throw badRequest('requestId must be an integer');
  }
  const request = await getGroupJoinRequest(requestId);
  if (!request) {
    throw notFound('入组申请不存在或已被处理');
  }
  if (request.fromAccount !== me.account) {
    throw forbidden('只能撤回自己提交的入组申请');
  }
  await removeGroupJoinRequest(request.id);
  return {
    request: { id: request.id, groupId: request.groupId, groupName: request.groupName, fromAccount: request.fromAccount, status: 'cancelled' },
    message: '已撤回入组申请'
  };
}

// 我发出的未处理入组申请（组号集合）：供公开卡片组库（服务 3）标记「已申请入组」状态
export async function listAppliedGroupIds(account) {
  if (typeof account !== 'string' || account.trim() === '') {
    return [];
  }
  const outgoing = await listOutgoingGroupJoins(account.trim());
  return outgoing.filter(r => r.status === 'pending').map(r => r.groupId);
}
