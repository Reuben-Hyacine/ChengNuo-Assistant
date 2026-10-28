import { appStore } from '../store/AppStore';
import { InboxGroup, InboxItem } from '../model/Types';
import { Theme } from '../common/Theme';
import { EmptyState } from '../components/EmptyState';
import { ServerGateway } from '../net/ServerGateway';
import { MailInfo, MailListOutcome, friendlyMs } from '../net/ServerModels';
import { tr } from '../common/I18n';

/**
 * 收件箱：日程提醒邮件（mailbox.list 42，提醒到点由服务器自动投递；已读 43 / 删除 44）
 */
@Entry
@Component
struct InboxPage {
  @StorageProp('appLang') appLang: string = 'zh';
  @State items: InboxItem[] = [];
  @State unreadLeft: number = 0;
  @State loading: boolean = false;
  @State isRefreshing: boolean = false;
  /** 邮件条目缓存：键 = 收件箱条目 id（"mail-<服务器邮件 id>"），已读/删除时定位服务器 id */
  private mailById: Map<string, MailInfo> = new Map();

  aboutToAppear(): void {
    this.items = [];
    this.unreadLeft = AppStorage.get<number>('inboxUnread') ?? 0;
    this.loadServer();
  }

  private async loadServer(): Promise<void> {
    if (!appStore.serverOnline) {
      this.items = [];
      return;
    }
    this.loading = true;
    const list: InboxItem[] = [];
    // 日程提醒邮件（42）：到点提醒由服务器自动投递，展开即标记已读（43），可删除（44）
    this.mailById = new Map();
    const mails: MailListOutcome = await ServerGateway.mailList();
    if (mails.ok) {
      mails.mails.forEach((mail: MailInfo) => {
        const key: string = `mail-${mail.id}`;
        this.mailById.set(key, mail);
        list.push(InboxItem.of(key, InboxGroup.Report,
          mail.title.length > 0 ? mail.title : tr('📬 系统邮件'),
          this.mailSummaryOf(mail.body),
          friendlyMs(mail.createdAt), '📬', mail.readAt > 0, mail.body));
      });
    }
    this.items = list;
    this.loading = false;
    if (list.length > 0) {
      this.unreadLeft = AppStorage.get<number>('inboxUnread') ?? list.length;
    }
  }

  /** 邮件摘要：正文第一个非空行 */
  private mailSummaryOf(body: string): string {
    const lines: string[] = body.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length > 0) {
        return line;
      }
    }
    return tr('（空白邮件）');
  }

  /** 下拉刷新：重拉邮件，动画至少展示 600ms 再收起 */
  private handleRefresh(): void {
    const start: number = Date.now();
    this.loadServer().then((): void => {
      const rest: number = Math.max(600 - (Date.now() - start), 0);
      setTimeout(() => {
        this.isRefreshing = false;
      }, rest);
    });
  }

  private itemsOf(group: InboxGroup): InboxItem[] {
    const list: InboxItem[] = [];
    this.items.forEach((it: InboxItem) => {
      if (it.group === group) {
        list.push(it);
      }
    });
    return list;
  }

  private handleReadOne(): void {
    this.unreadLeft = this.unreadLeft > 0 ? this.unreadLeft - 1 : 0;
    appStore.setUnread(this.unreadLeft);
  }

  /** 展开邮件：本地计入已读 + 服务器标记已读（43，失败静默、下次展开重试） */
  private handleReadMail(key: string): void {
    this.handleReadOne();
    const mail: MailInfo | undefined = this.mailById.get(key);
    if (mail !== undefined) {
      ServerGateway.mailRead(mail.id, false);
    }
  }

  /** 删除邮件（44）：成功后重拉列表 */
  private async handleDeleteMail(key: string): Promise<void> {
    const mail: MailInfo | undefined = this.mailById.get(key);
    if (mail === undefined) {
      return;
    }
    const outcome = await ServerGateway.mailRemove(mail.id, false);
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message.length > 0 ? outcome.message : tr('删除失败') });
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: tr('已删除邮件 🗑') });
    this.loadServer();
  }

  private handleMarkAll(): void {
    if (this.unreadLeft === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('已经是全部已读啦 ✨') });
      return;
    }
    const next: InboxItem[] = [];
    this.items.forEach((it: InboxItem) => {
      const r: InboxItem = it.cloneWithId(`${it.id}-r`);
      r.read = true;
      next.push(r);
      // 克隆后的 id 同步注册邮件索引，展开/删除仍能定位服务器邮件
      const mail: MailInfo | undefined = this.mailById.get(it.id);
      if (mail !== undefined) {
        this.mailById.set(r.id, mail);
      }
    });
    this.items = next;
    this.unreadLeft = 0;
    appStore.markAllInboxRead();
    // 有邮件时同步服务器全部已读（43）
    if (this.itemsOf(InboxGroup.Report).length > 0) {
      ServerGateway.mailRead(0, true);
    }
    this.getUIContext().getPromptAction().showToast({ message: tr('已全部标记为已读 ✨') });
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
        Text(tr('收件箱'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(tr('全部已读'))
          .fontSize(Theme.fontCaption)
          .fontColor(Theme.brandDeep())
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(Theme.brandSoft())
          .borderRadius(Theme.radiusTag)
          .onClick(() => {
            this.handleMarkAll();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (!appStore.serverOnline) {
        Column() {
          EmptyState({ emoji: '🍊', title: tr('暂时无法连接'), subtitle: tr('请稍后再试') })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          if (this.loading && this.items.length === 0) {
            Column() {
              Text(tr('正在拉取消息…'))
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          } else if (this.items.length === 0) {
            Scroll() {
              Column() {
                EmptyState({ emoji: '✨', title: tr('这里干干净净'), subtitle: tr('暂无消息；日程提醒邮件会出现在这里') })
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
            }
            .width('100%')
            .height('100%')
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          } else {
            List({ space: 8 }) {
              if (this.itemsOf(InboxGroup.Report).length > 0) {
                ListItemGroup({ header: this.reportHeader }) {
                  ForEach(this.itemsOf(InboxGroup.Report), (it: InboxItem) => {
                    ListItem() {
                      InboxRow({
                        item: it,
                        deletable: true,
                        onRead: () => {
                          this.handleReadMail(it.id);
                        },
                        onDelete: () => {
                          this.handleDeleteMail(it.id);
                        }
                      })
                    }
                  }, (it: InboxItem) => it.id)
                }
              }
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          }
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          this.handleRefresh();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  reportHeader() {
    Text(tr('报告'))
      .fontSize(Theme.fontCaption)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 4 })
  }
}

/**
 * 收件箱行：展开态与已读态为行内 @State（不换 key，保住展开状态）
 */
@Component
struct InboxRow {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop item: InboxItem = new InboxItem();
  onRead: () => void = () => {};
  /** 可删除（邮件类条目）：展开态露出「删除」按钮 */
  deletable: boolean = false;
  onDelete: () => void = () => {};
  @State expanded: boolean = false;
  @State readView: boolean = false;
  @State deleting: boolean = false;

  aboutToAppear(): void {
    this.readView = this.item.read;
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Text(this.item.icon)
          .fontSize(18)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(20)

        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(this.item.title)
              .fontSize(Theme.fontBody)
              .fontWeight(this.readView ? FontWeight.Normal : FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (!this.readView) {
              Column()
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor($r('app.color.badge_red'))
            }
          }
          .width('100%')

          Text(this.item.summary)
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.item.timeText)
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.expanded ? '▾' : '›')
          .fontSize(16)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .onClick(() => {
        this.expanded = !this.expanded;
        if (!this.readView) {
          this.readView = true;
          this.onRead();
        }
      })

      if (this.expanded) {
        Column({ space: 10 }) {
          Text(this.item.detail)
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(20)
            .width('100%')

          Row({ space: 10 }) {
            Blank()
            if (this.deletable) {
              Text(this.deleting ? tr('删除中…') : tr('🗑 删除'))
                .fontSize(Theme.fontTag)
                .fontColor($r('app.color.error'))
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .border({ width: 1, color: $r('app.color.error') })
                .borderRadius(Theme.radiusTag)
                .onClick(() => {
                  if (!this.deleting) {
                    this.deleting = true;
                    this.onDelete();
                  }
                })
            }
            Text(tr('知道了'))
              .fontSize(Theme.fontTag)
              .fontColor(Theme.brandDeep())
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .border({ width: 1, color: Theme.brand() })
              .borderRadius(Theme.radiusTag)
              .onClick(() => {
                this.expanded = false;
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ top: 10 })
        .transition(TransitionEffect.OPACITY)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Theme.radiusCard)
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
  }
}
