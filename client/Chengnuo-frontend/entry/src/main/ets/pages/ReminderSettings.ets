import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';
import { NotifKind, notificationPrefStore } from '../store/NotificationPrefStore';

/**
 * 提醒设置（通用设置 → 提醒设置进入）：应用外横幅通知开关。
 * - 第一行「通知」总开关：关闭后所有横幅通知停发（分项设置记录保留）；
 *   重新开启后各分项按记录恢复
 * - 总开关开启时两类分项可独立控制：系统通知 / 提醒通知
 * - 默认开启通知且全部开启；应用内的弹窗、角标与消息列表不受任何开关影响
 */
@Entry
@Component
struct ReminderSettingsPage {
  @State masterOn: boolean = true;
  /** 分项开关记录（顺序同 KINDS：系统/提醒） */
  @State kinds: boolean[] = [true, true];
  private static readonly KINDS: string[] = [
    NotifKind.SYSTEM, NotifKind.REMINDER
  ];

  aboutToAppear(): void {
    this.masterOn = notificationPrefStore.isMasterOn();
    const kinds: boolean[] = [];
    for (let i = 0; i < ReminderSettingsPage.KINDS.length; i++) {
      kinds.push(notificationPrefStore.isKindStoredOn(ReminderSettingsPage.KINDS[i]));
    }
    this.kinds = kinds;
  }

  private handleMaster(isOn: boolean): void {
    if (isOn === this.masterOn) {
      return;
    }
    notificationPrefStore.setMaster(isOn);
    this.masterOn = isOn;
  }

  private handleKind(index: number, isOn: boolean): void {
    if (isOn === this.kinds[index]) {
      return;
    }
    notificationPrefStore.setKind(ReminderSettingsPage.KINDS[index], isOn);
    const kinds: boolean[] = this.kinds.slice(0);
    kinds[index] = isOn;
    this.kinds = kinds;
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(24)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Text(tr('提醒设置'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 16 }) {
          Column() {
            Row({ space: 12 }) {
              Text('🔔')
                .fontSize(18)
              Column({ space: 2 }) {
                Text(tr('通知'))
                  .fontSize(Theme.fontBody)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text(tr('关闭后不接收任何横幅通知；分项设置保留，重新开启后恢复'))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_secondary'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.masterOn })
                .selectedColor(Theme.brand())
                .switchPointColor(Color.White)
                .onChange((isOn: boolean) => {
                  this.handleMaster(isOn);
                })
            }
            .width('100%')
            .padding(16)
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Column() {
            this.switchRow(0, '📢', tr('系统通知'), tr('系统邮件与应用公告'))
            this.rowDivider()
            this.switchRow(1, '⏰', tr('提醒通知'), tr('日程到点提醒'))
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Column({ space: 10 }) {
            Text(tr('仅控制应用外横幅通知（通知中心/锁屏/横幅）'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(tr('应用内的弹窗、角标与消息列表不受开关影响，始终照常展示'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(20)
            Divider()
              .color($r('app.color.divider'))
              .margin({ top: 2, bottom: 2 })
            Text(tr('默认开启通知，两类通知全部开启'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(20)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
        }
        .width('100%')
        .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 12 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /** 分项开关行：总开关关闭时禁用置灰（记录保留，重新开启后恢复显示） */
  @Builder
  private switchRow(index: number, icon: string, label: string, caption: string) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(18)
      Column({ space: 2 }) {
        Text(label)
          .fontSize(Theme.fontBody)
          .fontColor($r('app.color.text_primary'))
        Text(caption)
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.kinds[index] })
        .selectedColor(Theme.brand())
        .switchPointColor(Color.White)
        .opacity(this.masterOn ? 1 : 0.45)
        .enabled(this.masterOn)
        .onChange((isOn: boolean) => {
          this.handleKind(index, isOn);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .opacity(this.masterOn ? 1 : 0.6)
  }

  @Builder
  private rowDivider() {
    Column()
      .width('100%')
      .height(0.5)
      .backgroundColor($r('app.color.divider'))
  }
}
