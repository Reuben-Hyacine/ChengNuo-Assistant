import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { tr } from './I18n';
import { nearestRegion, RegionSelection } from './CityCoords';

/** 定位结果：ok=false 时 message 为已本地化的失败提示 */
export class LocationResult {
  readonly ok: boolean;
  readonly province: string;
  readonly city: string;
  readonly lat: number;
  readonly lng: number;
  readonly message: string;

  constructor(ok: boolean, province: string, city: string, lat: number, lng: number, message: string) {
    this.ok = ok;
    this.province = province;
    this.city = city;
    this.lat = lat;
    this.lng = lng;
    this.message = message;
  }
}

/**
 * 设备定位（日程页天气块「🎯 定位」用）：
 * 运行时权限弹窗（APPROXIMATELY_LOCATION + LOCATION，模糊/精确任一授权即可）→
 * 系统定位开关为关时应用内拉起半模态开关（requestGlobalSwitch，用户一键开启后继续，不跳设置）→
 * LocationKit 取当前坐标（失败时回退最后一次缓存坐标 getLastLocation）→
 * 城市坐标表离线反查最近城市（不依赖系统地理编码服务，模拟器/非华为设备同样可用）。
 * 取点始终尝试（个别设备开关状态不可靠、注入坐标的模拟器开关为关也可能取得到）：
 * 取不到时按开关状态提示「开启系统定位服务」或「重试」。
 */
export class LocationService {
  static async locate(context: common.Context): Promise<LocationResult> {
    const granted: boolean = await LocationService.ensurePermission(context);
    if (!granted) {
      hilog.warn(0xA00002, 'ChengNuoServer', 'locate: permission not granted (denied or request failed)');
      return LocationService.fail(tr('定位权限未授权'));
    }
    // 系统定位开关：为关时先在应用内拉起半模态让用户开启（不跳设置页）
    let enabled: boolean = true;
    try {
      enabled = geoLocationManager.isLocationEnabled();
    } catch (e) {
      enabled = true;
    }
    if (!enabled) {
      enabled = await LocationService.requestLocationSwitch(context);
    }
    hilog.info(0xA00002, 'ChengNuoServer', `locate: permission ok, location switch enabled=${enabled}`);
    let latitude: number = 0;
    let longitude: number = 0;
    try {
      const request: geoLocationManager.CurrentLocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
        // 开关检测仍为关时也继续尝试（个别设备开关状态不可靠），短超时快速失败
        timeoutMs: enabled ? 10000 : 5000
      };
      const location: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(request);
      latitude = location.latitude;
      longitude = location.longitude;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0xA00002, 'ChengNuoServer',
        `getCurrentLocation failed: code=${err.code} msg=${err.message} (switch enabled=${enabled})`);
      // 回退：最后一次缓存坐标（室内/无 GNSS 时 getCurrentLocation 超时，系统可能留有近期定位）
      const cached: geoLocationManager.Location | null = LocationService.lastKnownLocation();
      if (cached === null) {
        // 开关检测为关：提示去开启定位；开关为开但取点失败：提示重试
        return LocationService.fail(enabled ? tr('定位失败，请重试') : tr('请开启系统定位服务'));
      }
      latitude = cached.latitude;
      longitude = cached.longitude;
    }
    hilog.info(0xA00002, 'ChengNuoServer', `located: lat=${latitude} lng=${longitude}`);
    const region: RegionSelection | null = nearestRegion(latitude, longitude);
    if (region === null) {
      return LocationService.fail(tr('定位失败，请重试'));
    }
    return new LocationResult(true, region.province, region.city, latitude, longitude, '');
  }

  /** 应用内拉起系统定位开关半模态（requestGlobalSwitch）：结束后开关为开返回 true */
  private static async requestLocationSwitch(context: common.Context): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const on: boolean = await atManager.requestGlobalSwitch(context, abilityAccessCtrl.SwitchType.LOCATION);
      hilog.info(0xA00002, 'ChengNuoServer', `requestGlobalSwitch result=${on}`);
      if (on) {
        return true;
      }
      // 弹窗被关闭（未开启或部分设备不支持返回 false）：再确认一次实际开关状态
      try {
        return geoLocationManager.isLocationEnabled();
      } catch (e) {
        return false;
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0xA00002, 'ChengNuoServer',
        `requestGlobalSwitch failed: code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  /** 最后一次缓存坐标：取不到或数值无效时返回 null */
  private static lastKnownLocation(): geoLocationManager.Location | null {
    try {
      const last: geoLocationManager.Location = geoLocationManager.getLastLocation();
      const valid: boolean = Math.abs(last.latitude) <= 90 && Math.abs(last.longitude) <= 180 &&
        (last.latitude !== 0 || last.longitude !== 0);
      if (valid) {
        return last;
      }
      return null;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0xA00002, 'ChengNuoServer', `getLastLocation failed: code=${err.code} msg=${err.message}`);
      return null;
    }
  }

  /** 运行时权限：模糊/精确任一授权即通过（天气城市级定位足够） */
  private static async ensurePermission(context: common.Context): Promise<boolean> {
    try {
      const perms: Array<Permissions> = [
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION'
      ];
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(context, perms);
      const results: number[] = result.authResults;
      hilog.info(0xA00002, 'ChengNuoServer', `locate: permission authResults=[${results.join(',')}]`);
      for (let i = 0; i < results.length; i++) {
        if (results[i] === 0) {
          return true;
        }
      }
      return false;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0xA00002, 'ChengNuoServer',
        `locate: requestPermissionsFromUser failed: code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  private static fail(message: string): LocationResult {
    return new LocationResult(false, '', '', 0, 0, message);
  }
}
