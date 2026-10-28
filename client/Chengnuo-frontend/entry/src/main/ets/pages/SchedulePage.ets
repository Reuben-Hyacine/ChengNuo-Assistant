import { appStore } from '../store/AppStore';
import { CalendarDay, CardKind, CardStatus, Postcard, TaskCard } from '../model/Types';
import { Theme } from '../common/Theme';
import { PageHeader } from '../components/PageHeader';
import { Card } from '../components/Card';
import { MonthCalendar } from '../components/Calendar';
import { WeatherCard } from '../components/WeatherCard';
import { EmptyState } from '../components/EmptyState';
import { PostcardCard, PostcardModal, ShredOverlay } from '../components/PostcardModal';
import { BirthdayPopup } from '../components/BirthdayPopup';
import { ServerGateway } from '../net/ServerGateway';
import {
  CardExtendOutcome, CompleteCardOutcome, LibraryEntryInfo, LibraryListOutcome, MessageOutcome,
  PostcardListOutcome, PostcardPullOutcome, PostcardRecordInfo, PulledPostcardInfo, ReminderInfo,
  RemindersOutcome, WeatherOutcome, WrittenCardInfo,
  friendlyTime, splitParticipants
} from '../net/ServerModels';
import { postcardStore, PostcardRecord } from '../store/PostcardStore';
import { groupChatStore } from '../store/GroupChatStore';
import { petStore, petPointsOfTime } from '../store/PetStore';
import { birthdayStore, isBirthdayDay } from '../store/BirthdayStore';
import { CountdownRow, countdownStore, sortedRowsOf } from '../store/CountdownStore';
import { Backend, ProfileRecord } from '@chengnuo/backend';
import { WeatherMark } from '../common/WeatherMark';
import { formProvider, formBindingData } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { FormCardData, FormIds, LockAction } from '../form/FormCardData';
import { tr, trf } from '../common/I18n';

/**
 * 日程页：自绘月历 + 当日安排
 * 卡片来源 = 服务器卡片库（groups.list 54：我创建/加入的卡片组，含私人卡与公开协作卡）；
 * 服务器侧已完成的卡不再出现在月历与当日安排（完成即归档为明信片）
 * 完成消卡 → 后端 AI 明信片（62 顺带出稿、客户端长期保存）；当日安排区用与卡片同尺寸的明信片顶替消失的卡
 * 明信片条目右上角 ✕ 确认后删除（客户端库记录走官方 DELETE 端点，本地保存的记录改端侧明信片库）
 * 完成/删除组内卡片后广播好友页刷新「我的卡片组」；若该组因此再无任何卡片（54 零条目）→ 顺带删除空组（55）
 * 月历头 🎂 生日入口：读个人空间记录（ProfileRecord.birthday），生日当天进页/回前台弹特别祝福（每天一次）
 */
@Component
export struct SchedulePage {
  @StorageProp('appLang') appLang: string = 'zh';
  @State allCards: TaskCard[] = [];
  @State selectedDate: string = '';
  @State eventDates: string[] = [];
  @State postcardDates: string[] = [];
  @State shredVisible: boolean = false;
  @State shreddingCard: TaskCard = new TaskCard();
  @State postcardVisible: boolean = false;
  @State activePostcard: Postcard = new Postcard();
  @State postcardMode: string = 'save';
  @State postcardIsoDate: string = '';
  @State isRefreshing: boolean = false;
  @State searchActive: boolean = false;
  @State keyword: string = '';
  /** 日历块卡片需要的高度 = 月历顶块实测高 + 日期格 6×59 + 卡片上下内边距 14×2；
   *  Swiper 定高用（天气块随日历块高度拉伸，左右滑动不跳变）。旧实现直接量卡片自身高度，
   *  但卡片在定高 Swiper 内会被压到与 Swiper 同高（循环测量恒等于旧值 360），第 6 行日期格被裁
   *  （如 2027-01-31 在第 6 行整格不显示）；现改为量月历顶块（不受 Swiper 定高污染）推算 */
  @State calendarCardHeight: number = 0;
  /** 日历 ↔ 倒计时 ↔ 天气 Swiper 当前页（0=日历 1=倒计时 2=天气；底部红点指示器高亮当前页、提示可左右滑动） */
  @State calWeatherIndex: number = 0;
  /** 月历右滑页展示的最近倒计时（null = 暂无记录） */
  @State cdNearest: CountdownRow | null = null;
  /** 倒计时数据版本（AppStorage；倒计时页增删改自增 → 刷新右滑预览） */
  @StorageProp('countdownStamp') @Watch('onCountdownStampChange') countdownStamp: number = 0;
  /** 打卡记录（`${cardId}|${isoDate}`，AppStore 副本）：重复卡非末日只记当日已完成 */
  @State checkinKeys: string[] = [];
  /** 用户生日（'YYYY-MM-DD'，个人空间记录镜像；月历 🎂 标与生日祝福共用；空串未设置） */
  @StorageProp('userBirthday') userBirthday: string = '';
  /** 生日当天特别祝福弹窗（每天一次，BirthdayStore 去重） */
  @State birthdayVisible: boolean = false;
  /** 生日保存进行中（防重复提交：本地已存，服务器 91 推送中） */
  private birthdaySaving: boolean = false;

  /** 62 完成返回里顺带带回的后端 AI 明信片（碎卡动画结束时展示；null = 本地卡或 AI 出稿失败） */
  private pendingPostcard: PostcardRecordInfo | null = null;
  /** 客户端明信片库（GET /api/postcards：完成卡片时后端 AI 出稿、客户端长期保存的记录） */
  @State clientPostcards: PostcardRecordInfo[] = [];
  /** 翻面确认：完成/删除按钮广播目标卡片翻到背面「确定」，点卡片=翻回并执行，点外部=翻回取消 */
  @State flipCardId: string = '';
  @State flipAction: string = '';
  /** 翻面卡片背面停留期间的全屏遮罩（命中判定用页面坐标缓存） */
  @State flipGuardActive: boolean = false;
  private flipRectX: number = 0;
  private flipRectY: number = 0;
  private flipRectW: number = 0;
  private flipRectH: number = 0;
  /** 延时面板（67）：目标卡 + 提交中标志 + 自定义时间输入 */
  @State extendVisible: boolean = false;
  @State extendTarget: TaskCard = new TaskCard();
  @State extendBusy: boolean = false;
  @State extendCustomText: string = '';
  /** 未来 7 天即将到来的提醒（reminders.upcoming 41，不消耗） */
  @State upcoming: ReminderInfo[] = [];
  private idSeq: number = 0;
  private searchSeq: number = 0;
  /** 主框架刷新广播（返回主框架 / 切回日程 tab 时自增）：页面保活不走 aboutToAppear，靠此重拉服务器 */
  @StorageProp('scheduleRefreshToken') @Watch('onRefreshTokenChange') refreshToken: number = 0;
  /** 锁屏卡片 router 动作（EntryAbility 写入：checkin=自动打卡；open 只落到日程页），进入页面/变化时消费 */
  @StorageProp('lockCardAction') @Watch('onLockCardActionChange') lockCardAction: string = '';
  /** 天气拉取成功广播（WeatherCard 写入）：天气话术可能变化，重推锁屏卡片保持桌面卡一致 */
  @StorageProp('weatherStamp') @Watch('onWeatherStampChange') weatherStamp: number = 0;

  aboutToAppear(): void {
    const now: Date = new Date();
    this.selectedDate = this.isoOf(now);
    this.allCards = [];
    this.clientPostcards = [];
    this.postcardDates = this.mergedPostcardDates();
    this.checkinKeys = appStore.checkinKeys.slice(0);
    this.refreshEventDates();
    this.loadBirthday();
    this.checkBirthdayGreeting();
    this.loadSchedule();
    this.refreshCdNearest();
    this.consumeLockCardAction();
  }

  /** 刷新月历右滑页的最近倒计时（倒计时页增删改 → countdownStamp 自增触发 @Watch） */
  private refreshCdNearest(): void {
    const rows: CountdownRow[] = sortedRowsOf(appStore.getAccount(), this.isoOf(new Date()));
    this.cdNearest = rows.length > 0 ? rows[0] : null;
  }

  private onCountdownStampChange(): void {
    this.refreshCdNearest();
  }

  /** 预览卡最近的倒计时是否带背景图（带 = 卡片改图片全铺 + 暗色渐变 + 白字） */
  private cdHasBg(): boolean {
    return this.cdNearest !== null && this.cdNearest.record.bg.length > 0;
  }

  /** 收到刷新广播：重拉服务器卡片库（创建页写卡返回等场景，当日安排保持最新）；
   *  顺带重取生日镜像（个人空间页可能改过生日）并检查生日祝福 */
  private onRefreshTokenChange(): void {
    this.loadBirthday();
    this.checkBirthdayGreeting();
    this.loadSchedule();
  }

  /** 锁屏卡片动作变化（应用存活时 router 热启动）：立即消费 */
  private onLockCardActionChange(): void {
    this.consumeLockCardAction();
  }

  /** 天气拉取成功：按最新快照重推锁屏卡片（桌面卡天气话术随之更新） */
  private onWeatherStampChange(): void {
    this.syncLockScreenCards();
  }

  /** 消费锁屏卡片动作：checkin 按携带的日期记录打卡（与应用内打卡同一键 `${cardId}|${iso}`），
   *  打卡后同步锁屏卡片（当日已打卡的重复卡让位给下一张）；open 无需执行（主框架已切到日程 tab） */
  private consumeLockCardAction(): void {
    if (this.lockCardAction.length === 0) {
      return;
    }
    const act: LockAction = LockAction.parse(this.lockCardAction);
    AppStorage.setOrCreate('lockCardAction', '');
    if (act.action !== 'checkin' || act.cardId.length === 0) {
      return;
    }
    const iso: string = act.date.length === 10 ? act.date : this.selectedDate;
    appStore.addCheckin(`${act.cardId}|${iso}`);
    this.checkinKeys = appStore.checkinKeys.slice(0);
    this.getUIContext().getPromptAction().showToast({ message: tr('已打卡 ✓') });
    this.syncLockScreenCards();
  }

  /** 锁屏卡片主动同步：数据变化（拉取/打卡/完成/删除/延时）后按当前卡片库重推载荷
   *  （已添加的锁屏卡片实例存 files/lock-card-ids.txt，与卡片进程共享沙箱）；无实例时静默跳过 */
  private async syncLockScreenCards(): Promise<void> {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    const ids: string[] = FormIds.list(ctx);
    if (ids.length === 0) {
      return;
    }
    const todayIso: string = this.isoOf(new Date());
    const snapshot: TaskCard[] = [];
    this.allCards.forEach((c: TaskCard) => {
      const copy: TaskCard = c.cloneWithId(c.id);
      const active: string = FormCardData.nextActiveDate(copy, todayIso);
      if (active.length === 10 && this.checkinKeys.indexOf(`${c.id}|${active}`) >= 0) {
        copy.status = CardStatus.Done;
      }
      snapshot.push(copy);
    });
    const next: TaskCard | undefined = FormCardData.pickNextCard(snapshot, todayIso);
    const payload: Record<string, Object> = FormCardData.buildPayload(next, appStore.getAccount(), '', 0);
    const formInfo: formBindingData.FormBindingData = formBindingData.createFormBindingData(payload);
    for (let i = 0; i < ids.length; i++) {
      formProvider.updateForm(ids[i], formInfo).catch((): void => {
      });
    }
  }

  /** 拉取服务器卡片库（54：我创建/加入的卡片组拍平），与本地快捷卡合并；keyword 非空时在网关本地按标题/地点/参与人过滤；
   *  同时拉取未来 7 天提醒预告（41） */
  private async loadSchedule(keyword?: string): Promise<void> {
    if (!appStore.serverOnline) {
      return;
    }
    const lib: LibraryListOutcome = await ServerGateway.myLibraryList(keyword);
    if (!lib.ok) {
      return;
    }
    const ups: RemindersOutcome = await ServerGateway.remindersUpcoming();
    this.upcoming = ups.ok ? ups.reminders : [];
    const locals: TaskCard[] = [];
    this.allCards.forEach((c: TaskCard) => {
      if (c.id.indexOf('srv-g') !== 0) {
        locals.push(c);
      }
    });
    const servers: TaskCard[] = [];
    for (let i = 0; i < lib.entries.length; i++) {
      const mapped: TaskCard | null = this.serverCardOf(lib.entries[i]);
      if (mapped !== null) {
        servers.push(mapped);
      }
    }
    this.allCards = [...locals, ...servers];
    this.refreshEventDates();
    // 明信片库与卡片库同源刷新（62 完成时后端 AI 出稿、客户端长期保存的记录）
    this.refreshPostcards();
    // 全量刷新（非搜索过滤）后同步锁屏卡片，保持锁屏与日程一致
    if (keyword === undefined || keyword.trim().length === 0) {
      this.syncLockScreenCards();
    }
    // 翻面等待确认的卡片若在刷新后消失，收起遮罩避免整页被遮罩卡死
    if (this.flipGuardActive) {
      let stillThere: boolean = false;
      for (let i = 0; i < this.allCards.length; i++) {
        if (this.allCards[i].id === this.flipCardId) {
          stillThere = true;
          break;
        }
      }
      if (!stillThere) {
        this.flipGuardActive = false;
        this.flipCardId = '';
        this.flipAction = '';
      }
    }
  }

  /** 卡片库条目（groups.list 54 拍平）→ 日程卡视图；无有效日期的卡不进日历；
   *  服务器侧已完成的卡直接排除（完成即归档为明信片，从月历/当日安排/搜索消失） */
  private serverCardOf(entry: LibraryEntryInfo): TaskCard | null {
    const card: WrittenCardInfo = entry.card;
    if (entry.completed) {
      return null;
    }
    if (card.time.length < 10) {
      return null;
    }
    const title: string = card.event.length > 0 ? card.event
      : (card.purpose.length > 0 ? card.purpose : tr('未命名卡片'));
    const participants: string[] = splitParticipants(card.participant);
    const id: string = `srv-g${entry.groupId}-${card.index}`;
    const c: TaskCard = TaskCard.of(id, title, CardKind.Schedule, CardStatus.Set,
      card.time.length >= 16 ? card.time.substring(11, 16) : tr('时间待定'),
      card.location.length > 0 ? card.location : tr('地点待定'),
      entry.library === 'public' ? '🤝' : '📅');
    c.dateText = card.time.substring(0, 10);
    c.groupId = entry.groupId;
    c.isOwner = entry.isOwner;
    c.completableBy = card.completableBy;
    c.tags = card.tags.slice();
    // 重复卡区间：time=首日，repeatUntil=末日（早于首日或非法时视为单日卡）
    const repeatEnd: string = card.repeatUntil.length >= 10 ? card.repeatUntil.substring(0, 10) : '';
    c.repeatEndDate = repeatEnd >= c.dateText ? repeatEnd : '';
    if (entry.library === 'public' && participants.length > 0) {
      c.note = trf('与 {0} 一起', participants.join('、'));
    }
    if (appStore.doneCardIds.indexOf(id) >= 0) {
      c.status = CardStatus.Done;
    }
    return c;
  }

  /** 下拉刷新：重拉服务器卡片库，动画至少展示 600ms 再收起 */
  private handleRefresh(): void {
    const start: number = Date.now();
    this.loadSchedule().then((): void => {
      const rest: number = Math.max(600 - (Date.now() - start), 0);
      setTimeout(() => {
        this.isRefreshing = false;
      }, rest);
    });
  }

  /** 页头搜索入口：进入搜索模式并刷新全量卡片 */
  private enterSearch(): void {
    this.searchActive = true;
    this.keyword = '';
    this.searchSeq += 1;
    this.loadSchedule();
  }

  /** 退出搜索模式：清空关键词并恢复全量列表 */
  private exitSearch(): void {
    this.searchActive = false;
    this.keyword = '';
    this.searchSeq += 1;
    this.loadSchedule();
  }

  /** 输入变化：界面即时本地过滤，350ms 后带关键词请求服务器搜索（seq 防抖：只保留最后一次输入） */
  private handleKeywordChange(value: string): void {
    this.keyword = value;
    this.searchSeq += 1;
    const seq: number = this.searchSeq;
    setTimeout(() => {
      if (seq !== this.searchSeq) {
        return;
      }
      const kw: string = this.keyword.trim();
      if (kw.length === 0) {
        this.loadSchedule();
      } else {
        this.loadSchedule(kw);
      }
    }, 350);
  }

  /** 回车提交：立即带关键词请求服务器搜索 */
  private handleSearchSubmit(): void {
    this.searchSeq += 1;
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      this.loadSchedule();
    } else {
      this.loadSchedule(kw);
    }
  }

  /** 搜索结果：全部卡片按标题/地点/参与人匹配关键词，按日期 + 时间排序 */
  private filteredCards(): TaskCard[] {
    const kw: string = this.keyword.trim().toLowerCase();
    const list: TaskCard[] = [];
    this.allCards.forEach((c: TaskCard) => {
      if (kw.length === 0 ||
        c.title.toLowerCase().indexOf(kw) >= 0 ||
        c.place.toLowerCase().indexOf(kw) >= 0 ||
        c.note.toLowerCase().indexOf(kw) >= 0) {
        list.push(c);
      }
    });
    list.sort((a: TaskCard, b: TaskCard): number => {
      if (a.dateText !== b.dateText) {
        return a.dateText < b.dateText ? -1 : 1;
      }
      if (a.timeText === b.timeText) {
        return 0;
      }
      return a.timeText < b.timeText ? -1 : 1;
    });
    return list;
  }

  /** 点击搜索结果：定位到卡片所在日期并退出搜索 */
  private handleSearchResultTap(c: TaskCard): void {
    if (c.dateText.length > 0) {
      this.selectedDate = c.dateText;
    }
    this.exitSearch();
  }

  private isoOf(d: Date): string {
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const dd: string = day < 10 ? `0${day}` : `${day}`;
    return `${d.getFullYear()}-${mm}-${dd}`;
  }

  private displayOfPlain(iso: string): string {
    const parts: string[] = iso.split('-');
    return trf('{0}月{1}日', Number(parts[1]), Number(parts[2]));
  }

  private displayOf(iso: string): string {
    const todayIso: string = this.isoOf(new Date());
    return trf('{0}{1}', this.displayOfPlain(iso), iso === todayIso ? tr(tr(' · 今天')) : '');
  }

  /** 提醒条目标题：事件名优先，回退目的 */
  private reminderTitleOf(r: ReminderInfo): string {
    return r.event.length > 0 ? r.event : (r.purpose.length > 0 ? r.purpose : tr('未命名日程'));
  }

  private refreshEventDates(): void {
    const dates: string[] = [];
    this.allCards.forEach((c: TaskCard) => {
      this.datesInRange(c).forEach((iso: string) => {
        if (dates.indexOf(iso) < 0) {
          dates.push(iso);
        }
      });
    });
    this.eventDates = dates;
  }

  /** 卡片占据的日期（月历红点）：单日卡 = 首日；重复卡 = 首日~末日逐日展开（上限 732 天防脏数据卡死） */
  private datesInRange(c: TaskCard): string[] {
    if (c.dateText.length !== 10) {
      return [];
    }
    if (c.repeatEndDate.length !== 10 || c.repeatEndDate <= c.dateText) {
      return [c.dateText];
    }
    const list: string[] = [];
    const end: Date = new Date(`${c.repeatEndDate}T00:00:00`);
    const cursor: Date = new Date(`${c.dateText}T00:00:00`);
    for (let i = 0; i < 732 && cursor.getTime() <= end.getTime(); i++) {
      list.push(this.isoOf(cursor));
      cursor.setDate(cursor.getDate() + 1);
    }
    return list;
  }

  /** 当日卡片，按时间先后排序（'时间待定' 排最后）；重复卡在首日~末日闭区间内每天出现，
   *  返回按当日打卡状态调整后的副本（当日已打卡 → Done） */
  private dayCards(): TaskCard[] {
    const list: TaskCard[] = [];
    this.allCards.forEach((c: TaskCard) => {
      if (this.cardShowsOnDate(c, this.selectedDate)) {
        const dayCard: TaskCard = c.cloneWithId(c.id);
        if (this.isDayDone(c, this.selectedDate)) {
          dayCard.status = CardStatus.Done;
        }
        list.push(dayCard);
      }
    });
    list.sort((a: TaskCard, b: TaskCard): number => {
      if (a.timeText === b.timeText) {
        return 0;
      }
      return a.timeText < b.timeText ? -1 : 1;
    });
    return list;
  }

  /** 卡片显示规则：单日卡只在 dateText 当天；重复卡在首日~末日闭区间内每天显示 */
  private cardShowsOnDate(c: TaskCard, iso: string): boolean {
    if (c.repeatEndDate.length !== 10 || c.dateText.length !== 10) {
      return c.dateText === iso;
    }
    return c.dateText <= iso && iso <= c.repeatEndDate;
  }

  /** 该卡在指定日期是否已完成：整卡已完成（服务器/本地）或当日已打卡 */
  private isDayDone(c: TaskCard, iso: string): boolean {
    if (c.status === CardStatus.Done) {
      return true;
    }
    return this.checkinKeys.indexOf(`${c.id}|${iso}`) >= 0;
  }

  /** 当前查看日是否该重复卡的末日：末日按钮为「完成」（碎卡动画+明信片），其余天为「打卡」 */
  private isFinalRepeatDay(c: TaskCard): boolean {
    return c.repeatEndDate.length !== 10 || this.selectedDate === c.repeatEndDate;
  }

  /** 打卡：重复卡非末日仅记录当日已完成，不执行碎卡动画与明信片 */
  private handleCheckIn(c: TaskCard): void {
    appStore.addCheckin(`${c.id}|${this.selectedDate}`);
    this.checkinKeys = appStore.checkinKeys.slice(0);
    this.getUIContext().getPromptAction().showToast({ message: tr('已打卡 ✓') });
    this.syncLockScreenCards();
  }

  /** 点日期：切换到当天并展示当日安排（明信片通过当日安排区的同尺寸明信片条目查看） */
  private handleDayTap(day: CalendarDay): void {
    this.selectedDate = day.dateText;
  }

  /** 读取个人空间生日 → AppStorage 镜像（月历「生日」红标与生日祝福共用） */
  private loadBirthday(): void {
    const record: ProfileRecord | null = Backend.getProfileRecord(appStore.getAccount());
    AppStorage.setOrCreate('userBirthday', record !== null ? record.birthday : '');
  }

  /** 主页月历 🎂 入口：系统日期弹窗选生日（生日当天有特别祝福，每年同月同日生效）；
   *  未设置时默认停在今天作参照，已设置时停在已存生日。
   *  end 取明天零点：selected==end（同一天）时选择器不生效、轮子会跌回起点（1900-01-31），
   *  推后一天让"今天"严格落在 (start, end) 区间内即可正常生效 */
  private openBirthdayPicker(): void {
    let selected: Date = new Date();
    if (this.userBirthday.length === 10) {
      const parts: string[] = this.userBirthday.split('-');
      const parsed: Date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
      if (!Number.isNaN(parsed.getTime())) {
        selected = parsed;
      }
    }
    const now: Date = new Date();
    const endAt: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
    this.getUIContext().showDatePickerDialog({
      start: new Date(1900, 0, 1),
      end: endAt,
      selected: selected,
      onDateAccept: (value: Date) => {
        this.saveBirthday(this.isoOf(value));
      }
    });
  }

  /** 保存生日：写个人空间本地副本（与「个人空间」页同一份记录，其余字段保持不动）+
   *  在线推服务器（91，失败不影响本机已生效）；当天恰好是生日则立即触发特别祝福 */
  private async saveBirthday(iso: string): Promise<void> {
    if (this.birthdaySaving) {
      return;
    }
    this.birthdaySaving = true;
    const account: string = appStore.getAccount();
    const record: ProfileRecord | null = Backend.getProfileRecord(account);
    const next: ProfileRecord = new ProfileRecord(account,
      record !== null ? record.gender : '', iso,
      record !== null ? record.signature : '',
      record !== null ? record.province : '', record !== null ? record.city : '',
      record !== null && record.hasAvatar, record !== null ? record.updatedAt : '');
    Backend.saveProfileRecord(next, undefined);
    AppStorage.setOrCreate('userBirthday', iso);
    AppStorage.setOrCreate('profileStamp', Date.now());
    this.getUIContext().getPromptAction().showToast({
      message: trf('生日已设置为 {0}，生日当天会有特别祝福 🎂', iso)
    });
    this.checkBirthdayGreeting();
    if (!appStore.serverOnline) {
      this.birthdaySaving = false;
      return;
    }
    const fields: Record<string, Object> = {
      'gender': next.gender,
      'birthday': iso,
      'signature': next.signature,
      'province': next.province,
      'city': next.city
    };
    const outcome: MessageOutcome = await ServerGateway.updateProfile(fields, 'keep', '');
    if (outcome.ok && Backend.isPersonalizationEnabled()) {
      await ServerGateway.syncUserInfoPut(fields);
    }
    this.birthdaySaving = false;
  }

  /** 生日当天进主页/回前台：弹特别祝福（BirthdayStore 记住当天已送，每天只弹一次） */
  private checkBirthdayGreeting(): void {
    const todayIso: string = this.isoOf(new Date());
    const birthday: string = AppStorage.get<string>('userBirthday') ?? '';
    if (!isBirthdayDay(birthday, todayIso)) {
      return;
    }
    const account: string = appStore.getAccount();
    if (birthdayStore.greetedOn(account) === todayIso) {
      return;
    }
    birthdayStore.markGreeted(account, todayIso);
    this.birthdayVisible = true;
  }

  /** 拉取客户端明信片库（GET /api/postcards）+ 参与者明信片中转（103），
   *  并重算月历 📮 角标日期（后端库 + 本地保存的合并） */
  private async refreshPostcards(): Promise<void> {
    if (!appStore.serverOnline) {
      this.clientPostcards = [];
      this.postcardDates = this.mergedPostcardDates();
      return;
    }
    const outcome: PostcardListOutcome = await ServerGateway.postcardsList();
    if (outcome.ok) {
      this.clientPostcards = outcome.postcards;
    }
    await this.pullParticipantPostcards();
    this.postcardDates = this.mergedPostcardDates();
  }

  /** 拉取参与者明信片（103，服务器中转、拉取即删）：新记录按 (date,title,text) 查重后合并进本地明信片库
   *  长期保存；clears（未完成卡被删除 57 时的 clear 墓碑）清理对应群的本地聊天记录 */
  private async pullParticipantPostcards(): Promise<void> {
    const outcome: PostcardPullOutcome = await ServerGateway.postcardsPull();
    if (!outcome.ok) {
      return;
    }
    const account: string = appStore.getAccount();
    const records: PostcardRecord[] = [];
    for (let i = 0; i < outcome.postcards.length; i++) {
      const pc: PulledPostcardInfo = outcome.postcards[i];
      const iso: string = this.pulledPostcardDateOf(pc);
      records.push(PostcardRecord.of(iso, this.displayOfPlain(iso),
        pc.event.length > 0 ? pc.event : tr('未命名卡片'), pc.text,
        postcardStore.countOf(account) % 2, '📮', '', '', pc.groupId, pc.groupName));
    }
    if (postcardStore.mergeMany(account, records) > 0) {
      this.notifyPostcardsChanged();
    }
    for (let i = 0; i < outcome.clears.length; i++) {
      groupChatStore.deleteThread(account, outcome.clears[i]);
    }
  }

  /** 参与者明信片归属日期：completedAt 完成时刻换算本地日期，解析不了回退卡片计划时间（time）的日期部分 */
  private pulledPostcardDateOf(pc: PulledPostcardInfo): string {
    if (pc.completedAt.length > 0) {
      const ts: number = Date.parse(pc.completedAt);
      if (!Number.isNaN(ts)) {
        return this.isoOf(new Date(ts));
      }
    }
    return pc.time.length >= 10 ? pc.time.substring(0, 10) : '';
  }

  /** 明信片归属日期（月历 📮 角标 / 当日安排）：后端记录按 createdAt 完成时刻换算本地日期，
   *  解析不了回退卡片计划时间（time）的日期部分 */
  private postcardDateOf(r: PostcardRecordInfo): string {
    if (r.createdAt.length > 0) {
      const ts: number = Date.parse(r.createdAt);
      if (!Number.isNaN(ts)) {
        return this.isoOf(new Date(ts));
      }
    }
    return r.time.length >= 10 ? r.time.substring(0, 10) : '';
  }

  /** 月历 📮 角标日期：后端明信片库 + 本地手动保存的明信片合并去重 */
  private mergedPostcardDates(): string[] {
    const dates: string[] = [];
    this.clientPostcards.forEach((r: PostcardRecordInfo) => {
      const iso: string = this.postcardDateOf(r);
      if (iso.length > 0 && dates.indexOf(iso) < 0) {
        dates.push(iso);
      }
    });
    postcardStore.datesOf(appStore.getAccount()).forEach((iso: string) => {
      if (dates.indexOf(iso) < 0) {
        dates.push(iso);
      }
    });
    return dates;
  }

  /** 指定日期的全部明信片：后端明信片库（62 完成 AI 出稿、客户端长期保存）+ 本地手动保存的记录；
   *  日期旁带生成当天天气（服务器记录回查端侧按日映射，本地记录随记录保存） */
  private postcardsOfDate(iso: string): Postcard[] {
    const list: Postcard[] = [];
    const dayWeather: string[] = postcardStore.dayWeatherOf(appStore.getAccount(), iso);
    this.clientPostcards.forEach((r: PostcardRecordInfo) => {
      if (this.postcardDateOf(r) === iso) {
        list.push(Postcard.of(`pcs-${r.id}`, this.displayOfPlain(iso),
          r.event.length > 0 ? r.event : tr('未命名卡片'), r.text, r.id % 2, '📮',
          dayWeather[0], dayWeather[1], r.groupId, r.groupName));
      }
    });
    const records: PostcardRecord[] = postcardStore.listOf(appStore.getAccount());
    for (let i = 0; i < records.length; i++) {
      if (records[i].date === iso) {
        list.push(Postcard.of(`pc-${i}`, records[i].dateText, records[i].title, records[i].text,
          records[i].gradientIndex, records[i].emoji, records[i].weatherText, records[i].weatherEmoji,
          records[i].groupId, records[i].groupName));
      }
    }
    return list;
  }

  /** 查看历史明信片 */
  private openPostcard(p: Postcard): void {
    this.activePostcard = p;
    this.postcardMode = 'view';
    this.postcardVisible = true;
  }

  /** 删除确认：明信片是回忆，删前二次确认 */
  private confirmDeletePostcard(p: Postcard): void {
    this.getUIContext().showAlertDialog({
      title: tr('删除明信片'),
      message: trf('「{0}」删除后无法恢复，确定删除吗？', p.title),
      primaryButton: {
        value: tr('先留着'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: tr('删除'),
        fontColor: $r('app.color.error'),
        action: (): void => {
          this.deletePostcard(p);
        }
      }
    });
  }

  /** 删除明信片：客户端库记录（pcs-*）走官方 DELETE 端点；本地保存的记录（pc-*）直接改端侧明信片库。
   *  关联群的明信片删除后同步清掉该群本地聊天记录（聊天跟随明信片存亡） */
  private deletePostcard(p: Postcard): void {
    if (p.id.indexOf('pcs-') === 0) {
      const id: number = Number(p.id.substring(4));
      if (!Number.isNaN(id)) {
        this.deleteClientPostcard(id, p.groupId);
      }
      return;
    }
    if (postcardStore.remove(appStore.getAccount(), this.selectedDate, p.title, p.blessing)) {
      if (p.groupId > 0) {
        groupChatStore.deleteThread(appStore.getAccount(), p.groupId);
      }
      this.postcardDates = this.mergedPostcardDates();
      this.getUIContext().getPromptAction().showToast({ message: tr('明信片已删除') });
    }
  }

  private async deleteClientPostcard(id: number, groupId: number): Promise<void> {
    const outcome: MessageOutcome = await ServerGateway.postcardsDelete(id);
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    if (groupId > 0) {
      groupChatStore.deleteThread(appStore.getAccount(), groupId);
    }
    this.getUIContext().getPromptAction().showToast({ message: tr('明信片已删除') });
    await this.refreshPostcards();
    this.notifyPostcardsChanged();
  }

  /** 客户端明信片库变化（新增/删除）后自增 stamp：「我的」页监听后重取最近一张 */
  private notifyPostcardsChanged(): void {
    const stamp: number = AppStorage.get<number>('postcardStamp') ?? 0;
    AppStorage.setOrCreate('postcardStamp', stamp + 1);
  }

  /** 周报数据变化（完成/延时）后自增 stamp：「我的」页监听后重取周报 */
  private notifyWeekChanged(): void {
    const stamp: number = AppStorage.get<number>('weekReportStamp') ?? 0;
    AppStorage.setOrCreate('weekReportStamp', stamp + 1);
  }

  /** 我是否该卡的发起者：完成/删除按钮的显示条件（本地演示卡视为自己的卡；
   *  服务器卡完成者固定为发起者本人，只有发起者能完成） */
  private isCardInitiator(c: TaskCard): boolean {
    if (c.id.indexOf('srv-g') !== 0) {
      return true;
    }
    return c.isOwner;
  }

  /** 完成：服务器卡走 groups.complete-card（62，仅发起者可见此按钮）——客户端本地化后一步完成
   *  「标记完成 + 后端 AI 出稿明信片并长期落库 + 出稿成功即把该卡从卡片组删除（归档）」，成功后再走碎卡动画；
   *  本地演示卡保持纯本地动画 */
  private handleComplete(c: TaskCard): void {
    if (c.id.indexOf('srv-g') === 0 && c.groupId > 0) {
      this.completeServerCard(c);
      return;
    }
    this.startShred(c);
  }

  private async completeServerCard(c: TaskCard): Promise<void> {
    const parts: string[] = c.id.split('-');
    const cardIndex: number = Number(parts.length === 3 ? parts[2] : 'NaN');
    if (Number.isNaN(cardIndex)) {
      this.startShred(c);
      return;
    }
    // 62 含 AI 出稿可能等待数秒，先给个提示再请求
    this.getUIContext().getPromptAction().showToast({ message: tr('正在兑现承诺…') });
    const outcome: CompleteCardOutcome = await ServerGateway.groupsCompleteCard(c.groupId, cardIndex);
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    // 后端 AI 明信片已随 62 生成并长期保存在客户端明信片库（outcome.postcard 为 null 表示出稿失败）
    this.pendingPostcard = outcome.postcard;
    // 出稿成功即删卡归档（54 再看不到该卡）：此刻先把功能上线前的历史明信片一次性补记进宠物积分账本
    // （新明信片尚未入库不会重复），再把本次完成按计划时长记入账本；出稿失败的卡留在组内，由宠物页经 54 补记
    if (outcome.postcard !== null) {
      const account: string = appStore.getAccount();
      const records: PostcardRecord[] = postcardStore.listOf(account);
      const dates: string[] = [];
      for (let i = 0; i < records.length; i++) {
        dates.push(records[i].date);
      }
      petStore.seedLegacyOnce(account, dates);
      if (outcome.postcard.time.length > 0) {
        petStore.addEarned(account, `pc-${outcome.postcard.id}`, petPointsOfTime(outcome.postcard.time));
      }
    }
    // 62 成功 → 客户端周报库本周完成数 +1，通知「我的」页重取周报
    this.notifyWeekChanged();
    // 该卡已从组里移除：组可能因此变空 → 顺带清理空组并同步好友页「我的卡片组」
    this.cleanupGroupAndSyncFriends(c.groupId);
    this.startShred(c);
  }

  private startShred(c: TaskCard): void {
    this.shreddingCard = c;
    this.shredVisible = true;
    this.getUIContext().getPromptAction().showToast({ message: tr('承诺兑现，看着它变成明信片 ✨') });
  }

  /** 删除：点「删除」按钮先翻面确认（背面点卡片后进入这里），服务器卡回传服务器（57/15），本地卡直接移除 */
  private handleTear(c: TaskCard): void {
    const isServerCard: boolean = c.id.indexOf('srv-g') === 0 && c.groupId > 0;
    if (!isServerCard) {
      this.removeLocalCard(c);
      this.getUIContext().getPromptAction().showToast({ message: tr('已删除，不再出现在日程里') });
      return;
    }
    this.tearServerCard(c);
  }

  private async tearServerCard(c: TaskCard): Promise<void> {
    const parts: string[] = c.id.split('-');
    const cardIndex: number = Number(parts.length === 3 ? parts[2] : 'NaN');
    if (Number.isNaN(cardIndex)) {
      this.removeLocalCard(c);
      return;
    }
    const outcome: MessageOutcome = c.isOwner
      ? await ServerGateway.groupRemoveCard(c.groupId, cardIndex)
      : await ServerGateway.cardsLeave(c.groupId, cardIndex);
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    this.removeLocalCard(c);
    this.getUIContext().getPromptAction().showToast({ message: outcome.message });
    // 卡片已从组里删除/退出：同步好友页「我的卡片组」；创建者删卡可能清空整组 → 顺带清理空组；
    // 创建者删除的卡不再兑现（无明信片）→ 该群本地聊天记录一并清掉
    if (c.isOwner) {
      groupChatStore.deleteThread(appStore.getAccount(), c.groupId);
      this.cleanupGroupAndSyncFriends(c.groupId);
    } else {
      this.notifyFriendsChanged();
    }
  }

  private removeLocalCard(c: TaskCard): void {
    const next: TaskCard[] = [];
    this.allCards.forEach((x: TaskCard) => {
      if (x.id !== c.id) {
        next.push(x);
      }
    });
    this.allCards = next;
    this.refreshEventDates();
    this.syncLockScreenCards();
  }

  /** 好友页「我的卡片组」同步：完成/删除服务器卡片后自增广播令牌（好友页保活不走 aboutToAppear，靠它重拉 54） */
  private notifyFriendsChanged(): void {
    AppStorage.setOrCreate('friendsRefreshToken',
      (AppStorage.get<number>('friendsRefreshToken') ?? 0) + 1);
  }

  /** 卡片从组移除后：54 重拉确认该组已无任何卡片条目（含已完成归档卡）→ 55 删除空组；
   *  54/55 失败静默忽略（网络抖动/组已不存在/非创建者），最后无论如何广播好友页刷新 */
  private async cleanupGroupAndSyncFriends(groupId: number): Promise<void> {
    if (groupId > 0) {
      const lib: LibraryListOutcome = await ServerGateway.myLibraryList();
      if (lib.ok) {
        let remaining: number = 0;
        for (let i = 0; i < lib.entries.length; i++) {
          if (lib.entries[i].groupId === groupId) {
            remaining += 1;
          }
        }
        if (remaining === 0) {
          await ServerGateway.groupsDelete(groupId);
        }
      }
    }
    this.notifyFriendsChanged();
  }

  /** 完成/删除按钮：广播目标卡片翻到背面「确定」等待确认（点卡片=翻回并执行，点外部=翻回取消）。
   *  走 AppStorage 广播而非 @Prop 传参：V1 ForEach 同 key 复用的组件收不到参数更新，传参卡片永不翻面 */
  private armFlip(c: TaskCard, action: string): void {
    this.flipCardId = c.id;
    this.flipAction = action;
    AppStorage.setOrCreate('flipArmTargetId', c.id);
    AppStorage.setOrCreate('flipArmToken', (AppStorage.get<number>('flipArmToken') ?? 0) + 1);
  }

  /** Card.onFlipChange：卡片翻到背面升起全屏遮罩（缓存其页面坐标），翻回后收起 */
  private handleFlipChange(cardId: string, back: boolean, x: number, y: number, w: number, h: number): void {
    if (back) {
      this.flipRectX = x;
      this.flipRectY = y;
      this.flipRectW = w;
      this.flipRectH = h;
      this.flipGuardActive = true;
      return;
    }
    this.flipGuardActive = false;
  }

  /** 背面点了卡片本体（翻回动画结束 onSequenceDone）：执行待确认动作（完成/删除） */
  private handleFlipConfirm(card: TaskCard): void {
    const action: string = this.flipAction;
    this.flipCardId = '';
    this.flipAction = '';
    if (action === 'tear') {
      this.handleTear(card);
      return;
    }
    this.handleComplete(card);
  }

  /** 遮罩点击：落在卡片区域内 → 广播确定；区域外 → 广播取消翻回 */
  private handleGuardTap(e: ClickEvent): void {
    const insideX: boolean = e.x >= this.flipRectX && e.x <= this.flipRectX + this.flipRectW;
    const insideY: boolean = e.y >= this.flipRectY && e.y <= this.flipRectY + this.flipRectH;
    if (insideX && insideY) {
      AppStorage.setOrCreate('flipConfirmToken', (AppStorage.get<number>('flipConfirmToken') ?? 0) + 1);
    } else {
      AppStorage.setOrCreate('flipCancelToken', (AppStorage.get<number>('flipCancelToken') ?? 0) + 1);
    }
  }

  /** 打开延时面板（67）：快捷档基于卡片当前开始时间平移，也可输入绝对时间 */
  private openExtendPanel(c: TaskCard): void {
    this.extendTarget = c;
    this.extendCustomText = '';
    this.extendBusy = false;
    this.extendVisible = true;
  }

  private closeExtendPanel(): void {
    if (this.extendBusy) {
      return;
    }
    this.extendVisible = false;
  }

  /** 解析 "YYYY-MM-DD HH:mm"，非法返回 null */
  private parseYyyyMmDdHm(text: string): Date | null {
    if (text.length !== 16 || text.charAt(10) !== ' ') {
      return null;
    }
    const dParts: string[] = text.substring(0, 10).split('-');
    const tParts: string[] = text.substring(11, 16).split(':');
    if (dParts.length !== 3 || tParts.length !== 2) {
      return null;
    }
    if (dParts[0].length !== 4 || dParts[1].length !== 2 || dParts[2].length !== 2
      || tParts[0].length !== 2 || tParts[1].length !== 2) {
      return null;
    }
    const year: number = Number(dParts[0]);
    const month: number = Number(dParts[1]);
    const day: number = Number(dParts[2]);
    const hour: number = Number(tParts[0]);
    const minute: number = Number(tParts[1]);
    if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day)
      || Number.isNaN(hour) || Number.isNaN(minute)) {
      return null;
    }
    if (hour > 23 || minute > 59 || month < 1 || month > 12 || day < 1) {
      return null;
    }
    const dt: Date = new Date(year, month - 1, day, hour, minute, 0, 0);
    if (dt.getFullYear() !== year || dt.getMonth() !== month - 1 || dt.getDate() !== day) {
      return null;
    }
    return dt;
  }

  /** 延时基准时刻：卡片当前开始时间（dateText + timeText），解析不了回退当前时刻 */
  private extendBaseOf(c: TaskCard): Date {
    const parsed: Date | null = this.parseYyyyMmDdHm(`${c.dateText} ${c.timeText}`);
    if (parsed !== null) {
      return parsed;
    }
    return new Date();
  }

  private pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 服务器要的绝对时间 "YYYY-MM-DD HH:mm" */
  private fmtExtendTime(dt: Date): string {
    return `${dt.getFullYear()}-${this.pad2(dt.getMonth() + 1)}-${this.pad2(dt.getDate())}`
      + ` ${this.pad2(dt.getHours())}:${this.pad2(dt.getMinutes())}`;
  }

  /** 快捷档展示 "M月d日 HH:mm" */
  private fmtExtendCn(dt: Date): string {
    return trf('{0}月{1}日 {2}:{3}', dt.getMonth() + 1, dt.getDate(), this.pad2(dt.getHours()), this.pad2(dt.getMinutes()));
  }

  /** 快捷档：基准时刻 + minutes 分钟后的服务器格式时间 */
  private extendOptionTime(c: TaskCard, minutes: number): string {
    return this.fmtExtendTime(new Date(this.extendBaseOf(c).getTime() + minutes * 60000));
  }

  /** 快捷档：基准时刻 + minutes 分钟后的中文展示 */
  private extendOptionCn(c: TaskCard, minutes: number): string {
    return this.fmtExtendCn(new Date(this.extendBaseOf(c).getTime() + minutes * 60000));
  }

  /** 提交延时（67）：创建者立即改期并刷新日程；被指定的完成者向创建者提交申请，等待审批 */
  private async submitExtend(c: TaskCard, newTime: string): Promise<void> {
    if (this.extendBusy) {
      return;
    }
    const parts: string[] = c.id.split('-');
    const cardIndex: number = Number(parts.length === 3 ? parts[2] : 'NaN');
    if (Number.isNaN(cardIndex) || c.groupId <= 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('该卡片无法延时') });
      return;
    }
    this.extendBusy = true;
    const outcome: CardExtendOutcome = await ServerGateway.cardsExtend(c.groupId, cardIndex, newTime);
    this.extendBusy = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    // 67 成功 → 客户端周报库本周延时数 +1（无论立即改期还是等审批），通知「我的」页重取周报
    this.notifyWeekChanged();
    this.extendVisible = false;
    if (outcome.mode === 'applied') {
      this.getUIContext().getPromptAction().showToast({
        message: outcome.message.length > 0 ? outcome.message : trf('已改期至 {0}', outcome.time)
      });
      this.loadSchedule();
    } else {
      this.getUIContext().getPromptAction().showToast({
        message: outcome.message.length > 0 ? outcome.message : tr('已提交延时申请，等待发起者同意 ⏳')
      });
    }
  }

  /** 自定义时间提交：校验 "YYYY-MM-DD HH:mm" 后走 67 */
  private submitExtendCustom(): void {
    const parsed: Date | null = this.parseYyyyMmDdHm(this.extendCustomText.trim());
    if (parsed === null) {
      this.getUIContext().getPromptAction().showToast({ message: tr('时间格式：2026-10-05 09:00') });
      return;
    }
    this.submitExtend(this.extendTarget, this.fmtExtendTime(parsed));
  }

  private blessingOf(c: TaskCard): string {
    if (c.kind === CardKind.Schedule) {
      return tr('按时赴约的你，正在把生活过成想要的样子。');
    }
    if (c.kind === CardKind.Task) {
      return tr('又兑现一个对自己的承诺，真了不起。');
    }
    return tr('认真对待每件事的人，生活也会认真回应。');
  }

  private handleShredFinished(card: TaskCard): void {
    const next: TaskCard[] = [];
    this.allCards.forEach((c: TaskCard) => {
      if (c.id !== card.id) {
        next.push(c);
      }
    });
    this.allCards = next;
    this.refreshEventDates();
    this.syncLockScreenCards();
    appStore.addDoneCard(card.id);
    this.shredVisible = false;

    const iso: string = this.selectedDate;
    const pending: PostcardRecordInfo | null = this.pendingPostcard;
    this.pendingPostcard = null;
    if (pending === null) {
      // 本地演示卡 / AI 出稿失败：沿用本地祝福语，仍可手动存入本地明信片库
      this.showPostcardModal(card, this.blessingOf(card), iso, 'save');
      return;
    }
    // 62 已带回后端 AI 正文，且明信片已长期保存在客户端明信片库：直接展示，收下即得
    this.showPostcardModal(card, pending.text, iso, 'view');
    // 明信片库已新增记录：重拉让当日安排的同尺寸明信片条目与月历 📮 角标立即出现，
    // 并通知「我的」页重取最近一张
    this.refreshPostcards();
    this.notifyPostcardsChanged();
  }

  /** 组装并弹出明信片（正文 = 62 后端 AI 文本或本地祝福语；渐变色六款按明信片库数量轮换；
   *  mode='view'（后端已自动落库）只展示，mode='save' 可手动存入本地明信片库；
   *  日期旁由程序自动附加生成当天天气（晴雨等，不涉及 AI）：直接取自天气快照当日实况/预报 */
  private showPostcardModal(card: TaskCard, text: string, iso: string, mode: string): void {
    this.idSeq += 1;
    const weather: string[] = this.postcardDayWeather();
    const postcard: Postcard = Postcard.of(`pc-${this.idSeq}`, this.displayOfPlain(iso),
      card.title, text, postcardStore.countOf(appStore.getAccount()) % 6, card.symbol,
      weather[0], weather[1], card.groupId);
    if (mode === 'view') {
      // 服务器明信片记录不带天气字段：生成时刻按日期端侧补存，当日安排/最近一张展示时回查
      postcardStore.setDayWeather(appStore.getAccount(), this.isoOf(new Date()), weather[0], weather[1]);
    }
    this.activePostcard = postcard;
    this.postcardIsoDate = iso;
    this.postcardMode = mode;
    this.postcardVisible = true;
  }

  /** 明信片生成当天天气 [text, emoji]：优先天气快照里今天的预报（晴雨等现象），
   *  快照过期找不到今天时回退当前实况；无任何天气数据返回 ['', '']（日期行不附加） */
  private postcardDayWeather(): string[] {
    const w: WeatherOutcome | null = ServerGateway.weatherSnapshot();
    if (w === null) {
      return ['', ''];
    }
    const today: string = this.isoOf(new Date());
    for (let i = 0; i < w.days.length; i++) {
      if (w.days[i].fxDate === today && w.days[i].textDay.length > 0) {
        return [w.days[i].textDay, WeatherMark.emojiOfIcon(w.days[i].iconDay)];
      }
    }
    if (w.now !== null && w.now.text.length > 0) {
      return [w.now.text, WeatherMark.emojiOfIcon(w.now.icon)];
    }
    return ['', ''];
  }

  private handleSavePostcard(): void {
    const rec: PostcardRecord = PostcardRecord.of(this.postcardIsoDate, this.activePostcard.dateText,
      this.activePostcard.title, this.activePostcard.blessing, this.activePostcard.gradientIndex,
      this.activePostcard.emoji, this.activePostcard.weatherText, this.activePostcard.weatherEmoji,
      this.activePostcard.groupId, this.activePostcard.groupName);
    postcardStore.append(appStore.getAccount(), rec);
    this.postcardDates = postcardStore.datesOf(appStore.getAccount());
    this.postcardVisible = false;
    this.getUIContext().getPromptAction().showToast({ message: tr('已存入明信片库，日后翻开看看 📮') });
  }

  /** 延时面板快捷档：标签 + 平移后的中文时间，点击即按该时间提交 67 */
  @Builder
  private ExtendOptionChip(c: TaskCard, label: string, minutes: number): void {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(Theme.fontBody)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.brand())
      Text(this.extendOptionCn(c, minutes))
        .fontSize(Theme.fontCaption)
        .fontColor($r('app.color.text_tertiary'))
    }
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .margin(4)
    .backgroundColor(Theme.brandSoft())
    .borderRadius(Theme.radiusBtn)
    .onClick(() => {
      this.submitExtend(c, this.extendOptionTime(c, minutes));
    })
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: tr('日程'),
          onSearchTap: () => {
            this.enterSearch();
          }
        })

        if (this.searchActive) {
          Row({ space: 8 }) {
            Image($r('app.media.icon_search'))
              .width(24)
              .height(24)

            TextInput({ placeholder: tr('搜索日程卡片（标题 / 地点 / 参与人）'), text: this.keyword })
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusInput)
              .height(40)
              .padding({ left: 12, right: 12 })
              .layoutWeight(1)
              .defaultFocus(true)
              .onChange((value: string) => {
                this.handleKeywordChange(value);
              })
              .onSubmit(() => {
                this.handleSearchSubmit();
              })

            if (this.keyword.length > 0) {
              Text('✕')
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_tertiary'))
                .padding({ left: 4, right: 4, top: 9, bottom: 9 })
                .onClick(() => {
                  this.handleKeywordChange('');
                })
            }

            Text(tr('取消'))
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 4, right: 4, top: 9, bottom: 9 })
              .onClick(() => {
                this.exitSearch();
              })
          }
          .width('100%')
          .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 2, bottom: 6 })
        }

        Refresh({ refreshing: $$this.isRefreshing }) {
          Scroll() {
            Column({ space: 16 }) {
              if (this.searchActive) {
                Column({ space: 12 }) {
                  Row() {
                    Text(trf('搜索结果 · {0} 张', this.filteredCards().length))
                      .fontSize(Theme.fontSectionTitle)
                      .fontWeight(FontWeight.Bold)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                    Text(tr('点卡片定位到那天'))
                      .fontSize(Theme.fontCaption)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                  .width('100%')

                  if (this.filteredCards().length === 0) {
                    Column({ space: 6 }) {
                      Image($r('app.media.icon_search'))
                        .width(44)
                        .height(44)
                      Text(this.keyword.trim().length > 0 ? trf('没有找到与「{0}」相关的日程卡片', this.keyword.trim())
                        : (appStore.serverOnline ? tr('还没有日程卡片，去创建页和 AI 聊一张吧') : tr('暂时无法加载，请稍后再试')))
                        .fontSize(Theme.fontCaption)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                    .width('100%')
                    .padding({ top: 36, bottom: 36 })
                    .justifyContent(FlexAlign.Center)
                  } else {
                    ForEach(this.filteredCards(), (c: TaskCard) => {
                      Column({ space: 8 }) {
                        if (c.dateText.length > 0) {
                          Row() {
                            Text(`📅 ${this.displayOf(c.dateText)}`)
                              .fontSize(Theme.fontCaption)
                              .fontWeight(FontWeight.Bold)
                              .fontColor(Theme.brand())
                              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                              .backgroundColor($r('app.color.chip_bg'))
                              .borderRadius(Theme.radiusTag)
                            Blank()
                          }
                          .width('100%')
                        }
                        Card({ card: c, interactive: false, cardHeight: 130 })
                      }
                      .width('100%')
                      .onClick(() => {
                        this.handleSearchResultTap(c);
                      })
                    }, (c: TaskCard) => `${c.id}-${c.dateText}`)
                  }
                }
                .width('100%')
              } else {
                // 日历块 ↔ 倒计时块 ↔ 天气块循环滑动（loop：三页首尾相连可循环）；
                // 底部红点指示器：三枚红点标示可左右滑动，当前页红点拉长高亮
                Column() {
                  Swiper() {
                     Column() {
                        MonthCalendar({
                          eventDates: this.eventDates,
                          postcardDates: this.postcardDates,
                          selectedDate: this.selectedDate,
                          onDayTap: (day: CalendarDay) => {
                            this.handleDayTap(day);
                          },
                          onBirthdayTap: () => {
                            this.openBirthdayPicker();
                          },
                          onTopMeasure: (topHeight: number) => {
                            const need: number = topHeight + 354 + 28;
                            if (need > 0 && Math.abs(need - this.calendarCardHeight) > 0.5) {
                              this.calendarCardHeight = need;
                            }
                          }
                        })
                     }
                     .width('100%')
                     .padding({ top: 14, bottom: 14 })
                     .backgroundColor($r('app.color.bg_card'))
                     .borderRadius(Theme.radiusCard)
                     .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

                      // 倒计时预览页：最近的倒数日大数字 + 一句话，点卡片进倒计时页；
                      // 最近倒计时上传了背景图时卡片改图片全铺 + 暗色渐变 + 白字
                      Stack() {
                        if (this.cdNearest !== null && this.cdNearest.record.bg.length > 0) {
                          Image(`file://${countdownStore.bgPathOf(this.cdNearest.record.bg)}`)
                            .width('100%')
                            .height('100%')
                            .objectFit(ImageFit.Cover)
                          Column()
                            .width('100%')
                            .height('100%')
                            .linearGradient({ angle: 180, colors: [['#8C000000', 0], ['#40000000', 0.45], ['#73000000', 1]] })
                        }

                        Column() {
                          Row() {
                            Text(`⏳ ${tr('倒计时')}`)
                              .fontSize(Theme.fontBody)
                              .fontWeight(FontWeight.Bold)
                              .fontColor(this.cdHasBg() ? Color.White : $r('app.color.text_primary'))
                              .layoutWeight(1)
                            Text(tr('查看全部 ›'))
                              .fontSize(Theme.fontTag)
                              .fontColor(this.cdHasBg() ? Color.White : $r('app.color.text_tertiary'))
                          }
                          .width('100%')

                          if (this.cdNearest === null) {
                            Column({ space: 8 }) {
                              Image($r('app.media.penguin'))
                                .width(72)
                                .height(72)
                                .objectFit(ImageFit.Contain)
                              Text(tr('还没有倒数的日子'))
                                .fontSize(Theme.fontCaption)
                                .fontColor($r('app.color.text_secondary'))
                            }
                            .width('100%')
                            .layoutWeight(1)
                            .justifyContent(FlexAlign.Center)
                          } else {
                            Column({ space: 6 }) {
                              Text(this.cdNearest.record.title)
                                .fontSize(18)
                                .fontWeight(FontWeight.Bold)
                                .fontColor(this.cdHasBg() ? Color.White : $r('app.color.text_primary'))
                                .maxLines(1)
                                .textOverflow({ overflow: TextOverflow.Ellipsis })
                                .width('100%')

                              if (this.cdNearest.days === 0) {
                                Row({ space: 8 }) {
                                  Text(tr('今天'))
                                    .fontSize(44)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(this.cdHasBg() ? Color.White : Theme.brandDeep())
                                  Text('🎉')
                                    .fontSize(24)
                                }
                                .alignItems(VerticalAlign.Bottom)
                              } else {
                                Row({ space: 4 }) {
                                  Text(`${Math.abs(this.cdNearest.days)}`)
                                    .fontSize(56)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(this.cdHasBg() ? Color.White
                                      : (this.cdNearest.days > 0
                                        ? Theme.brandDeep() : $r('app.color.text_tertiary')))
                                  Text(this.cdNearest.days > 0 ? tr('天') : tr('天前'))
                                    .fontSize(18)
                                    .fontColor(this.cdHasBg() ? Color.White
                                      : (this.cdNearest.days > 0
                                        ? $r('app.color.text_secondary') : $r('app.color.text_tertiary')))
                                    .padding({ bottom: 8 })
                                }
                                .alignItems(VerticalAlign.Bottom)
                              }

                              Text(this.cdNearest.record.repeatAnnual
                                ? `${this.cdNearest.record.targetDate} · ${tr('每年重复')}`
                                : this.cdNearest.record.targetDate)
                                .fontSize(Theme.fontCaption)
                                .fontColor(this.cdHasBg() ? Color.White : $r('app.color.text_tertiary'))

                              if (this.cdNearest.days < 0) {
                                Text(tr('这一天已经过去啦'))
                                  .fontSize(Theme.fontCaption)
                                  .fontColor(this.cdHasBg() ? Color.White : $r('app.color.text_secondary'))
                              } else if (this.cdNearest.days === 0) {
                                Text(tr('就是今天，去赴约吧 🎉'))
                                  .fontSize(Theme.fontCaption)
                                  .fontColor(this.cdHasBg() ? Color.White : $r('app.color.text_secondary'))
                              } else if (this.cdNearest.days <= 7) {
                                Text(tr('越来越近啦，期待值拉满 ✨'))
                                  .fontSize(Theme.fontCaption)
                                  .fontColor(this.cdHasBg() ? Color.White : $r('app.color.text_secondary'))
                              } else {
                                Text(tr('把期待折成天数，一天一天拆 ✨'))
                                  .fontSize(Theme.fontCaption)
                                  .fontColor(this.cdHasBg() ? Color.White : $r('app.color.text_secondary'))
                              }
                            }
                            .width('100%')
                            .layoutWeight(1)
                            .justifyContent(FlexAlign.Center)
                          }
                        }
                        .width('100%')
                        .height('100%')
                        .padding({ top: 14, bottom: 14, left: 16, right: 16 })
                      }
                      .width('100%')
                      .height('100%')
                      .backgroundColor($r('app.color.bg_card'))
                      .borderRadius(Theme.radiusCard)
                      .clip(true)
                      .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
                      .onClick(() => {
                        this.getUIContext().getRouter().pushUrl({ url: 'pages/CountdownPage' });
                      })

                     WeatherCard()
                   }
                   .loop(true)
                   .duration(300)
                   .indicator(false)
                   .height(this.calendarCardHeight > 0 ? this.calendarCardHeight : 448)
                  .onChange((index: number) => {
                    this.calWeatherIndex = index;
                  })

                  Row({ space: 6 }) {
                    Column()
                      .width(this.calWeatherIndex === 0 ? 16 : 6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.calWeatherIndex === 0 ? '#E53935' : '#4DE53935')
                      .animation({ duration: 200, curve: Curve.EaseInOut })
                    Column()
                      .width(this.calWeatherIndex === 1 ? 16 : 6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.calWeatherIndex === 1 ? '#E53935' : '#4DE53935')
                      .animation({ duration: 200, curve: Curve.EaseInOut })
                    Column()
                      .width(this.calWeatherIndex === 2 ? 16 : 6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.calWeatherIndex === 2 ? '#E53935' : '#4DE53935')
                      .animation({ duration: 200, curve: Curve.EaseInOut })
                  }
                  .margin({ top: 8 })
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                }
                .width('100%')

                if (this.upcoming.length > 0) {
                  Column({ space: 10 }) {
                    Row() {
                      Text(tr('⏰ 未来 7 天提醒'))
                        .fontSize(Theme.fontSectionTitle)
                        .fontWeight(FontWeight.Bold)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)
                      Text(trf('{0} 条', this.upcoming.length))
                        .fontSize(Theme.fontCaption)
                        .fontColor($r('app.color.text_tertiary'))
                    }
                    .width('100%')

                    Scroll() {
                      Row({ space: 8 }) {
                        ForEach(this.upcoming, (r: ReminderInfo) => {
                          Column({ space: 3 }) {
                            Text(trf('{0} 提醒', friendlyTime(r.remindAt)))
                              .fontSize(Theme.fontTag)
                              .fontWeight(FontWeight.Bold)
                              .fontColor(Theme.brand())
                            Text(this.reminderTitleOf(r))
                              .fontSize(Theme.fontCaption)
                              .fontColor($r('app.color.text_secondary'))
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                          }
                          .constraintSize({ maxWidth: 180 })
                          .alignItems(HorizontalAlign.Start)
                          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                          .backgroundColor($r('app.color.bg_card'))
                          .borderRadius(Theme.radiusTag)
                          .border({ width: 1, color: $r('app.color.divider') })
                        }, (r: ReminderInfo) => `${r.groupId}-${r.cardIndex}-${r.remindAt}`)
                      }
                      .padding({ bottom: 2 })
                    }
                    .scrollable(ScrollDirection.Horizontal)
                    .scrollBar(BarState.Off)
                    .width('100%')
                    .align(Alignment.Start)
                  }
                  .width('100%')
                }

                Column({ space: 12 }) {
                  Row() {
                    Text(trf('当日安排 · {0}', this.displayOf(this.selectedDate)))
                      .fontSize(Theme.fontSectionTitle)
                      .fontWeight(FontWeight.Bold)
                      .fontColor($r('app.color.text_primary'))
                      .layoutWeight(1)
                  }
                  .width('100%')

                  if (this.dayCards().length === 0 && this.postcardsOfDate(this.selectedDate).length === 0) {
                    EmptyState({ emoji: '🌱', title: tr('这天暂时空白'), subtitle: tr('去创建页和 AI 聊一张卡吧') })
                  } else {
                    ForEach(this.dayCards(), (c: TaskCard) => {
                      Column({ space: 10 }) {
                        Card({
                          card: c,
                          interactive: false,
                          cardHeight: 130,
                          armable: true,
                          onSequenceDone: (done: TaskCard) => {
                            this.handleFlipConfirm(done);
                          },
                          onFlipChange: (cardId: string, back: boolean, x: number, y: number, w: number, h: number) => {
                            this.handleFlipChange(cardId, back, x, y, w, h);
                          }
                        })
                        if (c.status !== CardStatus.Done) {
                          // 完成者固定为发起者本人：完成/删除按钮均仅发起者可见，延时按钮服务器卡可见（创建者立即改期）；
                          // 按钮并排各占一份宽，缺失的由其余按钮撑满，都不是则不显示操作行；
                          // 完成/删除先翻面确认（背面点卡片执行，点外部取消）；
                          // 重复卡非末日为「打卡」（直接记录当日完成，不翻面不动画），末日为「完成」
                          if (this.isCardInitiator(c)) {
                            Row({ space: 10 }) {
                              Column() {
                                Text(this.isFinalRepeatDay(c) ? tr('✓ 完成') : tr('📍 打卡'))
                                  .fontSize(Theme.fontCaption)
                                  .fontWeight(FontWeight.Bold)
                                  .fontColor(Color.White)
                              }
                              .layoutWeight(1)
                              .height(38)
                              .justifyContent(FlexAlign.Center)
                              .linearGradient({
                                angle: 135,
                                colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
                              })
                              .borderRadius(Theme.radiusBtn)
                              .onClick(() => {
                                if (this.isFinalRepeatDay(c)) {
                                  this.armFlip(c, 'complete');
                                } else {
                                  this.handleCheckIn(c);
                                }
                              })

                              if (c.id.indexOf('srv-g') === 0 && c.groupId > 0) {
                                Column() {
                                  Text(tr('⏳ 延时'))
                                    .fontSize(Theme.fontCaption)
                                    .fontWeight(FontWeight.Bold)
                                    .fontColor(Theme.brand())
                                }
                                .layoutWeight(1)
                                .height(38)
                                .justifyContent(FlexAlign.Center)
                                .backgroundColor(Theme.brandSoft())
                                .borderRadius(Theme.radiusBtn)
                                .onClick(() => {
                                  this.openExtendPanel(c);
                                })
                              }

                              Column() {
                                Text(tr('🗑 删除'))
                                  .fontSize(Theme.fontCaption)
                                  .fontColor($r('app.color.error'))
                              }
                              .layoutWeight(1)
                              .height(38)
                              .justifyContent(FlexAlign.Center)
                              .backgroundColor(Color.Transparent)
                              .border({ width: 1, color: $r('app.color.error') })
                              .borderRadius(Theme.radiusBtn)
                              .onClick(() => {
                                this.armFlip(c, 'tear');
                              })
                            }
                            .width('100%')
                          }
                        } else {
                          Column() {
                            Text(tr('✓ 已完成'))
                              .fontSize(Theme.fontCaption)
                              .fontWeight(FontWeight.Bold)
                              .fontColor($r('app.color.success'))
                          }
                          .width('100%')
                          .height(38)
                          .justifyContent(FlexAlign.Center)
                          .backgroundColor($r('app.color.success_soft'))
                          .borderRadius(Theme.radiusBtn)
                        }
                      }
                      .width('100%')
                    }, (c: TaskCard) => `${c.id}|${this.selectedDate}|${c.title}|${c.dateText}|${c.timeText}|${c.place}|${c.note}|${c.status === CardStatus.Done ? 1 : 0}`)

                    // 完成的卡片已消失：同尺寸明信片顶替位置（点击查看全文，✕ 确认后删除）
                    ForEach(this.postcardsOfDate(this.selectedDate), (p: Postcard) => {
                      PostcardCard({
                        postcard: p,
                        onTap: () => {
                          this.openPostcard(p);
                        },
                        onDelete: () => {
                          this.confirmDeletePostcard(p);
                        }
                      })
                    }, (p: Postcard) => `${p.id}-${p.title}`)
                  }
                }
                .width('100%')
              }
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 4, bottom: 24 })
          .height('100%')
          .width('100%')
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

      if (this.flipGuardActive) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.guard_mask'))
          .onClick((e: ClickEvent) => {
            this.handleGuardTap(e);
          })
      }

      if (this.extendVisible) {
        // 延时面板：全屏遮罩点外部关闭 + 居中面板（快捷档 + 自定义时间）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.guard_mask'))
          .onClick(() => {
            this.closeExtendPanel();
          })

        Column({ space: Theme.spaceLg }) {
          Text(tr('⏳ 延时'))
            .fontSize(Theme.fontSectionTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

          Column({ space: 4 }) {
            Text(`「${this.extendTarget.title}」`)
              .fontSize(Theme.fontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(trf('当前：{0} {1}', this.extendTarget.dateText, this.extendTarget.timeText))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
            this.ExtendOptionChip(this.extendTarget, tr('+1小时'), 60)
            this.ExtendOptionChip(this.extendTarget, tr('+3小时'), 180)
            this.ExtendOptionChip(this.extendTarget, tr('+1天'), 1440)
            this.ExtendOptionChip(this.extendTarget, tr('+3天'), 4320)
            this.ExtendOptionChip(this.extendTarget, tr('+7天'), 10080)
          }
          .width('100%')

          Column({ space: 8 }) {
            TextInput({ text: this.extendCustomText, placeholder: tr('自定义：如 2026-10-05 09:00') })
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(Theme.radiusBtn)
              .width('100%')
              .onChange((v: string) => {
                this.extendCustomText = v;
              })
            Text(this.extendTarget.isOwner ? tr('你是发起者：确认后立即改期')
              : tr('你是完成者：将向发起者提交延时申请，同意后生效'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')

          Row({ space: 10 }) {
            Text(tr('取消'))
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
              .height(42)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(Theme.radiusBtn)
              .onClick(() => {
                this.closeExtendPanel();
              })
            Text(this.extendBusy ? tr('提交中…') : tr('确定'))
              .fontSize(Theme.fontBody)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .layoutWeight(1)
              .height(42)
              .textAlign(TextAlign.Center)
              .linearGradient({
                angle: 135,
                colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
              })
              .borderRadius(Theme.radiusBtn)
              .onClick(() => {
                this.submitExtendCustom();
              })
          }
          .width('100%')
        }
        .width('86%')
        .padding(Theme.spaceXl)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(Theme.radiusCard)
        .alignItems(HorizontalAlign.Center)
      }

      ShredOverlay({
        visible: this.shredVisible,
        card: this.shreddingCard,
        onFinished: (card: TaskCard) => {
          this.handleShredFinished(card);
        }
      })

      PostcardModal({
        visible: this.postcardVisible,
        postcard: this.activePostcard,
        mode: this.postcardMode,
        onSave: () => {
          this.handleSavePostcard();
        },
        onClose: () => {
          this.postcardVisible = false;
        }
      })

      BirthdayPopup({
        visible: this.birthdayVisible,
        onClose: () => {
          this.birthdayVisible = false;
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
