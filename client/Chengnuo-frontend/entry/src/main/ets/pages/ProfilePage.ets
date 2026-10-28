import { appStore } from '../store/AppStore';
import { Backend } from '@chengnuo/backend';
import { postcardStore, PostcardRecord } from '../store/PostcardStore';
import { groupChatStore } from '../store/GroupChatStore';
import { Postcard } from '../model/Types';
import { Theme } from '../common/Theme';
import { uidText } from '../common/Format';
import { PageHeader } from '../components/PageHeader';
import { EmptyState } from '../components/EmptyState';
import { PostcardCard, PostcardModal } from '../components/PostcardModal';
import { WeeklyReportBlocks } from '../components/WeeklyReportBlocks';
import { ServerGateway } from '../net/ServerGateway';
import {
  MailInfo, MailListOutcome, MessageOutcome, PostcardListOutcome,
  PostcardPullOutcome, PostcardRecordInfo, PulledPostcardInfo, WeekReportOutcome
} from '../net/ServerModels';
import { tr, trf } from '../common/I18n';

/**
 * 我的页：个人卡 + 周报（上下滑动切换五板块：完成率与本周设立/完成/延时 + 累计统计四块） + 回忆明信片（最近一张） + 设置列表
 * 设置密码与华为账号绑定已移至「通用设置 → 账号安全」；提醒设置已移至「通用设置」
 * 修改账号名（auth.rename 82）已移至个人空间页「账号名」行
 * 退出登录（auth.logout 12）与注销账号（auth.unregister 13）均走路由协议
 */
@Component
export struct ProfilePage {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('userName') userName: string = tr('程诺用户');
  @StorageProp('serverUserId') serverUserId: number = 0;
  @StorageProp('postcardStamp') @Watch('onPostcardsChanged') postcardStamp: number = 0;
  @StorageProp('weekReportStamp') @Watch('onWeekChanged') weekReportStamp: number = 0;
  /** 个人空间保存后头像/昵称板块刷新 */
  @StorageProp('profileStamp') @Watch('onProfileChanged') profileStamp: number = 0;
  /** 主框架切回我的 tab / 回到主框架的刷新广播（页面保活不走 aboutToAppear）：重拉明信片、周报与板块头像 */
  @StorageProp('profileRefreshToken') @Watch('onProfileRefreshTokenChange') profileRefreshToken: number = 0;
  @State plateAvatarUri: string = '';
  @State latestPostcard: Postcard = new Postcard();
  @State weekReport: WeekReportOutcome = new WeekReportOutcome();
  @State postcardVisible: boolean = false;
  @State viewPostcard: Postcard = new Postcard();
  @State loggingOut: boolean = false;
  @State unregisterArmed: boolean = false;
  @State isRefreshing: boolean = false;
  private armedAt: number = 0;

  aboutToAppear(): void {
    this.loadLatestPostcard();
    this.loadWeekReport();
    this.loadPlateAvatar();
  }

  /** 个人空间保存（头像落盘）→ 我的页板块头像刷新 */
  private onProfileChanged(): void {
    this.loadPlateAvatar();
  }

  /** 收到刷新广播：与 aboutToAppear 同一套加载（最近明信片 / 周报 / 板块头像） */
  private onProfileRefreshTokenChange(): void {
    this.loadLatestPostcard();
    this.loadWeekReport();
    this.loadPlateAvatar();
  }

  private loadPlateAvatar(): void {
    this.plateAvatarUri = Backend.profileAvatarUri(appStore.getAccount());
  }

  /** 明信片数据变化（完成出稿 / 删除 / 本地保存）→ 重取最近一张 */
  private onPostcardsChanged(): void {
    this.loadLatestPostcard();
  }

  /** 周报数据变化（完成 / 延时）→ 重取周报 */
  private onWeekChanged(): void {
    this.loadWeekReport();
  }

  /** 周报（74）：客户端周报库本地应答——本周设立数由服务器按周窗口计算快照，
   *  打卡/完成/延时由客户端在事件发生时累加；离线保持上次数据 */
  private async loadWeekReport(): Promise<void> {
    if (!appStore.serverOnline) {
      return;
    }
    const outcome: WeekReportOutcome = await ServerGateway.weekReport();
    if (outcome.ok) {
      this.weekReport = outcome;
    }
  }

  /** 周报日期区间（周一 - 周日，如「9月22日 - 9月28日」）：优先用后端返回的周窗口，
   *  未加载时本地推算本周一（周界按周一 00:00 本地时区，与后端一致） */
  private weekRangeText(): string {
    let startMs: number = this.weekReport.weekStartMs;
    if (startMs <= 0) {
      const d: Date = new Date();
      d.setHours(0, 0, 0, 0);
      const offset: number = (d.getDay() + 6) % 7;
      d.setDate(d.getDate() - offset);
      startMs = d.getTime();
    }
    const start: Date = new Date(startMs);
    const end: Date = new Date(startMs + 6 * 86400000);
    return trf('{0}月{1}日 - {2}月{3}日', start.getMonth() + 1, start.getDate(), end.getMonth() + 1, end.getDate());
  }

  /** 完成率展示文本：周报库落盘值（0-1 小数）转百分比；
   *  null = 本周还没有到期卡片（后端约定界面显示 —） */
  private rateText(): string {
    if (this.weekReport.rate === null) {
      return '—';
    }
    return `${Math.round(this.weekReport.rate * 100)}%`;
  }

  /** 最近一张明信片：本地端侧库最新一条先就位（同步），再拉参与者明信片中转（103，查重合并进端侧库）
   *  与客户端明信片库（服务器 AI 出稿、长期保存）取日期更新的；同日以客户端记录为准（62 出稿是主流程） */
  private async loadLatestPostcard(): Promise<void> {
    if (appStore.serverOnline) {
      await this.pullParticipantPostcards();
    }
    let best: Postcard = new Postcard();
    let bestIso: string = '';
    const records: PostcardRecord[] = postcardStore.listOf(appStore.getAccount());
    if (records.length > 0) {
      const last: PostcardRecord = records[records.length - 1];
      best = Postcard.of('latest-local', last.dateText, last.title, last.text,
        last.gradientIndex, last.emoji, last.weatherText, last.weatherEmoji,
        last.groupId, last.groupName);
      bestIso = last.date;
      this.latestPostcard = best;
    }
    if (!appStore.serverOnline) {
      return;
    }
    const outcome: PostcardListOutcome = await ServerGateway.postcardsList();
    if (!outcome.ok) {
      return;
    }
    outcome.postcards.forEach((r: PostcardRecordInfo) => {
      const iso: string = this.postcardIsoOf(r);
      if (iso.length > 0 && iso >= bestIso) {
        const dayWeather: string[] = postcardStore.dayWeatherOf(appStore.getAccount(), iso);
        best = Postcard.of(`latest-pcs-${r.id}`, this.displayOfPlain(iso),
          r.event.length > 0 ? r.event : tr('未命名卡片'), r.text, r.id % 2, '📮',
          dayWeather[0], dayWeather[1], r.groupId, r.groupName);
        bestIso = iso;
      }
    });
    this.latestPostcard = best;
  }

  /** 拉取参与者明信片（103，服务器中转、拉取即删）：查重合并进端侧明信片库长期保存；
   *  clears（未完成卡被删除 57 的 clear 墓碑）清理对应群的本地聊天记录 */
  private async pullParticipantPostcards(): Promise<void> {
    const pull: PostcardPullOutcome = await ServerGateway.postcardsPull();
    if (!pull.ok) {
      return;
    }
    const account: string = appStore.getAccount();
    const records: PostcardRecord[] = [];
    for (let i = 0; i < pull.postcards.length; i++) {
      const pc: PulledPostcardInfo = pull.postcards[i];
      const iso: string = this.pulledIsoOf(pc);
      records.push(PostcardRecord.of(iso, this.displayOfPlain(iso),
        pc.event.length > 0 ? pc.event : tr('未命名卡片'), pc.text,
        postcardStore.countOf(account) % 2, '📮', '', '', pc.groupId, pc.groupName));
    }
    postcardStore.mergeMany(account, records);
    for (let i = 0; i < pull.clears.length; i++) {
      groupChatStore.deleteThread(account, pull.clears[i]);
    }
  }

  /** 参与者明信片归属日期：completedAt 完成时刻换算本地日期，解析不了回退计划时间日期部分 */
  private pulledIsoOf(pc: PulledPostcardInfo): string {
    if (pc.completedAt.length > 0) {
      const ts: number = Date.parse(pc.completedAt);
      if (!Number.isNaN(ts)) {
        const d: Date = new Date(ts);
        const m: number = d.getMonth() + 1;
        const day: number = d.getDate();
        const mm: string = m < 10 ? `0${m}` : `${m}`;
        const dd: string = day < 10 ? `0${day}` : `${day}`;
        return `${d.getFullYear()}-${mm}-${dd}`;
      }
    }
    return pc.time.length >= 10 ? pc.time.substring(0, 10) : '';
  }

  /** 明信片归属日期：createdAt 完成时刻换算本地日期（yyyy-MM-dd），解析不了回退计划时间日期部分 */
  private postcardIsoOf(r: PostcardRecordInfo): string {
    if (r.createdAt.length > 0) {
      const ts: number = Date.parse(r.createdAt);
      if (!Number.isNaN(ts)) {
        const d: Date = new Date(ts);
        const m: number = d.getMonth() + 1;
        const day: number = d.getDate();
        const mm: string = m < 10 ? `0${m}` : `${m}`;
        const dd: string = day < 10 ? `0${day}` : `${day}`;
        return `${d.getFullYear()}-${mm}-${dd}`;
      }
    }
    return r.time.length >= 10 ? r.time.substring(0, 10) : '';
  }

  /** yyyy-MM-dd → 展示日期（如 10月3日） */
  private displayOfPlain(iso: string): string {
    const parts: string[] = iso.split('-');
    return trf('{0}月{1}日', Number(parts[1]), Number(parts[2]));
  }

  /** 退出登录：注销服务器会话，清空本地并回登录页 */
  private async handleLogout(): Promise<void> {
    if (this.loggingOut) {
      return;
    }
    this.loggingOut = true;
    if (appStore.serverOnline) {
      await ServerGateway.logout();
    }
    appStore.clearSession();
    AppStorage.setOrCreate('agreementChecked', false);
    this.getUIContext().getPromptAction().showToast({ message: tr('已退出登录，再见 👋') });
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
  }

  /** 注销账号：两段确认后调用 auth.unregister（服务器清空该账号全部数据） */
  private async handleUnregister(): Promise<void> {
    if (this.loggingOut) {
      return;
    }
    const now: number = Date.now();
    if (!this.unregisterArmed || now - this.armedAt > 5000) {
      this.unregisterArmed = true;
      this.armedAt = now;
      this.getUIContext().getPromptAction().showToast({ message: tr('将删除服务器上该账号的全部数据，再点一次确认 ⚠️') });
      return;
    }
    this.unregisterArmed = false;
    this.loggingOut = true;
    const outcome: MessageOutcome = await ServerGateway.unregister(appStore.getPassword());
    if (!outcome.ok) {
      this.loggingOut = false;
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    appStore.clearSession();
    this.getUIContext().getPromptAction().showToast({ message: tr('账号已注销，数据已清空 👋') });
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
  }

  /** 重拉邮件 42 同步未读角标 */
  private async loadSummary(): Promise<void> {
    if (!appStore.serverOnline) {
      return;
    }
    const mails: MailListOutcome = await ServerGateway.mailList();
    let unread: number = 0;
    if (mails.ok) {
      mails.mails.forEach((mail: MailInfo) => {
        if (mail.readAt <= 0) {
          unread++;
        }
      });
    }
    appStore.setUnread(unread);
  }

  /** 下拉刷新：同步未读角标、最近明信片与周报，动画至少展示 600ms 再收起 */
  private handleRefresh(): void {
    const start: number = Date.now();
    this.loadLatestPostcard();
    this.loadWeekReport();
    this.loadSummary().then((): void => {
      const rest: number = Math.max(600 - (Date.now() - start), 0);
      setTimeout(() => {
        this.isRefreshing = false;
      }, rest);
    });
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: tr('我的'), showSearch: false })

        Refresh({ refreshing: $$this.isRefreshing }) {
          Scroll() {
            Column({ space: 16 }) {
            Row({ space: 14 }) {
              Stack({ alignContent: Alignment.Center }) {
                if (this.plateAvatarUri.length > 0) {
                  Image(this.plateAvatarUri)
                    .width(56)
                    .height(56)
                    .borderRadius(28)
                    .objectFit(ImageFit.Cover)
                } else {
                  Image($r('app.media.penguin'))
                    .width(56)
                    .height(56)
                    .borderRadius(28)
                    .objectFit(ImageFit.Contain)
                }
              }
              .width(56)
              .height(56)

              Column({ space: 4 }) {
                Text(this.userName)
                  .fontSize(Theme.fontSectionTitle)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Text(this.serverUserId > 0 ? `UID：${uidText(this.serverUserId)}` : 'UID：—')
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_secondary'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding(18)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/PersonalSpace' });
            })

            Column({ space: 14 }) {
              Text(tr('周报'))
                .fontSize(Theme.fontCardTitle)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .width('100%')

              Text(this.weekRangeText())
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')

              // 周报五板块（等高，上下滑动循环切换 + 右侧竖排红点指示器，参考日程页日历块 ↔ 天气块）：
              // ① 完成率与本周设立/完成/延时 ② 时段分布（柱状图）③④⑤ 类型/场景/主题分布（环状图）
              WeeklyReportBlocks({
                setCount: this.weekReport.setCount,
                doneCount: this.weekReport.doneCount,
                extendCount: this.weekReport.extendCount,
                tagCounts: this.weekReport.tagCounts
              })
            }
            .width('100%')
            .padding(18)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

            Column({ space: 12 }) {
              Text(tr('回忆明信片'))
                .fontSize(Theme.fontCardTitle)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .width('100%')

              if (this.latestPostcard.title.length === 0) {
                EmptyState({ emoji: '📮', title: tr('还没有明信片'), subtitle: tr('完成日程卡后，AI 会为你写下回忆') })
              } else {
                // 最近一张明信片：点击打开查看全文
                PostcardCard({
                  postcard: this.latestPostcard,
                  onTap: () => {
                    this.viewPostcard = this.latestPostcard;
                    this.postcardVisible = true;
                  }
                })
              }
            }
            .width('100%')

            Column() {
              this.settingRow('⏳', tr('倒计时'), 'countdown')
              Column()
                .width('100%')
                .height(0.5)
                .backgroundColor($r('app.color.divider'))
              this.settingRow('⚙️', tr('通用设置'), 'general')
              Column()
                .width('100%')
                .height(0.5)
                .backgroundColor($r('app.color.divider'))
              this.settingRow('📄', tr('关于程诺'), 'about')
              Column()
                .width('100%')
                .height(0.5)
                .backgroundColor($r('app.color.divider'))
              this.settingRow('🚪', tr('退出登录'), 'logout')
              Column()
                .width('100%')
                .height(0.5)
                .backgroundColor($r('app.color.divider'))
              this.settingRow('🗑️', tr('注销账号'), 'unregister')
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
          }
          .width('100%')
          .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 4 })
          }
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          this.handleRefresh();
        })
      }
      .width('100%')
      .height('100%')

      PostcardModal({
        visible: this.postcardVisible,
        postcard: this.viewPostcard,
        mode: 'view',
        onSave: () => {
        },
        onClose: () => {
          this.postcardVisible = false;
        }
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  settingRow(icon: string, label: string, action: string) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(18)
      Text(action === 'unregister' && this.unregisterArmed ? tr('再点一次确认注销 ⚠️') : label)
        .fontSize(Theme.fontBody)
        .fontColor(action === 'logout' || action === 'unregister' ? $r('app.color.error') : $r('app.color.text_primary'))
        .layoutWeight(1)
      Text('›')
        .fontSize(18)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 15, bottom: 15 })
    .onClick(() => {
      if (action === 'logout') {
        this.handleLogout();
      } else if (action === 'unregister') {
        this.handleUnregister();
      } else if (action === 'countdown') {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/CountdownPage' });
      } else if (action === 'general') {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/GeneralSettings' });
      } else if (action === 'about') {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutChengNuo' });
      }
    })
  }
}
