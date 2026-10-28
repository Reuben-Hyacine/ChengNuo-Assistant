import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Backend, ApiResult, RouteOutcome } from '@chengnuo/backend';
import {
  AccountOutcome, AskOutcome, CardExtendOutcome, CompleteCardOutcome, CompleteOutcome, ConflictsOutcome,
  ConversationsOutcome, EmailStateOutcome, FlowOutcome, GroupCreatedOutcome, HuaweiStateOutcome,
  LibraryEntryInfo, LibraryListOutcome, LoginStateOutcome,
  MailListOutcome, MessageOutcome, PickOutcome,
  PostcardListOutcome, PostcardPullOutcome, ProfileOutcome,
  RemindersOutcome, ServerMapper, ServerResp, ServerTaskData, ShopOutcome, StatusOutcome, WeatherOutcome, WeekReportOutcome
} from './ServerModels';
import { tr, trf } from '../common/I18n';
import { WeatherTips } from '../common/WeatherTips';

/**
 * 后端网关：App 内置本地后端（@chengnuo/backend）→ server（:3000）。
 * - 会话/明信片/周报等本地服务由内置后端库函数直答，其余服务转发 server :3000
 * - server 地址自动探测（模拟器 NAT 网关 / 虚拟网卡 / 局域网依次尝试），结果缓存到 AppStorage 并同步给内置后端
 * - 统一走 task { serviceId, token, payload } 路由协议
 * - token 失效（服务器重启 / 40101）时用保存的凭据自动重登并重试一次
 * - 网络失败返回 code = -1 的 ServerResp，由页面决定是否回退离线演示
 * - 所有请求/响应通过 hilog 输出（tag: ChengNuoServer）
 */
export class ServerGateway {
  /** server 候选地址（ourchengnuo.cn = 已备案域名 HTTPS 加密传输，首选 / 47.103.x = 阿里云公网 IP 明文回退，云端优先，数据统一存云上 / 127.0.0.1 = 真机 USB 反向转发 hdc rport / 10.117.x = 电脑 WLAN 局域网 / 10.0.2.2 = 模拟器 NAT 宿主机），
    *  探测成功一个即用并同步给内置后端；
    *  转发型服务由内置后端直接访问 server（App 不再经独立 client 进程 :4000） */
  static readonly CANDIDATE_BASES: string[] = [
    'https://ourchengnuo.cn',
    'http://47.103.13.210:3000',
    'http://127.0.0.1:3000',
    'http://10.117.22.107:3000',
    'http://10.0.2.2:3000',
    'http://192.168.56.1:3000'
  ];
  /** 登录时自报的客户端地址（仅写入服务器地址台账，用于路由 IP 绑定演示） */
  private static readonly CLIENT_IP: string = '10.0.2.15';
  private static readonly CLIENT_PORT: number = 8888;
  private static readonly LOG_DOMAIN: number = 0x0002;
  private static readonly LOG_TAG: string = 'ChengNuoServer';
  private static base: string = '';
  private static token: string = '';
  private static account: string = '';
  private static password: string = '';
  private static userId: number = 0;

  static getBaseUrl(): string {
    return ServerGateway.base;
  }

  /** 登录/会话恢复时写入（account/password 供 token 失效后自动重登） */
  static setSession(token: string, account: string, password: string): void {
    ServerGateway.token = token;
    ServerGateway.account = account;
    ServerGateway.password = password;
    if (token.length === 0) {
      ServerGateway.userId = 0;
    }
  }

  static getToken(): string {
    return ServerGateway.token;
  }

  /** 确保服务器可达：已缓存则复用，否则按候选列表探测 */
  static async ensureBase(): Promise<boolean> {
    if (ServerGateway.base.length > 0) {
      return true;
    }
    const cached: string = AppStorage.get<string>('serverBase') ?? '';
    if (cached.length > 0) {
      if (await ServerGateway.ping(cached)) {
        ServerGateway.base = cached;
        Backend.setServerBase(cached);
        return true;
      }
      AppStorage.setOrCreate('serverBase', '');
    }
    for (let i = 0; i < ServerGateway.CANDIDATE_BASES.length; i++) {
      const candidate: string = ServerGateway.CANDIDATE_BASES[i];
      if (await ServerGateway.ping(candidate)) {
        ServerGateway.base = candidate;
        Backend.setServerBase(candidate);
        AppStorage.setOrCreate('serverBase', candidate);
        hilog.info(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG, `server connected: ${candidate}`);
        return true;
      }
      hilog.warn(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG, `probe failed: ${candidate}`);
    }
    hilog.error(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG, 'all candidate servers unreachable');
    return false;
  }

  private static async ping(base: string): Promise<boolean> {
    try {
      const request: http.HttpRequest = http.createHttp();
      try {
        const response: http.HttpResponse = await request.request(`${base}/api/health`, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 2000,
          readTimeout: 2000
        });
        return response.responseCode > 0;
      } finally {
        request.destroy();
      }
    } catch (e) {
      return false;
    }
  }

  private static localFail(message: string): ServerResp {
    const fail: ServerResp = new ServerResp();
    fail.code = -1;
    fail.message = message;
    return fail;
  }

  /**
   * 路由任务统一入口：POST /api/route/task
   * withToken=false 用于注册/登录/退出（AUTH_EXEMPT 服务）；40101 时自动重登重试一次
   */
  private static async task(serviceId: number, payload: Record<string, Object>,
    withToken: boolean, retried: boolean, readTimeout: number): Promise<ServerResp> {
    const token: string = withToken ? ServerGateway.token : '';
    const outcome: RouteOutcome = await Backend.handleRoute(serviceId, token, payload);
    if (outcome.handled) {
      if (outcome.code === 40101 && withToken && !retried) {
        if (await ServerGateway.relogin()) {
          return ServerGateway.task(serviceId, payload, withToken, true, readTimeout);
        }
      }
      hilog.info(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
        `<- task ${serviceId} local code=${outcome.code} msg=${outcome.message}`);
      const resp: ServerResp = new ServerResp();
      resp.code = outcome.code;
      resp.message = outcome.message;
      if (outcome.code === 0 && outcome.result !== null) {
        const data: ServerTaskData = new ServerTaskData();
        data.serviceId = outcome.serviceId;
        data.service = outcome.service ?? '';
        data.result = outcome.result;
        resp.data = data;
      }
      return resp;
    }
    if (ServerGateway.base.length === 0) {
      hilog.warn(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
        `drop task ${serviceId}: base not ready`);
      return ServerGateway.localFail(tr('服务器地址未就绪'));
    }
    const body: Record<string, Object> = {
      'serviceId': serviceId,
      'token': token,
      'payload': payload
    };
    hilog.info(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG, `-> task ${serviceId}`);
    try {
      const request: http.HttpRequest = http.createHttp();
      try {
        const header: Record<string, string> = { 'Content-Type': 'application/json' };
        const response: http.HttpResponse = await request.request(`${ServerGateway.base}/api/route/task`, {
          method: http.RequestMethod.POST,
          header: header,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 8000,
          readTimeout: readTimeout,
          extraData: JSON.stringify(body)
        });
        if (typeof response.result === 'string') {
          const text: string = response.result;
          let parsed: ServerResp | null = null;
          try {
            parsed = JSON.parse(text) as ServerResp;
          } catch (e) {
            parsed = null;
          }
          if (parsed !== null) {
            hilog.info(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
              `<- task ${serviceId} HTTP ${response.responseCode} code=${parsed.code} msg=${parsed.message}`);
            if (parsed.code === 40101 && withToken && !retried) {
              if (await ServerGateway.relogin()) {
                return ServerGateway.task(serviceId, payload, withToken, true, readTimeout);
              }
            }
            return parsed;
          }
        }
        hilog.warn(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
          `<- task ${serviceId} HTTP ${response.responseCode} no json body`);
        return ServerGateway.localFail(trf('服务异常（HTTP {0}）', response.responseCode));
      } finally {
        request.destroy();
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
        `<- task ${serviceId} network error ${err.code}`);
      return ServerGateway.localFail(trf('网络异常（{0}）', err.code));
    }
  }

  /** token 失效后用保存的凭据重登（服务器内存 session 重启即清空）；
   *  登录标识优先取落盘登录态（HAR 本地应答，其 account 字段为登录时提交的标识：邮箱账号=邮箱）——
   *  进程内 account 在登录成功后会被 saveSession 覆盖为展示账号名，而有邮箱的账号服务器只认邮箱登录；
   *  游客/自动建号账号密码为空也可重登（空密码登录），有密码账号空密码自然登录失败 */
  private static async relogin(): Promise<boolean> {
    if (ServerGateway.account.length === 0) {
      return false;
    }
    hilog.warn(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG, 'token expired, relogin');
    const state: LoginStateOutcome = await ServerGateway.loginState();
    if (state.ok && state.state === 1 && state.account.length > 0) {
      const saved: AccountOutcome = await ServerGateway.loginInternal(state.account, state.password);
      if (saved.ok) {
        AppStorage.setOrCreate('serverToken', saved.token);
        return true;
      }
    }
    const outcome: AccountOutcome = await ServerGateway.loginInternal(ServerGateway.account, ServerGateway.password);
    if (outcome.ok) {
      AppStorage.setOrCreate('serverToken', outcome.token);
      return true;
    }
    return false;
  }

  /** 成功响应取 result，失败返回 null */
  private static resultOf(resp: ServerResp): Object | null {
    if (resp.code === 0 && resp.data !== null) {
      return resp.data.result;
    }
    return null;
  }

  /** 通用消息任务：成功取 result.message，失败取 resp.message */
  private static async messageTask(serviceId: number, payload: Record<string, Object>): Promise<MessageOutcome> {
    const resp: ServerResp = await ServerGateway.task(serviceId, payload, true, false, 15000);
    const outcome: MessageOutcome = new MessageOutcome();
    if (resp.code !== 0) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('操作失败');
      return outcome;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    outcome.ok = true;
    if (rec !== null) {
      outcome.message = ServerMapper.text(rec, 'message');
    }
    return outcome;
  }

  /** 通用工作卡任务：返回 workingCard + flowStatus（邀请类服务附带 message） */
  private static async flowTask(serviceId: number, payload: Record<string, Object>): Promise<FlowOutcome> {
    const resp: ServerResp = await ServerGateway.task(serviceId, payload, true, false, 15000);
    const outcome: FlowOutcome = new FlowOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('操作失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.message = ServerMapper.text(rec, 'message');
    outcome.working = ServerMapper.toWorkingCard(rec['workingCard'] ?? null);
    outcome.flow = ServerMapper.toFlow(rec['flowStatus'] ?? null);
    return outcome;
  }

  /** ---------- 账号模块（serviceId 10/11/12） ---------- */

  /** auth.login（11）：校验密码 + 绑定客户端地址 + 签发 token，成功后记录 token */
  private static async loginInternal(account: string, password: string): Promise<AccountOutcome> {
    const payload: Record<string, Object> = {
      'account': account,
      'password': password,
      'ip': ServerGateway.CLIENT_IP,
      'port': ServerGateway.CLIENT_PORT
    };
    const resp: ServerResp = await ServerGateway.task(11, payload, false, false, 10000);
    const outcome: AccountOutcome = new AccountOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('服务器登录失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.token = ServerMapper.text(rec, 'token');
    outcome.userId = ServerMapper.num(rec, 'userId', 0);
    ServerGateway.token = outcome.token;
    ServerGateway.userId = outcome.userId;
    return outcome;
  }

  /** auth.register（10）：账号查重（已存在返回 code!=0） */
  static async register(account: string, password: string): Promise<AccountOutcome> {
    const payload: Record<string, Object> = {
      'account': account,
      'password': password
    };
    const resp: ServerResp = await ServerGateway.task(10, payload, false, false, 10000);
    const outcome: AccountOutcome = new AccountOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('服务器注册失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.userId = ServerMapper.num(rec, 'userId', 0);
    return outcome;
  }

  /** auth.login-state（9，后端本地应答）：读登录状态文件（0=未登录 / 1=已登录，含记录的账号密码），App 启动时调用 */
  static async loginState(): Promise<LoginStateOutcome> {
    const resp: ServerResp = await ServerGateway.task(9, {}, false, false, 8000);
    const outcome: LoginStateOutcome = new LoginStateOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('登录状态读取失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.state = ServerMapper.num(rec, 'state', 0);
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.password = ServerMapper.text(rec, 'password');
    return outcome;
  }

  /** auth.login（11）：仅登录（账号名或注册邮箱皆可，服务器双查），失败不自动注册；
   *  成功后记录 token 与重登凭据（account/password 供 token 失效后自动重登） */
  static async login(account: string, password: string): Promise<AccountOutcome> {
    const outcome: AccountOutcome = await ServerGateway.loginInternal(account, password);
    if (outcome.ok) {
      ServerGateway.account = account;
      ServerGateway.password = password;
    }
    return outcome;
  }

  /** auth.logout（12）：payload 携带 token（AUTH_EXEMPT 服务），幂等 */
  static async logout(): Promise<void> {
    if (ServerGateway.token.length === 0) {
      return;
    }
    const payload: Record<string, Object> = { 'token': ServerGateway.token };
    await ServerGateway.task(12, payload, false, false, 10000);
    ServerGateway.token = '';
  }

  /** auth.unregister（13）：注销账号（密码校验；AUTH_EXEMPT 服务，payload 显式携带账号密码） */
  static async unregister(password: string): Promise<MessageOutcome> {
    const payload: Record<string, Object> = {
      'account': ServerGateway.account,
      'password': password
    };
    const resp: ServerResp = await ServerGateway.task(13, payload, false, false, 15000);
    const outcome: MessageOutcome = new MessageOutcome();
    if (resp.code !== 0) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('注销失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.message = tr('账号已注销');
    ServerGateway.token = '';
    return outcome;
  }

  /** auth.rename（82）：修改账号名（服务器级联全库改名；成功后 account 返回规范后的新名字） */
  static async renameAccount(newAccount: string): Promise<AccountOutcome> {
    const payload: Record<string, Object> = { 'newAccount': newAccount };
    const resp: ServerResp = await ServerGateway.task(82, payload, true, false, 15000);
    const outcome: AccountOutcome = new AccountOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('改名失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.userId = ServerMapper.num(rec, 'userId', 0);
    return outcome;
  }

  /** auth.set-password（83）：设置/修改密码（游客首设免旧密码；已有密码须校验旧密码） */
  static async setPassword(oldPassword: string, newPassword: string): Promise<MessageOutcome> {
    const payload: Record<string, Object> = {
      'oldPassword': oldPassword,
      'newPassword': newPassword
    };
    const resp: ServerResp = await ServerGateway.task(83, payload, true, false, 15000);
    const outcome: MessageOutcome = new MessageOutcome();
    if (resp.code !== 0) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('设置失败');
      return outcome;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    outcome.ok = true;
    if (rec !== null) {
      outcome.message = ServerMapper.text(rec, 'message');
    }
    return outcome;
  }

  /** ---------- 华为账号模块（serviceId 77/78/79/80：账号密码登录后绑定，登录页一键登录） ---------- */

  /** auth.huawei-login（78，AUTH_EXEMPT 无需 token）：华为账号一键登录——服务器按 unionId 反查绑定的程诺账号，
   *  校验通过即绑定客户端地址并签发新 token（与密码登录同会话机制）；成功后记录 token（同 loginInternal） */
  static async huaweiLogin(unionId: string, openId: string): Promise<AccountOutcome> {
    const payload: Record<string, Object> = {
      'unionId': unionId,
      'openId': openId,
      'ip': ServerGateway.CLIENT_IP,
      'port': ServerGateway.CLIENT_PORT
    };
    const resp: ServerResp = await ServerGateway.task(78, payload, false, false, 15000);
    const outcome: AccountOutcome = new AccountOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('华为账号登录失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.token = ServerMapper.text(rec, 'token');
    outcome.userId = ServerMapper.num(rec, 'userId', 0);
    ServerGateway.token = outcome.token;
    return outcome;
  }

  /** auth.huawei-bind（77）：把当前登录账号与华为账号绑定（一个华为账号同一时间只能绑一个程诺账号） */
  static async huaweiBind(unionId: string, openId: string): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'unionId': unionId, 'openId': openId };
    return ServerGateway.messageTask(77, payload);
  }

  /** auth.huawei-state（79）：当前账号是否已绑定华为账号（含绑定时上报的 unionId） */
  static async huaweiState(): Promise<HuaweiStateOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(79, payload, true, false, 15000);
    const outcome: HuaweiStateOutcome = new HuaweiStateOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('华为账号绑定状态读取失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.bound = ServerMapper.flag(rec, 'huaweiBound');
    outcome.unionId = ServerMapper.text(rec, 'huaweiUnionId');
    return outcome;
  }

  /** auth.huawei-unbind（80）：解除当前账号的华为账号绑定（幂等；解绑后登录页华为一键登录不可用） */
  static async huaweiUnbind(): Promise<MessageOutcome> {
    const payload: Record<string, Object> = {};
    return ServerGateway.messageTask(80, payload);
  }

  /** ---------- 邮箱认证模块（serviceId 85/86/88：验证码走 AGC，账号会话走程诺服务器） ---------- */

  /** auth.email-register（85，AUTH_EXEMPT）：邮箱验证码注册——App 侧 AGC 校验验证码通过后调用，
   *  服务器自动建号（UIDxxxxx / 空密码 + 邮箱标识）并签发 token；成功后记录 token（同 loginInternal） */
  static async emailRegister(email: string): Promise<AccountOutcome> {
    const payload: Record<string, Object> = {
      'email': email,
      'ip': ServerGateway.CLIENT_IP,
      'port': ServerGateway.CLIENT_PORT
    };
    const resp: ServerResp = await ServerGateway.task(85, payload, false, false, 15000);
    const outcome: AccountOutcome = new AccountOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('注册失败，请重试');
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.token = ServerMapper.text(rec, 'token');
    outcome.userId = ServerMapper.num(rec, 'userId', 0);
    ServerGateway.token = outcome.token;
    return outcome;
  }

  /** auth.email-reset-password（86，AUTH_EXEMPT）：邮箱找回密码——App 侧 AGC 验证码校验通过后调用，
   *  服务器按邮箱把程诺账号密码重置为新密码（未注册邮箱 404 / 新密码格式不符 400） */
  static async emailResetPassword(email: string, newPassword: string): Promise<MessageOutcome> {
    const payload: Record<string, Object> = {
      'email': email,
      'newPassword': newPassword
    };
    const resp: ServerResp = await ServerGateway.task(86, payload, false, false, 15000);
    const outcome: MessageOutcome = new MessageOutcome();
    if (resp.code !== 0) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('重置失败，请重试');
      return outcome;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    outcome.ok = true;
    if (rec !== null) {
      outcome.message = ServerMapper.text(rec, 'message');
    }
    return outcome;
  }

  /** auth.email-state（95）：当前账号是否已绑定邮箱（含绑定邮箱地址；账号安全页邮箱行/设密门槛用） */
  static async emailState(): Promise<EmailStateOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(95, payload, true, false, 15000);
    const outcome: EmailStateOutcome = new EmailStateOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('邮箱绑定状态读取失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.userId = ServerMapper.num(rec, 'userId', 0);
    outcome.emailBound = ServerMapper.flag(rec, 'emailBound');
    outcome.email = ServerMapper.text(rec, 'email');
    outcome.hasPassword = ServerMapper.flag(rec, 'hasPassword');
    return outcome;
  }

  /** auth.email-bind（96）：把 AGC 验证码校验通过的新邮箱绑到当前账号（首次绑定/换绑共用；
   *  被其他账号占用 409）；绑定后该账号只能按邮箱登录 */
  static async emailBind(email: string): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'email': email };
    return ServerGateway.messageTask(96, payload);
  }

  /** auth.huawei-register（88，AUTH_EXEMPT）：华为账号注册（登录页 78 只查找的配对注册入口）——
   *  Account Kit 拿到 unionID/openID 后服务器自动建号并绑定（已绑定 409），签发 token；
   *  成功后记录 token（同 loginInternal） */
  static async huaweiRegister(unionId: string, openId: string): Promise<AccountOutcome> {
    const payload: Record<string, Object> = {
      'unionId': unionId,
      'openId': openId,
      'ip': ServerGateway.CLIENT_IP,
      'port': ServerGateway.CLIENT_PORT
    };
    const resp: ServerResp = await ServerGateway.task(88, payload, false, false, 15000);
    const outcome: AccountOutcome = new AccountOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('注册失败，请重试');
      return outcome;
    }
    outcome.ok = true;
    outcome.account = ServerMapper.text(rec, 'account');
    outcome.token = ServerMapper.text(rec, 'token');
    outcome.userId = ServerMapper.num(rec, 'userId', 0);
    ServerGateway.token = outcome.token;
    return outcome;
  }

  /** ---------- AI 成卡模块（serviceId 0/4/6/7/20/76） ---------- */

  /** ai.ask（0）：真实 DeepSeek 对话，读超时放宽到 90 秒。
   *  targetGroupId / targetCardIndex = 看板居中卡片组定位（0 = 最右「新卡片组」列，确定即新建组），
   *  FINALIZE 阶段自动落库按它落位。
   *  记日程默认随请求上送客户端本地天气（region + 一句话摘要），服务器注入 AI 提示词【天气】栏；
   *  对话中出现省市被服务器捕获后，捕获地区天气会覆盖该默认值直至卡片确定 */
  static async aiAsk(taskText: string, targetGroupId: number = 0, targetCardIndex: number = 0): Promise<AskOutcome> {
    const payload: Record<string, Object> = {
      'task': taskText,
      'targetGroupId': targetGroupId,
      'targetCardIndex': targetCardIndex
    };
    const weather: WeatherOutcome | null = ServerGateway.weatherSnapshot();
    if (weather !== null) {
      const region: string = weather.adm2.length > 0 ? weather.adm2 : weather.name;
      const text: string = WeatherTips.summaryOf(weather);
      if (region.length > 0 && text.length > 0) {
        const weatherPayload: Record<string, Object> = {
          'region': region,
          'text': text
        };
        payload['weather'] = weatherPayload;
      }
    }
    const resp: ServerResp = await ServerGateway.task(0, payload, true, false, 90000);
    if (resp.code !== 0) {
      const fail: AskOutcome = new AskOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('AI 调用失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: AskOutcome = new AskOutcome();
      fail.message = tr('AI 返回数据异常');
      return fail;
    }
    const outcome: AskOutcome = ServerMapper.toAskOutcome(result);
    outcome.ok = true;
    return outcome;
  }

  /** ai.shop（89）：卡片小铺按序取一张 AI 推荐卡（index = 第几张 1 起，服务端主题提示按 4 循环），
    *  exclude = 已推荐过的活动名清单（≤30 条，服务端拼进提示词避免重复）；无限追加流；
    *  读超时放宽到 90 秒；card 为 null 表示本次未取得有效推荐 */
  static async aiShop(index: number, exclude: string[] = []): Promise<ShopOutcome> {
    const payload: Record<string, Object> = { 'index': index, 'exclude': exclude };
    const resp: ServerResp = await ServerGateway.task(89, payload, true, false, 90000);
    if (resp.code !== 0) {
      const fail: ShopOutcome = new ShopOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('AI 推荐失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: ShopOutcome = new ShopOutcome();
      fail.message = tr('AI 返回数据异常');
      return fail;
    }
    const outcome: ShopOutcome = ServerMapper.toShopOutcome(result);
    if (outcome.card === null) {
      outcome.message = tr('AI 返回数据异常');
      return outcome;
    }
    outcome.ok = true;
    return outcome;
  }

  /** ai.status（4）：AI 配置 + 流程状态 + 当前工作卡 + 最近回复 */
  static async aiStatus(): Promise<StatusOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(4, payload, true, false, 15000);
    const outcome: StatusOutcome = new StatusOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('AI 状态查询失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.configured = ServerMapper.flag(rec, 'configured');
    outcome.lastReply = ServerMapper.text(rec, 'lastReply');
    outcome.working = ServerMapper.toWorkingCard(rec['workingCard'] ?? null);
    outcome.flow = ServerMapper.toFlow(rec['flowStatus'] ?? null);
    return outcome;
  }

  /** ai.reset（6）：一键取消，清空工作卡并重置确认状态 */
  static async aiReset(): Promise<FlowOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(6, payload, true, false, 15000);
    const outcome: FlowOutcome = new FlowOutcome();
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (resp.code !== 0 || rec === null) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('取消失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.working = ServerMapper.toWorkingCard(rec['workingCard'] ?? null);
    outcome.flow = ServerMapper.toFlow(rec['flowStatus'] ?? null);
    return outcome;
  }

  /** ai.complete（7）：确定——校验提醒时间与时间冲突后按看板居中组落库。
   *  groupId + cardIndex = 选取已入库卡确定（原位更新）；仅 groupId = 追加进该组；都为 0 = 新建同名组 */
  static async aiComplete(groupId: number = 0, cardIndex: number = 0): Promise<CompleteOutcome> {
    const payload: Record<string, Object> = {
      'groupId': groupId,
      'cardIndex': cardIndex
    };
    const resp: ServerResp = await ServerGateway.task(7, payload, true, false, 20000);
    if (resp.code !== 0) {
      const fail: CompleteOutcome = new CompleteOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('确定失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    const outcome: CompleteOutcome = new CompleteOutcome();
    if (rec === null) {
      outcome.message = tr('确定返回数据异常');
      return outcome;
    }
    outcome.ok = true;
    outcome.message = ServerMapper.text(rec, 'message');
    outcome.writtenCard = ServerMapper.toWrittenCard(rec['written'] ?? null);
    return outcome;
  }

  /** cards.pick（76）：把一张已入库卡片（组号 + 组内编号）整份载入「正在设置卡片」，
   *  载入后 AI 对话（0）与手动制作（51）都作用于该卡 */
  static async aiPick(groupId: number, cardIndex: number): Promise<PickOutcome> {
    const payload: Record<string, Object> = {
      'groupId': groupId,
      'cardIndex': cardIndex
    };
    const resp: ServerResp = await ServerGateway.task(76, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: PickOutcome = new PickOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('选取失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    const rec: Record<string, Object> | null = ServerMapper.toRecord(result);
    if (result === null || rec === null) {
      const fail: PickOutcome = new PickOutcome();
      fail.message = tr('选取返回数据异常');
      return fail;
    }
    const outcome: PickOutcome = ServerMapper.toPickOutcome(result);
    outcome.ok = true;
    outcome.message = ServerMapper.text(rec, 'message');
    return outcome;
  }

  /** ---------- 我的卡片库模块（serviceId 54/57，原 37/38 已按 PRO MAX 组模型重做） ---------- */

  /** groups.list（54）：我的卡片库 = 我创建的卡片组（公开+私人）+ 我加入的组，拍平成卡片条目；
   *  keyword 非空时在本地按标题/地点/参与人过滤（PRO MAX 的 54 不再支持服务器端过滤） */
  static async myLibraryList(keyword?: string): Promise<LibraryListOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(54, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: LibraryListOutcome = new LibraryListOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('卡片库拉取失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: LibraryListOutcome = new LibraryListOutcome();
      fail.message = tr('卡片库返回数据异常');
      return fail;
    }
    const outcome: LibraryListOutcome = ServerMapper.toLibraryList(result);
    outcome.ok = true;
    if (keyword !== undefined && keyword.trim().length > 0) {
      const kw: string = keyword.trim();
      const kept: LibraryEntryInfo[] = [];
      for (let i = 0; i < outcome.entries.length; i++) {
        const entry: LibraryEntryInfo = outcome.entries[i];
        const title: string = entry.card.event.length > 0 ? entry.card.event : entry.card.purpose;
        if (title.indexOf(kw) >= 0 || entry.card.location.indexOf(kw) >= 0 ||
          entry.card.participant.indexOf(kw) >= 0) {
          kept.push(entry);
        }
      }
      outcome.entries = kept;
    }
    return outcome;
  }

  /** ---------- 卡片操作模块（serviceId 15/57/67：退出、删除、延时） ---------- */

  /** cards.leave（15）：退出组内卡片（发起者不可退出） */
  static async cardsLeave(groupId: number, cardIndex: number): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'groupId': groupId, 'cardIndex': cardIndex };
    return ServerGateway.messageTask(15, payload);
  }

  /** cards.extend（67）：提交延时——创建者立即改期；被指定完成权限的成员生成延时申请交创建者审批 */
  static async cardsExtend(groupId: number, cardIndex: number, time: string): Promise<CardExtendOutcome> {
    const payload: Record<string, Object> = { 'groupId': groupId, 'cardIndex': cardIndex, 'time': time };
    const resp: ServerResp = await ServerGateway.task(67, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: CardExtendOutcome = new CardExtendOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('延时提交失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: CardExtendOutcome = new CardExtendOutcome();
      fail.message = tr('延时返回数据异常');
      return fail;
    }
    const outcome: CardExtendOutcome = ServerMapper.toCardExtend(result);
    outcome.ok = true;
    return outcome;
  }

  /** groups.remove-card（57）：删除我创建的组内一张卡片（未处理的加入申请一并清除；删空的组服务器会保留） */
  static async groupRemoveCard(groupId: number, cardIndex: number): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'groupId': groupId, 'cardIndex': cardIndex };
    return ServerGateway.messageTask(57, payload);
  }

  /** ---------- 卡片组管理模块（serviceId 51/53/55/56/62，PRO MAX 重做后新增） ---------- */

  /** cards.edit（51）：手动编辑当前工作卡文本字段（出现即写入，空串=清空，未提及=不变；写入后仍用 ai.complete 7 落库） */
  static async cardsEdit(fields: Record<string, Object>): Promise<FlowOutcome> {
    const payload: Record<string, Object> = { 'fields': fields };
    return ServerGateway.flowTask(51, payload);
  }

  /** groups.create（53）：手动创建空卡片组（public=公开库 / private=私人库；每人最多 20 个组） */
  static async groupsCreate(name: string, library: string): Promise<GroupCreatedOutcome> {
    const payload: Record<string, Object> = { 'name': name, 'library': library };
    const resp: ServerResp = await ServerGateway.task(53, payload, true, false, 15000);
    const outcome: GroupCreatedOutcome = new GroupCreatedOutcome();
    if (resp.code !== 0) {
      outcome.message = resp.message.length > 0 ? resp.message : tr('创建失败');
      return outcome;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      outcome.message = tr('创建返回数据异常');
      return outcome;
    }
    const created: GroupCreatedOutcome = ServerMapper.toGroupCreated(result);
    created.ok = true;
    created.message = trf('卡片组「{0}」已创建（#{1}）', created.groupName, created.groupId);
    return created;
  }

  /** groups.delete（55）：创建者删除整个卡片组（组内卡片与未处理申请一并清除） */
  static async groupsDelete(groupId: number): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'groupId': groupId };
    return ServerGateway.messageTask(55, payload);
  }

  /** groups.add-card（56）：创建者往组内添加一张卡片（event 必填；time/reminderTime 须绝对时间；每组最多 10 张） */
  static async groupsAddCard(groupId: number, fields: Record<string, Object>): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'groupId': groupId, 'fields': fields };
    return ServerGateway.messageTask(56, payload);
  }

  /** groups.complete-card（62）：客户端本地化后 = 服务器标记完成（仅发起者可完成）+ 后端 AI 顺带出稿明信片并长期落库
   *  + 出稿成功即把该卡从卡片组删除（归档为明信片，57）。AI 失败不影响完成（postcard 为 null）。
   *  请求耗时含 AI 出稿，读超时放宽到 30 秒 */
  static async groupsCompleteCard(groupId: number, cardIndex: number): Promise<CompleteCardOutcome> {
    const payload: Record<string, Object> = { 'groupId': groupId, 'cardIndex': cardIndex };
    const resp: ServerResp = await ServerGateway.task(62, payload, true, false, 30000);
    if (resp.code !== 0) {
      const fail: CompleteCardOutcome = new CompleteCardOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('完成失败');
      return fail;
    }
    return ServerMapper.toCompleteCard(ServerGateway.resultOf(resp));
  }

  /** 客户端明信片库（内置后端直读）：当前账号的全部明信片（完成卡片时由后端 AI 生成、
    *  客户端长期保存，新的在前）。原独立 REST 端点，现改走本地库函数 */
  static async postcardsList(): Promise<PostcardListOutcome> {
    const outcome: PostcardListOutcome = new PostcardListOutcome();
    const result: ApiResult = Backend.postcardsList(ServerGateway.token);
    hilog.info(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
      `<- local /api/postcards code=${result.code}`);
    if (result.code !== 0) {
      outcome.message = result.message.length > 0 ? result.message : tr('明信片库读取失败');
      return outcome;
    }
    return ServerMapper.toPostcardList(result.data);
  }

  /** 删除客户端明信片库中的一条（内置后端直删，仅限本账号自己的明信片） */
  static async postcardsDelete(id: number): Promise<MessageOutcome> {
    const outcome: MessageOutcome = new MessageOutcome();
    const result: ApiResult = Backend.postcardsDelete(ServerGateway.token, id);
    hilog.info(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
      `<- local /api/postcards/${id} code=${result.code}`);
    if (result.code !== 0) {
      outcome.message = result.message.length > 0 ? result.message : tr('明信片删除失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.message = tr('明信片已删除');
    return outcome;
  }

  /** postcards.pull（103）：拉取发给当前账号的参与者明信片 + 待清理群号（clear 墓碑）。
   *  服务器按账号短期中转（30 天/200 条上限）、拉取即删；客户端拉到后本地合并去重落库长期保存，
   *  clears 里的群号需同步清理本地群聊记录 */
  static async postcardsPull(): Promise<PostcardPullOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(103, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: PostcardPullOutcome = new PostcardPullOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('明信片拉取失败');
      return fail;
    }
    return ServerMapper.toPostcardPull(ServerGateway.resultOf(resp));
  }

  /** reports.week（74）：周报——客户端本地应答：服务器只算本周窗口命中的卡片数（快照进周报库），
   *  打卡（75）/ 完成（62）/ 延时（67）由客户端在事件发生时累加；返回本周窗口与本周四项计数 */
  static async weekReport(): Promise<WeekReportOutcome> {
    const payload: Record<string, Object> = { 'atMs': Date.now() };
    const resp: ServerResp = await ServerGateway.task(74, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: WeekReportOutcome = new WeekReportOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('周报读取失败');
      return fail;
    }
    return ServerMapper.toWeekReport(ServerGateway.resultOf(resp));
  }

  /** ---------- AI 工作卡扩展（serviceId 33/39） ---------- */

  /** cards.conflicts（33）：当前工作卡时间冲突查询（描述列表） */
  static async cardsConflicts(): Promise<ConflictsOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(33, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: ConflictsOutcome = new ConflictsOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('冲突查询失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: ConflictsOutcome = new ConflictsOutcome();
      fail.message = tr('冲突查询返回数据异常');
      return fail;
    }
    const outcome: ConflictsOutcome = ServerMapper.toConflicts(result);
    outcome.ok = true;
    return outcome;
  }

  /** conversations.list（39）：服务器保存的最近十条 AI 对话（已按旧 → 新排序） */
  static async conversationsList(): Promise<ConversationsOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(39, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: ConversationsOutcome = new ConversationsOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('对话记录拉取失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: ConversationsOutcome = new ConversationsOutcome();
      fail.message = tr('对话记录返回数据异常');
      return fail;
    }
    const outcome: ConversationsOutcome = ServerMapper.toConversations(result);
    outcome.ok = true;
    return outcome;
  }

  /** 清空本机 AI 对话记录（内置后端直清 conversations.txt，仅当前用户；「个人信息」管理页用） */
  static async clearConversations(): Promise<MessageOutcome> {
    const outcome: MessageOutcome = new MessageOutcome();
    const result: ApiResult = Backend.clearConversations(ServerGateway.token);
    hilog.info(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
      `<- local conversations-clear code=${result.code}`);
    if (result.code !== 0) {
      outcome.message = result.message.length > 0 ? result.message : tr('对话记录清除失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.message = tr('对话记录已清空');
    return outcome;
  }

  /** 清空本机周报库（内置后端直清 reports.txt，仅当前账号；下次周报 74 重新统计；「个人信息」管理页用） */
  static async clearWeekReport(): Promise<MessageOutcome> {
    const outcome: MessageOutcome = new MessageOutcome();
    const result: ApiResult = Backend.clearWeekReport(ServerGateway.token);
    hilog.info(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
      `<- local week-report-clear code=${result.code}`);
    if (result.code !== 0) {
      outcome.message = result.message.length > 0 ? result.message : tr('周报清除失败');
      return outcome;
    }
    outcome.ok = true;
    outcome.message = tr('周报数据已清除');
    return outcome;
  }

  /** ---------- 邮箱模块（serviceId 42-44，提醒到点自动投递的站内邮件） ---------- */

  /** mailbox.list（42）：我的邮件（新邮件在前，附未读数） */
  static async mailList(): Promise<MailListOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(42, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: MailListOutcome = new MailListOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('邮件列表拉取失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: MailListOutcome = new MailListOutcome();
      fail.message = tr('邮件列表返回数据异常');
      return fail;
    }
    const outcome: MailListOutcome = ServerMapper.toMailList(result);
    outcome.ok = true;
    return outcome;
  }

  /** mailbox.read（43）：标记邮件已读（id>0 单封；all=true 全部） */
  static async mailRead(id: number, all: boolean): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'id': id, 'all': all };
    return ServerGateway.messageTask(43, payload);
  }

  /** mailbox.remove（44）：删除邮件（id>0 单封；all=true 清空收件箱） */
  static async mailRemove(id: number, all: boolean): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'id': id, 'all': all };
    return ServerGateway.messageTask(44, payload);
  }

  /** ---------- 提醒模块（serviceId 40/41，无反向投递、客户端轮询拉取） ---------- */

  /** reminders.due（40）：拉取已到点且未送达过的提醒（拉取即送达、同一条只返回一次；服务器同步投递提醒邮件） */
  static async remindersDue(): Promise<RemindersOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(40, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: RemindersOutcome = new RemindersOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('提醒拉取失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: RemindersOutcome = new RemindersOutcome();
      fail.message = tr('提醒返回数据异常');
      return fail;
    }
    const outcome: RemindersOutcome = ServerMapper.toReminders(result);
    outcome.ok = true;
    return outcome;
  }

  /** reminders.upcoming（41）：未来 7 天即将到来的提醒预览（不写台账、不消耗） */
  static async remindersUpcoming(): Promise<RemindersOutcome> {
    const payload: Record<string, Object> = {};
    const resp: ServerResp = await ServerGateway.task(41, payload, true, false, 15000);
    if (resp.code !== 0) {
      const fail: RemindersOutcome = new RemindersOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('提醒预告拉取失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: RemindersOutcome = new RemindersOutcome();
      fail.message = tr('提醒预告返回数据异常');
      return fail;
    }
    const outcome: RemindersOutcome = ServerMapper.toReminders(result);
    outcome.ok = true;
    return outcome;
  }

  /** ---------- 个人空间模块（serviceId 90/91，服务器侧副本；客户端本地副本在 ProfileStore） ---------- */

  /** profile.get（90）：本账号的服务器侧副本（withAvatar=true 附带头像 base64，仅客户端副本为空时采纳服务器副本用） */
  static async getProfile(withAvatar: boolean): Promise<ProfileOutcome> {
    const payload: Record<string, Object> = { 'withAvatar': withAvatar };
    const resp: ServerResp = await ServerGateway.task(90, payload, true, false, 20000);
    if (resp.code !== 0) {
      const fail: ProfileOutcome = new ProfileOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('个人空间拉取失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: ProfileOutcome = new ProfileOutcome();
      fail.message = tr('个人空间返回数据异常');
      return fail;
    }
    const outcome: ProfileOutcome = ServerMapper.toProfile(result);
    outcome.ok = true;
    return outcome;
  }

  /** profile.update（91）：整份覆盖服务器侧副本（昵称即账号名，不再单独上送）。
   *  avatarOp：'keep' = 头像不动 / 'remove' = 恢复默认 / 'update' = 用 avatarBase64 覆盖（纯 base64，JPEG） */
  static async updateProfile(fields: Record<string, Object>, avatarOp: string, avatarBase64: string): Promise<MessageOutcome> {
    const payload: Record<string, Object> = {
      'gender': fields['gender'] ?? '',
      'birthday': fields['birthday'] ?? '',
      'signature': fields['signature'] ?? '',
      'province': fields['province'] ?? '',
      'city': fields['city'] ?? ''
    };
    if (avatarOp === 'update') {
      payload['avatarBase64'] = avatarBase64;
    } else if (avatarOp === 'remove') {
      payload['avatarBase64'] = '';
    }
    return ServerGateway.messageTask(91, payload);
  }

  /** ---------- 用户信息同步（serviceId 93，个性化服务开关驱动） ---------- */

  /** userinfo.sync（93）put：把个人空间五字段并入用户信息（AI 上下文「本人用户资料」），
   *  上送非空覆盖、上送为空清除；traits 等其余键保留。个性化服务开启时由个人空间保存 /
   *  通用设置开关调用 */
  static async syncUserInfoPut(fields: Record<string, Object>): Promise<MessageOutcome> {
    const profile: Record<string, Object> = {
      'gender': fields['gender'] ?? '',
      'birthday': fields['birthday'] ?? '',
      'signature': fields['signature'] ?? '',
      'province': fields['province'] ?? '',
      'city': fields['city'] ?? ''
    };
    const payload: Record<string, Object> = {
      'action': 'put',
      'profile': profile
    };
    return ServerGateway.messageTask(93, payload);
  }

  /** userinfo.sync（93）clear：清空用户信息（个性化服务关闭时调用；个人空间资料不受影响） */
  static async syncUserInfoClear(): Promise<MessageOutcome> {
    const payload: Record<string, Object> = { 'action': 'clear' };
    return ServerGateway.messageTask(93, payload);
  }

  /** ---------- 天气模块（serviceId 97，和风天气 8 产品聚合；内置后端拦截落库快照，每次新结果清空旧数据） ---------- */

  /** weather.fetch（97）：按定位拉取天气（lat/lon 传 NaN 时仅按城市名；快照由内置后端自动落库 weather.txt） */
  static async weatherFetch(lat: number, lon: number, city: string): Promise<WeatherOutcome> {
    const payload: Record<string, Object> = {};
    if (!Number.isNaN(lat) && !Number.isNaN(lon)) {
      payload['lat'] = lat;
      payload['lon'] = lon;
    }
    if (city.length > 0) {
      payload['city'] = city;
    }
    const resp: ServerResp = await ServerGateway.task(97, payload, true, false, 45000);
    if (resp.code !== 0) {
      const fail: WeatherOutcome = new WeatherOutcome();
      fail.message = resp.message.length > 0 ? resp.message : tr('天气拉取失败');
      return fail;
    }
    const result: Object | null = ServerGateway.resultOf(resp);
    if (result === null) {
      const fail: WeatherOutcome = new WeatherOutcome();
      fail.message = tr('天气返回数据异常');
      return fail;
    }
    const outcome: WeatherOutcome = ServerMapper.toWeather(result);
    outcome.ok = true;
    return outcome;
  }

  /** 最近一份天气快照（内置后端 weather.txt，只留最近一份；仅当前账号的快照，无则 null）。
   *  归属判定优先比 userId（账号名会因改名/邮箱登录变化，userId 稳定）；
   *  快照缺 userId（旧格式）时回退账号名比对 */
  static weatherSnapshot(): WeatherOutcome | null {
    const raw: Record<string, Object> | null = Backend.latestWeather();
    if (raw === null) {
      return null;
    }
    const snapshot: WeatherOutcome = ServerMapper.toWeather(raw);
    const uidObj: Object | undefined = raw['userId'];
    const snapUserId: number = typeof uidObj === 'number' ? uidObj : -1;
    if (snapUserId > 0 && ServerGateway.userId > 0) {
      if (snapUserId !== ServerGateway.userId) {
        hilog.warn(ServerGateway.LOG_DOMAIN, ServerGateway.LOG_TAG,
          'weather snapshot rejected: snapUid=%{public}d curUid=%{public}d', snapUserId, ServerGateway.userId);
        return null;
      }
      return snapshot;
    }
    if (snapshot.account.length > 0 && snapshot.account !== ServerGateway.account) {
      return null;
    }
    return snapshot;
  }
}
