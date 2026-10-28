import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 横幅通知类别（提醒设置页六分项）：横幅发布与轮询按类别检查开关
 */
export class NotifKind {
  static readonly SYSTEM: string = 'system';
  static readonly REMINDER: string = 'reminder';
  static readonly FRIEND: string = 'friend';
  static readonly JOIN: string = 'join';
  static readonly EXIT: string = 'exit';
  static readonly CHAT: string = 'chat';
}

/**
 * 横幅通知开关持久化（提醒设置页）：总开关 + 六类分项开关，preferences 落盘。
 * - 默认全部开启（缺省值 1）
 * - 总开关关闭：所有横幅停发，分项设置记录保留；重新开启后按记录恢复
 * - 分项开关仅总开关开启时可独立控制（UI 层约束；本类只负责存取）
 * 运行时镜像到 AppStorage（notifMaster / notifSystem / …），横幅发布直接读镜像（未初始化视为开启）。
 */
export class NotificationPrefStore {
  private static readonly PREF_NAME: string = 'app_notification';
  private static readonly KEY_MASTER: string = 'master';
  private static readonly KINDS: string[] = [
    NotifKind.SYSTEM, NotifKind.REMINDER, NotifKind.FRIEND,
    NotifKind.JOIN, NotifKind.EXIT, NotifKind.CHAT
  ];
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文：读盘并镜像 AppStorage */
  init(context: common.UIAbilityContext): void {
    this.context = context;
    AppStorage.setOrCreate('notifMaster', this.readBool(NotificationPrefStore.KEY_MASTER));
    for (let i = 0; i < NotificationPrefStore.KINDS.length; i++) {
      AppStorage.setOrCreate(this.mirrorKeyOf(NotificationPrefStore.KINDS[i]),
        this.readBool(NotificationPrefStore.KINDS[i]));
    }
  }

  private mirrorKeyOf(kind: string): string {
    return 'notif' + kind.charAt(0).toUpperCase() + kind.substring(1);
  }

  /** 读开关（默认开启；读取失败视为开启，横幅兜底可用） */
  private readBool(key: string): boolean {
    if (this.context === null) {
      return true;
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: NotificationPrefStore.PREF_NAME });
      const value: preferences.ValueType = store.getSync(key, 1);
      return typeof value === 'number' && value === 1;
    } catch (e) {
      return true;
    }
  }

  /** 写开关：AppStorage 镜像 + preferences 落盘（失败不阻塞，内存态仍生效） */
  private writeBool(key: string, value: boolean): void {
    if (this.context === null) {
      return;
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: NotificationPrefStore.PREF_NAME });
      store.putSync(key, value ? 1 : 0);
      store.flush();
    } catch (e) {
    }
  }

  /** 总开关（镜像缺失视为开启） */
  isMasterOn(): boolean {
    return AppStorage.get<boolean>('notifMaster') ?? true;
  }

  /** 分项开关记录值（不受总开关门控，供设置页回显） */
  isKindStoredOn(kind: string): boolean {
    return AppStorage.get<boolean>(this.mirrorKeyOf(kind)) ?? true;
  }

  /** 该类横幅当前是否允许发布：总开关 && 分项开关 */
  isKindOn(kind: string): boolean {
    return this.isMasterOn() && this.isKindStoredOn(kind);
  }

  setMaster(on: boolean): void {
    AppStorage.setOrCreate('notifMaster', on);
    this.writeBool(NotificationPrefStore.KEY_MASTER, on);
  }

  setKind(kind: string, on: boolean): void {
    AppStorage.setOrCreate(this.mirrorKeyOf(kind), on);
    this.writeBool(kind, on);
  }
}

export const notificationPrefStore: NotificationPrefStore = new NotificationPrefStore();
