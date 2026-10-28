import { listPrivateGroupsOf, deletePrivateGroup, moveGroupToPublic, moveGroupToPrivate } from './cardGroupStore.js';

// 卡片库（重做后）：卡片一律存放在卡片组里，公开/私人两个「卡片组库」取代原「卡片库」。
//   公开卡片组库：所有 library='public' 的组（服务 3 浏览），好友可加入组内卡片
//   私人卡片组库：本人创建、library='private' 的组（服务 37），仅本人可见
// 转换（50 / 52）以「整个卡片组」为单位在两个库之间移动。

function accountName(account) {
  return typeof account === 'string' ? account.trim() : '';
}

function requireAccount(account) {
  const name = accountName(account);
  if (name === '') {
    const err = new Error('需要账号身份才能查看私人卡片组库');
    err.status = 400;
    throw err;
  }
  return name;
}

function requireGroupId(groupId) {
  if (!Number.isInteger(groupId) || groupId < 1) {
    const err = new Error('groupId must be a positive integer');
    err.status = 400;
    throw err;
  }
  return groupId;
}

// 服务 37 cards.private-list：我的私人卡片组库（本人创建、library='private' 的卡片组，含组内全部卡片）
export async function listMyCardLibrary({ account = null } = {}) {
  const name = requireAccount(account);
  const groups = await listPrivateGroupsOf(name);
  const entries = groups.map(g => ({
    library: 'private',
    id: g.id,
    name: g.name,
    owner: g.owner,
    role: g.role,
    cardCount: g.cardCount,
    cards: g.cards,
    createdAt: g.createdAt,
    updatedAt: g.updatedAt
  }));
  return { account: name, entries };
}

// 服务 38 cards.private-delete：从私人卡片组库删除一个卡片组（整组删除，组内卡片一并移除）
export async function deleteFromMyCardLibrary({ account = null, groupId = null } = {}) {
  const name = requireAccount(account);
  const id = requireGroupId(groupId);
  const removed = await deletePrivateGroup(id, name);
  return {
    library: 'private',
    removed: { id: removed.id, name: removed.name, cardCount: removed.removedCards },
    message: `已从私人卡片组库删除卡片组「${removed.name}」（含 ${removed.removedCards} 张卡片）`
  };
}

// 服务 50 cards.publish：把我的一个私人卡片组转为公开卡片组——整组进入公开卡片组库，
// 组内卡片人数上限自动至少 2（保证好友能加入），之后可在聊天里发送该组或组内卡片给好友
export async function publishPrivateCard({ account = null, groupId = null } = {}) {
  const name = requireAccount(account);
  const id = requireGroupId(groupId);
  const group = await moveGroupToPublic(id, name);
  return {
    library: 'public',
    group,
    message: `已把卡片组「${group.name}」#${group.id} 转入公开卡片组库（组内卡片人数上限已至少为 2），现在可以发送给好友`
  };
}

// 服务 52 cards.unpublish：把我创建的一个公开卡片组转为私人卡片组（仅创建者可操作）——
// 整组转为仅本人可见：成员名单与各卡参与人一并清空（原成员与参与者在收件箱收到通知），
// 各卡完成者统一落到发起者本人（私人状态下不允许修改），未处理的加入申请清除
export async function unpublishPublicCard({ account = null, groupId = null } = {}) {
  const name = requireAccount(account);
  const id = requireGroupId(groupId);
  const moved = await moveGroupToPrivate(id, name);
  const group = moved.group;
  const notified = moved.notified;
  return {
    library: 'private',
    group,
    notified,
    message: notified > 0
      ? `已把卡片组「${group.name}」#${group.id} 转为私人卡片组，并已在收件箱通知 ${notified} 名成员/参与者`
      : `已把卡片组「${group.name}」#${group.id} 转为私人卡片组（仅本人可见）`
  };
}
