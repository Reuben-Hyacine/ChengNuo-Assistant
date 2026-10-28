import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';

/**
 * 关于程诺：隐私政策 / 用户协议 / 版本 / 关于我们 四入口，各自进入独立页面
 */
@Entry
@Component
struct AboutChengNuoPage {
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
        Text(tr('关于程诺'))
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
            this.entryRow('🔒', tr('隐私政策'), 'pages/PrivacyPolicy', '')

            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor($r('app.color.divider'))

            this.entryRow('📜', tr('用户协议'), 'pages/UserAgreement', '')

            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor($r('app.color.divider'))

            this.entryRow('📱', tr('版本'), 'pages/VersionInfo', 'v1.0.0')

            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor($r('app.color.divider'))

            this.entryRow('🍊', tr('关于我们'), 'pages/AboutUs', '')
          }
          .width('100%')
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

  /** 功能入口行：图标 + 标题 + 右侧值 + 箭头（与设置列表行样式一致） */
  @Builder
  private entryRow(icon: string, label: string, url: string, value: string) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(18)
      Text(label)
        .fontSize(Theme.fontBody)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (value.length > 0) {
        Text(value)
          .fontSize(Theme.fontBody)
          .fontColor($r('app.color.text_tertiary'))
      }
      Text('›')
        .fontSize(18)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 15, bottom: 15 })
    .onClick(() => {
      this.getUIContext().getRouter().pushUrl({ url: url });
    })
  }
}
