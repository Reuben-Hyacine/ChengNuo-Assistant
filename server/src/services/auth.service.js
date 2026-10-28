import { randomBytes } from 'node:crypto';
import {
  registerAccount as storeRegister, loginAccount as storeLogin, loginByNameOrEmail as storeLoginByNameOrEmail,
  deleteAccount as storeDelete,
  createAutoAccount, renameAccountOf as storeRename, setPasswordOf as storeSetPassword,
  findAccountByHuaweiUnionId, bindHuaweiId, unbindHuaweiId, huaweiBindingOf,
  createEmailAccount, resetPasswordByEmail, emailBindingOf, bindEmailOf
} from './accountStore.js';
import { upsertIp, unbindUserId, renameIpBindingsOf } from './routingIpStore.js';
import { clearAllRelationsOf } from './userRelationStore.js';
import { removeRequestsByAccount, renameRequestsByAccount } from './friendRequestStore.js';
import { removeCardRequestsByAccount, renameCardRequestsByAccount } from './cardRequestStore.js';
import { removeExtendRequestsByAccount, renameExtendRequestsByAccount } from './cardExtendStore.js';
import { removeGroupJoinRequestsByAccount, renameGroupJoinRequestsByAccount } from './groupJoinStore.js';
import { clearNoticesOf, renameNoticesOf } from './noticeStore.js';
import { clearPrivateCardsOf, renamePrivateCardsOf } from './privateCardStore.js';
import { clearProfile } from './userProfileStore.js';
import { clearByUser } from './conversationStore.js';
import { clearRemindersOf, renameRemindersOf } from './reminderStore.js';
import { clearMailboxOf, renameMailboxOf } from './mailboxStore.js';
import { clearChatsOf, renameChatsOf } from './chatStore.js';
import { clearGroupChatsOf, renameGroupChatsOf } from './groupChatStore.js';
import { clearOutboxOf, renameOutboxOf } from './postcardOutbox.js';
import { clearGroupsOf, renameGroupsAccountOf } from './cardGroupStore.js';
import { clearProfileOf, renameProfileOf } from './profileStore.js';
import { renameAccountInPublicCards } from './cardStore.js';
import { renameTombstonesOf } from './privateGroupTombstoneStore.js';
import { renameWorkingCardParticipant } from './workingCardStore.js';
import { isValidIPv4, isValidPort } from '../utils/validate.js';

// 登录后「账号与 IP 临时绑定」：session 只存内存，不落盘；账号表仍持久化在服务器。
// 每次登录签发一个随机 token 作为调用凭据；服务器据此反解调用者身份，不再相信 payload 里自报的 userId/account。
// token 不设过期时间，退出登录或注销时失效；服务器重启（内存清空）后所有 token 一并失效，需重新登录。
const sessions = new Map(); // account -> { userId, account, token, ip, port, loginAt }
const tokenIndex = new Map(); // token -> account

export function listSessions() {
  return [...sessions.values()].map(s => ({
    account: s.account,
    userId: s.userId,
    ip: s.ip,
    port: s.port,
    loginAt: s.loginAt
  }));
}

// 按 token 反解调用者身份：token 无效/已失效时返回 null
export function resolveToken(token) {
  const key = typeof token === 'string' ? token.trim() : '';
  if (key === '') {
    return null;
  }
  const account = tokenIndex.get(key);
  if (!account) {
    return null;
  }
  const session = sessions.get(account);
  if (!session || session.token !== key) {
    return null;
  }
  return { account: session.account, userId: session.userId };
}

function dropSession(account) {
  const session = sessions.get(account);
  if (!session) {
    return false;
  }
  tokenIndex.delete(session.token);
  sessions.delete(account);
  return true;
}

// 登录会话签发（账号密码 / 游客 / 华为一键登录共用）：
// 绑定客户端地址 → 作废旧 token → 签发新 token 并登记正反向索引
async function issueSession(info, ip, port) {
  const bound = await upsertIp({ ip, port, name: info.account, userId: info.userId });
  // 同一账号重新登录：旧 token 立即作废，只保留最新一次登录的凭据
  dropSession(info.account);
  const token = randomBytes(32).toString('hex');
  sessions.set(info.account, {
    userId: info.userId,
    account: info.account,
    token,
    ip,
    port,
    loginAt: new Date().toISOString()
  });
  tokenIndex.set(token, info.account);
  return {
    account: info.account,
    userId: info.userId,
    token,
    bound: { ip, port, id: bound.id }
  };
}

function requireClientAddress(payload = {}) {
  const { ip, port } = payload;
  if (!isValidIPv4(ip) || !isValidPort(port)) {
    const err = new Error('登录需要携带有效客户端地址（ip/port）用于临时绑定');
    err.status = 400;
    throw err;
  }
}

// 注册：仅账号 + 密码，账号写入服务器注册表
export async function registerAccount(payload = {}) {
  const { account, password } = payload;
  return storeRegister({ account, password });
}

// 登录：校验密码通过后，把当前客户端地址（ip/port）与账号临时绑定，并签发调用 token
// 自动建号的账号密码为空字符串，空密码同样走哈希校验，天然兼容；受密码保护的账号空密码自然 401
export async function loginAccount(payload = {}) {
  const { account, password, ip, port } = payload;
  const info = await storeLogin({ account, password });
  requireClientAddress({ ip, port });
  return issueSession(info, ip, port);
}

// 游客登录（81）：免填账号密码，点击即自动创建新账号（UID 名 + 空密码）并直接进入应用；
// 创建后可在「我的」页修改账号名、设置密码
export async function guestLoginAccount(payload = {}) {
  const { ip, port } = payload;
  requireClientAddress(payload);
  const info = await createAutoAccount();
  return { ...(await issueSession(info, ip, port)), autoCreated: true };
}

// 退出登录：清除该账号的 session 与 token（可用 account 或 token 定位，幂等）
export function logoutAccount(payload = {}) {
  const account = typeof payload?.account === 'string' ? payload.account.trim() : '';
  const token = typeof payload?.token === 'string' ? payload.token.trim() : '';
  const byToken = token !== '' ? tokenIndex.get(token) : undefined;
  const target = account !== '' ? account : (byToken ?? '');
  if (target !== '') {
    dropSession(target);
  }
  return { ok: true };
}

// ---------- 华为账号（Account Kit）登录方式 ----------
// 流程：用户先用账号密码注册/登录，再到「我的」页绑定华为账号（77）；
// 之后在登录页点「华为账号登录」→ Account Kit 授权返回 UnionID → 服务器按绑定关系反查账号并签发 token（78）。

// 绑定华为账号（77）：account 由路由层按 token 注入，不信任 payload 自报
export async function bindHuaweiAccount(payload = {}) {
  const { account, unionId, openId } = payload;
  const info = await bindHuaweiId({ account, unionId, openId });
  return { ...info, message: '华为账号绑定成功：下次可在登录页一键登录' };
}

// 华为账号登录（78）：按 unionID 反查已绑定账号并签发 token（与账号密码登录同一套会话机制）；
// 只查找、不建号——未注册的华为账号返回 404，引导到注册页的「华为账号注册」（88）完成注册
export async function loginHuaweiAccount(payload = {}) {
  const { unionId, ip, port } = payload;
  const key = typeof unionId === 'string' ? unionId.trim() : '';
  if (key === '' || key.length > 256) {
    const err = new Error('unionId 必须为 1-256 个字符');
    err.status = 400;
    throw err;
  }
  requireClientAddress(payload);
  const info = await findAccountByHuaweiUnionId(unionId);
  if (!info) {
    const err = new Error('该华为账号尚未注册程诺账号，请先到注册页完成注册');
    err.status = 404;
    throw err;
  }
  return { ...(await issueSession(info, ip, port)), autoCreated: false };
}

// 华为账号注册（88）：与登录页的「华为账号登录」（78，只查找）配对的注册入口——
// 未绑定的华为账号在此自动创建新账号（UID 名 + 空密码）并绑定 unionID，签发后进入设置引导页
export async function huaweiRegisterAccount(payload = {}) {
  const { unionId, openId, ip, port } = payload;
  const key = typeof unionId === 'string' ? unionId.trim() : '';
  if (key === '' || key.length > 256) {
    const err = new Error('unionId 必须为 1-256 个字符');
    err.status = 400;
    throw err;
  }
  requireClientAddress(payload);
  const bound = await findAccountByHuaweiUnionId(unionId);
  if (bound) {
    const err = new Error('该华为账号已注册过程诺账号，请直接在登录页一键登录');
    err.status = 409;
    throw err;
  }
  const info = await createAutoAccount();
  await bindHuaweiId({ account: info.account, unionId, openId });
  return { ...(await issueSession(info, ip, port)), autoCreated: true };
}

// ---------- 邮箱账号（AGC 邮箱验证码） ----------
// 验证码的发送与校验由 App 侧经 AGC 认证服务完成（requestVerifyCode + createUser / resetPassword），
// 服务器只负责建号、签发会话与密码哈希的存储校验；与华为登录同一信任模型（App 通过验证即视为本人）。

// 邮箱注册（85）：自动账号名（UID+编号）+ email 字段 + 空密码，随后进入「设置昵称与密码」引导页；
// 密码由 83 设置，忘记密码走 86（AGC 验证码）重置
export async function emailRegisterAccount(payload = {}) {
  const { email, ip, port } = payload;
  requireClientAddress(payload);
  const info = await createEmailAccount({ email });
  return { ...(await issueSession(info, ip, port)), autoCreated: true };
}

// 邮箱找回密码（86）：App 侧经 AGC 验证码校验后调用，服务器按邮箱重置密码哈希；
// 仅邮箱注册的账号适用，老账号保留原密码登录
export async function emailForgotPassword(payload = {}) {
  const { email, newPassword } = payload;
  const info = await resetPasswordByEmail({ email, newPassword });
  return { account: info.account, userId: info.userId, message: '密码已重置，请使用新密码登录' };
}

// 华为账号绑定状态查询（79）：account 由路由层按 token 注入
export async function huaweiStateOfAccount(payload = {}) {
  const { account } = payload;
  const info = await huaweiBindingOf({ account });
  return {
    account: info.account,
    userId: info.userId,
    huaweiBound: info.huaweiBound,
    huaweiUnionId: info.huaweiUnionId
  };
}

// 邮箱绑定状态查询（95）：account 由路由层按 token 注入。
// 账号安全页邮箱行与「设置密码」门槛用；未绑定 emailBound=false / email=null
export async function emailStateOfAccount(payload = {}) {
  const { account } = payload;
  const info = await emailBindingOf({ account });
  return {
    account: info.account,
    userId: info.userId,
    emailBound: info.emailBound,
    email: info.email ?? null,
    hasPassword: info.hasPassword === true
  };
}

// 绑定/换绑邮箱（96）：App 侧经 AGC 验证码校验后调用，服务器把邮箱绑到当前账号；
// account 由路由层按 token 注入。绑定后该账号只能按邮箱登录（账号名退化为昵称）
export async function emailBindOfSession(payload = {}) {
  const { account, email } = payload;
  const info = await bindEmailOf({ account, email });
  return {
    account: info.account,
    userId: info.userId,
    emailBound: true,
    email: info.email,
    message: info.unchanged ? '该邮箱已是当前绑定邮箱'
      : info.wasBound ? '邮箱换绑成功，请使用新邮箱登录' : '邮箱绑定成功，请使用邮箱登录'
  };
}

// 解除华为账号绑定（80，幂等）：account 由路由层按 token 注入
export async function unbindHuaweiAccount(payload = {}) {
  const { account } = payload;
  const info = await unbindHuaweiId({ account });
  return {
    account: info.account,
    userId: info.userId,
    huaweiBound: info.huaweiBound,
    message: info.wasBound ? '已解除华为账号绑定' : '该账号未绑定华为账号'
  };
}

// 修改账号名（82）：账号名在多个业务库中作外键，改名时全库级联；session/token 同步迁移到新名下。
// account 由路由层按 token 注入，newAccount 为用户新选的名字（禁止 UID+数字 保留格式）。
export async function renameAccountOfSession(payload = {}) {
  const { account, newAccount } = payload;
  const oldName = typeof account === 'string' ? account.trim() : '';
  const info = await storeRename({ account: oldName, newAccount });
  // 各业务库账号字段级联（顺序无依赖，逐一等待保证全部落盘后再迁移会话）
  await renameIpBindingsOf(oldName, info.account);
  await renameRequestsByAccount(oldName, info.account);
  await renameCardRequestsByAccount(oldName, info.account);
  await renameExtendRequestsByAccount(oldName, info.account);
  await renameGroupJoinRequestsByAccount(oldName, info.account);
  await renameNoticesOf(oldName, info.account);
  await renamePrivateCardsOf(oldName, info.account);
  await renameRemindersOf(oldName, info.account);
  await renameMailboxOf(oldName, info.account);
  await renameChatsOf(oldName, info.account);
  await renameGroupChatsOf(oldName, info.account);
  await renameOutboxOf(oldName, info.account);
  await renameGroupsAccountOf(oldName, info.account);
  await renameAccountInPublicCards(oldName, info.account);
  await renameTombstonesOf(oldName, info.account);
  await renameWorkingCardParticipant(oldName, info.account);
  await renameProfileOf(oldName, info.account);
  // 会话迁移：sessions 按账号名做键，tokenIndex 反向索引同步改指向（token 不变，客户端无需重新登录）
  const session = sessions.get(oldName);
  if (session) {
    sessions.delete(oldName);
    session.account = info.account;
    sessions.set(info.account, session);
    tokenIndex.set(session.token, info.account);
  }
  return { account: info.account, userId: info.userId, message: `账号名已修改为「${info.account}」` };
}

// 设置密码（83）：自动建号的空密码账号可直接设置；已有密码的账号须先验旧密码（错误 401）。
// account 由路由层按 token 注入。
export async function setPasswordOfSession(payload = {}) {
  const { account, oldPassword, newPassword } = payload;
  const info = await storeSetPassword({ account, oldPassword, newPassword });
  return { account: info.account, userId: info.userId, message: '密码设置成功' };
}

// 注销账号：用账号密码校验身份（不依赖易失的登录 session），再删除账号库记录 + 清除 session/token + 解除 IP 临时绑定
// 同时清空该账号的关系库记录、全部待处理申请，以及服务器上属于它的私人卡片库、用户资料库与对话记录，
// 避免账号编号回收后新账号继承旧账号的数据
export async function deleteAccount(payload = {}) {
  const { account, password } = payload;
  const info = await storeLoginByNameOrEmail({ account, password });
  dropSession(info.account);
  await unbindUserId(info.userId);
  await clearAllRelationsOf(info.userId);
  await removeRequestsByAccount(info.account);
  await removeCardRequestsByAccount(info.account);
  await removeExtendRequestsByAccount(info.account);
  await removeGroupJoinRequestsByAccount(info.account);
  await clearNoticesOf(info.account);
  await clearPrivateCardsOf(info.account);
  await clearProfile(info.userId);
  await clearByUser(info.userId);
  await clearRemindersOf(info.account);
  await clearMailboxOf(info.account);
  await clearChatsOf(info.account);
  await clearGroupChatsOf(info.account);
  await clearOutboxOf(info.account);
  await clearGroupsOf(info.account);
  await clearProfileOf(info.account);
  // 输入可能是邮箱或展示账号名（storeLoginByNameOrEmail 双查解析），删除时用解析出的真实账号名
  const removed = await storeDelete({ account: info.account });
  if (!removed) {
    const err = new Error('账号不存在');
    err.status = 404;
    throw err;
  }
  return { ...removed };
}
