import { JsonRec } from './Jsonl';
import { ServerClient, SubmitResult } from './ServerClient';
import { SessionRec, sessionStore } from './stores/SessionStore';
import { LoginState, loginStateStore } from './stores/LoginStateStore';
import { ConvRec, conversationStore } from './stores/ConversationStore';
import { personalizationStore } from './stores/PersonalizationStore';
import { ChatMsg, FriendBrief, chatStore } from './stores/ChatStore';
import { PrivateGroupRec, privateGroupStore } from './stores/PrivateGroupStore';
import { accountArchiveStore } from './stores/AccountArchiveStore';
import { PostcardRec, postcardStore } from './stores/PostcardStore';
import { reportStore, weekStartMsOf } from './stores/ReportStore';
import { weatherStore } from './stores/WeatherStore';

/** 分流结果：handled=false 表示未拦截、需照旧转发服务器；code=0 表示成功 */
export class RouteOutcome {
  readonly handled: boolean;
  readonly code: number;
  readonly status: number;
  readonly message: string;
  readonly serviceId: number;
  readonly service: string | null;
  readonly result: Object | null;

  constructor(handled: boolean, code: number, status: number, message: string,
    serviceId: number, service: string | null, result: Object | null) {
    this.handled = handled;
    this.code = code;
    this.status = status;
    this.message = message;
    this.serviceId = serviceId;
    this.service = service;
    this.result = result;
  }
}

/** 本地处理错误：携带服务器一致的业务码 / HTTP 状态码（对齐 Node 版 httpError） */
class RouteError extends Error {
  readonly code: number;
  readonly status: number;

  constructor(message: string, code: number, status: number) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

function badRequest(message: string): RouteError {
  return new RouteError(message, 40001, 400);
}

function unauthorized(): RouteError {
  // 与服务器一致：40101 会让 App 用保存的凭据自动重登一次，重登后客户端即可记下新会话
  return new RouteError('登录状态已失效，请重新登录', 40101, 401);
}

function forbidden(message: string): RouteError {
  return new RouteError(message, 40301, 403);
}

function notFound(message: string): RouteError {
  return new RouteError(message, 40401, 404);
}

function conflict(message: string): RouteError {
  return new RouteError(message, 40901, 409);
}

/** 本地化服务清单（其余服务照旧转发服务器） */
const INTERCEPTED: number[] =
  [0, 8, 9, 10, 11, 12, 13, 37, 38, 39, 41, 45, 46, 47, 48, 49, 50, 55, 57, 59, 60, 62, 66, 67, 74, 75, 78, 81, 82, 83, 85, 88, 97];

export function isIntercepted(serviceId: number): boolean {
  return INTERCEPTED.indexOf(serviceId) >= 0;
}

/** 本地应答带上的服务名（App 只认 data.result，控制台同样按此形状解析） */
export function serviceNameOf(serviceId: number): string | null {
  switch (serviceId) {
    case 0:
      return 'ai.ask';
    case 8:
      return 'ai.clear-context';
    case 9:
      return 'auth.login-state';
    case 10:
      return 'auth.register';
    case 11:
      return 'auth.login';
    case 12:
      return 'auth.logout';
    case 13:
      return 'auth.unregister';
    case 77:
      return 'auth.huawei-bind';
    case 78:
      return 'auth.huawei-login';
    case 79:
      return 'auth.huawei-state';
    case 80:
      return 'auth.huawei-unbind';
    case 81:
      return 'auth.guest-login';
    case 82:
      return 'auth.rename';
    case 83:
      return 'auth.set-password';
    case 85:
      return 'auth.email-register';
    case 86:
      return 'auth.email-reset-password';
    case 88:
      return 'auth.huawei-register';
    case 37:
      return 'cards.private-list';
    case 38:
      return 'cards.private-delete';
    case 39:
      return 'conversations.list';
    case 41:
      return 'reminders.upcoming';
    case 45:
      return 'chat.list';
    case 46:
      return 'chat.messages';
    case 47:
      return 'chat.send-text';
    case 48:
      return 'chat.send-card';
    case 49:
      return 'chat.accept-card';
    case 50:
      return 'cards.publish';
    case 55:
      return 'groups.delete';
    case 57:
      return 'groups.remove-card';
    case 59:
      return 'chat.send-group';
    case 60:
      return 'chat.accept-group';
    case 62:
      return 'groups.complete-card';
    case 66:
      return 'postcard.make';
    case 67:
      return 'cards.extend';
    case 74:
      return 'reports.week';
    case 75:
      return 'cards.checkin';
    case 97:
      return 'weather.fetch';
    default:
      return null;
  }
}

/**
 * 转发到服务器并按服务器原始业务码/状态码抛错（连不上时用 502）；
 * 返回值是服务器包装体里的 result（与交给 App 前再包一层 {serviceId, service, result} 对称）
 */
async function forwardOrThrow(serviceId: number, token: string | null,
  payload: Record<string, Object>): Promise<Object | null> {
  const out: SubmitResult = await ServerClient.submitToServer(serviceId, token, payload);
  if (!out.ok) {
    const bodyRec: Record<string, Object> | null = JsonRec.toRecord(out.body);
    const code: Object | undefined = JsonRec.val(bodyRec, 'code');
    const message: Object | undefined = JsonRec.val(bodyRec, 'message');
    if (code !== undefined && typeof code === 'number' && message !== undefined && typeof message === 'string') {
      throw new RouteError(message as string, code as number, out.status !== 0 ? out.status : 502);
    }
    const errText: string = out.error !== null ? out.error : `http ${out.status}`;
    throw new RouteError(`server returned error: ${errText}`, 50201, 502);
  }
  let data: Object | null = out.body;
  const bodyRec: Record<string, Object> | null = JsonRec.toRecord(out.body);
  const dataField: Object | undefined = JsonRec.val(bodyRec, 'data');
  if (dataField !== undefined && dataField !== null) {
    data = dataField;
  }
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  const resultField: Object | undefined = JsonRec.val(dataRec, 'result');
  if (resultField !== undefined) {
    return resultField;
  }
  return data;
}

async function requireSession(token: string | null): Promise<SessionRec> {
  const session: SessionRec | null = sessionStore.resolveSession(token);
  if (session === null) {
    throw unauthorized();
  }
  return session;
}

/** 服务 9：读取登录状态文件（无需 token，App 冷启动时调用） */
function handleLoginState(): Object {
  return loginStateStore.getLoginState().toRecord();
}

/** 注册成功：同样视为已登录（App 注册后紧接着会自动登录，凭据一致） */
async function handleRegister(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const data: Object | null = await forwardOrThrow(10, token, payload);
  loginStateStore.markLoggedIn(payload['account'], payload['password']);
  accountArchiveStore.recordAccount(JsonRec.trimText(payload['account']), JsonRec.text(payload['password']));
  return data;
}

/** 登录成功：记下 token -> 账号 的映射，并把本地私人卡片组副本与服务器双向合并 */
async function handleLogin(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
    const data: Object | null = await forwardOrThrow(11, token, payload);
    const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
    if (dataRec !== null && JsonRec.isString(dataRec['account']) && JsonRec.isString(dataRec['token'])) {
      const account: string = dataRec['account'] as string;
      sessionStore.rememberLogin(dataRec['token'] as string, account, dataRec['userId']);
      await syncPrivateGroups(dataRec['token'] as string, account);
      // 登录态记输入的登录标识（邮箱账号=邮箱、老账号=账号名），冷启动自动登录原样回传；
      // 展示用的账号名以会话/服务器解析结果为准
      loginStateStore.markLoggedIn(payload['account'], payload['password']);
      accountArchiveStore.recordAccount(account, JsonRec.text(payload['password']));
    await refreshArchivedPublicGroups(dataRec['token'] as string, account);
  }
  return data;
}

async function handleLogout(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const data: Object | null = await forwardOrThrow(12, token, payload);
  const payloadToken2: string = JsonRec.trimText(payload['token']);
  sessionStore.forgetSession(payloadToken2.length > 0 ? payloadToken2 : token, null);
  loginStateStore.markLoggedOut();
  return data;
}

/** 华为账号登录成功（78）：与密码登录一致地记录会话并合并私人卡片组副本；
 *  登录态：Account Kit 流程拿不到密码——同账号已有带密码的登录记录则原样保留
 *  （冷启动仍可密码自动登录），否则写游客式两行登录态（华为注册/自动建号账号
 *  服务器侧密码为空，冷启动按空密码自动登录），保证杀死进程重新进入不回登录页 */
async function handleHuaweiLogin(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const data: Object | null = await forwardOrThrow(78, token, payload);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  if (dataRec !== null && JsonRec.isString(dataRec['account']) && JsonRec.isString(dataRec['token'])) {
    const account: string = dataRec['account'] as string;
    sessionStore.rememberLogin(dataRec['token'] as string, account, dataRec['userId']);
    await syncPrivateGroups(dataRec['token'] as string, account);
    const current: LoginState = loginStateStore.getLoginState();
    if (current.state !== 1 || current.account !== account || current.password.length === 0) {
      loginStateStore.markGuestLoggedIn(account);
    }
    accountArchiveStore.recordAccount(account, '');
  }
  return data;
}

/** 游客一键进入（81）：服务器自动建号（UIDxxxxx / 空密码），与登录一致地记录会话、合并副本，
 *  并写入游客式两行登录态（不记密码，冷启动按空密码自动登录） */
async function handleGuestLogin(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const data: Object | null = await forwardOrThrow(81, token, payload);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  if (dataRec !== null && JsonRec.isString(dataRec['account']) && JsonRec.isString(dataRec['token'])) {
    const account: string = dataRec['account'] as string;
    sessionStore.rememberLogin(dataRec['token'] as string, account, dataRec['userId']);
    await syncPrivateGroups(dataRec['token'] as string, account);
    loginStateStore.markGuestLoggedIn(account);
    accountArchiveStore.recordAccount(account, '');
  }
  return data;
}

/** 邮箱验证码注册成功（85）：App 侧 AGC 已校验验证码，服务器自动建号（UIDxxxxx / 空密码 + 邮箱标识），
 *  与登录一致地记录会话、合并副本，并写入游客式两行登录态（不记密码，冷启动按空密码自动登录；
 *  界面2 设密后转三行式，跳过者可走登录页「忘记密码」重置） */
async function handleEmailRegister(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const data: Object | null = await forwardOrThrow(85, token, payload);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  if (dataRec !== null && JsonRec.isString(dataRec['account']) && JsonRec.isString(dataRec['token'])) {
    const account: string = dataRec['account'] as string;
    sessionStore.rememberLogin(dataRec['token'] as string, account, dataRec['userId']);
    await syncPrivateGroups(dataRec['token'] as string, account);
    loginStateStore.markGuestLoggedIn(account);
    accountArchiveStore.recordAccount(account, '');
  }
  return data;
}

/** 华为账号注册成功（88）：Account Kit 拿到 unionID 后服务器自动建号并绑定，与登录一致地记录会话、
 *  合并副本，并写入游客式两行登录态（Account Kit 流程拿不到密码，冷启动按空密码自动登录） */
async function handleHuaweiRegister(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const data: Object | null = await forwardOrThrow(88, token, payload);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  if (dataRec !== null && JsonRec.isString(dataRec['account']) && JsonRec.isString(dataRec['token'])) {
    const account: string = dataRec['account'] as string;
    sessionStore.rememberLogin(dataRec['token'] as string, account, dataRec['userId']);
    await syncPrivateGroups(dataRec['token'] as string, account);
    loginStateStore.markGuestLoggedIn(account);
    accountArchiveStore.recordAccount(account, '');
  }
  return data;
}

/** 修改账号名（82）：服务器改名成功后，把本地各库该账号的记录一并换名；
 *  新名字以服务器响应里的 account 为准（服务器已 trim / 校验 / 去重） */
async function handleRename(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const session: SessionRec = await requireSession(token);
  const data: Object | null = await forwardOrThrow(82, token, payload);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  if (dataRec !== null && JsonRec.isString(dataRec['account'])) {
    const newName: string = dataRec['account'] as string;
    if (newName.length > 0 && newName !== session.account) {
      conversationStore.renameAccountOf(session.account, newName);
      chatStore.renameAccountOf(session.account, newName);
      privateGroupStore.renameAccountOf(session.account, newName);
      postcardStore.renameAccountOf(session.account, newName);
      reportStore.renameAccountOf(session.account, newName);
      weatherStore.renameAccountOf(session.account, newName);
      sessionStore.renameAccountOf(session.account, newName);
      loginStateStore.renameLoggedInAccount(session.account, newName);
      accountArchiveStore.renameAccountOf(session.account, newName);
    }
  }
  return data;
}

/** 设置密码（83）：服务器落密码成功后，更新本地登录态里的密码记录（之后冷启动/自动重登都用新密码） */
async function handleSetPassword(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const session: SessionRec = await requireSession(token);
  const data: Object | null = await forwardOrThrow(83, token, payload);
  loginStateStore.markLoggedIn(session.account, payload['newPassword']);
  accountArchiveStore.recordPassword(session.account, JsonRec.text(payload['newPassword']));
  return data;
}

/** 注销：服务器删除账号后，客户端一并清掉该账号的本地记录（对话/聊天/私人卡片组/明信片/周报） */
async function handleUnregister(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const session: SessionRec | null = sessionStore.resolveSession(token);
  const data: Object | null = await forwardOrThrow(13, token, payload);
  if (session !== null) {
    conversationStore.clearByAccount(session.account);
    chatStore.clearByAccount(session.account);
    privateGroupStore.clearByAccount(session.account);
    postcardStore.clearByAccount(session.account);
    reportStore.clearByAccount(session.account);
    weatherStore.clearByAccount(session.account);
  }
  sessionStore.forgetSession(token, null);
  loginStateStore.markLoggedOut();
  return data;
}

/** 服务 0：把本地历史随请求上送（服务器不再持久化对话），成功后把本轮写入本地。
 *  个性化服务关闭时：上送的对话记录与用户信息一律为空值，且本轮对话不再记录 */
async function handleAiAsk(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const session: SessionRec = await requireSession(token);
  const personalized: boolean = personalizationStore.isEnabled();
  const out: Record<string, Object> = JsonRec.copyRecord(payload);
  if (!personalized) {
    out['history'] = [];
  } else if (session.userId !== null) {
    const history: Record<string, Object>[] = conversationStore.historyFor(session.userId);
    if (history.length > 0) {
      out['history'] = history;
    }
  }
  const data: Object | null = await forwardOrThrow(0, token, out);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  const parts: Record<string, Object> | null = JsonRec.toRecord(JsonRec.val(dataRec, 'parts') ?? null);
  let reply: string | null = null;
  if (parts !== null && JsonRec.isString(parts['reply'])) {
    reply = parts['reply'] as string;
  }
  if (personalized) {
    conversationStore.appendTurn(session.account, session.userId, out['task'] !== undefined ? out['task'] : null, reply);
  }
  return data;
}

async function handleClearContext(token: string | null): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  if (session.userId !== null) {
    conversationStore.clearByUser(session.userId);
  } else {
    conversationStore.clearByAccount(session.account);
  }
  const cleared: Record<string, Object> = { 'conversations': true };
  const result: Record<string, Object> = { 'cleared': cleared };
  return result;
}

async function handleConversationsList(token: string | null): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  const messages: Object[] = [];
  if (personalizationStore.isEnabled() && session.userId !== null) {
    const list: ConvRec[] = conversationStore.listByUser(session.userId);
    for (let i = 0; i < list.length; i++) {
      messages.push(list[i].toRecord());
    }
  }
  const result: Record<string, Object> = { 'messages': messages };
  JsonRec.put(result, 'userId', session.userId);
  return result;
}

/** 拉取服务器中转箱并合并进本地（拉取即删）；服务器不可达时只展示本地记录 */
async function drainRelay(token: string | null, account: string): Promise<void> {
  try {
    const empty: Record<string, Object> = {};
    const data: Object | null = await forwardOrThrow(64, token, empty);
    const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
    const messages: Object[] | null = JsonRec.arr(JsonRec.val(dataRec, 'messages') ?? null);
    if (messages !== null && messages.length > 0) {
      chatStore.mergeIncoming(account, messages);
    }
  } catch (e) {
    // 中转箱拉取失败不影响本地聊天记录展示
  }
}

/** 好友名单仍由服务器提供（关系库在服务器）；取不到时只展示本地聊过的会话 */
async function fetchFriends(token: string | null): Promise<FriendBrief[]> {
  try {
    const payload: Record<string, Object> = { 'keyword': '' };
    const data: Object | null = await forwardOrThrow(16, token, payload);
    const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
    const users: Object[] = JsonRec.arr(JsonRec.val(dataRec, 'users') ?? null) ?? [];
    const friends: FriendBrief[] = [];
    for (let i = 0; i < users.length; i++) {
      const u: Record<string, Object> | null = JsonRec.toRecord(users[i]);
      if (u === null) {
        continue;
      }
      if (u['state'] !== 'friend') {
        continue;
      }
      friends.push(new FriendBrief(u['account'], u['userId']));
    }
    return friends;
  } catch (e) {
    return [];
  }
}

async function handleChatList(token: string | null): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  await drainRelay(token, session.account);
  const friends: FriendBrief[] = await fetchFriends(token);
  return chatStore.listConversations(session.account, friends);
}

async function handleChatMessages(token: string | null, payload: Record<string, Object>): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  const withAccount: string = JsonRec.trimText(payload['withAccount']);
  if (withAccount.length === 0) {
    throw badRequest('需要指定对方账号（withAccount）');
  }
  await drainRelay(token, session.account);
  const thread: ChatMsg[] = chatStore.listThread(session.account, withAccount);
  const messages: Object[] = [];
  for (let i = 0; i < thread.length; i++) {
    messages.push(thread[i].toRecord());
  }
  const result: Record<string, Object> = { 'account': session.account, 'withAccount': withAccount, 'total': messages.length };
  result['messages'] = messages;
  return result;
}

/** 47/48/59：先让服务器校验并投递到对方中转箱，再把消息落到本地（本地是消息的长期存放处） */
async function sendAndStoreLocally(serviceId: number, token: string | null,
  payload: Record<string, Object>): Promise<Object> {
  await requireSession(token);
  const data: Object | null = await forwardOrThrow(serviceId, token, payload);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  const sent: Object | null = JsonRec.val(dataRec, 'sent') ?? null;
  const local: ChatMsg | null = sent !== null ? chatStore.appendMessage(sent) : null;
  const out: Record<string, Object> = dataRec !== null ? JsonRec.copyRecord(dataRec) : {};
  JsonRec.put(out, 'sent', local !== null ? local.toRecord() : sent);
  return out;
}

async function handleAcceptCard(token: string | null, payload: Record<string, Object>): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  const messageId: number = JsonRec.rawNum(payload['messageId']);
  if (!Number.isInteger(messageId)) {
    throw badRequest('messageId must be an integer');
  }
  const message: ChatMsg | null = chatStore.getMessage(session.account, messageId);
  if (message === null) {
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
  if (message.groupId === null || message.cardIndex === null) {
    throw notFound('卡片邀请缺少组号或卡号，无法加入');
  }
  const cardRec: Record<string, Object> | null = message.card;
  const needApproval: boolean = cardRec !== null && cardRec['needApproval'] === true;
  const base: Record<string, Object> = { 'account': session.account, 'groupId': message.groupId, 'cardIndex': message.cardIndex };
  // 需要申请的卡片自动转为加入申请（服务 25），否则直接加入卡片（服务 14）
  const data: Object | null = needApproval
    ? await forwardOrThrow(25, token, base)
    : await forwardOrThrow(14, token, base);
  const acceptedAt: number = Date.now();
  chatStore.markAccepted(session.account, messageId);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  const group: Record<string, Object> | null = JsonRec.toRecord(JsonRec.val(dataRec, 'group') ?? null);
  const accepted: Record<string, Object> = { 'id': messageId, 'acceptedAt': acceptedAt };
  const result: Record<string, Object> = { 'accepted': accepted, 'needApproval': needApproval };
  if (group !== null) {
    const groupOut: Record<string, Object> = { 'cardIndex': message.cardIndex };
    groupOut['id'] = group['id'];
    groupOut['name'] = group['name'];
    groupOut['owner'] = group['owner'];
    result['group'] = groupOut;
    const cards: Object[] = JsonRec.arr(group['cards']) ?? [];
    let cardHit: Object | null = null;
    for (let i = 0; i < cards.length; i++) {
      const cRec: Record<string, Object> | null = JsonRec.toRecord(cards[i]);
      if (cRec !== null && cRec['index'] === message.cardIndex) {
        cardHit = cards[i];
        break;
      }
    }
    JsonRec.put(result, 'card', cardHit);
  }
  if (needApproval) {
    const applied: Record<string, Object> = {};
    JsonRec.put(applied, 'request', JsonRec.val(dataRec, 'request') ?? null);
    result['applied'] = applied;
  }
  result['message'] = needApproval
    ? `已向创建者发送加入卡片 #${message.cardIndex} 的申请，等待对方同意`
    : `已加入卡片 #${message.cardIndex}，你已成为参与者`;
  return result;
}

async function handleAcceptGroup(token: string | null, payload: Record<string, Object>): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  const messageId: number = JsonRec.rawNum(payload['messageId']);
  if (!Number.isInteger(messageId)) {
    throw badRequest('messageId must be an integer');
  }
  const message: ChatMsg | null = chatStore.getMessage(session.account, messageId);
  if (message === null) {
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
  if (message.groupId === null) {
    throw notFound('卡片组邀请缺少组号，无法加入');
  }
  const joinPayload: Record<string, Object> = { 'account': session.account, 'groupId': message.groupId };
  const data: Object | null = await forwardOrThrow(65, token, joinPayload);
  chatStore.markAccepted(session.account, messageId);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  const g: Record<string, Object> | null = JsonRec.toRecord(JsonRec.val(dataRec, 'group') ?? null);
  const joinedCards: Object = JsonRec.val(dataRec, 'joinedCards') ?? 0;
  const skippedCards: Object = JsonRec.val(dataRec, 'skippedCards') ?? 0;
  const accepted: Record<string, Object> = { 'id': messageId, 'acceptedAt': Date.now() };
  const result: Record<string, Object> = { 'accepted': accepted, 'joinedCards': joinedCards, 'skippedCards': skippedCards };
  if (g !== null) {
    const groupOut: Record<string, Object> = {};
    groupOut['id'] = g['id'];
    groupOut['name'] = g['name'];
    groupOut['owner'] = g['owner'];
    groupOut['cardCount'] = g['cardCount'];
    result['group'] = groupOut;
  }
  const gName: Object = g !== null ? (JsonRec.val(g, 'name') ?? '') : '';
  const already: boolean = JsonRec.truthy(JsonRec.val(dataRec, 'already'));
  result['message'] = already
    ? `你已是卡片组「${gName}」的成员；本次新加入 ${joinedCards} 张卡片（${skippedCards} 张已满或已加入，已跳过）`
    : `已加入卡片组「${gName}」，其中自动加入 ${joinedCards} 张（${skippedCards} 张已满或已加入，已跳过）`;
  return result;
}

/** 私人卡片组同步：上送本地副本 -> 服务器按 updatedAt 合并 -> 用合并结果覆盖本地副本 */
async function syncPrivateGroups(token: string | null, account: string): Promise<void> {
  try {
    const local: PrivateGroupRec[] = privateGroupStore.listForAccount(account);
    const groups: Object[] = [];
    for (let i = 0; i < local.length; i++) {
      groups.push(local[i].toRecord());
    }
    const payload: Record<string, Object> = { 'account': account, 'groups': groups };
    const data: Object | null = await forwardOrThrow(63, token, payload);
    const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
    const remote: Object[] = JsonRec.arr(JsonRec.val(dataRec, 'groups') ?? null) ?? [];
    privateGroupStore.replaceForAccount(account, remote);
  } catch (e) {
    // 同步失败不阻塞登录，下次登录会重试
  }
}

/** 把该账号「自己创建的公开卡片组」快照写入客户端账号档案（登录后调用；
 *  按组名合并、较新者胜；读取失败静默跳过，不阻塞登录/登出） */
async function refreshArchivedPublicGroups(token: string | null, account: string): Promise<void> {
  try {
    const data: Object | null = await forwardOrThrow(54, token, { 'account': account });
    const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
    const groups: Object[] = JsonRec.arr(JsonRec.val(dataRec, 'groups') ?? null) ?? [];
    const own: Object[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g: Record<string, Object> | null = JsonRec.toRecord(groups[i]);
      if (g === null || JsonRec.text(g['owner']) !== account || JsonRec.text(g['library']) !== 'public') {
        continue;
      }
      const cards: Object[] = [];
      const cardViews: Object[] = JsonRec.arr(g['cards']) ?? [];
      for (let c = 0; c < cardViews.length; c++) {
        const cardView: Record<string, Object> | null = JsonRec.toRecord(cardViews[c]);
        const content: Record<string, Object> | null =
          JsonRec.toRecord(cardView !== null ? cardView['content'] : null);
        if (content !== null) {
          cards.push(JsonRec.copyRecord(content));
        }
      }
      const snapshot: Record<string, Object> = {
        'name': JsonRec.text(g['name']),
        'library': 'public',
        'cards': cards,
        'createdAt': JsonRec.text(g['createdAt']),
        'updatedAt': JsonRec.text(g['updatedAt'])
      };
      own.push(snapshot);
    }
    accountArchiveStore.recordGroups(account, own);
  } catch (e) {
    // 快照失败不阻塞登录/登出
  }
}

/** 把本地私人卡片组副本转成与服务器服务 37 同形的 entries（按 updatedAt 降序，新的在前） */
function privateEntriesOf(groups: PrivateGroupRec[]): Object[] {
  const sorted: PrivateGroupRec[] = groups.slice().sort((a: PrivateGroupRec, b: PrivateGroupRec): number => {
    if (a.updatedAt < b.updatedAt) {
      return 1;
    }
    if (a.updatedAt > b.updatedAt) {
      return -1;
    }
    return 0;
  });
  const out: Object[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const g: PrivateGroupRec = sorted[i];
    const entry: Record<string, Object> =
      { 'library': 'private', 'name': g.name, 'owner': g.account, 'role': 'owner', 'cardCount': g.cards.length, 'cards': g.cards };
    JsonRec.put(entry, 'id', g.id);
    JsonRec.put(entry, 'createdAt', g.createdAt);
    JsonRec.put(entry, 'updatedAt', g.updatedAt);
    out.push(entry);
  }
  return out;
}

/** 服务 37：优先取服务器（保证 50/52 转库后的新鲜度）；服务器不可达时回落本地私人卡片组副本 */
async function handlePrivateGroupsList(token: string | null): Promise<Object | null> {
  const session: SessionRec = await requireSession(token);
  try {
    const payload: Record<string, Object> = { 'account': session.account };
    return await forwardOrThrow(37, token, payload);
  } catch (e) {
    const err: Error = e instanceof Error ? e : new Error('客户端处理失败');
    if (!(err instanceof RouteError) || err.status !== 502) {
      throw err;
    }
    const groups: PrivateGroupRec[] = privateGroupStore.listForAccount(session.account);
    const entries: Object[] = privateEntriesOf(groups);
    const fallback: Record<string, Object> = { 'account': session.account, 'entries': entries, 'offline': true };
    return fallback;
  }
}

/** 服务 38：以服务器删除为准（校验归属/存在性），成功后一并删除本地私人卡片组副本 */
async function handlePrivateGroupsDelete(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const session: SessionRec = await requireSession(token);
  const groupId: number = JsonRec.rawNum(payload['groupId']);
  if (!Number.isInteger(groupId) || groupId < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  const data: Object | null = await forwardOrThrow(38, token, payload);
  try {
    privateGroupStore.removeForAccount(session.account, groupId);
  } catch (e) {
    // 副本清理失败不影响转发结果（服务器墓碑兜底）
  }
  return data;
}

/** 服务 50（整组转公开）/ 55（删组）：均以服务器为准，成功后同步删除本地私人卡片组副本 */
async function forwardThenDropPrivateGroup(serviceId: number, token: string | null,
  payload: Record<string, Object>): Promise<Object | null> {
  const data: Object | null = await forwardOrThrow(serviceId, token, payload);
  try {
    const session: SessionRec | null = sessionStore.resolveSession(token);
    if (session !== null) {
      privateGroupStore.removeForAccount(session.account, JsonRec.rawNum(payload['groupId']));
    }
  } catch (e) {
    // 副本清理失败不影响结果
  }
  return data;
}

/** 服务 57（删组内卡片）：以服务器为准，成功后同步从本地副本移除该卡（副本时间戳保持不动，63 合并时服务器照旧胜出） */
async function handleGroupRemoveCard(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const data: Object | null = await forwardOrThrow(57, token, payload);
  try {
    const session: SessionRec | null = sessionStore.resolveSession(token);
    if (session !== null) {
      privateGroupStore.removeCardForAccount(session.account, JsonRec.rawNum(payload['groupId']),
        JsonRec.rawNum(payload['cardIndex']));
    }
  } catch (e) {
    // 副本清理失败不影响结果
  }
  return data;
}

/** 服务 41：提前预告已在卡片延期改造时停用，本地固定返回空 */
async function handleUpcomingReminders(token: string | null): Promise<Object> {
  await requireSession(token);
  const reminders: Object[] = [];
  const result: Record<string, Object> = { 'reminders': reminders };
  return result;
}

/** 明信片生成结果：generated=服务器 66 的出稿，postcard=本地落库后的记录（text 为空时为 null） */
class PostcardBuild {
  readonly generated: Object | null;
  readonly postcard: PostcardRec | null;

  constructor(generated: Object | null, postcard: PostcardRec | null) {
    this.generated = generated;
    this.postcard = postcard;
  }
}

/** 服务器按「当前点击完成的这张卡片」出稿，客户端写入本地文本文件长期保存。
 *  明信片与卡片属 AI 服务本身，不受个性化服务开关影响，始终照常生成 */
async function generateAndStorePostcard(token: string | null, session: SessionRec,
  target: Record<string, Object>): Promise<PostcardBuild> {
  const groupId: number = JsonRec.rawNum(target['groupId']);
  const cardIndex: number = JsonRec.rawNum(target['cardIndex']);
  if (!Number.isInteger(groupId) || !Number.isInteger(cardIndex)) {
    throw badRequest('需要卡片组号与组内卡号（groupId / cardIndex）才能制作明信片');
  }
  const payload: Record<string, Object> = { 'groupId': groupId, 'cardIndex': cardIndex };
  const data: Object | null = await forwardOrThrow(66, token, payload);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  const created: PostcardRec | null = postcardStore.appendPostcard(
    session.account,
    session.userId,
    JsonRec.val(dataRec, 'groupId') ?? groupId,
    JsonRec.val(dataRec, 'groupName') ?? null,
    JsonRec.val(dataRec, 'cardIndex') ?? cardIndex,
    JsonRec.val(dataRec, 'event') ?? null,
    JsonRec.val(dataRec, 'time') ?? null,
    JsonRec.val(dataRec, 'text') ?? '',
    JsonRec.val(dataRec, 'model') ?? null,
    JsonRec.val(dataRec, 'createdAt') ?? null
  );
  return new PostcardBuild(data, created);
}

async function handleMakePostcard(token: string | null, payload: Record<string, Object>): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  const built: PostcardBuild = await generateAndStorePostcard(token, session, payload);
  const result: Record<string, Object> = {};
  JsonRec.put(result, 'generated', built.generated);
  JsonRec.put(result, 'postcard', built.postcard !== null ? built.postcard.toRecord() : null);
  return result;
}

/**
 * 服务 62：先让服务器把卡片标记完成，再顺带按该卡片生成一张明信片；
 * 完成数同步 +1 并给当天打卡 +1（本地周报库）；明信片生成失败绝不影响「完成」本身。
 * 明信片出稿成功后，把该卡片从卡片组删除（归档为明信片，服务 57）；删除失败不影响「完成」与明信片。
 */
async function handleCompleteCard(token: string | null, payload: Record<string, Object>): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  const data: Object | null = await forwardOrThrow(62, token, payload);
  try {
    reportStore.recordComplete(session.account, session.userId, payload['groupId'], payload['cardIndex'], null);
  } catch (e) {
    // 周报记录失败不影响完成
  }
  let postcard: PostcardRec | null = null;
  try {
    const built: PostcardBuild = await generateAndStorePostcard(token, session, payload);
    postcard = built.postcard;
  } catch (e) {
    // 无明信片则不动卡片（保留已完成的卡片，避免「既没出稿又没了卡」）
  }
  let removed: Object | null = null;
  if (postcard !== null) {
    try {
      const rmPayload: Record<string, Object> = { 'account': session.account };
      if (payload['groupId'] !== undefined) {
        rmPayload['groupId'] = payload['groupId'];
      }
      if (payload['cardIndex'] !== undefined) {
        rmPayload['cardIndex'] = payload['cardIndex'];
      }
      removed = await handleGroupRemoveCard(token, rmPayload);
    } catch (e) {
      // 非创建者/非完成者等无删除权限时忽略，不影响「完成」
    }
  }
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  const out: Record<string, Object> = dataRec !== null ? JsonRec.copyRecord(dataRec) : {};
  if (postcard !== null) {
    out['postcard'] = postcard.toRecord();
  }
  if (removed !== null) {
    out['removed'] = removed;
  }
  return out;
}

/**
 * 服务 74：取服务器按本周窗口算出的命中卡片数，分别对「今周」与「上一周」各快照一次写入周报库；
 * 同时把本次看到的相关卡片并入累计去重集合（卡片被删除后累计数也不会减少）。
 */
async function handleWeekReport(token: string | null, payload: Record<string, Object>): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  const atNum: number = JsonRec.rawNum(payload['atMs']);
  const now: number = Number.isFinite(atNum) ? atNum : Date.now();
  const currentStart: number = weekStartMsOf(now);
  const currentEnd: number = currentStart + 7 * 86400000;
  const prevStart: number = currentStart - 7 * 86400000;
  const curPayload: Record<string, Object> = { 'account': session.account, 'startMs': currentStart, 'endMs': currentEnd };
  const current: Object | null = await forwardOrThrow(74, token, curPayload);
  const curRec: Record<string, Object> | null = JsonRec.toRecord(current);
  reportStore.applyWeekSnapshot(
    session.account,
    session.userId,
    currentStart,
    currentEnd,
    JsonRec.val(curRec, 'weekCardKeys') ?? [],
    JsonRec.val(curRec, 'weekDueCardKeys') ?? [],
    JsonRec.val(curRec, 'allCardKeys') ?? [],
    JsonRec.val(curRec, 'weekTagCards') ?? [],
    JsonRec.val(curRec, 'allTagCards') ?? []
  );
  const prevPayload: Record<string, Object> = { 'account': session.account, 'startMs': prevStart, 'endMs': currentStart };
  const prev: Object | null = await forwardOrThrow(74, token, prevPayload);
  const prevRec: Record<string, Object> | null = JsonRec.toRecord(prev);
  reportStore.applyWeekSnapshot(
    session.account,
    session.userId,
    prevStart,
    currentStart,
    JsonRec.val(prevRec, 'weekCardKeys') ?? [],
    JsonRec.val(prevRec, 'weekDueCardKeys') ?? [],
    JsonRec.val(prevRec, 'allCardKeys') ?? [],
    JsonRec.val(prevRec, 'weekTagCards') ?? [],
    JsonRec.val(prevRec, 'allTagCards') ?? []
  );
  return reportStore.getReport(session.account, now);
}

/** 服务 75：给一张卡片打卡（只计数，一天一张卡片一次），本地应答 */
async function handleCheckin(token: string | null, payload: Record<string, Object>): Promise<Object> {
  const session: SessionRec = await requireSession(token);
  const out: Record<string, Object> | null = reportStore.recordCheckin(
    session.account,
    session.userId,
    payload['groupId'],
    payload['cardIndex'],
    JsonRec.val(payload, 'atMs') ?? null
  );
  if (out === null) {
    throw badRequest('需要卡片组号与组内卡号（groupId / cardIndex）才能打卡');
  }
  const merged: Record<string, Object> = JsonRec.copyRecord(out);
  merged['message'] = JsonRec.truthy(out['already']) ? '这张卡片今天已经打过卡了' : '打卡成功，已计入本周打卡数';
  return merged;
}

/** 服务 67：延期先由服务器处理（发起者直接改期 / 参与者生成申请），成功后本地延时数 +1（无论是否获批） */
async function handleExtendCard(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const session: SessionRec = await requireSession(token);
  const data: Object | null = await forwardOrThrow(67, token, payload);
  try {
    reportStore.recordExtend(session.account, session.userId, null);
  } catch (e) {
    // 周报记录失败不影响延期结果
  }
  return data;
}

/** 服务 97：客户端上送定位信息（经纬度 / IP / 城市名，服务器按优先级整理），
 *  服务器用和风天气查 8 个产品后返回；客户端把这一份结果写入本地天气文件长期保存
 *  （每次新结果清空旧数据，只留最近一份；服务器不持久化）。 */
async function handleWeatherFetch(token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  const session: SessionRec = await requireSession(token);
  const data: Object | null = await forwardOrThrow(97, token, payload);
  const dataRec: Record<string, Object> | null = JsonRec.toRecord(data);
  const stored: Record<string, Object> | null = dataRec !== null
    ? weatherStore.saveSnapshot(session.account, session.userId,
      JsonRec.toRecord(JsonRec.val(dataRec, 'location') ?? null),
      JsonRec.toRecord(JsonRec.val(dataRec, 'weather') ?? null),
      JsonRec.trimText(JsonRec.val(dataRec, 'fetchedAt')))
    : null;
  const out: Record<string, Object> = dataRec !== null ? JsonRec.copyRecord(dataRec) : {};
  JsonRec.put(out, 'stored', stored !== null ? JsonRec.copyRecord(stored) : null);
  return out;
}

async function dispatch(serviceId: number, token: string | null, payload: Record<string, Object>): Promise<Object | null> {
  switch (serviceId) {
    case 0:
      return await handleAiAsk(token, payload);
    case 8:
      return await handleClearContext(token);
    case 9:
      return handleLoginState();
    case 10:
      return await handleRegister(token, payload);
    case 11:
      return await handleLogin(token, payload);
    case 12:
      return await handleLogout(token, payload);
    case 13:
      return await handleUnregister(token, payload);
    case 78:
      return await handleHuaweiLogin(token, payload);
    case 81:
      return await handleGuestLogin(token, payload);
    case 82:
      return await handleRename(token, payload);
    case 83:
      return await handleSetPassword(token, payload);
    case 85:
      return await handleEmailRegister(token, payload);
    case 88:
      return await handleHuaweiRegister(token, payload);
    case 37:
      return await handlePrivateGroupsList(token);
    case 38:
      return await handlePrivateGroupsDelete(token, payload);
    case 39:
      return await handleConversationsList(token);
    case 41:
      return await handleUpcomingReminders(token);
    case 45:
      return await handleChatList(token);
    case 46:
      return await handleChatMessages(token, payload);
    case 47:
      return await sendAndStoreLocally(47, token, payload);
    case 48:
      return await sendAndStoreLocally(48, token, payload);
    case 49:
      return await handleAcceptCard(token, payload);
    case 50:
      return await forwardThenDropPrivateGroup(50, token, payload);
    case 55:
      return await forwardThenDropPrivateGroup(55, token, payload);
    case 57:
      return await handleGroupRemoveCard(token, payload);
    case 59:
      return await sendAndStoreLocally(59, token, payload);
    case 60:
      return await handleAcceptGroup(token, payload);
    case 62:
      return await handleCompleteCard(token, payload);
    case 66:
      return await handleMakePostcard(token, payload);
    case 67:
      return await handleExtendCard(token, payload);
    case 74:
      return await handleWeekReport(token, payload);
    case 75:
      return await handleCheckin(token, payload);
    case 97:
      return await handleWeatherFetch(token, payload);
    default: {
      const empty: Record<string, Object> = {};
      return empty;
    }
  }
}

/**
 * 分流入口（含 route.controller 的错误映射）：返回 handled=false 表示照旧转发服务器；
 * code=0 表示成功，其余为业务错误码（40101 会让 App 自动重登一次）。
 */
export async function handleRoute(serviceId: number, token: string | null,
  payload: Record<string, Object>): Promise<RouteOutcome> {
  if (!isIntercepted(serviceId)) {
    return new RouteOutcome(false, 0, 200, '', serviceId, null, null);
  }
  try {
    const result: Object | null = await dispatch(serviceId, token, payload);
    return new RouteOutcome(true, 0, 200, 'ok', serviceId, serviceNameOf(serviceId), result);
  } catch (e) {
    if (e instanceof RouteError) {
      return new RouteOutcome(true, e.code, e.status, e.message, serviceId, serviceNameOf(serviceId), null);
    }
    const message: string = e instanceof Error ? e.message : '客户端处理失败';
    return new RouteOutcome(true, 500, 500, message, serviceId, serviceNameOf(serviceId), null);
  }
}
