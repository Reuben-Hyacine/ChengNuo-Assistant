/**
 * 品牌贴纸图标：命中映射的 emoji 以白底圆角贴纸图渲染（🤝 协作握手 / 📅 日历 / 🔍 搜索 / 🔔 通知），
 * 其余 emoji 原样文字渲染；用于数据驱动的卡片符号、空态占位等场景
 */
@Component
export struct GlyphIcon {
  @Prop emoji: string = '';
  iconSize: number = 24;

  build() {
    if (this.emoji === '🤝') {
      Image($r('app.media.icon_cooperation'))
        .width(this.iconSize)
        .height(this.iconSize)
    } else if (this.emoji === '📅') {
      Image($r('app.media.icon_calendar'))
        .width(this.iconSize)
        .height(this.iconSize)
    } else if (this.emoji === '🔍') {
      Image($r('app.media.icon_search'))
        .width(this.iconSize)
        .height(this.iconSize)
    } else if (this.emoji === '🔔') {
      Image($r('app.media.icon_notice'))
        .width(this.iconSize)
        .height(this.iconSize)
    } else {
      Text(this.emoji)
        .fontSize(this.iconSize)
        .maxLines(1)
    }
  }
}
