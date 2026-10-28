import { Backend } from '@chengnuo/backend';
import { ServerGateway } from '../net/ServerGateway';
import { ConversationMessageInfo, ConversationsOutcome, MessageOutcome } from '../net/ServerModels';
import { EmptyState } from '../components/EmptyState';
import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';

/**
 * AI 对话记录（个人信息进入）：查看本机保存的最近对话（conversations.txt，服务 39 本地应答，
 * 个性化服务开启时记录、最多保留最近 10 条、旧 → 新展示），底部「清空对话记录」按钮
 * 删除本机该用户的全部对话记录。个性化服务关闭时不记录对话，页面只显示提示。
 */
@Entry
@Component
struct ConversationsDataPage {
  @StorageProp('appLang') appLang: string = 'zh';
  @State messages: ConversationMessageInfo[] = [];
  @State loading: boolean = true;
  @State personalized: boolean = true;
  @State clearing: boolean = false;

  aboutToAppear(): void {
    this.personalized = Backend.isPersonalizationEnabled();
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    const outcome: ConversationsOutcome = await ServerGateway.conversationsList();
    this.loading = false;
    this.messages = outcome.ok ? outcome.messages : [];
  }

  /** 对话时间（ISO 字符串 → 本地「M月D日 HH:mm」；解析失败显示原文） */
  private timeText(iso: string): string {
    const ts: number = Date.parse(iso);
    if (!Number.isNaN(ts)) {
      const d: Date = new Date(ts);
      const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
      const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
      return trf('{0}月{1}日 {2}:{3}', d.getMonth() + 1, d.getDate(), hh, mm);
    }
    return iso;
  }

  /** 清空确认：本机对话记录删除后无法恢复 */
  private confirmClear(): void {
    this.getUIContext().showAlertDialog({
      title: tr('清空对话记录'),
      message: tr('清除后无法恢复，确定清除吗？'),
      primaryButton: {
        value: tr('先留着'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: tr('清空'),
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.doClear();
        }
      }
    });
  }

  private async doClear(): Promise<void> {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    const outcome: MessageOutcome = await ServerGateway.clearConversations();
    this.clearing = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    this.messages = [];
    this.getUIContext().getPromptAction().showToast({ message: outcome.message });
  }

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(24)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Text(tr('AI 对话记录'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 16 }) {
          if (this.loading) {
            Text(tr('读取中…'))
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 40 })
          } else if (!this.personalized) {
            // 个性化服务关闭：不记录任何对话
            EmptyState({
              emoji: '🤖',
              title: tr('个性化服务已关闭'),
              subtitle: tr('AI 不会记录你的对话内容')
            })
          } else if (this.messages.length === 0) {
            EmptyState({
              emoji: '💬',
              title: tr('还没有对话记录'),
              subtitle: tr('和 AI 聊过后会保存在这里')
            })
          } else {
            // 对话列表（旧 → 新）：我 = 品牌色标签 / AI = 灰色标签 + 内容 + 时间
            Column({ space: 0 }) {
              ForEach(this.messages, (m: ConversationMessageInfo) => {
                this.messageRow(m)
              }, (m: ConversationMessageInfo) => `${m.id}`)
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

            // 清空按钮：删除本机对话记录（仅当前用户）
            Column() {
              Text(this.clearing ? tr('清除中…') : tr('清空对话记录'))
                .fontSize(Theme.fontBody)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.error'))
            }
            .width('100%')
            .height(48)
            .justifyContent(FlexAlign.Center)
            .borderRadius(Theme.radiusBtn)
            .backgroundColor($r('app.color.bg_card'))
            .border({ width: 1, color: $r('app.color.error') })
            .opacity(this.clearing ? 0.6 : 1.0)
            .onClick(() => {
              this.confirmClear();
            })
          }

          Text(tr('对话记录仅保存在本机，最多保留最近 10 条；清空后无法恢复'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ left: 12, right: 12, bottom: 8 })
        }
        .width('100%')
        .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 12 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /** 单条对话行：方向标签（我/AI）+ 内容 + 时间（direction: in = 我方发言 / out = AI 回复） */
  @Builder
  private messageRow(m: ConversationMessageInfo) {
    Column() {
      Row({ space: 8 }) {
        // AI 记录角标用「AI生成」：GB 45438-2025 文字形式显式标识（AI + 生成）位于文本起始位置
        Text(m.direction === 'in' ? tr('我') : 'AI生成')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(m.direction === 'in' ? Theme.brandDeep() : $r('app.color.text_secondary'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(Theme.radiusBtn)
          .backgroundColor(m.direction === 'in' ? Theme.brandSoft() : $r('app.color.chip_bg'))
        Text(this.timeText(m.time))
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Text(m.content)
        .fontSize(Theme.fontBody)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .lineHeight(22)

      // AI 回复：展示生成合成内容隐式标识（GB 45438-2025），供用户查证 AI 生成属性
      if (m.direction !== 'in' && m.aigcLabel.length > 0) {
        Text(`ⓘ AI 生成内容隐式标识：${m.aigcLabel}`)
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: 6 })
          .lineHeight(16)
          .copyOption(CopyOptions.LocalDevice)
      }

      Column()
        .width('100%')
        .height(0.5)
        .backgroundColor($r('app.color.divider'))
        .margin({ top: 14, bottom: 14 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14 })
  }
}
