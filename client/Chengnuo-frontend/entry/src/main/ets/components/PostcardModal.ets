import { Postcard, TaskCard } from '../model/Types';
import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';
import { appStore } from '../store/AppStore';
import { groupChatStore } from '../store/GroupChatStore';
import { GroupChatMessageInfo } from '../net/ServerModels';
import { GlyphIcon } from './GlyphIcon';

/**
 * 明信片弹层：全屏遮罩 + 渐变明信片（日期戳 / AI 祝福 / 存入日历）
 * mode='save' 显示「存入日历 / 先收着」；mode='view' 显示「好的，收下」
 * 关联群的明信片（groupId > 0）支持上滑在弹窗内展开该群本地聊天记录：
 * 剧本式纯文字（用户名：… / 我：…），不另开界面、不写标题，下滑收起
 * （只读：长期记录在本机 GroupChatStore，无网络请求）
 */
@Component
export struct PostcardModal {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop @Watch('onVisibleChange') visible: boolean = false;
  @Prop postcard: Postcard = new Postcard();
  @Prop mode: string = 'save';
  onSave: () => void = () => {};
  onClose: () => void = () => {};
  /** 弹窗内展开的剧本式聊天记录（上滑展开 / 下滑收起） */
  @State chatVisible: boolean = false;
  @State chatMessages: GroupChatMessageInfo[] = [];
  private chatScroller: Scroller = new Scroller();

  /** 上滑超过阈值（px）展开 / 下滑超过阈值收起 */
  private static readonly SWIPE_OPEN: number = -30;
  private static readonly SWIPE_CLOSE: number = 30;

  /** 每次打开弹窗都从收起状态开始 */
  onVisibleChange(): void {
    if (this.visible) {
      this.chatVisible = false;
    }
  }

  /** 展开该群本地聊天记录（拉取即得的长期真源，无网络请求） */
  private openChat(): void {
    if (this.postcard.groupId <= 0 || this.chatVisible) {
      return;
    }
    this.chatMessages = groupChatStore.listThread(appStore.getAccount(), this.postcard.groupId);
    this.chatVisible = true;
  }

  /** 剧本式单行：自己的消息「我：…」，他人「用户名：…」 */
  @Builder
  private ChatScriptLine(m: GroupChatMessageInfo) {
    Text(m.fromAccount === appStore.getAccount() ? `我：${m.text}` : `${m.fromAccount}：${m.text}`)
      .fontSize(Theme.fontCaption)
      .fontColor(Color.White)
      .opacity(0.92)
      .lineHeight(20)
      .width('100%')
  }

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

        Column({ space: 16 }) {
          Row() {
            Text(this.postcard.dateLine())
              .fontSize(Theme.fontCaption)
              .fontColor(Color.White)
              .opacity(0.85)
            Blank()
            Text(this.postcard.emoji)
              .fontSize(30)
          }
          .width('100%')

          if (!this.chatVisible) {
            Blank()
          }

          Column({ space: 8 }) {
            // GB 45438-2025 文本内容显式标识：AI 写下的标题/祝福为生成文本，「AI生成」标签置于起始位置
            Text('AI生成')
              .fontSize(Theme.fontTag)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .padding({ left: 7, right: 7, top: 3, bottom: 3 })
              .borderRadius(Theme.radiusTag)
              .backgroundColor('rgba(0,0,0,0.30)')
              .alignSelf(ItemAlign.Start)
            Text(this.postcard.title)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
            Text(this.postcard.blessing)
              .fontSize(Theme.fontBody)
              .fontColor(Color.White)
              .opacity(0.92)
              .lineHeight(22)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          if (this.chatVisible) {
            if (this.chatMessages.length === 0) {
              Column() {
                Text(tr('暂无聊天记录'))
                  .fontSize(Theme.fontCaption)
                  .fontColor(Color.White)
                  .opacity(0.75)
              }
              .width('100%')
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
            } else {
              Scroll(this.chatScroller) {
                Column({ space: 10 }) {
                  ForEach(this.chatMessages, (m: GroupChatMessageInfo) => {
                    this.ChatScriptLine(m)
                  }, (m: GroupChatMessageInfo) => `s-${m.id}`)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .layoutWeight(1)
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
              .align(Alignment.Top)
              .parallelGesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical })
                .onActionEnd((e: GestureEvent) => {
                  if (e.offsetY > PostcardModal.SWIPE_CLOSE && this.chatScroller.currentOffset().yOffset <= 0.5) {
                    this.chatVisible = false;
                  }
                }))
            }
          }

          if (!this.chatVisible) {
            Blank()
          }

          if (this.postcard.groupId > 0) {
            Row({ space: 6 }) {
              Text(this.chatVisible ? '⬇' : '⬆')
                .fontSize(Theme.fontTag)
                .fontColor(Color.White)
                .opacity(0.9)
              Text(this.chatVisible ? tr('下滑收起聊天记录') : tr('上滑查看聊天记录'))
                .fontSize(Theme.fontTag)
                .fontColor(Color.White)
                .opacity(0.9)
            }
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor('rgba(255,255,255,0.22)')
            .borderRadius(Theme.radiusTag)
          }

          Row({ space: 10 }) {
            Column() {
              Text(this.mode === 'save' ? tr('📮 存入日历') : tr('好的，收下'))
                .fontSize(Theme.fontBody)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.brandDeep())
            }
            .layoutWeight(1)
            .height(42)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.White)
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              if (this.mode === 'save') {
                this.onSave();
              } else {
                this.onClose();
              }
            })

            if (this.mode === 'save') {
              Column() {
                Text(tr('先收着'))
                  .fontSize(Theme.fontBody)
                  .fontColor(Color.White)
              }
              .padding({ left: 18, right: 18 })
              .height(42)
              .justifyContent(FlexAlign.Center)
              .border({ width: 1, color: Color.White })
              .borderRadius(Theme.radiusBtn)
              .onClick(() => {
                this.onClose();
              })
            }
          }
          .width('100%')
        }
        .width('82%')
        .height(this.chatVisible ? '80%' : 380)
        .padding(22)
        .borderRadius(Theme.radiusModal)
        .linearGradient({
          angle: 135,
          colors: [[Theme.postcardGradientFrom(this.postcard.gradientIndex), 0.0],
            [Theme.postcardGradientTo(this.postcard.gradientIndex), 1.0]]
        })
        .animation({ duration: 260, curve: Curve.EaseOut })
        .gesture(PanGesture({ fingers: 1, direction: PanDirection.Vertical })
          .onActionEnd((e: GestureEvent) => {
            if (e.offsetY < PostcardModal.SWIPE_OPEN) {
              this.openChat();
            } else if (e.offsetY > PostcardModal.SWIPE_CLOSE && this.chatVisible) {
              this.chatVisible = false;
            }
          }))
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })))
      }
      .width('100%')
      .height('100%')
      .transition(TransitionEffect.OPACITY)
    }
  }
}

/**
 * 日程当日安排里的明信片条目：与日程卡片同尺寸比例（宽 100% × 高 130），
 * 完成的卡片消失后由它顶替位置；点击打开 PostcardModal 查看全文；
 * 传入 onDelete 时右上角显示删除按钮（不传则纯展示，「我的」页最近一张复用本组件）
 */
@Component
export struct PostcardCard {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop postcard: Postcard = new Postcard();
  onTap: () => void = () => {};
  onDelete?: () => void;

  build() {
    Row({ space: 10 }) {
      Column({ space: 6 }) {
        Row() {
          Text(this.postcard.dateLine())
            .fontSize(Theme.fontCaption)
            .fontColor(Color.White)
            .opacity(0.85)
          Blank()
          Text(this.postcard.emoji)
            .fontSize(22)
        }
        .width('100%')

        Blank()

        // GB 45438-2025 文本内容显式标识：AI 生成祝福文本，「AI生成」标签置于起始位置（内联避免 130 定高溢出）
        Row({ space: 6 }) {
          Text('AI生成')
            .fontSize(Theme.fontTag)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(Theme.radiusTag)
            .backgroundColor('rgba(0,0,0,0.30)')
          Text(this.postcard.title)
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        Text(this.postcard.blessing)
          .fontSize(Theme.fontCaption)
          .fontColor(Color.White)
          .opacity(0.92)
          .lineHeight(18)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Blank()
      }
      .layoutWeight(1)
      .height('100%')
      .onClick(() => {
        this.onTap();
      })

      if (this.onDelete !== undefined) {
        Text('✕')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .width(26)
          .height(26)
          .borderRadius(13)
          .backgroundColor('rgba(255,255,255,0.28)')
          .onClick(() => {
            if (this.onDelete !== undefined) {
              this.onDelete();
            }
          })
      }
    }
    .width('100%')
    .height(130)
    .alignItems(VerticalAlign.Top)
    .padding({ left: 18, right: this.onDelete !== undefined ? 12 : 18, top: 14, bottom: 14 })
    .borderRadius(Theme.radiusCard)
    .linearGradient({
      angle: 135,
      colors: [[Theme.postcardGradientFrom(this.postcard.gradientIndex), 0.0],
        [Theme.postcardGradientTo(this.postcard.gradientIndex), 1.0]]
    })
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
  }
}

/**
 * 消卡碎片动画：phase1 整卡 420ms → phase2 12 碎片错峰散落 → onFinished
 * 若碎片动画异常可降级为整卡 scale+rotate+fade（本实现用标准属性动画，无需降级）
 */
@Component
export struct ShredOverlay {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop @Watch('onVisibleChange') visible: boolean = false;
  @Prop card: TaskCard = new TaskCard();
  onFinished: (card: TaskCard) => void = () => {};

  @State phase: number = 0;
  @State shardFly: boolean = false;
  private shardIdx: number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
  private flyX: number[] = [];
  private flyY: number[] = [];
  private flyR: number[] = [];

  onVisibleChange(): void {
    if (!this.visible) {
      return;
    }
    this.flyX = [];
    this.flyY = [];
    this.flyR = [];
    let i: number = 0;
    for (i = 0; i < 12; i++) {
      this.flyX.push(Math.random() * 320 - 160);
      this.flyY.push(Math.random() * 260 + 120);
      this.flyR.push(Math.random() * 360 - 180);
    }
    this.phase = 1;
    this.shardFly = false;
    setTimeout(() => {
      this.phase = 2;
      setTimeout(() => {
        this.shardFly = true;
      }, 60);
      setTimeout(() => {
        this.phase = 0;
        this.onFinished(this.card);
      }, 1600);
    }, 420);
  }

  build() {
    if (this.visible) {
      Column() {
        Stack() {
          if (this.phase === 1) {
            Column({ space: 6 }) {
              GlyphIcon({ emoji: this.card.symbol, iconSize: 44 })
              Text(this.card.title)
                .fontSize(Theme.fontCardTitle)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              Text(tr('正在兑现这个承诺…'))
                .fontSize(Theme.fontTag)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.kindBg(this.card.kind))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
            .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.92, y: 0.92 })))
          }

          if (this.phase === 2) {
            Grid() {
              ForEach(this.shardIdx, (i: number) => {
                GridItem() {
                  Column()
                    .width('100%')
                    .height('100%')
                    .borderRadius(3)
                    .linearGradient({
                      angle: 135,
                      colors: [[Theme.kindAccent(this.card.kind), 0.0], [Theme.kindDeep(this.card.kind), 1.0]]
                    })
                    .translate({
                      x: this.shardFly ? this.flyX[i] : 0,
                      y: this.shardFly ? this.flyY[i] : 0
                    })
                    .rotate({ angle: this.shardFly ? this.flyR[i] : 0 })
                    .opacity(this.shardFly ? 0 : 1)
                    .animation({ delay: i * 40, duration: 700, curve: Curve.EaseIn })
                }
              }, (i: number) => `shard-${i}`)
            }
            .columnsTemplate('1fr 1fr 1fr 1fr')
            .rowsTemplate('1fr 1fr 1fr')
            .width('100%')
            .height('100%')
          }
        }
        .width('76%')
        .height(170)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.overlay_mask'))
      .transition(TransitionEffect.OPACITY)
    }
  }
}
