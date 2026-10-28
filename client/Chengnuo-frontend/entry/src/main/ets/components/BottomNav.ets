import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';

/**
 * 底部五入口导航：日程 / 宠物 / 中央+ / 发现 / 我的
 */
@Component
export struct BottomNav {
  @Prop current: number = 0;
  onTab: (index: number) => void = () => {};
  onCreate: () => void = () => {};

  build() {
    Row() {
      this.tabItem(0, $r('app.media.icon_calendar'), tr('日程'))
      this.tabItem(1, $r('app.media.penguin_original'), tr('宠物'))
      this.createButton()
      this.tabItem(2, $r('app.media.icon_explore'), tr('发现'))
      this.tabItem(3, $r('app.media.icon_my_profile'), tr('我的'))
    }
    .width('100%')
    .height(60)
    .backgroundColor($r('app.color.nav_bg'))
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  tabItem(index: number, icon: Resource, label: string) {
    Column({ space: 2 }) {
      Image(icon)
        .width(36)
        .height(36)
        .objectFit(ImageFit.Contain)
        .scale(index === this.current ? { x: 1.15, y: 1.15 } : { x: 1, y: 1 })
        .animation({ duration: 200, curve: Curve.Smooth })
      Text(label)
        .fontSize(Theme.fontTag)
        .fontWeight(index === this.current ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(index === this.current ? Theme.brand() : $r('app.color.text_tertiary'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.onTab(index);
    })
  }

  @Builder
  createButton() {
    Column() {
      Stack() {
        Column()
          .width(48)
          .height(48)
          .linearGradient({
            angle: 135,
            colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
          })
          .borderRadius(24)
          .shadow({ radius: 10, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
        Text('＋')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      }
      .translate({ y: -8 })
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.onCreate();
    })
  }
}
