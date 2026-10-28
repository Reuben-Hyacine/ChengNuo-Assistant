import { Activity } from '../model/Types';
import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';

/**
 * 发现页活动卡：渐变/组封面封面区（组有封面（105 上传 / 112 缓存）时替换渐变顶部封面）
 * + 标签/发起人/时间地点/容量进度 + 加入日程
 * 点「加入日程」先翻到背面「确定」等待确认：点卡片=翻回并触发 onJoin（宿主页执行加入/申请），
 * 点卡片外部=遮罩广播翻回取消（AppStorage 广播驱动，与日程/好友页同款翻转动画）。
 * 未翻面时点卡片空白区触发 onBodyTap（宿主页打开卡片详情页）。
 */
@Component
export struct ActivityCard {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop activity: Activity = new Activity();
  /** 是否展示容量进度行（发现页公开卡 true / 卡片小铺单人推荐卡 false） */
  @Prop showCapacity: boolean = true;
  /** 背面点了卡片本体（翻回动画结束）：宿主页执行加入/申请 */
  onJoin: (activity: Activity) => void = () => {};
  /** 封面右上角「⋯」点开卡片菜单（宿主页弹出菜单/举报弹窗）；仅公开卡（slot- 前缀）展示 */
  onMenuTap: (activity: Activity) => void = () => {};
  /** 未翻面时点卡片空白区（宿主页打开卡片详情页） */
  onBodyTap: (activity: Activity) => void = () => {};
  /** 翻面状态通知：back=true 回传卡片页面坐标（遮罩命中判定用），back=false 表示已翻回 */
  onFlipChange: (actId: string, back: boolean, x: number, y: number, w: number, h: number) => void = () => {};
  /** 遮罩点击广播（AppStorage，绕开 ForEach 同 key 不刷新的限制；独立 token 避免与其他页面互扰） */
  @StorageProp('discoverFlipCancelToken') @Watch('onCancelBroadcast') cancelBroadcast: number = 0;
  @StorageProp('discoverFlipConfirmToken') @Watch('onConfirmBroadcast') confirmBroadcast: number = 0;

  @State flipAngle: number = 0;
  @State showBack: boolean = false;
  /** 正面实测高度（onAreaChange 维护）：背面按此高度撑起，翻面时卡片尺寸不跳变 */
  @State bodyH: number = 0;
  private sequencing: boolean = false;
  /** 页面坐标缓存（onAreaChange 维护），翻到背面时回传给宿主页 */
  private rectX: number = 0;
  private rectY: number = 0;

  /** 「加入日程」按钮：翻到背面等待确认（再点卡片 / 遮罩命中 → 翻回并执行加入；点外部翻回取消） */
  private handleJoinTap(): void {
    if (this.sequencing || this.showBack) {
      return;
    }
    this.flipToBack();
  }

  private handleTap(): void {
    if (this.sequencing) {
      return;
    }
    if (this.showBack) {
      this.flipBack(true);
      return;
    }
    this.onBodyTap(this.activity);
  }

  /** 遮罩广播：点卡片外部 → 翻回且不执行加入 */
  private onCancelBroadcast(): void {
    if (this.showBack && !this.sequencing) {
      this.flipBack(false);
    }
  }

  /** 遮罩广播：点卡片本体 → 翻回并执行加入 */
  private onConfirmBroadcast(): void {
    if (this.showBack && !this.sequencing) {
      this.flipBack(true);
    }
  }

  private notifyFlip(back: boolean): void {
    if (back) {
      this.onFlipChange(this.activity.id, true, this.rectX, this.rectY, this.bodyH > 0 ? this.bodyH : 0, this.bodyH);
    } else {
      this.onFlipChange(this.activity.id, false, 0, 0, 0, 0);
    }
  }

  private flipToBack(): void {
    this.sequencing = true;
    this.getUIContext().animateTo({
      duration: 180,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.showBack = true;
        this.notifyFlip(true);
        this.getUIContext().animateTo({
          duration: 180,
          curve: Curve.EaseOut,
          onFinish: () => {
            this.sequencing = false;
          }
        }, () => {
          this.flipAngle = 180;
        });
      }
    }, () => {
      this.flipAngle = 90;
    });
  }

  /** 翻回正面：confirm=true 时动画结束触发 onJoin */
  private flipBack(confirm: boolean): void {
    this.sequencing = true;
    this.getUIContext().animateTo({
      duration: 180,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.showBack = false;
        this.notifyFlip(false);
        this.getUIContext().animateTo({
          duration: 180,
          curve: Curve.EaseOut,
          onFinish: () => {
            this.sequencing = false;
            if (confirm) {
              this.onJoin(this.activity);
            }
          }
        }, () => {
          this.flipAngle = 0;
        });
      }
    }, () => {
      this.flipAngle = 90;
    });
  }

  build() {
    Stack() {
      if (!this.showBack) {
        this.frontFace()
      } else {
        this.backFace()
      }
    }
    .width('100%')
    .borderRadius(Theme.radiusCard)
    .rotate({ x: 0, y: 1, z: 0, angle: this.flipAngle, centerX: '50%', centerY: '50%' })
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.92, y: 0.92 })))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.rectX = Number(newValue.globalPosition.x ?? 0);
      this.rectY = Number(newValue.globalPosition.y ?? 0);
      this.bodyH = Number(newValue.height);
    })
    .onClick(() => {
      this.handleTap();
    })
  }

  @Builder
  frontFace() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack({ alignContent: Alignment.BottomStart }) {
          if (this.activity.groupCoverUri.length > 0) {
            Image(this.activity.groupCoverUri)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
          } else {
            Column() {
              Text(this.activity.emoji)
                .fontSize(34)
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }

          if (this.activity.conflictFree) {
            Text(tr('✓ 与日程不冲突'))
              .fontSize(Theme.fontTag)
              .fontColor($r('app.color.success'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor($r('app.color.success_soft'))
              .borderRadius(Theme.radiusTag)
              .margin(8)
          }
        }
        .width('100%')
        .height('100%')

        if (this.activity.id.indexOf('slot-') === 0) {
          Column() {
            Text('⋯')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
          }
          .width(28)
          .height(28)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor('#33000000')
          .borderRadius(14)
          .margin(8)
          .onClick(() => {
            this.onMenuTap(this.activity);
          })
        }
      }
      .width('100%')
      .height(86)
      .linearGradient({
        angle: 135,
        colors: [[Theme.postcardGradientFrom(this.activity.colorIndex), 0.0],
          [Theme.postcardGradientTo(this.activity.colorIndex), 1.0]]
      })
      .borderRadius({ topLeft: Theme.radiusCard, topRight: Theme.radiusCard, bottomLeft: 0, bottomRight: 0 })

      Column({ space: 8 }) {
        Row({ space: 6 }) {
          Text(this.activity.tag)
            .fontSize(Theme.fontTag)
            .fontColor(Theme.brandDeep())
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Theme.brandSoft())
            .borderRadius(Theme.radiusTag)
          if (this.activity.hostIsFriend) {
            Text(tr('✨ 好友'))
              .fontSize(Theme.fontTag)
              .fontColor(Theme.brandDeep())
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(Theme.brandSoft())
              .borderRadius(Theme.radiusTag)
          }
        }
        .width('100%')

        Text(this.activity.title)
          .fontSize(Theme.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(trf('发起人 · {0}', this.activity.hostName))
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(`⏰ ${this.activity.timeText} · ${this.activity.place}`)
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.activity.groupIntro.length > 0) {
          Text(`📝 ${this.activity.groupIntro}`)
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        if (this.showCapacity) {
          Row({ space: 8 }) {
            Column() {
              Column()
                .width(`${Math.min(100, Math.floor(this.activity.currentCount / Math.max(1, this.activity.capacity) * 100))}%`)
                .height('100%')
                .backgroundColor(Theme.brand())
                .borderRadius(3)
            }
            .layoutWeight(1)
            .height(5)
            .backgroundColor($r('app.color.divider'))
            .borderRadius(3)

            Text(trf('{0}/{1} 人', this.activity.currentCount, this.activity.capacity))
              .fontSize(Theme.fontTag)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }

        if (this.activity.ended) {
          Column() {
            Text(tr('📁 已结束'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height(34)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(Theme.radiusBtn)
        } else if (this.activity.joined) {
          Column() {
            Text(tr('✓ 已加入日程'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.success'))
          }
          .width('100%')
          .height(34)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.success_soft'))
          .borderRadius(Theme.radiusBtn)
        } else if (this.activity.groupJoinApplied) {
          Column() {
            Text(tr('⏳ 入组审核中 · 待创建者同意'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height(34)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(Theme.radiusBtn)
        } else if (this.activity.pending) {
          Column() {
            Text(tr('⏳ 申请中 · 待创建者确认'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .height(34)
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(Theme.radiusBtn)
        } else if (this.activity.groupJoinMode === 'review'
          && this.activity.groupRole !== 'owner' && this.activity.groupRole !== 'member') {
          Column() {
            Text(tr('🛡 申请入组'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
          }
          .width('100%')
          .height(34)
          .justifyContent(FlexAlign.Center)
          .linearGradient({
            angle: 135,
            colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
          })
          .borderRadius(Theme.radiusBtn)
          .onClick(() => {
            this.handleJoinTap();
          })
        } else {
          Column() {
            Text(tr('加入日程'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
          }
          .width('100%')
          .height(34)
          .justifyContent(FlexAlign.Center)
          .linearGradient({
            angle: 135,
            colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
          })
          .borderRadius(Theme.radiusBtn)
          .onClick(() => {
            this.handleJoinTap();
          })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Theme.radiusCard)
  }

  @Builder
  backFace() {
    Column() {
      Text(tr('确定'))
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
    }
    .width('100%')
    .height(this.bodyH > 0 ? this.bodyH : 200)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .linearGradient({
      angle: 135,
      colors: [[Theme.postcardGradientFrom(this.activity.colorIndex), 0.0],
        [Theme.postcardGradientTo(this.activity.colorIndex), 1.0]]
    })
    .borderRadius(Theme.radiusCard)
    .rotate({ x: 0, y: 1, z: 0, angle: 180, centerX: '50%', centerY: '50%' })
  }
}
