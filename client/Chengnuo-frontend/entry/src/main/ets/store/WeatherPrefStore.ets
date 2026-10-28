import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 天气城市偏好（日程页天气块）：preferences（app_weather）落盘 +
 * AppStorage 镜像（weatherProvince / weatherCity），默认北京市 市辖区。
 * 手动选地区与自动定位都走 setRegion 统一落盘。
 */
export class WeatherPrefStore {
  private static readonly PREF_NAME: string = 'app_weather';
  private static readonly KEY_PROVINCE: string = 'province';
  private static readonly KEY_CITY: string = 'city';
  static readonly DEFAULT_PROVINCE: string = '北京市';
  static readonly DEFAULT_CITY: string = '市辖区';
  private context: common.UIAbilityContext | null = null;

  /** EntryAbility 启动时注入上下文：读盘并镜像 AppStorage（未落盘时用默认城市） */
  init(context: common.UIAbilityContext): void {
    this.context = context;
    AppStorage.setOrCreate('weatherProvince', this.province());
    AppStorage.setOrCreate('weatherCity', this.city());
  }

  province(): string {
    const value: string = this.readString(WeatherPrefStore.KEY_PROVINCE);
    return value.length > 0 ? value : WeatherPrefStore.DEFAULT_PROVINCE;
  }

  city(): string {
    const value: string = this.readString(WeatherPrefStore.KEY_CITY);
    return value.length > 0 ? value : WeatherPrefStore.DEFAULT_CITY;
  }

  setRegion(province: string, city: string): void {
    AppStorage.setOrCreate('weatherProvince', province);
    AppStorage.setOrCreate('weatherCity', city);
    if (this.context === null) {
      return;
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: WeatherPrefStore.PREF_NAME });
      store.putSync(WeatherPrefStore.KEY_PROVINCE, province);
      store.putSync(WeatherPrefStore.KEY_CITY, city);
      store.flush();
    } catch (e) {
    }
  }

  private readString(key: string): string {
    if (this.context === null) {
      return '';
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(this.context, { name: WeatherPrefStore.PREF_NAME });
      const value: preferences.ValueType = store.getSync(key, '');
      return typeof value === 'string' ? value : '';
    } catch (e) {
      return '';
    }
  }
}

export const weatherPrefStore: WeatherPrefStore = new WeatherPrefStore();
