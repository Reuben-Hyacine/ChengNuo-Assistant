import { appStore } from '../store/AppStore';
import { BottomNav } from '../components/BottomNav';
import { SchedulePage } from './SchedulePage';
import { PetPage } from './PetPage';
import { DiscoverPage } from './DiscoverPage';
import { ProfilePage } from './ProfilePage';
import { ServerGateway } from '../net/ServerGateway';
import { MailInfo, MailListOutcome, ReminderInfo, RemindersOutcome } from '../net/ServerModels';
import { ReminderPopup } from '../components/ReminderPopup';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { tr, trf } from '../common/I18n';
import { WeatherTips } from '../common/WeatherTips';
import { BannerCenter } from '../common/BannerCenter';
import { NotifKind } from '../store/NotificationPrefStore';

/**
 * 主框架：四 tab 页叠放保活（Stack + Visibility），底部五入口导航
 * 前台提醒轮询（reminders.due 40）：服务器无反向投递，主框架每分钟拉取一次已到点提醒，
 * 明信片风格弹窗展示：保持 3 秒自动关闭，点击确定立即关闭
 * （同一条提醒服务器只送达一次，并同步投递提醒邮件到收件箱，收件箱照常保留）
 * 到点提醒同时经 Notification Kit 发系统通知（SERVICE_INFORMATION 渠道，支持横幅/锁屏展示，并挂
 * wantAgent：点击横幅/通知中心条目拉起应用并定位日程页）。
    * 横幅事件轮询（60 秒）：邮件增量发系统横幅；只读轮询、首轮只建基线不发横幅；
    * 横幅开关见「提醒设置」（总开关 + 分项，默认全开；关闭分项仅停横幅，
    * 应用内弹窗/角标/消息列表不受影响）。
 * 横幅是否展示受系统通知开关与用户横幅开关控制。
 */
@Entry
@Component
struct Main {
  @StorageProp('appLang') appLang: string = 'zh';
  @State currentTab: number = 0;
  /** 到点提醒弹窗：显示状态与本次送达的提醒列表 */
  @State reminderPopupVisible: boolean = false;
  @State dueReminders: ReminderInfo[] = [];
  /** 弹窗展示时的天气话术（每次送达提醒时从天气快照重算；好天气为空串不展示） */
  @State reminderWeatherTip: string = '';
  private reminderTimer: number = -1;
  /** 弹窗 3 秒自动关闭定时器 */
  private popupTimer: number = -1;
  /** 拉取进行中标记（防止轮询重入） */
  private reminding: boolean = false;
  /** 横幅事件轮询：邮件/聊天增量检测（首轮只建基线不发横幅） */
  private bannerTimer: number = -1;
  private bannerPolling: boolean = false;
  private lastMailId: number = 0;
  private mailBaseReady: boolean = false;
  /** 建帧后首次 onPageShow 跳过刷新广播（登录/进应用时四保活页刚经 aboutToAppear 全量加载，再广播会双重拉取） */
  private firstShow: boolean = true;

  aboutToAppear(): void {
    appStore.initAppStorage();
    this.startReminderPolling();
    this.startBannerPolling();
    this.ensureNotificationEnabled();
  }

  aboutToDisappear(): void {
    this.stopReminderPolling();
    this.stopBannerPolling();
    this.cancelPopupAutoClose();
  }

  /** 回到主框架（创建页写卡返回 / 应用切回前台 / 点击提醒横幅拉起）：广播刷新三保活页，各页收到后重拉自己的数据 */
  onPageShow(): void {
    if (AppStorage.get<boolean>('reminderBannerOpen') ?? false) {
      AppStorage.setOrCreate('reminderBannerOpen', false);
      this.currentTab = 0;
      hilog.info(0x0000, 'testTag', 'opened from reminder banner: focus schedule tab');
    }
    if (this.firstShow) {
      this.firstShow = false;
    } else {
      this.broadcastTabRefresh();
    }
    this.pollDueReminders();
    this.pollBannerEvents();
  }

  /** 四保活页刷新广播（日程/宠物/发现/我的）：进主框架（登录/进应用后的 onPageShow）或回到主框架时各页自增令牌后重拉数据（宠物页令牌 petShowToken 仅在点进宠物 tab 时自增，见 onTab） */
  private broadcastTabRefresh(): void {
    for (let i = 0; i <= 3; i++) {
      this.bumpTabRefresh(i);
    }
  }

  /** 自增某 tab 对应页的刷新令牌（0 日程 / 1 宠物 / 2 发现 / 3 我的）：页面保活不走 aboutToAppear，靠令牌重拉 */
  private bumpTabRefresh(index: number): void {
    if (index === 0) {
      AppStorage.setOrCreate('scheduleRefreshToken',
        (AppStorage.get<number>('scheduleRefreshToken') ?? 0) + 1);
    }
    if (index === 2) {
      AppStorage.setOrCreate('discoverRefreshToken',
        (AppStorage.get<number>('discoverRefreshToken') ?? 0) + 1);
    }
    if (index === 3) {
      AppStorage.setOrCreate('profileRefreshToken',
        (AppStorage.get<number>('profileRefreshToken') ?? 0) + 1);
    }
  }

  /** 前台每分钟拉取一次到点提醒 */
  private startReminderPolling(): void {
    this.pollDueReminders();
    this.reminderTimer = setInterval((): void => {
      this.pollDueReminders();
    }, 60000);
  }

  private stopReminderPolling(): void {
    if (this.reminderTimer >= 0) {
      clearInterval(this.reminderTimer);
      this.reminderTimer = -1;
    }
  }

  /** reminders.due（40）：拉取已到点且未送达过的提醒，非空时弹窗展示（3 秒自动关 / 确定立即关） */
  private async pollDueReminders(): Promise<void> {
    if (this.reminding || !appStore.serverOnline) {
      return;
    }
    this.reminding = true;
    const outcome: RemindersOutcome = await ServerGateway.remindersDue();
    this.reminding = false;
    if (!outcome.ok || outcome.reminders.length === 0) {
      return;
    }
    this.dueReminders = outcome.reminders;
    this.reminderWeatherTip = WeatherTips.topTipOf(ServerGateway.weatherSnapshot());
    hilog.info(0x0000, 'testTag', 'reminder weatherTip: %{public}s', this.reminderWeatherTip);
    this.reminderPopupVisible = true;
    this.publishReminderBanner(outcome.reminders, this.reminderWeatherTip);
    hilog.info(0x0000, 'testTag', 'reminder popup show: %{public}d 条', outcome.reminders.length);
    this.schedulePopupAutoClose();
  }

  /** 申请通知授权：系统弹窗仅弹一次；此前已拒绝则直接返回 1600004，不再打扰 */
  private ensureNotificationEnabled(): void {
    notificationManager.isNotificationEnabled().then((enabled: boolean) => {
      if (enabled) {
        return;
      }
      const host: common.UIAbilityContext | undefined =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (host === undefined) {
        return;
      }
      notificationManager.requestEnableNotification(host)
        .then(() => {
          hilog.info(0x0000, 'testTag', 'notification enabled by user');
        })
        .catch((err: BusinessError) => {
          hilog.info(0x0000, 'testTag', 'notification request refused: %{public}d', err.code);
        });
    }).catch((err: BusinessError) => {
      hilog.warn(0x0000, 'testTag', 'isNotificationEnabled failed: %{public}d', err.code);
    });
  }

  /** 单条提醒标题：事件名优先，回退目的，再回退默认（与弹窗同款语义） */
  private reminderTitleOf(r: ReminderInfo): string {
    if (r.event.length > 0) {
      return r.event;
    }
    if (r.purpose.length > 0) {
      return r.purpose;
    }
    return tr('未命名日程');
  }

  /** 到点提醒发系统横幅通知（提醒设置「提醒通知」开关控制）：SERVICE_INFORMATION 渠道（横幅/锁屏随系统与用户开关展示）；
   *  挂 wantAgent（拉起 EntryAbility，parameters.from=reminderBanner），点击横幅/通知条目回应用定位日程页。
   *  横幅只渲染 title/text（additionalText 仅通知中心小字）：单条时事件名作标题、`🕒 开始时间 · 天气话术` 作正文确保话术上横幅；
   *  多条时标题「日程提醒（N 条）」、正文「X 等 N 条日程」，时间+话术放副文本（通知中心可见） */
  private publishReminderBanner(reminders: ReminderInfo[], weatherTip: string): void {
    const count: number = reminders.length;
    if (count === 0) {
      return;
    }
    const first: ReminderInfo = reminders[0];
    const timeTip: string = weatherTip.length > 0
      ? `🕒 ${first.eventStart} · ${weatherTip}`
      : `🕒 ${first.eventStart}`;
    if (count > 1) {
      const title: string = trf('日程提醒（{0} 条）', count);
      const text: string = trf('{0} 等 {1} 条日程', this.reminderTitleOf(first), count);
      BannerCenter.publish(NotifKind.REMINDER, title, text, 'reminderBanner', timeTip);
      return;
    }
    BannerCenter.publish(NotifKind.REMINDER, this.reminderTitleOf(first), timeTip, 'reminderBanner');
  }

  /** 横幅事件轮询（60 秒）：邮件增量发系统横幅。首轮只建基线不发横幅；提醒通知横幅由 reminders.due（40）流单独负责 */
  private startBannerPolling(): void {
    this.pollBannerEvents();
    this.bannerTimer = setInterval((): void => {
      this.pollBannerEvents();
    }, 60000);
  }

  private stopBannerPolling(): void {
    if (this.bannerTimer >= 0) {
      clearInterval(this.bannerTimer);
      this.bannerTimer = -1;
    }
  }

  private async pollBannerEvents(): Promise<void> {
    if (this.bannerPolling || !appStore.serverOnline) {
      return;
    }
    this.bannerPolling = true;
    try {
      await this.pollMailBanners();
    } finally {
      this.bannerPolling = false;
    }
  }

  /** 邮件增量 → 分类横幅（mailbox.list 42 只读不标已读；基线为已见过的最大邮件 id） */
  private async pollMailBanners(): Promise<void> {
    const outcome: MailListOutcome = await ServerGateway.mailList();
    if (!outcome.ok) {
      return;
    }
    const mails: MailInfo[] = outcome.mails;
    let maxId: number = this.lastMailId;
    for (let i = 0; i < mails.length; i++) {
      if (mails[i].id > maxId) {
        maxId = mails[i].id;
      }
    }
    if (!this.mailBaseReady) {
      this.lastMailId = maxId;
      this.mailBaseReady = true;
      return;
    }
    const systemMails: MailInfo[] = [];
    for (let i = 0; i < mails.length; i++) {
      const mail: MailInfo = mails[i];
      if (mail.id <= this.lastMailId) {
        continue;
      }
      if (this.classifyMail(mail.title) === NotifKind.SYSTEM) {
        systemMails.push(mail);
      }
    }
    this.lastMailId = maxId;
    this.publishMailBanner(NotifKind.SYSTEM, tr('系统通知'), systemMails);
  }

  /** 邮件标题 → 横幅类别（与服务器邮件标题前缀对齐；空串 = 跳过不横幅） */
  private classifyMail(title: string): string {
    if (title.startsWith('日程提醒邮件')) {
      // 提醒横幅由 reminders.due（40）流负责，邮件副本不重复横幅
      return '';
    }
    return NotifKind.SYSTEM;
  }

  /** 同类多条合并一条横幅（正文取首条标题，多条追加条数；开关关闭由 BannerCenter 跳过） */
  private publishMailBanner(kind: string, title: string, mails: MailInfo[]): void {
    if (mails.length === 0) {
      return;
    }
    const text: string = mails.length > 1
      ? `${mails[0].title}（${mails.length} 条）`
      : mails[0].title;
    BannerCenter.publish(kind, title, text, 'notifBanner');
  }

  /** 弹窗保持 3 秒后自动关闭；期间又送达新提醒则重置计时 */
  private schedulePopupAutoClose(): void {
    this.cancelPopupAutoClose();
    this.popupTimer = setTimeout(() => {
      this.popupTimer = -1;
      this.reminderPopupVisible = false;
      hilog.info(0x0000, 'testTag', 'reminder popup auto-close');
    }, 3000);
  }

  private cancelPopupAutoClose(): void {
    if (this.popupTimer >= 0) {
      clearTimeout(this.popupTimer);
      this.popupTimer = -1;
    }
  }

  /** 点击确定/遮罩：取消自动关闭并立即收起 */
  private onReminderConfirm(): void {
    this.cancelPopupAutoClose();
    this.reminderPopupVisible = false;
    hilog.info(0x0000, 'testTag', 'reminder popup confirm-close');
  }

  build() {
    Stack() {
      Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          SchedulePage()
            .visibility(this.currentTab === 0 ? Visibility.Visible : Visibility.Hidden)
          PetPage()
            .visibility(this.currentTab === 1 ? Visibility.Visible : Visibility.Hidden)
          DiscoverPage()
            .visibility(this.currentTab === 2 ? Visibility.Visible : Visibility.Hidden)
          ProfilePage()
            .visibility(this.currentTab === 3 ? Visibility.Visible : Visibility.Hidden)
        }
        .layoutWeight(1)
        .width('100%')

        BottomNav({
          current: this.currentTab,
          onTab: (index: number) => {
            this.currentTab = index;
            // 进 tab 即广播该页刷新（再点当前 tab 视为手动刷新）
            this.bumpTabRefresh(index);
            // 进宠物 tab：触发问候与积分折算（宠物页只认这个令牌）
            if (index === 1) {
              AppStorage.setOrCreate('petShowToken',
                (AppStorage.get<number>('petShowToken') ?? 0) + 1);
            }
          },
          onCreate: () => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/CreatePage' });
          }
        })
      }
      .width('100%')
      .height('100%')

      ReminderPopup({
        visible: this.reminderPopupVisible,
        reminders: this.dueReminders,
        weatherTip: this.reminderWeatherTip,
        onConfirm: () => {
          this.onReminderConfirm();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
