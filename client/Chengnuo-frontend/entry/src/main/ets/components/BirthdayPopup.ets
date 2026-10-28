import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';

/**
 * 生日特别祝福弹窗：生日当天进主页/回前台弹出（每天一次，BirthdayStore 去重）
 * 明信片展开同款比例（82% 宽、radiusModal 圆角），生日粉渐变底
 * 文案带用户昵称；点「收下祝福」或遮罩关闭
 */
@Component
export struct BirthdayPopup {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('userName') userName: string = '';
  @Prop visible: boolean = false;
  onClose: () => void = () => {};

  build() {
    if (this.visible) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.overlay_mask'))
          .onClick(() => {
            this.onClose();
          })

        Column({ space: 14 }) {
          Text('🎂')
            .fontSize(56)

          Text(tr('生日快乐！'))
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)

          Text(trf('{0}，今天是你的生日！程诺把这一天悄悄圈了出来，愿你新的一岁里心愿慢慢兑现，被世界温柔以待 🎉', this.userName))
            .fontSize(Theme.fontBody)
            .fontColor(Color.White)
            .opacity(0.95)
            .textAlign(TextAlign.Center)
            .lineHeight(24)

          Text('🎈 🎁 ✨')
            .fontSize(16)

          Row() {
            Column() {
              Text(tr('收下祝福'))
                .fontSize(Theme.fontBody)
                .fontWeight(FontWeight.Bold)
                .fontColor('#EC4899')
            }
            .layoutWeight(1)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.White)
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.onClose();
            })
          }
          .width('100%')
        }
        .width('82%')
        .padding(26)
        .borderRadius(Theme.radiusModal)
        .linearGradient({
          angle: 135,
          colors: [['#FFB3D1', 0.0], ['#EC4899', 1.0]]
        })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })))
      }
      .width('100%')
      .height('100%')
      .transition(TransitionEffect.OPACITY)
    }
  }
}
