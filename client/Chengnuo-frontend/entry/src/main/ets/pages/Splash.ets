/**
 * 开屏动画页：每次冷启动都播放（杀后台重新打开会再次出现；从后台恢复不会重复播放）。
 * 布局：中央应用图标 + 大号品牌橙「程诺」（一开始就有），下一行黑色副标「让我们把想法变成现实」
 * 0.5 秒渐显；整体静止 0.5 秒后进入登录页（总时长约 1.15 秒）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { tr } from '../common/I18n';
import { Theme } from '../common/Theme';

@Entry
@Component
struct Splash {
  @StorageProp('appLang') appLang: string = 'zh';
  @State subtitleOpacity: number = 0;

  aboutToAppear(): void {
    hilog.info(0x0000, 'testTag', 'splash: aboutToAppear');
    // 静止 0.5 秒后结束，进入登录页（延迟 150ms + 渐显 0.5s + 静止 0.5s）
    setTimeout(() => {
      hilog.info(0x0000, 'testTag', 'splash: navigate to Index');
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
    }, 1150);
  }

  // 页面完成首帧上屏后才会走到这里；再延迟 150ms 确保渲染树就绪，
  // 否则（aboutToAppear/onAppear 阶段）animateTo 会瞬间应用终值、动画不播放
  onPageShow(): void {
    hilog.info(0x0000, 'testTag', 'splash: onPageShow');
    setTimeout(() => {
      hilog.info(0x0000, 'testTag', 'splash: fade start');
      this.getUIContext().animateTo({
        duration: 500,
        curve: Curve.EaseOut,
        onFinish: () => {
          hilog.info(0x0000, 'testTag', 'splash: fade done');
        }
      }, () => {
        this.subtitleOpacity = 1;
      });
    }, 150);
  }

  build(): void {
    Column({ space: 20 }) {
      Image($r('app.media.app_logo'))
        .width(96)
        .height(96)
        .borderRadius(28)
      Text(tr('程诺助手'))
        .fontSize(72)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.brand())
        .letterSpacing(6)
      Text(tr('让我们把想法变成现实'))
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.Black)
        .opacity(this.subtitleOpacity)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.start_window_background'))
  }
}
