import { runAiAsk, getAiControlStatus, resetAiCard, clearAiContext, completeAiCard, setCardVisibility, setCardFriendOnly, setCardCapacity, setCardNeedApproval, inviteToWorkingCard, uninviteFromWorkingCard, editCardFields, pickCardAsWorking, getWorkingCardConflicts as getWorkingCardConflictDetail } from './ai/aiAskService.js';
import { runShopRecommend } from './ai/shopService.js';
import { listMyCardLibrary, deleteFromMyCardLibrary, publishPrivateCard, unpublishPublicCard } from './cardLibrary.service.js';
import { registerAccount, loginAccount, logoutAccount, deleteAccount,
  bindHuaweiAccount, loginHuaweiAccount, huaweiStateOfAccount, unbindHuaweiAccount,
  guestLoginAccount, renameAccountOfSession, setPasswordOfSession,
  emailRegisterAccount, emailForgotPassword, huaweiRegisterAccount,
  emailStateOfAccount, emailBindOfSession
} from './auth.service.js';
import { listUsersFor, sendFriendRequest, getInbox, acceptFriendRequest, rejectFriendRequest, removeFriend, areFriends } from './friend.service.js';
import { applyToCard, getCardRequestInbox, approveCardRequest, rejectCardRequest, listAppliedCardKeys } from './cardApplication.service.js';
import { collectDueReminders } from './reminderService.js';
import { listMyMails, markMyMailRead, removeMyMail } from './mailbox.service.js';
import { listMyChats, getChatMessages, sendChatText, sendChatCard, acceptChatCard, sendChatGroup, acceptChatGroup, pullRelayMessages } from './chat.service.js';
import { sendGroupChatText, sendGroupChatCard, pullGroupChatMessages } from './groupChat.service.js';
import { makePostcard, pullPostcards, deliverPostcardToParticipants, makeCompleterPostcard } from './postcard.service.js';
import { applyCardExtend, getCardExtendInbox, approveCardExtend, rejectCardExtend } from './cardExtend.service.js';
import { setGroupJoinModeOf, setGroupMemberCapOf, applyToJoinGroup, getGroupJoinInbox, approveGroupJoin, rejectGroupJoin, cancelGroupJoin, listAppliedGroupIds } from './groupJoin.service.js';
import { submitCardReport } from './cardReport.service.js';
import { listMyNotices, markMyNoticeRead, removeMyNotice } from './notice.service.js';
import { getWeekCardReport } from './report.service.js';
import { fetchWeather } from './qweather/index.js';
import { getMyProfile, updateMyProfile, getAvatarOfAccount } from './profile.service.js';
import { findAccount, findAccountByUserId } from './accountStore.js';
import { getProfileOf } from './profileStore.js';
import { getProfile as getUserProfile, setProfile as setUserProfile, clearProfile } from './userProfileStore.js';
import {
  createGroup,
  listGroupsVisibleTo,
  listPublicGroupsFor,
  deleteGroup,
  addGroupCard,
  removeGroupCard,
  leaveGroup,
  joinGroup,
  joinGroupCard,
  leaveGroupCard,
  removeCardParticipantByOwner,
  setCardCompleter,
  completeGroupCard,
  syncPrivateGroups,
  setGroupProfile,
  getGroupCover
} from './cardGroupStore.js';

const services = new Map();

function install(number, name, handler) {
  services.set(number, { number, name, handler });
  return number;
}

// 内置服务：AI 调用编号固定为 0，其余顺序编号
// 编号 0 走完整 AI 流程（状态机 mode + 四栏上下文 + 持久化），保证经路由调用与服务器控制台行为一致
install(0, 'ai.ask', async (payload) => runAiAsk(payload ?? {}));
install(1, 'health', async () => ({ status: 'ok', time: new Date().toISOString() }));
install(2, 'echo', async (payload) => ({ echo: payload ?? null }));
// 公开卡片组库列表（重做后）：所有 library='public' 的卡片组（含组内卡片）；
// 组内「仅好友」卡片只对组创建者本人、成员与创建者的好友可见；
// 同时为当前账号标记 applied（已提交加入申请、等待创建者处理）
install(3, 'cards.list', async (payload) => {
  const me = Number.isInteger(payload?.userId) ? await findAccountByUserId(payload.userId) : null;
  const account = me ? me.account : (typeof payload?.account === 'string' ? payload.account.trim() : '');
  const groups = await listPublicGroupsFor(account);
  if (!me && account === '') {
    return { groups };
  }
  const applied = new Set(await listAppliedCardKeys(account));
  // 二期组加入审核：我已提交入组申请（待处理）的组标记 joinApplied（客户端按钮显示「审核中」）
  const joinApplied = new Set(await listAppliedGroupIds(account));
  if (applied.size === 0 && joinApplied.size === 0) {
    return { groups };
  }
  return {
    groups: groups.map(g => ({
      ...g,
      ...(joinApplied.has(g.id) ? { joinApplied: true } : {}),
      cards: (g.cards || []).map(c => applied.has(`${g.id}:${c.index}`) ? { ...c, applied: true } : c)
    }))
  };
});
// AI 控制服务：状态查询 / 取消重置 / 确定完成 / 清空上下文；卡片库删除
install(4, 'ai.status', async () => getAiControlStatus());
install(6, 'ai.reset', async () => resetAiCard());
install(7, 'ai.complete', async (payload) => completeAiCard(payload ?? {}));
install(8, 'ai.clear-context', async () => clearAiContext());
// 删除组内卡片（真删，仅卡片组创建者）：该卡片上未处理的加入申请一并清除
install(9, 'cards.delete', async (payload) => {
  const { account, groupId, cardIndex } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份（卡片组创建者）才能删除卡片');
    err.status = 400;
    throw err;
  }
  const removed = await removeGroupCard(groupId, cardIndex, account.trim());
  return { removed: removed.removed, group: removed.group, message: `已从卡片组「${removed.group.name}」删除卡片 #${cardIndex}` };
});

// 注册 / 登录（仅账号密码；登录后账号与 IP 临时绑定），经路由编号调用
install(10, 'auth.register', async (payload) => registerAccount(payload ?? {}));
install(11, 'auth.login', async (payload) => loginAccount(payload ?? {}));
// 退出登录 / 注销账号：仅登录状态可调用
install(12, 'auth.logout', async (payload) => logoutAccount(payload ?? {}));
install(13, 'auth.unregister', async (payload) => deleteAccount(payload ?? {}));
// 卡片参与：加入某卡片组内的一张卡片（写参与人并成为组成员）/ 退出该卡片（移除参与人），均由当前登录账号操作
install(14, 'cards.join', async (payload) => {
  const { account, groupId, cardIndex } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能加入');
    err.status = 400;
    throw err;
  }
  const group = await joinGroupCard(groupId, cardIndex, account.trim());
  return { group, message: `已加入卡片组「${group.name}」的卡片 #${cardIndex}，并成为该组成员` };
});
install(15, 'cards.leave', async (payload) => {
  const { account, groupId, cardIndex } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能退出');
    err.status = 400;
    throw err;
  }
  const group = await leaveGroupCard(groupId, cardIndex, account.trim());
  return { group, message: `已退出卡片组「${group.name}」的卡片 #${cardIndex}（组身份保留，仍可见全组）` };
});

// 好友：用户列表（含搜索）、发送申请、收件箱、同意申请（写关系库）
install(16, 'users.list', async (payload) => listUsersFor(payload ?? {}));
install(17, 'friends.request', async (payload) => sendFriendRequest(payload ?? {}));
install(18, 'friends.inbox', async (payload) => getInbox(payload ?? {}));
install(19, 'friends.accept', async (payload) => {
  const { requestId } = payload ?? {};
  if (!Number.isInteger(requestId)) {
    const err = new Error('requestId must be an integer');
    err.status = 400;
    throw err;
  }
  return acceptFriendRequest(payload ?? {});
});

let nextNumber = 20;

// 卡片「公开/私人」切换：客户端在点「确定」前用按钮更改
install(20, 'ai.visibility', async (payload) => {
  const { public: isPublic } = payload ?? {};
  if (typeof isPublic !== 'boolean') {
    const err = new Error('public must be a boolean');
    err.status = 400;
    throw err;
  }
  return setCardVisibility(isPublic);
});

// 删除好友：无需申请，直接解除双方关系（关系库双向清空）
install(21, 'friends.remove', async (payload) => removeFriend(payload ?? {}));

// 卡片「仅好友」切换：仅在「公开」卡片上生效，客户端在点「确定」前用按钮更改
install(22, 'ai.friend-only', async (payload) => {
  const { friendOnly } = payload ?? {};
  if (typeof friendOnly !== 'boolean') {
    const err = new Error('friendOnly must be a boolean');
    err.status = 400;
    throw err;
  }
  return setCardFriendOnly(friendOnly);
});

// 拒绝好友申请：不写关系库，直接把申请从申请库删除
install(23, 'friends.reject', async (payload) => rejectFriendRequest(payload ?? {}));

// 卡片「人数上限」设置：包含发起者本人，最小为 1；客户端在点「确定」前用输入框修改
install(24, 'ai.capacity', async (payload) => {
  const { capacity } = payload ?? {};
  if (!Number.isInteger(capacity) || capacity < 1) {
    const err = new Error('capacity must be an integer >= 1');
    err.status = 400;
    throw err;
  }
  return setCardCapacity(capacity);
});

// 卡片加入申请：「需要申请」的卡片，他人点「+」先发申请给发起者，暂不写入参与人
install(25, 'cards.apply', async (payload) => applyToCard(payload ?? {}));
// 卡片申请收件箱：我发起的卡片收到的待处理加入申请
install(26, 'cards.requests', async (payload) => getCardRequestInbox(payload ?? {}));
// 同意加入申请：写入参与人（卡片随之出现在申请者卡片库），并把申请从申请库删除
install(27, 'cards.approve', async (payload) => {
  const { requestId } = payload ?? {};
  if (!Number.isInteger(requestId)) {
    const err = new Error('requestId must be an integer');
    err.status = 400;
    throw err;
  }
  return approveCardRequest(payload ?? {});
});
// 拒绝加入申请：不写入参与人，直接把申请从申请库删除
install(28, 'cards.reject', async (payload) => {
  const { requestId } = payload ?? {};
  if (!Number.isInteger(requestId)) {
    const err = new Error('requestId must be an integer');
    err.status = 400;
    throw err;
  }
  return rejectCardRequest(payload ?? {});
});
// 卡片「需要申请」切换：仅在「公开」卡片上生效，客户端在点「确定」前用按钮更改
install(29, 'ai.need-approval', async (payload) => {
  const { needApproval } = payload ?? {};
  if (typeof needApproval !== 'boolean') {
    const err = new Error('needApproval must be a boolean');
    err.status = 400;
    throw err;
  }
  return setCardNeedApproval(needApproval);
});

// 创建者移除某张卡片的参与者：无需申请，直接把该账号从参与人字段删去（组内该卡随之从对方视图消失）
install(30, 'cards.remove-participant', async (payload) => {
  const { account, groupId, cardIndex, toAccount, toUserId } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份（卡片组创建者）才能删除参与者');
    err.status = 400;
    throw err;
  }
  // 目标参与者可由账号名或 userId 指定
  let target = typeof toAccount === 'string' ? toAccount.trim() : '';
  if (target === '' && Number.isInteger(toUserId)) {
    const found = await findAccountByUserId(toUserId);
    if (found) {
      target = found.account;
    }
  }
  if (target === '') {
    const err = new Error('需要指定要删除的参与者（toAccount 或 toUserId）');
    err.status = 400;
    throw err;
  }
  const group = await removeCardParticipantByOwner(groupId, cardIndex, account.trim(), target);
  return { group, message: `已把 ${target} 从卡片组「${group.name}」的卡片 #${cardIndex} 中移除` };
});

// 邀请好友加入「正在设置的卡片」：设置卡片阶段可用（空卡也可先邀请），仅限已是好友的账号；
// 邀请后把好友账号加入卡片参与人，AI 调用时会带出其用户资料与卡片
install(31, 'cards.invite', async (payload) => inviteToWorkingCard(payload ?? {}));

// 取消邀请：确定卡片前把参与人从工作卡中移出
install(32, 'cards.uninvite', async (payload) => uninviteFromWorkingCard(payload ?? {}));

// 时间冲突查询：返回当前工作卡与已有卡片（公开卡片库 + 本人与参与人的私人卡片）的冲突清单，用于展示与禁用「确定」
install(33, 'cards.conflicts', async (payload) => getWorkingCardConflictDetail(payload ?? {}));

// 私人卡片库（本人视图）：公开卡片库中本人发起/参与的卡片 + 本人私人卡片库中的卡片，全部由服务器合成
install(37, 'cards.private-list', async (payload) => listMyCardLibrary(payload ?? {}));

// 从本人私人卡片库删除一条：private → 删除私人卡片；public → 发起者删卡 / 参与者退出
install(38, 'cards.private-delete', async (payload) => deleteFromMyCardLibrary(payload ?? {}));

// 对话记录库（本人视图）：本地化改造后 AI 对话记录长期保存在客户端，服务器不再保存。
// App 走客户端（:4000）时本服务由客户端本地应答；此处仅作兜底，固定返回空列表。
install(39, 'conversations.list', async (payload) => {
  const { userId = null } = payload ?? {};
  return { userId, messages: [] };
});

// 日程提醒（到点拉取）：按本人卡片的「提醒时间」返回已到点且未送达过的提醒；拉取即视为送达，同一条只发一次
install(40, 'reminders.due', async (payload) => collectDueReminders(payload ?? {}));

// 收件箱（站内邮件）：本人日程提醒到点时，服务器自动把提醒邮件投递到其收件箱；
// 到点投递由服务 40 触发（弹窗提醒保持不变），本组服务只负责查看、标记已读与删除
install(42, 'mailbox.list', async (payload) => listMyMails(payload ?? {}));
install(43, 'mailbox.read', async (payload) => markMyMailRead(payload ?? {}));
install(44, 'mailbox.remove', async (payload) => removeMyMail(payload ?? {}));

// 好友聊天：仅好友之间可互发消息（文字 / 卡片邀请）；消息由客户端轮询拉取，服务器不反向投递。
// 「发送卡片」把我发起的公开卡片以快照发进聊天邀请对方；「接受邀请」加入卡片（需要申请的卡片自动转为加入申请）
install(45, 'chat.list', async (payload) => listMyChats(payload ?? {}));
install(46, 'chat.messages', async (payload) => getChatMessages(payload ?? {}));
install(47, 'chat.send-text', async (payload) => sendChatText(payload ?? {}));
install(48, 'chat.send-card', async (payload) => sendChatCard(payload ?? {}));
install(49, 'chat.accept-card', async (payload) => acceptChatCard(payload ?? {}));

// 私人卡片转公开：把本人私人卡片库中的一张卡片转入公开卡片库（发起者=本人，人数上限至少 2），
// 原私人卡片随之删除；转为公开后即可通过 chat.send-card 发送给好友
install(50, 'cards.publish', async (payload) => publishPrivateCard(payload ?? {}));

// 手动制作卡片：直接编辑当前工作卡的文本字段（fields 中出现即写入，空字符串=清空，未提及=保持不变），
// 「时间/提醒时间」须为绝对时间；写入后用 ai.complete（编号 7）确定落库，与 AI 对话可混用
install(51, 'cards.edit', async (payload) => editCardFields((payload ?? {}).fields ?? {}));

// 选取卡片：把一张已有卡片（组号 + 组内编号）整份载入「正在设置卡片」。
// 载入后「手动制作」（51）与 AI 对话（0）作用于同一张工作卡，故选取功能两种输入方式共用
install(76, 'cards.pick', async (payload) => pickCardAsWorking(payload ?? {}));

// 华为账号（Account Kit）登录方式：绑定（77）/ 一键登录（78）/ 绑定状态（79）/ 解绑（80）。
// 77/79/80 需登录 token（路由层按 token 注入 account）；78 免 token，按 unionID 反查账号签发 token，
// 未绑定的华为账号自动创建新账号（UID 名 + 空密码）并绑定
install(77, 'auth.huawei-bind', async (payload) => bindHuaweiAccount(payload ?? {}));
install(78, 'auth.huawei-login', async (payload) => loginHuaweiAccount(payload ?? {}));
install(79, 'auth.huawei-state', async (payload) => huaweiStateOfAccount(payload ?? {}));
install(80, 'auth.huawei-unbind', async (payload) => unbindHuaweiAccount(payload ?? {}));

// 自动建号与账号自助管理：游客登录免 token（与注册/登录同类的开箱入口）；
// 修改账号名 / 设置密码需登录 token（路由层按 token 注入 account）
install(81, 'auth.guest-login', async (payload) => guestLoginAccount(payload ?? {}));
install(82, 'auth.rename', async (payload) => renameAccountOfSession(payload ?? {}));
install(83, 'auth.set-password', async (payload) => setPasswordOfSession(payload ?? {}));

// 邮箱认证（AGC 邮箱验证码）：注册（85）/ 找回密码（86）免 token——验证码校验由 App 侧经 AGC 完成，
// 服务器只做建号 / 重置密码哈希；华为账号注册（88）与登录页的 78（只查找登录）配对，
// 未绑定的华为账号在注册页经此自动建号并绑定 unionID
install(85, 'auth.email-register', async (payload) => emailRegisterAccount(payload ?? {}));
install(86, 'auth.email-reset-password', async (payload) => emailForgotPassword(payload ?? {}));
install(88, 'auth.huawei-register', async (payload) => huaweiRegisterAccount(payload ?? {}));

// 公开卡片转私人：仅卡片创建者可操作。原卡片转入其私人卡片库（上限还原 1、清空参与人），
// 并从公开卡片库删除；原参与者在收件箱收到「卡片已转私人」的通知
install(52, 'cards.unpublish', async (payload) => unpublishPublicCard(payload ?? {}));

// 卡片组（重做后）：每张卡片都存放在某个卡片组里——「确定」时自动建组收纳，也可手动创建空组再往里加卡。
// 组分公开/私人两个库；仅创建者可建卡/删卡/删组/设置完成权限，被邀请加入的好友是成员（可见全部卡片并收提醒）
install(53, 'groups.create', async (payload) => {
  const { account, name, library } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能创建卡片组');
    err.status = 400;
    throw err;
  }
  return createGroup(account.trim(), name, { library: library === 'private' ? 'private' : 'public' });
});
install(54, 'groups.list', async (payload) => {
  const { account } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能查看卡片组');
    err.status = 400;
    throw err;
  }
  const groups = await listGroupsVisibleTo(account.trim());
  return { account: account.trim(), total: groups.length, groups };
});
install(55, 'groups.delete', async (payload) => {
  const { account, groupId } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能删除卡片组');
    err.status = 400;
    throw err;
  }
  const removed = await deleteGroup(groupId, account.trim());
  return { ...removed, message: `已删除卡片组「${removed.name}」及其 ${removed.removedCards} 张卡片` };
});
install(56, 'groups.add-card', async (payload) => {
  const { account, groupId, fields } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能添加组内卡片');
    err.status = 400;
    throw err;
  }
  const group = await addGroupCard(groupId, account.trim(), fields ?? {});
  return { group, message: `已把卡片加入卡片组「${group.name}」（现有 ${group.cardCount} 张）` };
});
install(57, 'groups.remove-card', async (payload) => {
  const { account, groupId, cardIndex } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能删除组内卡片');
    err.status = 400;
    throw err;
  }
  const removed = await removeGroupCard(groupId, cardIndex, account.trim());
  return { ...removed, message: `已从卡片组中删除卡片 #${cardIndex}` };
});
// 退出卡片组：仅成员可退（同时从组内卡片参与人中移除）；创建者只能删除组
install(58, 'groups.leave', async (payload) => {
  const { account, groupId } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能退出卡片组');
    err.status = 400;
    throw err;
  }
  const left = await leaveGroup(groupId, account.trim());
  return { ...left, message: '已退出该卡片组，组内卡片的参与人列表已同步移除你' };
});

// 卡片组聊天邀请：把自己创建的卡片组发给好友（59），对方接受后加入组并自动加入组内卡片（60）
install(59, 'chat.send-group', async (payload) => sendChatGroup(payload ?? {}));
install(60, 'chat.accept-group', async (payload) => acceptChatGroup(payload ?? {}));

// 完成权限（重做后）：已废弃——完成者固定为卡片发起者本人（61 保留服务号、固定返回拒绝）；
// 发起者把卡片标记为已完成（62）——已完成卡片不再提醒、归档展示，记录保留
install(61, 'groups.set-completer', async (payload) => {
  const { account, groupId, cardIndex, memberAccount } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份（卡片组创建者）才能设置完成权限');
    err.status = 400;
    throw err;
  }
  return setCardCompleter(groupId, cardIndex, account.trim(), memberAccount ?? null);
});
install(62, 'groups.complete-card', async (payload) => {
  const { account, groupId, cardIndex } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能标记卡片完成');
    err.status = 400;
    throw err;
  }
  const completed = await completeGroupCard(groupId, cardIndex, account.trim());
  // 参与者明信片：按完成快照后台出稿并投递到外发中转库（不阻塞 62 响应）
  let postcard = null;
  if (completed.postcardSnapshot) {
    deliverPostcardToParticipants(completed.postcardSnapshot).catch(err => {
      console.error(`[postcard] 参与者明信片投递失败 groupId=${groupId}:`, err.message);
    });
    // 完成者本人的明信片：同步出稿随 62 响应返回（应用内完成弹窗与锁屏卡片完成
    // 反馈靠 postcard 字段展示 AI 寄语），同时投一份到外发中转库（103），
    // 由应用端拉取后落本地库长期保存（客户端 mergeMany 按 日期+标题+正文 去重）
    postcard = await makeCompleterPostcard(completed.postcardSnapshot, account.trim());
  }
  return { ...completed, postcard };
});

// 私人卡片组同步（本地化改造新增）：私人卡片组及卡片在服务器与客户端双端存储。
// 客户端连接/登录时上送本地副本（groups），此处按 updatedAt 合并（较新者胜），返回合并结果供客户端覆盖本地；
// 不传 groups 时只做拉取。公开卡片组仍只存服务器，不参与同步。
install(63, 'private.sync', async (payload) => {
  const { account, groups = null } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能同步私人卡片组');
    err.status = 400;
    throw err;
  }
  return syncPrivateGroups(account.trim(), groups);
});

// 好友对话中转箱（本地化改造新增）：拉取服务器上发给我的消息，拉取即删。
// 服务器只做「短期中转、送达即删」，好友对话的长期保存由客户端负责。
install(64, 'relay.pull', async (payload) => pullRelayMessages(payload ?? {}));

// 加入卡片组（本地化改造新增）：接受聊天里的卡片组邀请时，由客户端定位本地邀请消息后按组号加入
install(65, 'groups.join', async (payload) => {
  const { account, groupId } = payload ?? {};
  if (!account || typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能加入卡片组');
    err.status = 400;
    throw err;
  }
  const joined = await joinGroup(groupId, account.trim());
  const group = joined.group;
  return {
    ...joined,
    message: joined.already
      ? `你已是卡片组「${group.name}」的成员（本次新加入 ${joined.joinedCards} 张卡片）`
      : `已加入卡片组「${group.name}」（含 ${group.cardCount} 张卡片），其中自动加入 ${joined.joinedCards} 张`
  };
});

// 明信片（服务 66）：点击卡片「完成」后，用该卡片作为唯一资料调用 AI 生成一句明信片正文（时间 + 事件 + 祝福）。
// 服务器只负责生成，不持久化；明信片由客户端本地文本文件长期保存。
install(66, 'postcard.make', async (payload) => makePostcard(payload ?? {}));

// 明信片外发拉取（服务 103）：62 完成后服务器后台出稿、投递给参与者（除发起者）的明信片，
// 与 57 删除未完成卡时的「清理聊天记录」墓碑，都暂存在外发中转库（送达即删、30 天过期）。
// 各端拉取后：明信片落本地库长期保存、clear 墓碑删除对应群本地聊天线程
install(103, 'postcards.pull', async (payload) => pullPostcards(payload ?? {}));

// 公开卡片举报（服务 104）：发现页卡片 ⋯ 菜单提交，快照卡片内容入库；
// 同一举报人对同一卡片去重；处理（驳回/下架）在管理台 /api/reports（仅本机）
install(104, 'report.submit', async (payload) => submitCardReport(payload ?? {}));

// 组简介（服务 105）：创建者为卡片组补充公开招募信息——组简介（≤200 字）与目标受众（≤50 字），
// 均逐段过智能审核；公开组在发现页展示（卡片摘要 + 「⋯ → 组简介」全文），私人组可预填，转公开后即展示。
// coverOp：keep=封面不变（缺省）/ remove=清除封面 / update=上传封面（coverBase64 必填，≤40 万字符）
install(105, 'groups.set-profile', async (payload) => {
  const { account, groupId, intro, audience, coverOp, coverBase64 } = payload ?? {};
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    const err = new Error('需要账号身份才能修改组简介');
    err.status = 400;
    throw err;
  }
  const group = await setGroupProfile(groupId, name, { intro, audience, coverOp, coverBase64 });
  return { group, message: '组简介已保存' };
});

// 组封面原图拉取（服务 112）：发现页/组管理按 groupId 拉取封面 base64。
// 列表接口只回 hasCover+coverUpdatedAt 轻摘要，客户端比对时间戳后用本服务取图。
// 公开组任何人可拉；私人组仅创建者与成员可拉；组未设封面时 hasCover=false、cover=null
install(112, 'groups.cover', async (payload) => {
  const { account, groupId } = payload ?? {};
  const name = typeof account === 'string' ? account.trim() : '';
  if (!Number.isInteger(groupId) || groupId < 1) {
    const err = new Error('groupId must be a positive integer');
    err.status = 400;
    throw err;
  }
  return getGroupCover(groupId, name);
});

// 组加入审核（二期）：创建者把组设为「审核加入」（106）——其他人加入整组（65/60）
// 与直接加入组内卡片（14/49）都会被服务器拦截，须先提交入组申请（107，陈述可选），
// 由创建者同意（109，自动加入组内未满且未完成的卡片）/ 拒绝（110），处理前可撤回（111）；
// 108 为创建者的待处理入组申请收件箱。106 切回「自由加入」时存量申请自动通过（逐个加入 + 回执）。
install(106, 'groups.set-join-mode', async (payload) => setGroupJoinModeOf(payload ?? {}));
install(107, 'groups.apply', async (payload) => applyToJoinGroup(payload ?? {}));
install(108, 'groups.join-requests', async (payload) => getGroupJoinInbox(payload ?? {}));
install(109, 'groups.join-approve', async (payload) => {
  const { requestId } = payload ?? {};
  if (!Number.isInteger(requestId)) {
    const err = new Error('requestId must be an integer');
    err.status = 400;
    throw err;
  }
  return approveGroupJoin(payload ?? {});
});
install(110, 'groups.join-reject', async (payload) => {
  const { requestId } = payload ?? {};
  if (!Number.isInteger(requestId)) {
    const err = new Error('requestId must be an integer');
    err.status = 400;
    throw err;
  }
  return rejectGroupJoin(payload ?? {});
});
install(111, 'groups.join-cancel', async (payload) => {
  const { requestId } = payload ?? {};
  if (!Number.isInteger(requestId)) {
    const err = new Error('requestId must be an integer');
    err.status = 400;
    throw err;
  }
  return cancelGroupJoin(payload ?? {});
});

// 组人数上限（服务 98）：创建者限制卡片组总人数（含创建者，2~99，null/0=不限）；
// 加入整组 / 加入组内卡片 / 接受聊天组邀请的成员名单增长点统一拦截，审核通过路径同样受限
install(98, 'groups.set-member-cap', async (payload) => setGroupMemberCapOf(payload ?? {}));

// 卡片延期（服务 67–70）：只有卡片组创建者或被指定「完成权限」的成员可延期。
// 创建者提交 → 时间立即改变；成员提交 → 生成延期申请交给创建者审批（与卡片加入申请同构）。
install(67, 'cards.extend', async (payload) => applyCardExtend(payload ?? {}));
// 延期申请收件箱：我（作为创建者）收到的、仍待处理的延期申请
install(68, 'cards.extend-requests', async (payload) => getCardExtendInbox(payload ?? {}));
// 同意延期申请：按申请里的时间快照改期，并把结果提示投递到申请者的通知通道与收件箱
install(69, 'cards.extend-approve', async (payload) => approveCardExtend(payload ?? {}));
// 拒绝延期申请：卡片时间不变，同样回执告知申请者
install(70, 'cards.extend-reject', async (payload) => rejectCardExtend(payload ?? {}));

// 通知通道（服务 71–73）：延期审批结果的站内通知，与收件箱并行投递
install(71, 'notices.list', async (payload) => listMyNotices(payload ?? {}));
install(72, 'notices.read', async (payload) => markMyNoticeRead(payload ?? {}));
install(73, 'notices.remove', async (payload) => removeMyNotice(payload ?? {}));

// 周报统计（服务 74）：只计算「我设置/参与、且时间段与本周有交集」的卡片数，供客户端周报库落库；
// 周报数据（近两周 + 累计）全部保存在转发台客户端，服务器不持久化。
install(74, 'reports.week', async (payload) => getWeekCardReport(payload ?? {}));

// 卡片小铺（服务 89）：AI 按「周报累计统计 + 资料 + 已有日程」直接推荐一张完整私人卡片
// （允许合理编造、贴合长期习惯）；不进对话流程、不落库，客户端按账号按周存本地小铺，
// 用户点「加入日程」时经 53+56 建私人卡片组加卡。account 由路由层按 token 注入。
install(89, 'ai.shop', async (payload) => runShopRecommend(payload ?? {}));

// 个人空间（服务 90/91）：资料字段 + 头像（JPEG base64）客户端与服务器各存一份；
// 昵称（必填）与个性签名过智能审核（命中词库 409）；account 由路由层按 token 注入
install(90, 'profile.get', async (payload) => getMyProfile(payload ?? {}));
install(91, 'profile.update', async (payload) => updateMyProfile(payload ?? {}));
install(92, 'profile.avatar', async (payload) => getAvatarOfAccount(payload ?? {}));

// 用户信息同步（服务 93）：个性化服务开关驱动的「个人空间 → 用户信息」同步。
// 用户信息（user-profile.txt，AI 上下文的「本人用户资料」，含 AI 记住的 traits）与个人空间
// （profile.txt，服务 90/91）分开存储：put 把个人空间五字段并入用户信息——上送字段非空覆盖、
// 上送为空清除该键、未上送保持现状，traits 等其余键始终保留；clear 清空该账号的用户信息
// （个性化服务关闭时调用，个人空间不受影响）。account 由路由层按 token 注入。
install(93, 'userinfo.sync', async (payload) => {
  const { account, action, profile } = payload ?? {};
  if (typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能同步用户信息');
    err.status = 400;
    throw err;
  }
  const name = account.trim();
  const found = await findAccount(name);
  if (!found) {
    const err = new Error('账号不存在');
    err.status = 400;
    throw err;
  }
  if (action === 'clear') {
    await clearProfile(found.userId);
    return { account: name, action: 'clear', message: '用户信息已清空' };
  }
  if (action === 'put') {
    const FIELDS = ['gender', 'birthday', 'signature', 'province', 'city'];
    const entry = await getUserProfile(found.userId);
    const merged = entry?.profile ? { ...entry.profile } : {};
    if (profile && typeof profile === 'object' && !Array.isArray(profile)) {
      for (const key of FIELDS) {
        if (!(key in profile)) {
          continue;
        }
        const value = profile[key];
        if (typeof value === 'string' && value.trim() !== '') {
          merged[key] = value.trim();
        } else {
          delete merged[key];
        }
      }
    }
    await setUserProfile(found.userId, merged);
    return { account: name, action: 'put', message: '个人空间已写入用户信息' };
  }
  const err = new Error('action 只能是 put / clear');
  err.status = 400;
  throw err;
});

// 好友空间（服务 94）：查好友的个人空间资料（好友页「空间」按钮展开块用）。
// 仅好友可查（生日/地区比头像敏感，92 式全开放不适用）；目标账号不存在时 found=false；
// 头像仍走 92（好友列表已有缓存），此服务只回资料字段。account 由路由层按 token 注入。
install(94, 'profile.friend', async (payload) => {
  const { account, targetAccount } = payload ?? {};
  if (typeof account !== 'string' || account.trim() === '') {
    const err = new Error('需要账号身份才能查看好友空间');
    err.status = 400;
    throw err;
  }
  const name = account.trim();
  const me = await findAccount(name);
  if (!me) {
    const err = new Error('账号不存在');
    err.status = 400;
    throw err;
  }
  const target = typeof targetAccount === 'string' ? targetAccount.trim() : '';
  if (target === '') {
    const err = new Error('需要目标账号');
    err.status = 400;
    throw err;
  }
  const targetEntry = await findAccount(target);
  const out = { account: target, found: false };
  if (!targetEntry) {
    return out;
  }
  if (!(await areFriends(me.userId, targetEntry.userId))) {
    const err = new Error('仅好友可查看个人空间');
    err.status = 403;
    throw err;
  }
  const found = await getProfileOf(target);
  if (found.profile !== null) {
    out.found = true;
    out.profile = found.profile;
  }
  return out;
});

// 邮箱绑定（服务 95/96）：账号安全页「绑定邮箱/邮箱换绑」与「设置密码」门槛。
// 验证码发送与校验由 App 侧经 AGC 完成（同 85/86 信任模型），服务器只存绑定关系：
// 95 查绑定态（未绑定不允许设置密码）；96 绑定/换绑共用（跨账号唯一 409），
// 绑定后该账号只能按邮箱登录（账号名退化为昵称）。account 由路由层按 token 注入。
install(95, 'auth.email-state', async (payload) => emailStateOfAccount(payload ?? {}));
install(96, 'auth.email-bind', async (payload) => emailBindOfSession(payload ?? {}));

// 天气查询（服务 97）：客户端上送定位信息（经纬度 / IP / 城市名，优先级见 locationResolver），
// 服务器整理后用和风天气查 8 个产品（GeoAPI / 天气预报 / 分钟降水 / 空气质量 / 天气指数 /
// 天气预警 / 天文 / 时光机）并一并返回。API Key 存于 server/qweather-api-key.txt，调用时读取。
// 天气数据由客户端写入本地文件长期保存，服务器不持久化。
install(97, 'weather.fetch', async (payload) => fetchWeather(payload ?? {}));

// 卡片组群聊（服务 100-102）：群 = 卡片组（成员 = 创建者 + 组成员，覆盖组内所有卡的
// 参与者和发起者）。服务器只做「短期中转、送达即删」（groupChatStore）：发送时按当前
// 花名册 fan-out 副本给其他成员，成员拉取（102）即删；群聊记录的长期保存由各客户端
// 本地负责，服务器不存历史。分享卡片 = 本人创建的公开组卡快照，接受方走原 14/25 加入链路。
install(100, 'group-chat.send-text', async (payload) => sendGroupChatText(payload ?? {}));
install(101, 'group-chat.send-card', async (payload) => sendGroupChatCard(payload ?? {}));
install(102, 'group-chat.messages', async (payload) => pullGroupChatMessages(payload ?? {}));

export function registerService(number, name, handler) {
  if (!Number.isInteger(number) || number < 0) {
    throw new TypeError('service number must be a non-negative integer');
  }
  if (typeof name !== 'string' || name.trim() === '') {
    throw new TypeError('service name must be a non-empty string');
  }
  if (typeof handler !== 'function') {
    throw new TypeError('handler must be a function');
  }
  if (services.has(number)) {
    throw new Error(`service number ${number} already registered`);
  }
  services.set(number, { number, name: name.trim(), handler });
  nextNumber = Math.max(nextNumber, number + 1);
  return number;
}

export function listServices() {
  return [...services.keys()]
    .sort((a, b) => a - b)
    .map(number => ({ id: number, name: services.get(number).name }));
}

// 通过数字编号执行服务
export async function execute(number, payload) {
  const entry = services.get(number);
  if (!entry) {
    const err = new Error(`unknown service: ${number}`);
    err.status = 400;
    throw err;
  }
  return entry.handler(payload ?? {});
}

// 兼容按名称执行
export async function executeByName(name, payload) {
  const entry = [...services.values()].find(s => s.name === name);
  if (!entry) {
    const err = new Error(`unknown service: ${name}`);
    err.status = 400;
    throw err;
  }
  return entry.handler(payload ?? {});
}