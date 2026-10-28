import { CardStatus, TaskCard } from '../model/Types';
import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';
import { GlyphIcon } from './GlyphIcon';

/**
 * 核心卡片组件：日程(暖)/任务(冷)/活动(亮) 三态配色
 * interactive=true 且卡片已设置时，点击翻转露出背面"确定"，再点击翻回并触发 onSequenceDone（打卡完成）。
 * deleteMode=true（已入库卡删除模式）：正面上角为「删除」按钮，点按钮翻面，点卡片本体不翻面；
 * 背面再点（或遮罩确认广播）翻回并触发 onSequenceDone（宿主页执行删除）。
 * armable=true 的卡片监听外部翻面广播（AppStorage flipArmToken 自增 + flipArmTargetId，如日程页完成/删除按钮）：
 * 目标 id 匹配才翻到背面等待确认，确认/取消流程同上（绕开 V1 ForEach 同 key 不刷新、@Prop 参数更新收不到的限制）。
 * 背面停留期间宿主页展示全屏遮罩：点卡片=翻回并确定，点卡片外部=翻回并取消（AppStorage 广播驱动）。
 */
@Component
export struct Card {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop card: TaskCard = new TaskCard();
  @Prop interactive: boolean = false;
  @Prop cardHeight: number = 150;
  /** 已设置入库卡片：正面上角展示「已设置」标签替代图标 */
  @Prop showSettledTag: boolean = false;
  /** 删除模式：正面上角「删除」按钮替代标签；正面点卡片本体不翻面，翻面与确认流程不变 */
  @Prop deleteMode: boolean = false;
  /** 外部翻面广播开关：true 时监听 flipArmToken 广播（日程页当日列表开启，其余使用点关闭防同 id 卡片跨处误翻） */
  @Prop armable: boolean = false;
  onCardTap: (card: TaskCard) => void = () => {};
  onSequenceDone: (card: TaskCard) => void = () => {};
  /** 翻面状态通知：back=true 回传卡片页面坐标（遮罩命中判定用），back=false 表示已翻回 */
  onFlipChange: (cardId: string, back: boolean, x: number, y: number, w: number, h: number) => void = () => {};
  /** 外部翻面广播（flipArmToken 自增，如日程页完成/删除按钮）：目标 id 匹配且本卡片允许才翻到背面等待确认 */
  @StorageProp('flipArmToken') @Watch('onExternalFlip') armBroadcast: number = 0;
  /** 遮罩点击广播（AppStorage，绕开 V1 ForEach 同 key 不刷新的限制） */
  @StorageProp('flipCancelToken') @Watch('onCancelBroadcast') cancelBroadcast: number = 0;
  @StorageProp('flipConfirmToken') @Watch('onConfirmBroadcast') confirmBroadcast: number = 0;

  @State flipAngle: number = 0;
  @State showBack: boolean = false;
  private sequencing: boolean = false;
  /** 页面坐标缓存（onAreaChange 维护），翻到背面时回传给宿主页 */
  private rectX: number = 0;
  private rectY: number = 0;
  private rectW: number = 0;
  private rectH: number = 0;

  aboutToAppear(): void {
    if (this.card.flipToken > 0) {
      this.playFlipOnly();
    }
  }

  /** 自动庆祝翻转：全程占用 sequencing，广播命令与点击都不打断它 */
  private playFlipOnly(): void {
    this.sequencing = true;
    this.getUIContext().animateTo({
      duration: 180,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.showBack = true;
        this.getUIContext().animateTo({
          duration: 180,
          curve: Curve.EaseOut,
          onFinish: () => {
            setTimeout(() => {
              this.getUIContext().animateTo({
                duration: 180,
                curve: Curve.EaseIn,
                onFinish: () => {
                  this.showBack = false;
                  this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut, onFinish: () => {
                    this.sequencing = false;
                  } }, () => {
                    this.flipAngle = 0;
                  });
                }
              }, () => {
                this.flipAngle = 90;
              });
            }, 600);
          }
        }, () => {
          this.flipAngle = 180;
        });
      }
    }, () => {
      this.flipAngle = 90;
    });
  }

  private handleTap(): void {
    // 背面：点卡片本体 = 翻回并确定（触发 onSequenceDone），与翻面触发方式无关
    if (this.showBack && !this.sequencing) {
      this.flipBack(true);
      return;
    }
    if (this.deleteMode && !this.showBack) {
      this.onCardTap(this.card);
      return;
    }
    if (!this.interactive || this.card.status !== CardStatus.Set || this.sequencing) {
      this.onCardTap(this.card);
      return;
    }
    this.flipToBack();
  }

  /** 外部触发广播（flipArmToken 自增，如日程页完成/删除按钮）：目标 id 匹配且允许广播才翻到背面等待确认 */
  private onExternalFlip(): void {
    if (!this.armable || this.armBroadcast <= 0) {
      return;
    }
    const targetId: string = AppStorage.get<string>('flipArmTargetId') ?? '';
    if (targetId === this.card.id && !this.showBack && !this.sequencing) {
      this.flipToBack();
    }
  }

  /** 正面「删除」按钮：翻到背面等待确认（再点卡片 / 遮罩命中 → 翻回并执行删除；点外部翻回取消） */
  private handleDeleteTap(): void {
    if (this.sequencing || this.showBack) {
      return;
    }
    this.flipToBack();
  }

  /** 遮罩广播：点卡片外部 → 翻回且不执行确定 */
  onCancelBroadcast(): void {
    if (this.showBack && !this.sequencing) {
      this.flipBack(false);
    }
  }

  /** 遮罩广播：点卡片本体 → 翻回并执行确定 */
  onConfirmBroadcast(): void {
    if (this.showBack && !this.sequencing) {
      this.flipBack(true);
    }
  }

  private notifyFlip(back: boolean): void {
    if (back) {
      this.onFlipChange(this.card.id, true, this.rectX, this.rectY, this.rectW, this.rectH);
    } else {
      this.onFlipChange(this.card.id, false, 0, 0, 0, 0);
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

  /** 翻回正面：confirm=true 时动画结束触发 onSequenceDone */
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
              this.onSequenceDone(this.card);
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
    .height(this.cardHeight)
    .borderRadius(Theme.radiusCard)
    .rotate({ x: 0, y: 1, z: 0, angle: this.flipAngle, centerX: '50%', centerY: '50%' })
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.92, y: 0.92 })))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.rectX = Number(newValue.globalPosition.x ?? 0);
      this.rectY = Number(newValue.globalPosition.y ?? 0);
      this.rectW = Number(newValue.width);
      this.rectH = Number(newValue.height);
    })
    .onClick(() => {
      this.handleTap();
    })
  }

  @Builder
  frontFace() {
    Column() {
      Row() {
        Text(Theme.kindLabel(this.card.kind))
          .fontSize(Theme.fontTag)
          .fontColor(Color.White)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(Theme.kindAccent(this.card.kind))
          .borderRadius(Theme.radiusTag)
        if (this.card.status === CardStatus.Done) {
          Text(tr('✓ 已完成'))
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.success'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.success_soft'))
            .borderRadius(Theme.radiusTag)
            .margin({ left: 8 })
        }
        Blank()
        if (this.deleteMode) {
          Text(tr('删除'))
            .fontSize(Theme.fontTag)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor($r('app.color.error'))
            .borderRadius(Theme.radiusTag)
            .onClick(() => {
              this.handleDeleteTap();
            })
        } else if (this.showSettledTag) {
          Text(tr('已设置'))
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.success'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.success_soft'))
            .borderRadius(Theme.radiusTag)
        } else {
          GlyphIcon({ emoji: this.card.symbol, iconSize: 40 })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14 })

      Column({ space: 6 }) {
        Text(this.card.title)
          .fontSize(Theme.fontCardTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 12 }) {
          Text(`⏰ ${this.card.timeText}`)
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
          if (this.card.place.length > 0) {
            Text(`📍 ${this.card.place}`)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 10 })

      if (this.card.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.card.tags, (tag: string) => {
            Text(`#${tag}`)
              .fontSize(Theme.fontTag)
              .fontColor(Theme.kindAccent(this.card.kind))
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(Theme.radiusTag)
              .margin({ right: 6, bottom: 4 })
          }, (tag: string) => tag)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 6 })
      }

      Blank()

      Column({ space: 6 }) {
        if (this.card.isRepeat) {
          Row({ space: 8 }) {
            Column() {
              Column()
                .width(`${this.card.progress}%`)
                .height('100%')
                .backgroundColor(Theme.kindAccent(this.card.kind))
                .borderRadius(3)
            }
            .layoutWeight(1)
            .height(6)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(3)
            Text(`${this.card.progress}%`)
              .fontSize(Theme.fontTag)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }
        if (this.card.status === CardStatus.Empty) {
          Text(tr('✏️ 待设置 — 在下方对话里告诉 AI'))
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.text_tertiary'))
        } else if (this.card.note.length > 0) {
          Text(this.card.note)
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.card.confirmText.length > 0) {
          Text(this.card.confirmText)
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 8, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.kindBg(this.card.kind))
    .borderRadius(Theme.radiusCard)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  backFace() {
    Column() {
      Text(this.deleteMode ? tr('删除') : tr('确定'))
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.deleteMode ? $r('app.color.error') : Theme.kindDeep(this.card.kind))
    .borderRadius(Theme.radiusCard)
    .rotate({ x: 0, y: 1, z: 0, angle: 180, centerX: '50%', centerY: '50%' })
  }
}
