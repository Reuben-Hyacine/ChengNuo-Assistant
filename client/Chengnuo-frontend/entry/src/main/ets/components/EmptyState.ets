import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';
import { GlyphIcon } from './GlyphIcon';

/**
 * 通用空状态占位
 */
@Component
export struct EmptyState {
  @StorageProp('appLang') appLang: string = 'zh';
  emoji: string = '🌱';
  title: string = tr('这里空空如也');
  subtitle: string = '';

  build() {
    Column({ space: 8 }) {
      GlyphIcon({ emoji: this.emoji, iconSize: 72 })
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .padding({ top: 28, bottom: 28 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
