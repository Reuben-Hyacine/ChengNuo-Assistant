let lockCardStorage = new LocalStorage();

/**
 * 桌面服务卡片页面（2*4，动态卡片）：
 * 展示「最近的未完成/打卡卡片」，不解锁即可操作——
 * - 完成（服务器卡指定完成者）：message 事件 → 卡片进程 62 兑现 + AI 明信片
 * - 打卡（重复卡非末日）：router 拉起应用自动打卡（打卡记录在应用内）
 * - 延时：message 事件 → 卡片进程 67 顺延 30 分钟
 * - 取消：message 事件 → 卡片进程 57/15 删除/退出
 * - 点标题/时间区域：router 打开应用日程页（按钮区不冒泡，ClickEvent 无 stopPropagation，
 *   故打开动作只挂在内容区、不挂在卡片根节点）
 * 数据由 CardFormAbility / 应用主进程通过 formProvider.updateForm 推送
 */
@Entry(lockCardStorage)
@Component
struct LockScreenCard {
  @LocalStorageProp('hasCard') hasCard: string = '0';
  @LocalStorageProp('symbol') symbol: string = '🌱';
  @LocalStorageProp('title') title: string = '程诺助手';
  @LocalStorageProp('dateLabel') dateLabel: string = '';
  @LocalStorageProp('timeLine') timeLine: string = '';
  @LocalStorageProp('feedback') feedback: string = '';
  @LocalStorageProp('primaryLabel') primaryLabel: string = '';
  @LocalStorageProp('primaryKind') primaryKind: string = '';
  @LocalStorageProp('canDelay') canDelay: string = '0';
  @LocalStorageProp('canCancel') canCancel: string = '0';
  @LocalStorageProp('busy') busy: string = '0';
  @LocalStorageProp('cardId') cardId: string = '';
  @LocalStorageProp('activeDate') activeDate: string = '';
  /** 天气话术：空态为「但今天有雨…」前缀句（反馈展示时为空）；有卡时为按钮下方独立居中一行 */
  @LocalStorageProp('weatherTip') weatherTip: string = '';

  /** 有卡且带话术时布局紧凑（加一行防超出卡片高度被裁切） */
  private isCompact(): boolean {
    return this.hasCard === '1' && this.weatherTip.length > 0;
  }

  /** router 拉起应用：open=进日程页；checkin=进日程页并自动打卡（date 为打卡目标日） */
  private routerToApp(action: string): void {
    const params: Record<string, Object> = {
      'from': 'lockCard',
      'action': action,
      'cardId': this.cardId,
      'date': this.activeDate
    };
    const act: Record<string, Object> = { 'action': 'router', 'abilityName': 'EntryAbility', 'params': params };
    postCardAction(this, act);
  }

  /** message 发给卡片进程执行服务器动作。
   *  注意：message 事件的入参 JSON 顶层 action 固定为 'message'（包裹层键会覆盖 params.action），
   *  故语义动作用 'act' 键传递 */
  private messageToAbility(action: string): void {
    const params: Record<string, Object> = { 'act': action, 'cardId': this.cardId };
    const act: Record<string, Object> = { 'action': 'message', 'params': params };
    postCardAction(this, act);
  }

  private onPrimaryClick(): void {
    if (this.busy === '1') {
      return;
    }
    if (this.primaryKind === 'checkin') {
      this.routerToApp('checkin');
      return;
    }
    if (this.primaryKind === 'open') {
      this.routerToApp('open');
      return;
    }
    this.messageToAbility('complete');
  }

  /** 空态文本行统一样式（标题 / 一次性反馈 / 天气话术共用；点击进日程页） */
  @Builder
  private emptyLine(text: string) {
    Text(text)
      .fontSize(14)
      .lineHeight(18)
      .fontColor('#FFFFFF')
      .opacity(0.9)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .onClick(() => {
        this.routerToApp('open');
      })
  }

  build() {
    Column({ space: this.isCompact() ? 4 : 8 }) {
      if (this.hasCard === '1') {
        Row({ space: 8 }) {
          if (this.symbol === '🤝') {
            Image($r('app.media.icon_cooperation'))
              .width(28)
              .height(28)
          } else if (this.symbol === '📅') {
            Image($r('app.media.icon_calendar'))
              .width(28)
              .height(28)
          } else {
            Text(this.symbol)
              .fontSize(20)
              .lineHeight(24)
              .maxLines(1)
          }
          Text(this.title)
            .fontSize(20)
            .lineHeight(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.dateLabel.length > 0) {
            Text(this.dateLabel)
              .fontSize(12)
              .lineHeight(15)
              .fontColor('#FFFFFF')
              .opacity(0.92)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('#33FFFFFF')
              .borderRadius(10)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.routerToApp('open');
        })

        Text(this.feedback.length > 0 ? this.feedback : this.timeLine)
          .fontSize(14)
          .lineHeight(18)
          .fontColor('#FFFFFF')
          .opacity(0.9)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .onClick(() => {
            this.routerToApp('open');
          })

        Row({ space: 10 }) {
          if (this.primaryLabel.length > 0) {
            Text(this.busy === '1' ? '…' : this.primaryLabel)
              .fontSize(14)
              .lineHeight(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.brand_deep'))
              .maxLines(1)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(14)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.onPrimaryClick();
              })
          }
          if (this.canDelay === '1') {
            Text('⏳ 延时')
              .fontSize(14)
              .lineHeight(18)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .backgroundColor('#2EFFFFFF')
              .borderRadius(14)
              .layoutWeight(this.primaryLabel.length > 0 ? 1 : 0)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                if (this.busy === '1') {
                  return;
                }
                this.messageToAbility('delay');
              })
          }
          if (this.canCancel === '1') {
            Text('✕ 取消')
              .fontSize(14)
              .lineHeight(18)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .backgroundColor('#2EFFFFFF')
              .borderRadius(14)
              .layoutWeight(this.primaryLabel.length > 0 ? 1 : 0)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                if (this.busy === '1') {
                  return;
                }
                this.messageToAbility('cancel');
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.weatherTip.length > 0) {
          Text(this.weatherTip)
            .fontSize(12)
            .lineHeight(15)
            .fontColor('#FFFFFF')
            .opacity(0.92)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
            .onClick(() => {
              this.routerToApp('open');
            })
        }
      } else {
        Column() {
          if (this.symbol === '🤝') {
            Image($r('app.media.icon_cooperation'))
              .width(42)
              .height(42)
          } else if (this.symbol === '📅') {
            Image($r('app.media.icon_calendar'))
              .width(42)
              .height(42)
          } else {
            Text(this.symbol)
              .fontSize(30)
              .lineHeight(34)
              .maxLines(1)
          }
        }
        .onClick(() => {
          this.routerToApp('open');
        })
        if (this.timeLine.length > 0) {
          // 一次性操作反馈（如在卡片上完成后的提示），反馈优先于空态文案
          this.emptyLine(this.timeLine)
        } else {
          // 空态：暂没有日程安排 + 但今天有雨…（无话术时仅标题一行）
          this.emptyLine(this.title)
          if (this.weatherTip.length > 0) {
            this.emptyLine(this.weatherTip)
          }
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.isCompact() ? 8 : 12,
      bottom: this.isCompact() ? 8 : 12
    })
    .clip(true)
    .linearGradient({
      angle: 135,
      colors: [[$r('app.color.brand'), 0.0], [$r('app.color.brand_deep'), 1.0]]
    })
    .borderRadius(22)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
