import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';

/**
 * 版本页（关于程诺入口）：居中展示应用名与当前版本号
 */
@Entry
@Component
struct VersionInfoPage {
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
        Text(tr('版本'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Column({ space: 10 }) {
        Text('🍊')
          .fontSize(52)
        Text(tr('程诺助手'))
          .fontSize(Theme.fontCardTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('v1.0.0')
          .fontSize(Theme.fontBody)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
