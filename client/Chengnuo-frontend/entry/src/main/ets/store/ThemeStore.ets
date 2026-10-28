import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 主题色持久化（'#RRGGBB' 十六进制，默认 #FF7A59 珊瑚橙）。
 * EntryAbility 启动时读入 AppStorage('themeColor')，通用设置「个性化 → 主题色」切换时写回。
 */
export class ThemeStore {
  private static readonly PREF_NAME: string = 'app_theme';
  private static readonly KEY: string = 'themeColor';
  static readonly DEFAULT: string = '#FF7A59';
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文（preferences 所在） */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 读取主题色（非法值/读取失败一律回退默认珊瑚橙） */
  load(): string {
    if (this.context === null) {
      return ThemeStore.DEFAULT;
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: ThemeStore.PREF_NAME });
      const value: preferences.ValueType = store.getSync(ThemeStore.KEY, ThemeStore.DEFAULT);
      return typeof value === 'string' && ThemeStore.isValidHex(value) ? value : ThemeStore.DEFAULT;
    } catch (e) {
      return ThemeStore.DEFAULT;
    }
  }

  /** 保存主题色（非法值不落盘，本次会话仍生效） */
  save(hex: string): void {
    if (this.context === null || !ThemeStore.isValidHex(hex)) {
      return;
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: ThemeStore.PREF_NAME });
      store.putSync(ThemeStore.KEY, hex);
      store.flush();
    } catch (e) {
    }
  }

  /** '#RRGGBB' 校验：井号 + 6 位十六进制 */
  private static isValidHex(v: string): boolean {
    if (v.length !== 7 || v[0] !== '#') {
      return false;
    }
    for (let i: number = 1; i < 7; i++) {
      const c: string = v[i];
      const ok: boolean = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
      if (!ok) {
        return false;
      }
    }
    return true;
  }
}

export const themeStore: ThemeStore = new ThemeStore();
