import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 界面语言持久化（'zh' 中文 / 'en' 英文），默认中文。
 * EntryAbility 启动时读入 AppStorage('appLang')，通用设置切换时写回。
 */
export class LangStore {
  private static readonly PREF_NAME: string = 'app_lang';
  private static readonly KEY: string = 'lang';
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文（preferences 所在） */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** 读取语言偏好（未设置或读取失败一律回退中文） */
  load(): string {
    if (this.context === null) {
      return 'zh';
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: LangStore.PREF_NAME });
      const value: preferences.ValueType = store.getSync(LangStore.KEY, 'zh');
      return value === 'en' ? 'en' : 'zh';
    } catch (e) {
      return 'zh';
    }
  }

  /** 保存语言偏好（失败不阻塞切换，本次会话仍生效） */
  save(lang: string): void {
    if (this.context === null) {
      return;
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: LangStore.PREF_NAME });
      store.putSync(LangStore.KEY, lang);
      store.flush();
    } catch (e) {
    }
  }
}

export const langStore: LangStore = new LangStore();
