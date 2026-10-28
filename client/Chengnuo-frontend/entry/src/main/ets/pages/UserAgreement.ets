import { tr } from '../common/I18n';
import { DocViewer } from '../components/DocViewer';
import { AGREEMENT_DOC } from '../common/LegalDocs';

/**
 * 用户协议页（关于程诺入口）：展示《程诺助手用户服务协议》全文
 * 正文与官网（ourchengnuo.cn/agreement.html）及提审版本逐字一致
 */
@Entry
@Component
struct UserAgreementPage {
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
        Text(tr('用户协议'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      DocViewer({ blocks: AGREEMENT_DOC })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
