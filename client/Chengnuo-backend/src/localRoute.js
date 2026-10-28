import { submitToServer } from './clientRouter.js';
import { rememberLogin, forgetSession, resolveSession, renameAccountOf as renameSession } from './store/sessionStore.js';
import { getLoginState, markLoggedIn, markLoggedOut, markGuestLoggedIn, renameLoggedInAccount } from './store/loginStateStore.js';
import { appendTurn, listByUser, historyFor, clearByUser, clearByAccount as clearConversations, renameAccountOf as renameConversations } from './store/conversationStore.js';
import {
  appendMessage,
  mergeIncoming,
  listThread,
  listConversations,
  getMessage,
  markAccepted,
  clearByAccount as clearChats,
  renameAccountOf as renameChats
} from './store/chatStore.js';
import { listForAccount, replaceForAccount, removeForAccount as removePrivateGroup, removeCardForAccount as removePrivateCard, clearByAccount as clearPrivateGroups, renameAccountOf as renamePrivateGroups } from './store/privateGroupStore.js';
import { appendPostcard, clearByAccount as clearPostcards, renameAccountOf as renamePostcards } from './store/postcardStore.js';
import {
  applyWeekSnapshot,
  recordCheckin,
  recordComplete,
  recordExtend,
  getReport,
  weekStartMsOf,
  clearByAccount as clearReports,
  renameAccountOf as renameReports
} from './store/reportStore.js';
import {
  appendSnapshot as appendWeatherSnapshot,
  clearByAccount as clearWeather,
  renameAccountOf as renameWeather
} from './store/weatherStore.js';

// 客户端本地化分流：App 的本地化服务由客户端直接应答，其余服务照旧转发给服务器。
//  - AI 对话记录：长期存客户端（服务 39 本地读、8 本地清、0 上送历史后转发并追加本轮）
//  - 好友对话：长期存客户端（服务 45/46 本地读、47/48/59 本地存 + 投服务器中转、49/60 本地定位 + 服务器落库）
//  - 私人卡片组：双端存储（登录成功即与服务器按 updatedAt 双向合并，服务 63）
//    服务 37（私人卡片组库列表）服务器优先、不可达时回落本地副本；38（私人组删除）以服务器为准并同步删本地副本；
//    50（整组转公开）/ 55（删组）转发成功后同步删本地副本、57（删组内卡片）转发成功后同步删副本内该卡——
//    副本不再保留服务器已删的内容，登录上送时才不会把已删的组/卡复活（服务器侧另有删除墓碑兜底）；
//    41（提前预告）本地固定返回空
//  - 明信片：长期存客户端（服务 62 完成卡片时顺带生成、66 单独生成，均由服务器出稿、客户端落库）
//  - 周报：长期存客户端（74 取服务器算出的周卡片数并快照、75 打卡、62 完成、67 延时均本地累加）
//  - 天气：长期存客户端（服务 97 上送定位信息，服务器调和风天气 8 个产品后由客户端落库）
//  - 登录状态：login-state.txt 首行 0=未登录 / 1=已登录（服务 9 读取；
//    10 注册 / 11 登录成功后写 1 + 账号密码，12 退出 / 13 注销成功后写 0 清凭据；
//    状态为 1 时 App 启动自动用记录的凭据登录，不显示登录界面）
// 服务器只做短期中转（服务 64 拉取即删），不再长期保存 AI 对话与好友聊天。
const INTERCEPTED = new Set([0, 8, 9, 10, 11, 12, 13, 37, 38, 39, 41, 45, 46, 47, 48, 49, 50, 55, 57, 59, 60, 62, 66, 67, 74, 75, 78, 81, 82, 83, 85, 88, 97]);

// 本地应答也要带上与服务器一致的服务名（App 只认 data.result，客户端控制台同样按此形状解析）
const SERVICE_NAMES = new Map([
  [0, 'ai.ask'],
  [8, 'ai.clear-context'],
  [9, 'auth.login-state'],
  [10, 'auth.register'],
  [11, 'auth.login'],
  [12, 'auth.logout'],
  [13, 'auth.unregister'],
  [77, 'auth.huawei-bind'],
  [78, 'auth.huawei-login'],
  [79, 'auth.huawei-state'],
  [80, 'auth.huawei-unbind'],
  [81, 'auth.guest-login'],
  [82, 'auth.rename'],
  [83, 'auth.set-password'],
  [85, 'auth.email-register'],
  [86, 'auth.email-reset-password'],
  [88, 'auth.huawei-register'],
  [37, 'cards.private-list'],
  [38, 'cards.private-delete'],
  [39, 'conversations.list'],
  [41, 'reminders.upcoming'],
  [45, 'chat.list'],
  [46, 'chat.messages'],
  [47, 'chat.send-text'],
  [48, 'chat.send-card'],
  [49, 'chat.accept-card'],
  [50, 'cards.publish'],
  [55, 'groups.delete'],
  [57, 'groups.remove-card'],
  [59, 'chat.send-group'],
  [60, 'chat.accept-group'],
  [62, 'groups.complete-card'],
  [66, 'postcard.make'],
  [67, 'cards.extend'],
  [74, 'reports.week'],
  [75, 'cards.checkin'],
  [97, 'weather.fetch']
]);

function httpError(code, status, message) {
  const err = new Error(message);
  err.code = code;
  err.status = status;
  return err;
}

function badRequest(message) {
  return httpError(40001, 400, message);
}

function unauthorized() {
  // 与服务器一致：40101 会让 App 用保存的凭据自动重登一次，重登后客户端即可记下新会话
  return httpError(40101, 401, '登录状态已失效，请重新登录');
}

function forbidden(message) {
  return httpError(40301, 403, message);
}

function notFound(message) {
  return httpError(40401, 404, message);
}

function conflict(message) {
  return httpError(40901, 409, message);
}

// 转发到服务器并按服务器原始业务码/状态码抛错（连不上时用 502）；
// 返回值是服务器包装体里的 result（与交给 App 前再包一层 {serviceId, service, result} 对称）
async function forwardOrThrow(serviceId, token, payload) {
  const out = await submitToServer({ serviceId, token, payload });
  if (!out.ok) {
    const code = out.body?.code;
    const message = out.body?.message;
    if (typeof code === 'number' && typeof message === 'string') {
      throw httpError(code, out.status || 502, message);
    }
    throw httpError(50201, 502, `server returned error: ${out.error ?? ('http ' + out.status)}`);
  }
  const data = out.body?.data ?? out.body;
  if (data && typeof data === 'object' && !Array.isArray(data) && 'result' in data) {
    return data.result;
  }
  return data;
}

async function requireSession(token) {
  const session = await resolveSession(token);
  if (!session) {
    throw unauthorized();
  }
  return session;
}

// 服务 9：读取登录状态文件（无需 token，App 冷启动时调用）
async function handleLoginState() {
  return getLoginState();
}

// 注册成功：同样视为已登录（App 注册后紧接着会自动登录，凭据一致）
async function handleRegister(token, payload) {
  const data = await forwardOrThrow(10, token, payload);
  await markLoggedIn({ account: payload?.account, password: payload?.password });
  return data;
}

// 登录成功：记下 token -> 账号 的映射，并把本地私人卡片组副本与服务器双向合并
async function handleLogin(token, payload) {
  const data = await forwardOrThrow(11, token, payload);
  if (data && typeof data.account === 'string' && typeof data.token === 'string') {
    await rememberLogin({ token: data.token, account: data.account, userId: data.userId });
    await syncPrivateGroups(data.token, data.account);
    await markLoggedIn({ account: data.account, password: payload?.password });
  }
  return data;
}

async function handleLogout(token, payload) {
  const data = await forwardOrThrow(12, token, payload);
  await forgetSession({ token });
  await markLoggedOut();
  return data;
}

// 华为账号登录成功（78）：与密码登录一致地记录会话并合并私人卡片组副本；
// 登录态文件不写凭据（Account Kit 流程拿不到密码），原文件状态保持不变——
// 同账号此前有密码记录则冷启动仍可密码自动登录，否则下次启动回到登录页再点华为登录；
// 服务器自动建号（autoCreated）且本机无登录记录时，写入游客式两行登录态（空密码自动登录）
async function handleHuaweiLogin(token, payload) {
  const data = await forwardOrThrow(78, token, payload);
  if (data && typeof data.account === 'string' && typeof data.token === 'string') {
    await rememberLogin({ token: data.token, account: data.account, userId: data.userId });
    await syncPrivateGroups(data.token, data.account);
    await markLoggedIn({ account: data.account, password: '' });
    if (data.autoCreated === true) {
      const current = await getLoginState();
      if (current.state !== 1) {
        await markGuestLoggedIn({ account: data.account });
      }
    }
  }
  return data;
}

// 游客一键进入（81）：服务器自动建号（UIDxxxxx / 空密码），与登录一致地记录会话、合并副本，
// 并写入游客式两行登录态（不记密码，冷启动按空密码自动登录）
async function handleGuestLogin(token, payload) {
  const data = await forwardOrThrow(81, token, payload);
  if (data && typeof data.account === 'string' && typeof data.token === 'string') {
    await rememberLogin({ token: data.token, account: data.account, userId: data.userId });
    await syncPrivateGroups(data.token, data.account);
    await markGuestLoggedIn({ account: data.account });
  }
  return data;
}

// 邮箱验证码注册成功（85）：App 侧 AGC 已校验验证码，服务器自动建号（UIDxxxxx / 空密码 + 邮箱标识），
// 与登录一致地记录会话、合并副本，并写入游客式两行登录态（不记密码，冷启动按空密码自动登录；
// 界面2 设密后转三行式，跳过者可走登录页「忘记密码」重置）
async function handleEmailRegister(token, payload) {
  const data = await forwardOrThrow(85, token, payload);
  if (data && typeof data.account === 'string' && typeof data.token === 'string') {
    await rememberLogin({ token: data.token, account: data.account, userId: data.userId });
    await syncPrivateGroups(data.token, data.account);
    await markGuestLoggedIn({ account: data.account });
  }
  return data;
}

// 华为账号注册成功（88）：Account Kit 拿到 unionID 后服务器自动建号并绑定，与登录一致地记录会话、
// 合并副本，并写入游客式两行登录态（Account Kit 流程拿不到密码，冷启动按空密码自动登录）
async function handleHuaweiRegister(token, payload) {
  const data = await forwardOrThrow(88, token, payload);
  if (data && typeof data.account === 'string' && typeof data.token === 'string') {
    await rememberLogin({ token: data.token, account: data.account, userId: data.userId });
    await syncPrivateGroups(data.token, data.account);
    await markGuestLoggedIn({ account: data.account });
  }
  return data;
}

// 修改账号名（82）：服务器改名成功后，把本地各库该账号的记录一并换名；
// 新名字以服务器响应里的 account 为准（服务器已 trim / 校验 / 去重）
async function handleRename(token, payload) {
  const session = await requireSession(token);
  const data = await forwardOrThrow(82, token, payload);
  if (data && typeof data.account === 'string' && data.account !== '' && data.account !== session.account) {
    await renameConversations(session.account, data.account);
    await renameChats(session.account, data.account);
    await renamePrivateGroups(session.account, data.account);
    await renamePostcards(session.account, data.account);
    await renameReports(session.account, data.account);
    await renameWeather(session.account, data.account);
    await renameSession({ account: session.account, newAccount: data.account });
    await renameLoggedInAccount({ account: session.account, newAccount: data.account });
  }
  return data;
}

// 设置密码（83）：服务器落密码成功后，更新本地登录态里的密码记录（之后冷启动/自动重登都用新密码）
async function handleSetPassword(token, payload) {
  const session = await requireSession(token);
  const data = await forwardOrThrow(83, token, payload);
  await markLoggedIn({ account: session.account, password: payload?.newPassword });
  return data;
}

// 注销：服务器删除账号后，客户端一并清掉该账号的本地记录（对话 / 聊天 / 私人卡片组副本）
async function handleUnregister(token, payload) {
  const session = await resolveSession(token);
  const data = await forwardOrThrow(13, token, payload);
  if (session) {
    await clearConversations(session.account);
    await clearChats(session.account);
    await clearPrivateGroups(session.account);
    await clearPostcards(session.account);
    await clearReports(session.account);
    await clearWeather(session.account);
  }
  await forgetSession({ token });
  await markLoggedOut();
  return data;
}

// 服务 0：把本地历史随请求上送（服务器不再持久化对话），成功后把本轮写入本地
async function handleAiAsk(token, payload) {
  const session = await requireSession(token);
  const out = { ...(payload ?? {}) };
  if (Number.isInteger(session.userId)) {
    const history = await historyFor(session.userId);
    if (history.length > 0) {
      out.history = history;
    }
  }
  const data = await forwardOrThrow(0, token, out);
  const reply = data?.parts && typeof data.parts.reply === 'string' ? data.parts.reply : null;
  await appendTurn({ account: session.account, userId: session.userId, userText: out.task, replyText: reply });
  return data;
}

async function handleClearContext(token) {
  const session = await requireSession(token);
  if (Number.isInteger(session.userId)) {
    await clearByUser(session.userId);
  } else {
    await clearConversations(session.account);
  }
  return { cleared: { conversations: true } };
}

async function handleConversationsList(token) {
  const session = await requireSession(token);
  const messages = Number.isInteger(session.userId) ? await listByUser(session.userId) : [];
  return { userId: session.userId, messages };
}

// 拉取服务器中转箱并合并进本地（拉取即删）；服务器不可达时只展示本地记录
async function drainRelay(token, account) {
  try {
    const data = await forwardOrThrow(64, token, {});
    const messages = Array.isArray(data?.messages) ? data.messages : [];
    if (messages.length > 0) {
      await mergeIncoming(account, messages);
    }
  } catch {
    // 中转箱拉取失败不影响本地聊天记录展示
  }
}

// 好友名单仍由服务器提供（关系库在服务器）；取不到时只展示本地聊过的会话
async function fetchFriends(token) {
  try {
    const data = await forwardOrThrow(16, token, { keyword: '' });
    const users = Array.isArray(data?.users) ? data.users : [];
    return users
      .filter(u => u && u.state === 'friend')
      .map(u => ({ account: u.account, userId: u.userId }));
  } catch {
    return [];
  }
}

async function handleChatList(token) {
  const session = await requireSession(token);
  await drainRelay(token, session.account);
  return listConversations(session.account, await fetchFriends(token));
}

async function handleChatMessages(token, payload) {
  const session = await requireSession(token);
  const withAccount = typeof payload?.withAccount === 'string' ? payload.withAccount.trim() : '';
  if (withAccount === '') {
    throw badRequest('需要指定对方账号（withAccount）');
  }
  await drainRelay(token, session.account);
  const messages = await listThread(session.account, withAccount);
  return { account: session.account, withAccount, total: messages.length, messages };
}

// 47/48/59：先让服务器校验并投递到对方中转箱，再把消息落到本地（本地是消息的长期存放处）
async function sendAndStoreLocally(serviceId, token, payload) {
  await requireSession(token);
  const data = await forwardOrThrow(serviceId, token, payload);
  const sent = data?.sent ?? null;
  const local = sent ? await appendMessage(sent) : null;
  return { ...data, sent: local ?? sent };
}

async function handleAcceptCard(token, payload) {
  const session = await requireSession(token);
  const messageId = Number(payload?.messageId);
  if (!Number.isInteger(messageId)) {
    throw badRequest('messageId must be an integer');
  }
  const message = await getMessage(session.account, messageId);
  if (!message) {
    throw notFound('聊天消息不存在');
  }
  if (message.kind !== 'card') {
    throw badRequest('该消息不是卡片邀请');
  }
  if (message.toAccount !== session.account) {
    throw forbidden('这张卡片邀请不是发给你的');
  }
  if (message.acceptedAt !== null) {
    throw conflict('你已经接受过这条卡片邀请了');
  }
  if (!Number.isInteger(message.groupId) || !Number.isInteger(message.cardIndex)) {
    throw notFound('卡片邀请缺少组号或卡号，无法加入');
  }
  const needApproval = message.card?.needApproval === true;
  const base = { account: session.account, groupId: message.groupId, cardIndex: message.cardIndex };
  // 需要申请的卡片自动转为加入申请（服务 25），否则直接加入卡片（服务 14）
  const data = needApproval ? await forwardOrThrow(25, token, base) : await forwardOrThrow(14, token, base);
  const acceptedAt = Date.now();
  await markAccepted(session.account, messageId);
  const group = data?.group ?? null;
  return {
    accepted: { id: messageId, acceptedAt },
    group: group ? { id: group.id, name: group.name, owner: group.owner, cardIndex: message.cardIndex } : null,
    card: group ? ((group.cards || []).find(c => c.index === message.cardIndex) ?? null) : null,
    applied: needApproval ? { request: data?.request ?? null } : null,
    needApproval,
    message: needApproval
      ? `已向创建者发送加入卡片 #${message.cardIndex} 的申请，等待对方同意`
      : `已加入卡片 #${message.cardIndex}，你已成为参与者`
  };
}

async function handleAcceptGroup(token, payload) {
  const session = await requireSession(token);
  const messageId = Number(payload?.messageId);
  if (!Number.isInteger(messageId)) {
    throw badRequest('messageId must be an integer');
  }
  const message = await getMessage(session.account, messageId);
  if (!message) {
    throw notFound('聊天消息不存在');
  }
  if (message.kind !== 'group') {
    throw badRequest('该消息不是卡片组邀请');
  }
  if (message.toAccount !== session.account) {
    throw forbidden('这个卡片组邀请不是发给你的');
  }
  if (message.acceptedAt !== null) {
    throw conflict('你已经接受过这个卡片组邀请了');
  }
  if (!Number.isInteger(message.groupId)) {
    throw notFound('卡片组邀请缺少组号，无法加入');
  }
  const data = await forwardOrThrow(65, token, { account: session.account, groupId: message.groupId });
  await markAccepted(session.account, messageId);
  const g = data?.group ?? null;
  const joinedCards = data?.joinedCards ?? 0;
  const skippedCards = data?.skippedCards ?? 0;
  return {
    accepted: { id: messageId, acceptedAt: Date.now() },
    group: g ? { id: g.id, name: g.name, owner: g.owner, cardCount: g.cardCount } : null,
    joinedCards,
    skippedCards,
    message: data?.already
      ? `你已是卡片组「${g?.name ?? ''}」的成员；本次新加入 ${joinedCards} 张卡片（${skippedCards} 张已满或已加入，已跳过）`
      : `已加入卡片组「${g?.name ?? ''}」，其中自动加入 ${joinedCards} 张（${skippedCards} 张已满或已加入，已跳过）`
  };
}

// 私人卡片组同步：上送本地副本 → 服务器按 updatedAt 合并 → 用合并结果覆盖本地副本
async function syncPrivateGroups(token, account) {
  try {
    const local = await listForAccount(account);
    const data = await forwardOrThrow(63, token, { account, groups: local });
    const groups = Array.isArray(data?.groups) ? data.groups : [];
    await replaceForAccount(account, groups);
  } catch {
    // 同步失败不阻塞登录，下次登录会重试
  }
}

// 把本地私人卡片组副本转成与服务器服务 37 同形的 entries（按 updatedAt 降序，新的在前）
function privateEntriesOf(groups) {
  return (Array.isArray(groups) ? groups : [])
    .slice()
    .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : (a.updatedAt > b.updatedAt ? -1 : 0)))
    .map(g => ({
      library: 'private',
      id: g.id ?? null,
      name: g.name,
      owner: g.account,
      role: 'owner',
      cardCount: Array.isArray(g.cards) ? g.cards.length : 0,
      cards: Array.isArray(g.cards) ? g.cards : [],
      createdAt: g.createdAt ?? null,
      updatedAt: g.updatedAt ?? null
    }));
}

// 服务 37：优先取服务器（保证 50/52 转库后的新鲜度）；服务器不可达时回落本地私人卡片组副本
async function handlePrivateGroupsList(token) {
  const session = await requireSession(token);
  try {
    return await forwardOrThrow(37, token, { account: session.account });
  } catch (err) {
    if (err?.status !== 502) {
      throw err;
    }
    const groups = await listForAccount(session.account);
    return { account: session.account, entries: privateEntriesOf(groups), offline: true };
  }
}

// 服务 38：以服务器删除为准（校验归属/存在性），成功后一并删除本地私人卡片组副本
async function handlePrivateGroupsDelete(token, payload) {
  const session = await requireSession(token);
  const groupId = Number(payload?.groupId);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  const data = await forwardOrThrow(38, token, payload);
  await removePrivateGroup(session.account, groupId).catch(() => null);
  return data;
}

// 服务 50（整组转公开）/ 55（删组）：均以服务器为准，成功后同步删除本地私人卡片组副本——
// 该组已离开私人库或已不存在，副本留着会在登录同步（63）上送时以「新私人组」复活。
// 公开组不在副本中，删除为空操作；副本清理失败不影响转发结果（服务器墓碑兜底）
async function forwardThenDropPrivateGroup(serviceId, token, payload) {
  const data = await forwardOrThrow(serviceId, token, payload);
  try {
    const session = await resolveSession(token);
    if (session) {
      await removePrivateGroup(session.account, Number(payload?.groupId));
    }
  } catch {
    // 副本清理失败不影响结果
  }
  return data;
}

// 服务 57（删组内卡片）：以服务器为准，成功后同步从本地私人卡片组副本移除该卡（副本无此组时空操作）。
// 副本时间戳保持不动（仍比服务器旧），63 合并时服务器版本照旧胜出
async function handleGroupRemoveCard(token, payload) {
  const data = await forwardOrThrow(57, token, payload);
  try {
    const session = await resolveSession(token);
    if (session) {
      await removePrivateCard(session.account, Number(payload?.groupId), Number(payload?.cardIndex));
    }
  } catch {
    // 副本清理失败不影响结果
  }
  return data;
}

// 服务 41：提前预告已在卡片延期改造时停用，本地固定返回空
async function handleUpcomingReminders(token) {
  await requireSession(token);
  return { reminders: [] };
}

// ---- 明信片（服务 66 / 62）：服务器按「当前点击完成的这张卡片」出稿，客户端写入本地文本文件长期保存 ----
// 上下文只带该卡片，服务器不持久化；AI 未配置或调用失败时抛错，由调用方决定是否忽略。
async function generateAndStorePostcard(token, session, target) {
  const groupId = Number(target?.groupId);
  const cardIndex = Number(target?.cardIndex);
  if (!Number.isInteger(groupId) || !Number.isInteger(cardIndex)) {
    throw badRequest('需要卡片组号与组内卡号（groupId / cardIndex）才能制作明信片');
  }
  const data = await forwardOrThrow(66, token, { groupId, cardIndex });
  const created = await appendPostcard({
    account: session.account,
    userId: session.userId,
    groupId: data?.groupId ?? groupId,
    groupName: data?.groupName ?? null,
    cardIndex: data?.cardIndex ?? cardIndex,
    event: data?.event ?? null,
    time: data?.time ?? null,
    text: data?.text ?? '',
    model: data?.model ?? null,
    createdAt: data?.createdAt ?? null
  });
  return { generated: data, postcard: created };
}

async function handleMakePostcard(token, payload) {
  const session = await requireSession(token);
  return generateAndStorePostcard(token, session, payload ?? {});
}

// 服务 62：先让服务器把卡片标记完成，再顺带按该卡片生成一张明信片；
// 完成数同步 +1 并给当天打卡 +1（本地周报库）；明信片生成失败绝不影响「完成」本身。
// 明信片出稿成功后，把该卡片从卡片组删除（归档为明信片，服务 57）；删除失败不影响「完成」与明信片。
async function handleCompleteCard(token, payload) {
  const session = await requireSession(token);
  const data = await forwardOrThrow(62, token, payload);
  await recordComplete({
    account: session.account,
    userId: session.userId,
    groupId: payload?.groupId,
    cardIndex: payload?.cardIndex
  }).catch(() => null);
  let postcard = null;
  try {
    const built = await generateAndStorePostcard(token, session, payload ?? {});
    postcard = built.postcard;
  } catch {
    // 无明信片则不动卡片（保留已完成的卡片，避免「既没出稿又没了卡」）
  }
  let removed = null;
  if (postcard) {
    try {
      removed = await handleGroupRemoveCard(token, {
        account: session.account,
        groupId: payload?.groupId,
        cardIndex: payload?.cardIndex
      });
    } catch {
      // 非创建者/非完成者等无删除权限时忽略，不影响「完成」
    }
  }
  const out = { ...data };
  if (postcard) {
    out.postcard = postcard;
  }
  if (removed) {
    out.removed = removed;
  }
  return out;
}

// ---- 周报（服务 74 / 75 / 67）：只有「卡片数」需要服务器展开计算，其余事件在客户端本地累加 ----
// 服务 74：取服务器按本周窗口算出的命中卡片数，分别对「今周」与「上一周」各快照一次写入周报库；
// 同时把本次看到的相关卡片并入累计去重集合（这样卡片被删除后累计数也不会减少）。
async function handleWeekReport(token, payload) {
  const session = await requireSession(token);
  const now = Number.isFinite(Number(payload?.atMs)) ? Number(payload.atMs) : Date.now();
  const currentStart = weekStartMsOf(now);
  const currentEnd = currentStart + 7 * 86400000;
  const prevStart = currentStart - 7 * 86400000;
  const base = { account: session.account, userId: session.userId };
  const current = await forwardOrThrow(74, token, { account: session.account, startMs: currentStart, endMs: currentEnd });
  await applyWeekSnapshot({
    ...base,
    startMs: currentStart,
    endMs: currentEnd,
    weekCardKeys: current?.weekCardKeys ?? [],
    weekDueCardKeys: current?.weekDueCardKeys ?? [],
    allCardKeys: current?.allCardKeys ?? []
  });
  const prev = await forwardOrThrow(74, token, { account: session.account, startMs: prevStart, endMs: currentStart });
  await applyWeekSnapshot({
    ...base,
    startMs: prevStart,
    endMs: currentStart,
    weekCardKeys: prev?.weekCardKeys ?? [],
    weekDueCardKeys: prev?.weekDueCardKeys ?? [],
    allCardKeys: prev?.allCardKeys ?? []
  });
  return getReport(session.account, now);
}

// 服务 75：给一张卡片打卡（只计数，一天一张卡片一次），本地应答
async function handleCheckin(token, payload) {
  const session = await requireSession(token);
  const out = await recordCheckin({
    account: session.account,
    userId: session.userId,
    groupId: payload?.groupId,
    cardIndex: payload?.cardIndex,
    atMs: payload?.atMs ?? null
  });
  if (!out) {
    throw badRequest('需要卡片组号与组内卡号（groupId / cardIndex）才能打卡');
  }
  return { ...out, message: out.already ? '这张卡片今天已经打过卡了' : '打卡成功，已计入本周打卡数' };
}

// 服务 67：延期先由服务器处理（发起者直接改期 / 参与者生成申请），成功后本地延时数 +1（无论是否获批）
async function handleExtendCard(token, payload) {
  const session = await requireSession(token);
  const data = await forwardOrThrow(67, token, payload);
  await recordExtend({ account: session.account, userId: session.userId }).catch(() => null);
  return data;
}

// 服务 97：客户端上送定位信息（经纬度 / IP / 城市名，服务器按此优先级整理），
// 服务器用和风天气查 8 个产品后返回；客户端把这一份结果写入本地天气文件长期保存（服务器不持久化）。
async function handleWeatherFetch(token, payload) {
  const session = await requireSession(token);
  const data = await forwardOrThrow(97, token, payload ?? {});
  const stored = await appendWeatherSnapshot({
    account: session.account,
    userId: session.userId,
    location: data?.location ?? null,
    weather: data?.weather ?? null,
    fetchedAt: data?.fetchedAt ?? null
  });
  return {
    ...data,
    stored: stored ? { id: stored.id, fetchedAt: stored.fetchedAt } : null
  };
}

const HANDLERS = new Map([
  [0, handleAiAsk],
  [8, handleClearContext],
  [9, handleLoginState],
  [10, handleRegister],
  [11, handleLogin],
  [12, handleLogout],
  [13, handleUnregister],
  [78, handleHuaweiLogin],
  [81, handleGuestLogin],
  [82, handleRename],
  [83, handleSetPassword],
  [85, handleEmailRegister],
  [88, handleHuaweiRegister],
  [37, handlePrivateGroupsList],
  [38, handlePrivateGroupsDelete],
  [39, handleConversationsList],
  [41, handleUpcomingReminders],
  [45, handleChatList],
  [46, handleChatMessages],
  [47, (token, payload) => sendAndStoreLocally(47, token, payload)],
  [48, (token, payload) => sendAndStoreLocally(48, token, payload)],
  [49, handleAcceptCard],
  [50, (token, payload) => forwardThenDropPrivateGroup(50, token, payload)],
  [55, (token, payload) => forwardThenDropPrivateGroup(55, token, payload)],
  [57, handleGroupRemoveCard],
  [59, (token, payload) => sendAndStoreLocally(59, token, payload)],
  [60, handleAcceptGroup],
  [62, handleCompleteCard],
  [66, handleMakePostcard],
  [67, handleExtendCard],
  [74, handleWeekReport],
  [75, handleCheckin],
  [97, handleWeatherFetch]
]);

// 分流入口：返回 { handled: true, data } 表示客户端本地应答；handled=false 表示照旧转发给服务器
export async function handleRoute(serviceId, { token = null, payload = {} } = {}) {
  if (!INTERCEPTED.has(serviceId)) {
    return { handled: false };
  }
  const handler = HANDLERS.get(serviceId);
  if (!handler) {
    return { handled: false };
  }
  const result = await handler(token, payload ?? {});
  return { handled: true, data: { serviceId, service: SERVICE_NAMES.get(serviceId) ?? null, result } };
}