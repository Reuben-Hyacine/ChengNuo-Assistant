import { ReminderInfo } from '../net/ServerModels';
import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';

/**
 * 到点提醒弹窗：明信片展开同款比例（82% 宽 × 380 高、radiusModal 圆角、明信片渐变底）
 * 内容为本次送达的到点提醒列表，底部「确定」按钮
 * 生命周期由 Main 持有：显示 3 秒后自动关闭，点击确定/遮罩立即关闭
 * 收件箱不受影响：服务器在送达提醒的同时自动投递提醒邮件（mailbox.list 42）
 */
@Component
export struct ReminderPopup {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop visible: boolean = false;
  @Prop reminders: ReminderInfo[] = [];
  /** 天气话术（Main 在弹窗展示时从天气快照计算；好天气/无数据为空串不展示） */
  @Prop weatherTip: string = '';
  onConfirm: () => void = () => {};

  /** 单条提醒标题：事件名优先，回退目的，再回退默认 */
  private titleOf(r: ReminderInfo): string {
    if (r.event.length > 0) {
      return r.event;
    }
    if (r.purpose.length > 0) {
      return r.purpose;
    }
    return tr('未命名日程');
  }

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.overlay_mask'))
          .onClick(() => {
            this.onConfirm();
          })

        Column({ space: 16 }) {
          Row() {
            Text(trf('日程提醒{0}', this.reminders.length > 1 ? trf('（{0} 条）', this.reminders.length) : ''))
              .fontSize(Theme.fontCaption)
              .fontColor(Color.White)
              .opacity(0.85)
            Blank()
            Text('⏰')
              .fontSize(30)
          }
          .width('100%')

          if (this.weatherTip.length > 0) {
            Text(`🌦️ ${this.weatherTip}`)
              .fontSize(Theme.fontBody)
              .fontColor(Color.White)
              .opacity(0.92)
              .width('100%')
          }

          Scroll() {
            Column({ space: 14 }) {
              ForEach(this.reminders, (r: ReminderInfo) => {
                Column({ space: 6 }) {
                  Text(`⏰ ${this.titleOf(r)}`)
                    .fontSize(18)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Color.White)
                  Text(`🕒 ${r.eventStart}`)
                    .fontSize(Theme.fontBody)
                    .fontColor(Color.White)
                    .opacity(0.92)
                  if (r.location.length > 0) {
                    Text(`📍 ${r.location}`)
                      .fontSize(Theme.fontBody)
                      .fontColor(Color.White)
                      .opacity(0.92)
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }, (r: ReminderInfo, idx: number) => `${r.groupId}-${r.cardIndex}-${r.remindAt}-${idx}`)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .width('100%')

          Row() {
            Column() {
              Text(tr('确定'))
                .fontSize(Theme.fontBody)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.brandDeep())
            }
            .layoutWeight(1)
            .height(42)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.White)
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.onConfirm();
            })
          }
          .width('100%')
        }
        .width('82%')
        .height(380)
        .padding(22)
        .borderRadius(Theme.radiusModal)
        .linearGradient({
          angle: 135,
          colors: [[Theme.brandTint(), 0.0], [Theme.brand(), 1.0]]
        })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })))
      }
      .width('100%')
      .height('100%')
      .transition(TransitionEffect.OPACITY)
    }
  }
}
