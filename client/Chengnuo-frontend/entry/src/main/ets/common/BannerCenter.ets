import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationPrefStore } from '../store/NotificationPrefStore';

/**
 * 横幅通知发布中心（应用外系统通知：通知中心/锁屏/横幅）：
 * - 发布前检查提醒设置开关：总开关 && 分项开关都开启才发布；关闭时静默跳过
 * - 应用内的弹窗、角标与消息列表不经此类，不受开关影响
 * - SERVICE_INFORMATION 渠道（横幅/锁屏随系统与用户开关展示），挂 wantAgent：
 *   from=reminderBanner 定位日程页 / chatBanner 定位好友页 / notifBanner 仅回应用
 */
export class BannerCenter {
  private static seq: number = 0;

  /** 该类横幅当前是否允许发布（总开关 && 分项开关） */
  static isOn(kind: string): boolean {
    return notificationPrefStore.isKindOn(kind);
  }

  /** 发布一条横幅：kind 开关关闭直接跳过；title/text 应用外通知正文，extra 为附加小字（可空） */
  static async publish(kind: string, title: string, text: string, from: string, extra: string = ''): Promise<void> {
    if (!BannerCenter.isOn(kind)) {
      hilog.info(0x0000, 'testTag', 'banner skipped (switch off): %{public}s', kind);
      return;
    }
    BannerCenter.seq = (BannerCenter.seq + 1) % 1000;
    const id: number = Date.now() * 1000 + BannerCenter.seq;
    let request: notificationManager.NotificationRequest;
    if (extra.length > 0) {
      request = {
        id: id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: extra
          }
        },
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION
      };
    } else {
      request = {
        id: id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text
          }
        },
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION
      };
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          deviceId: '',
          bundleName: 'com.chengnuo.app',
          abilityName: 'EntryAbility',
          action: '',
          entities: [],
          uri: '',
          parameters: {
            'from': from
          }
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      request.wantAgent = agent;
    } catch (e) {
      hilog.warn(0x0000, 'testTag', 'banner wantAgent build failed: %{public}s', JSON.stringify(e));
    }
    notificationManager.publish(request).then(() => {
      hilog.info(0x0000, 'testTag', 'banner published: %{public}s', kind);
    }).catch((err: BusinessError) => {
      hilog.info(0x0000, 'testTag', 'banner publish failed: %{public}d %{public}s', err.code, err.message);
    });
  }
}
