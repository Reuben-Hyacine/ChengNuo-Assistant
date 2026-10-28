import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 生日祝福当天已送标记（preferences 持久化，按账号记录最近一次送出祝福的日期）：
 * 生日当天多次进主页/回前台，特别祝福弹窗只弹一次。
 * 生日本体存个人空间记录（ProfileRecord.birthday，Backend 本地 + 服务器 91 各一份），
 * 本 store 只负责「今天祝福过了吗」的去重标记。
 */
export class BirthdayStore {
  private static readonly PREF_NAME: string = 'birthday_greet';
  private static readonly KEY_PREFIX: string = 'greeted-';
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文（preferences 所在） */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 该账号最近一次收到生日祝福的日期（'YYYY-MM-DD'，从未祝福/读取失败返回 ''） */
  greetedOn(account: string): string {
    if (this.context === null || account.length === 0) {
      return '';
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: BirthdayStore.PREF_NAME });
      const value: preferences.ValueType = store.getSync(BirthdayStore.KEY_PREFIX + account, '');
      return typeof value === 'string' ? value : '';
    } catch (e) {
      return '';
    }
  }

  /** 记录该账号已在 iso 这天收到生日祝福（落盘失败不阻塞弹窗，下次启动会再弹一次） */
  markGreeted(account: string, iso: string): void {
    if (this.context === null || account.length === 0) {
      return;
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: BirthdayStore.PREF_NAME });
      store.putSync(BirthdayStore.KEY_PREFIX + account, iso);
      store.flush();
    } catch (e) {
    }
  }
}

export const birthdayStore: BirthdayStore = new BirthdayStore();

/** 生日是否落在 dateIso 这天：每年同月同日重复生效（2/29 生日仅闰年命中） */
export function isBirthdayDay(birthdayIso: string, dateIso: string): boolean {
  if (birthdayIso.length !== 10 || dateIso.length !== 10) {
    return false;
  }
  return birthdayIso.substring(5, 10) === dateIso.substring(5, 10);
}
