import { ServerGateway } from '../net/ServerGateway';
import { tr } from '../common/I18n';

/**
 * 全局共享存储：
 * - AppStorage 保存跨页基本状态（收件箱未读数、用户名、明信片戳、服务器登录会话）
 * - appStore 单例保存运行期可变集合（初始为空，页面数据一律来自后端 client → server）
 */
export class AppStore {
  joinedActivityIds: string[] = [];
  doneCardIds: string[] = [];
  /** 重复卡打卡记录：键格式 `${cardId}|${isoDate}`（当日完成，不触发碎卡动画/明信片） */
  checkinKeys: string[] = [];
  /** 后端（client :4000 → server :3000）已登录可用 */
  serverOnline: boolean = false;

  initAppStorage(): void {
    AppStorage.setOrCreate('inboxUnread', 0);
    // userName 已有值（登录时写入的账号名）时不覆盖：Main 每次进入主框架都会调用本方法
    if (!AppStorage.has('userName')) {
      AppStorage.setOrCreate('userName', tr('程诺用户'));
    }
    AppStorage.setOrCreate('postcardStamp', 0);
    AppStorage.setOrCreate('weekReportStamp', 0);
    AppStorage.setOrCreate('flipCancelToken', 0);
    AppStorage.setOrCreate('flipConfirmToken', 0);
    AppStorage.setOrCreate('discoverFlipCancelToken', 0);
    AppStorage.setOrCreate('discoverFlipConfirmToken', 0);
    AppStorage.setOrCreate('friendFlipCancelToken', 0);
    AppStorage.setOrCreate('friendFlipConfirmToken', 0);
    AppStorage.setOrCreate('friendKickCancelToken', 0);
    AppStorage.setOrCreate('friendKickConfirmToken', 0);
    AppStorage.setOrCreate('friendCollabCollapseToken', 0);
    AppStorage.setOrCreate('scheduleRefreshToken', 0);
    AppStorage.setOrCreate('friendsRefreshToken', 0);
    AppStorage.setOrCreate('chatWithAccount', '');
    AppStorage.setOrCreate('chatWithUserId', 0);
  }

  /** 登录成功后保存服务器会话（凭据留存供 token 失效自动重登） */
  saveSession(token: string, userId: number, account: string, password: string): void {
    ServerGateway.setSession(token, account, password);
    AppStorage.setOrCreate('serverToken', token);
    AppStorage.setOrCreate('serverUserId', userId);
    AppStorage.setOrCreate('serverAccount', account);
    AppStorage.setOrCreate('serverPassword', password);
    this.serverOnline = true;
    this.setUserName(account);
  }

  /** 服务器不可达：标记离线，页面按需降级 */
  markServerOffline(): void {
    this.serverOnline = false;
  }

  /** 退出登录 / 注销账号：清空服务器会话，回到未登录态 */
  clearSession(): void {
    ServerGateway.setSession('', '', '');
    AppStorage.setOrCreate('serverToken', '');
    AppStorage.setOrCreate('serverUserId', 0);
    AppStorage.setOrCreate('serverAccount', '');
    AppStorage.setOrCreate('serverPassword', '');
    this.serverOnline = false;
    this.setUserName(tr('程诺用户'));
  }

  /** 同一进程内回到登录页时恢复会话（凭据在，token 失效由网关自动重登） */
  restoreSession(): void {
    const token: string = AppStorage.get<string>('serverToken') ?? '';
    const account: string = AppStorage.get<string>('serverAccount') ?? '';
    const password: string = AppStorage.get<string>('serverPassword') ?? '';
    if (account.length > 0) {
      ServerGateway.setSession(token, account, password);
      this.serverOnline = true;
      this.setUserName(account);
    }
  }

  /** 当前登录账号（服务器账号名，同时作为昵称展示） */
  getAccount(): string {
    return AppStorage.get<string>('serverAccount') ?? '';
  }

  /** 当前登录密码（注销账号时需再次校验） */
  getPassword(): string {
    return AppStorage.get<string>('serverPassword') ?? '';
  }

  getUserId(): number {
    return AppStorage.get<number>('serverUserId') ?? 0;
  }

  markAllInboxRead(): void {
    AppStorage.setOrCreate('inboxUnread', 0);
  }

  setUnread(count: number): void {
    AppStorage.setOrCreate('inboxUnread', count);
  }

  bumpUnread(): void {
    const current: number = AppStorage.get<number>('inboxUnread') ?? 0;
    AppStorage.setOrCreate('inboxUnread', current + 1);
  }

  getUserName(): string {
    return AppStorage.get<string>('userName') ?? tr('程诺用户');
  }

  setUserName(name: string): void {
    AppStorage.setOrCreate('userName', name);
  }

  addJoinedActivity(id: string): void {
    if (this.joinedActivityIds.indexOf(id) < 0) {
      this.joinedActivityIds.push(id);
    }
  }

  addDoneCard(id: string): void {
    if (this.doneCardIds.indexOf(id) < 0) {
      this.doneCardIds.push(id);
    }
  }

  addCheckin(key: string): void {
    if (this.checkinKeys.indexOf(key) < 0) {
      this.checkinKeys.push(key);
    }
  }
}

export const appStore: AppStore = new AppStore();
