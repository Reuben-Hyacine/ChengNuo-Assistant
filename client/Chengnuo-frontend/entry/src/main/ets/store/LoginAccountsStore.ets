import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 最近登录账号表（preferences 持久化，登录页邮箱框下拉展示）：
 * - 手输账号密码登录成功即记录：登录标识（邮箱或账号名）+ 密码；同一标识重复登录置顶并更新密码，
 *   新的在前，最多保留 5 条；空密码（华为一键登录/跳过设密）不记录
 * - 密码只落本表与登录请求，界面永不展示（下拉仅显示登录标识）
 * - 「✕」仅把记录从本表移除（下次不再出现在下拉），不涉及服务器侧注销/删号
 */
export class SavedLogin {
  account: string = '';
  password: string = '';

  static of(account: string, password: string): SavedLogin {
    const rec: SavedLogin = new SavedLogin();
    rec.account = account;
    rec.password = password;
    return rec;
  }
}

export class LoginAccountsStore {
  private static readonly PREF_NAME: string = 'login_accounts';
  private static readonly KEY_COUNT: string = 'count';
  private static readonly KEY_ACC_PREFIX: string = 'acc_';
  private static readonly KEY_PASS_PREFIX: string = 'pass_';
  private static readonly MAX_COUNT: number = 5;
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文（preferences 所在） */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 读取最近登录列表（新的在前）；未初始化/读取失败返回空表 */
  list(): SavedLogin[] {
    const store: preferences.Preferences | null = this.open();
    if (store === null) {
      return [];
    }
    try {
      const countValue: preferences.ValueType = store.getSync(LoginAccountsStore.KEY_COUNT, 0);
      if (typeof countValue !== 'number') {
        return [];
      }
      const count: number = countValue;
      const result: SavedLogin[] = [];
      for (let i = 0; i < count; i++) {
        const acc: preferences.ValueType = store.getSync(LoginAccountsStore.KEY_ACC_PREFIX + i, '');
        const pass: preferences.ValueType = store.getSync(LoginAccountsStore.KEY_PASS_PREFIX + i, '');
        if (typeof acc === 'string' && typeof pass === 'string' && acc.length > 0) {
          result.push(SavedLogin.of(acc, pass));
        }
      }
      return result;
    } catch (e) {
      return [];
    }
  }

  /** 登录成功后记录（置顶去重；账号或密码为空不记录，失败不阻塞登录） */
  record(account: string, password: string): void {
    if (account.length === 0 || password.length === 0) {
      return;
    }
    const store: preferences.Preferences | null = this.open();
    if (store === null) {
      return;
    }
    const current: SavedLogin[] = this.list();
    const kept: SavedLogin[] = [];
    for (let i = 0; i < current.length; i++) {
      if (current[i].account !== account) {
        kept.push(current[i]);
      }
    }
    const merged: SavedLogin[] = [SavedLogin.of(account, password)];
    for (let i = 0; i < kept.length && merged.length < LoginAccountsStore.MAX_COUNT; i++) {
      merged.push(kept[i]);
    }
    this.write(store, merged);
  }

  /** 「✕」移除：仅从本表删记录（不涉及注销）；失败静默 */
  remove(account: string): void {
    const store: preferences.Preferences | null = this.open();
    if (store === null) {
      return;
    }
    const current: SavedLogin[] = this.list();
    const kept: SavedLogin[] = [];
    for (let i = 0; i < current.length; i++) {
      if (current[i].account !== account) {
        kept.push(current[i]);
      }
    }
    this.write(store, kept);
  }

  private open(): preferences.Preferences | null {
    if (this.context === null) {
      return null;
    }
    try {
      return preferences.getPreferencesSync(this.context, { name: LoginAccountsStore.PREF_NAME });
    } catch (e) {
      return null;
    }
  }

  /** 全量覆写（先写条目再清尾部残留键，count 收尾；失败静默） */
  private write(store: preferences.Preferences, items: SavedLogin[]): void {
    try {
      for (let i = 0; i < items.length; i++) {
        store.putSync(LoginAccountsStore.KEY_ACC_PREFIX + i, items[i].account);
        store.putSync(LoginAccountsStore.KEY_PASS_PREFIX + i, items[i].password);
      }
      for (let i = items.length; i < LoginAccountsStore.MAX_COUNT; i++) {
        store.deleteSync(LoginAccountsStore.KEY_ACC_PREFIX + i);
        store.deleteSync(LoginAccountsStore.KEY_PASS_PREFIX + i);
      }
      store.putSync(LoginAccountsStore.KEY_COUNT, items.length);
      store.flush();
    } catch (e) {
    }
  }
}

export const loginAccountsStore: LoginAccountsStore = new LoginAccountsStore();
