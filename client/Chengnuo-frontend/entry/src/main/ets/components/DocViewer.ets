import { DocBlock } from '../common/LegalDocs';
import { Theme } from '../common/Theme';

/**
 * 法务文档正文渲染器（隐私声明 / 用户协议共用）：
 * 按块类型渲染标题、日期行、章节、小节、段落、加粗段、列表、第三方卡片与落款
 */
@Component
export struct DocViewer {
  blocks: DocBlock[] = [];

  build() {
    Scroll() {
      Column() {
        ForEach(this.blocks, (b: DocBlock) => {
          if (b.kind === 'title') {
            Text(b.text)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 6 })
          } else if (b.kind === 'meta') {
            Text(b.text)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ bottom: 20 })
          } else if (b.kind === 'h2') {
            Text(b.text)
              .fontSize(Theme.fontCardTitle)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .margin({ top: 22, bottom: 2 })
          } else if (b.kind === 'h3') {
            Text(b.text)
              .fontSize(Theme.fontBody)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .margin({ top: 14 })
          } else if (b.kind === 'strong') {
            Text(b.text)
              .fontSize(Theme.fontBody)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(26)
              .width('100%')
              .textAlign(TextAlign.JUSTIFY)
              .margin({ top: 8 })
          } else if (b.kind === 'li') {
            Text(b.text)
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(26)
              .width('100%')
              .textAlign(TextAlign.JUSTIFY)
              .margin({ top: 6 })
              .padding({ left: 12 })
          } else if (b.kind === 'card') {
            Text(b.text)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(24)
              .width('100%')
              .textAlign(TextAlign.JUSTIFY)
              .margin({ top: 12 })
              .padding(Theme.spaceMd)
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusInput)
          } else if (b.kind === 'right') {
            Text(b.text)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.End)
              .margin({ top: 24 })
          } else {
            Text(b.text)
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(26)
              .width('100%')
              .textAlign(TextAlign.JUSTIFY)
              .margin({ top: 8 })
          }
        }, (b: DocBlock, index: number) => `${index}_${b.kind}`)
      }
      .width('100%')
      .padding({
        left: Theme.spaceLg,
        right: Theme.spaceLg,
        top: Theme.spaceSm,
        bottom: Theme.spaceXxl
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }
}
