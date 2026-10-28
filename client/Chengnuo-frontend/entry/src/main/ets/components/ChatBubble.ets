import { ChatMsg } from '../model/Types';
import { Theme } from '../common/Theme';

/**
 * AI 对话气泡：AI 左（brand_soft 底）/ 用户右（brand 渐变），气泡下方快捷 chips
 */
@Component
export struct ChatBubble {
  @Prop msg: ChatMsg = new ChatMsg();
  onChipTap: (chip: string) => void = () => {};

  build() {
    Column({ space: 8 }) {
      if (this.msg.fromAI) {
        Row() {
          Column() {
            // GB 45438-2025 文本内容显式标识：文字形式「AI生成」（人工智能要素 + 生成合成要素），位于文本起始位置
            Text('AI生成')
              .fontSize(Theme.fontTag)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.brandDeep())
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(Theme.radiusTag)
              .backgroundColor(Color.White)
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 6 })
            Text(this.msg.text)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_primary'))
              .lineHeight(20)
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor(Theme.brandSoft())
          .borderRadius({ topLeft: 4, topRight: 16, bottomLeft: 16, bottomRight: 16 })
          .constraintSize({ maxWidth: '78%' })

          Blank()
        }
        .width('100%')
      } else {
        Row() {
          Blank()
          Column() {
            Text(this.msg.text)
              .fontSize(Theme.fontCaption)
              .fontColor(Color.White)
              .lineHeight(20)
          }
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .linearGradient({
            angle: 135,
            colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
          })
          .borderRadius({ topLeft: 16, topRight: 4, bottomLeft: 16, bottomRight: 16 })
          .constraintSize({ maxWidth: '78%' })
        }
        .width('100%')
      }

      if (this.msg.chips.length > 0) {
        Row({ space: 8 }) {
          ForEach(this.msg.chips, (chip: string) => {
            Text(chip)
              .fontSize(Theme.fontCaption)
              .fontColor(Theme.brandDeep())
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(Theme.radiusTag)
              .border({ width: 1, color: Theme.brand() })
              .onClick(() => {
                this.onChipTap(chip);
              })
          }, (chip: string) => chip)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(this.msg.fromAI ? HorizontalAlign.Start : HorizontalAlign.End)
  }
}
