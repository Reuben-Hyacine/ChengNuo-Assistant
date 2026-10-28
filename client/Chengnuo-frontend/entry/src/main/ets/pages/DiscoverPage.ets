import { appStore } from '../store/AppStore';
import { Activity } from '../model/Types';
import { Theme } from '../common/Theme';
import { PageHeader } from '../components/PageHeader';
import { ActivityCard } from '../components/ActivityCard';
import { ServerGateway } from '../net/ServerGateway';
import { GroupCreatedOutcome, LibraryEntryInfo, LibraryListOutcome, MessageOutcome, ShopOutcome,
  endMomentOf, friendlyTime, startMomentOf } from '../net/ServerModels';
import { tr, trf } from '../common/I18n';
import { shopStore, ShopCardRecord, todayKey } from '../store/ShopStore';
import { GlyphIcon } from '../components/GlyphIcon';

/**
 * 发现页：卡片小铺（89 ai.shop 客户端本地存、一天自动上新一批、无主动刷新）
 * + 关键词本地过滤（# 开头仅匹配话题标签，普通词匹配标题/地点/话题标签）
 * + 卡片详情页（点卡片空白区进入：图片/事件/来源/标签，底部返回+加入日程）
 * + 小铺卡加入 = 新建私人卡片组（53）+ 加卡（56）
 * 推荐卡由 AI 生成（AIGC），标识「由 AI 为你推荐」
 */
@Component
export struct DiscoverPage {
  @StorageProp('appLang') appLang: string = 'zh';
  /** 主框架切回发现 tab / 回到主框架的刷新广播（页面保活不走 aboutToAppear）：重读小铺并对账 */
  @StorageProp('discoverRefreshToken') @Watch('onDiscoverRefreshTokenChange') discoverRefreshToken: number = 0;
  @State keyword: string = '';
  @State searchActive: boolean = false;
  @State isRefreshing: boolean = false;
  /** 卡片小铺：AI 推荐卡（客户端按账号文件保存，历史保留上限 50；每天自动上新一批，无主动刷新入口） */
  @State shopCards: ShopCardRecord[] = [];
  /** 小铺生成中（每天首批 4 张串行生成，每张生成即落盘增量展示） */
  @State shopGenerating: boolean = false;
  /** 上一轮生成全部失败（下拉刷新重置后重试；避免离线/无 AI 时反复自动打接口） */
  @State shopGenerateFailed: boolean = false;
  /** 本轮生成进度（第几张，空态进度文案用） */
  @State shopProgress: number = 0;
  /** 翻面确认：加入日程按钮先让卡片翻到背面「确定」（点卡片=翻回并执行，点外部=翻回取消） */
  @State flipGuardActive: boolean = false;
  private flipActId: string = '';
  private flipRectX: number = 0;
  private flipRectY: number = 0;
  private flipRectW: number = 0;
  private flipRectH: number = 0;
  /** 卡片详情页（点卡片空白区打开）：目标小铺卡 */
  @State detailActivity: Activity | null = null;

  aboutToAppear(): void {
    this.loadShop();
  }

  /** 收到刷新广播：重读小铺并对账（日程已删的卡回归可加入） */
  private onDiscoverRefreshTokenChange(): void {
    this.refreshShop();
  }

  /** 下拉刷新：重置失败标记后重读本地（为空重新触发生成）；动画至少展示 600ms 再收起 */
  private handleRefresh(): void {
    const start: number = Date.now();
    this.refreshShop().then((): void => {
      const rest: number = Math.max(600 - (Date.now() - start), 0);
      setTimeout(() => {
        this.isRefreshing = false;
      }, rest);
    });
  }

  /** 小铺刷新：先清掉已结束的推荐，重读本地文件（一天一批：当天还没生成过才补当日批）；对照 54 对账已加入卡的日程存续（删卡回归可加入） */
  private async refreshShop(): Promise<void> {
    this.shopGenerateFailed = false;
    const account: string = appStore.getAccount();
    if (!this.shopGenerating) {
      shopStore.pruneEnded(account);
    }
    this.shopCards = shopStore.listOf(account);
    await this.syncShopJoined();
    if (this.shopDailyDue(account) && !this.shopGenerating && account.length > 0 && appStore.serverOnline) {
      this.generateShopCards();
    }
  }

  /** 今天还没生成过小铺批次（一天刷一次：本地为空或 genDay 非今日 → 需要生成当日一批） */
  private shopDailyDue(account: string): boolean {
    if (account.length === 0) {
      return false;
    }
    return shopStore.listOf(account).length === 0 || shopStore.genDayOf(account) !== todayKey();
  }

  /** 进入小铺：先清掉已结束的推荐，读本地推荐；今天还没生成过时自动补当日一批（一天一次，无主动刷新入口）；已有推荐时后台对账 54（不阻塞展示）：已加入卡对应日程被删则回归未加入，恢复「加入日程」按钮 */
  private loadShop(): void {
    const account: string = appStore.getAccount();
    if (!this.shopGenerating) {
      shopStore.pruneEnded(account);
    }
    this.shopCards = shopStore.listOf(account);
    if (this.shopDailyDue(account) && !this.shopGenerating && !this.shopGenerateFailed &&
      account.length > 0 && appStore.serverOnline) {
      this.generateShopCards();
      return;
    }
    this.syncShopJoined();
  }

  /** 对照 54 我的卡片库：已标记加入（joinedGroupId>0）的小铺卡若条目已不存在（55 删组/57 删卡），回归未加入 */
  private async syncShopJoined(): Promise<void> {
    const account: string = appStore.getAccount();
    if (account.length === 0 || !appStore.serverOnline) {
      return;
    }
    const list: ShopCardRecord[] = shopStore.listOf(account);
    const joinedOnes: ShopCardRecord[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].joinedGroupId > 0) {
        joinedOnes.push(list[i]);
      }
    }
    if (joinedOnes.length === 0) {
      return;
    }
    const lib: LibraryListOutcome = await ServerGateway.myLibraryList();
    if (!lib.ok) {
      return; // 拉取失败保持现状，下次进小铺/下拉刷新再对账
    }
    let changed: boolean = false;
    for (let i = 0; i < joinedOnes.length; i++) {
      const rec: ShopCardRecord = joinedOnes[i];
      let exists: boolean = false;
      for (let j = 0; j < lib.entries.length; j++) {
        const entry: LibraryEntryInfo = lib.entries[j];
        if (entry.groupId === rec.joinedGroupId && entry.card.event === rec.event) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        changed = shopStore.resetJoined(account, rec.event, rec.time) || changed;
      }
    }
    if (changed) {
      this.shopCards = shopStore.listOf(account);
    }
  }

  /** 生成当日一批小铺推荐（一天一批）：按 index 1~4 串行请求 AI（每张成功即落盘并刷新列表，中断可保留已生成部分）；
    *  ≥1 张成功即记 genDay=今天（当天不再生成），全部失败保留失败标记等下拉重试 */
  private async generateShopCards(): Promise<void> {
    if (this.shopGenerating) {
      return;
    }
    const account: string = appStore.getAccount();
    if (account.length === 0 || !appStore.serverOnline) {
      return;
    }
    this.shopGenerating = true;
    this.shopGenerateFailed = false;
    this.shopProgress = 0;
    let added: number = 0;
    for (let i = 1; i <= 4; i++) {
      this.shopProgress = i;
      const outcome: ShopOutcome = await ServerGateway.aiShop(i, this.shopExcludeNames());
      if (outcome.ok && outcome.card !== null) {
        shopStore.add(account, ShopCardRecord.fromCard(outcome.card));
        added++;
        this.shopCards = shopStore.listOf(account);
      }
    }
    if (added > 0) {
      shopStore.setGenDay(account, todayKey());
    }
    this.shopGenerating = false;
    this.shopGenerateFailed = this.shopCards.length === 0;
    this.collapseFlipGuardIfNeeded();
  }

  /** 已推荐过的活动名清单（89 exclude 入参：服务端拼进提示词避免重复推荐；上限 30 条与服务端一致） */
  private shopExcludeNames(): string[] {
    const names: string[] = [];
    for (let i = 0; i < this.shopCards.length && names.length < 30; i++) {
      const name: string = this.shopCards[i].event;
      if (name.length > 0) {
        names.push(name);
      }
    }
    return names;
  }

  /** 关键词匹配：# 开头只按话题标签命中；普通词按标题/地点/话题标签命中（均为包含匹配） */
  private matchKeyword(a: Activity, kw: string): boolean {
    if (kw.charAt(0) === '#') {
      const tag: string = kw.substring(1);
      if (tag.length === 0) {
        return true;
      }
      for (let i = 0; i < a.tags.length; i++) {
        if (a.tags[i].indexOf(tag) >= 0) {
          return true;
        }
      }
      return false;
    }
    if (a.title.indexOf(kw) >= 0 || a.place.indexOf(kw) >= 0) {
      return true;
    }
    for (let i = 0; i < a.tags.length; i++) {
      if (a.tags[i].indexOf(kw) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 卡片时段归类（与服务端周报统计同口径）：开始时刻 05:00-12:00=上午、12:00-18:00=下午、
    *  其余=夜晚（含深夜凌晨）；无有效时间返回空串 */
  private daySlotOf(rawTime: string): string {
    const start: Date | null = startMomentOf(rawTime);
    if (start === null) {
      return '';
    }
    const hour: number = start.getHours();
    if (hour >= 5 && hour < 12) {
      return 'morning';
    }
    if (hour >= 12 && hour < 18) {
      return 'afternoon';
    }
    return 'night';
  }

  /** 当前展示列表：本周小铺推荐包装成 Activity（含关键词过滤） */
  private displayList(): Activity[] {
    const list: Activity[] = [];
    const kw: string = this.keyword.trim();
    for (let i = 0; i < this.shopCards.length; i++) {
      const act: Activity = this.shopActivityOf(this.shopCards[i], i);
      if (kw.length === 0 || this.matchKeyword(act, kw)) {
        list.push(act);
      }
    }
    return list;
  }

  /** 小铺推荐卡包装成发现页活动卡（id=shop-<小铺下标>，加入时按下标回查记录；joined=已加入日程保留在小铺） */
  private shopActivityOf(rec: ShopCardRecord, index: number): Activity {
    const act: Activity = Activity.of(`shop-${index}`,
      rec.event.length > 0 ? rec.event : rec.purpose, tr('AI 推荐'), tr('卡片小铺'), false,
      friendlyTime(rec.time), rec.location.length > 0 ? rec.location : tr('地点待定'),
      this.shopEmojiOf(rec.theme), rec.joinedGroupId > 0, 1, 1, false);
    const endMoment: Date | null = endMomentOf(rec.time);
    act.ended = endMoment !== null && endMoment.getTime() < Date.now();
    act.tags = rec.tags.slice();
    act.rawTime = rec.time;
    act.colorIndex = Theme.colorIndexOf(`${rec.event}|${rec.time}`);
    act.type = rec.type;
    act.scene = rec.scene;
    act.theme = rec.theme;
    act.daySlot = this.daySlotOf(rec.time);
    return act;
  }

  /** 主题标签 → 封面 emoji（非法/缺失兜底 🛍） */
  private shopEmojiOf(theme: string): string {
    if (theme === 'academic') {
      return '📚';
    }
    if (theme === 'sports') {
      return '🏃';
    }
    if (theme === 'entertainment') {
      return '🎮';
    }
    if (theme === 'social') {
      return '👥';
    }
    if (theme === 'creative') {
      return '🎨';
    }
    if (theme === 'life') {
      return '🌱';
    }
    return '🛍';
  }

  private rowsOf(list: Activity[]): Activity[][] {
    const rows: Activity[][] = [];
    let i: number = 0;
    while (i < list.length) {
      const row: Activity[] = [];
      row.push(list[i]);
      if (i + 1 < list.length) {
        row.push(list[i + 1]);
      }
      rows.push(row);
      i += 2;
    }
    return rows;
  }

  /** ActivityCard.onFlipChange：卡片翻到背面升起全屏遮罩（缓存其页面坐标），翻回后收起 */
  private handleFlipChange(actId: string, back: boolean, x: number, y: number, w: number, h: number): void {
    if (back) {
      this.flipActId = actId;
      this.flipRectX = x;
      this.flipRectY = y;
      this.flipRectW = w;
      this.flipRectH = h;
      this.flipGuardActive = true;
      return;
    }
    this.flipGuardActive = false;
  }

  /** 遮罩点击：落在卡片区域内 → 广播确定；区域外 → 广播取消翻回 */
  private handleGuardTap(e: ClickEvent): void {
    const insideX: boolean = e.x >= this.flipRectX && e.x <= this.flipRectX + this.flipRectW;
    const insideY: boolean = e.y >= this.flipRectY && e.y <= this.flipRectY + this.flipRectH;
    if (insideX && insideY) {
      AppStorage.setOrCreate('discoverFlipConfirmToken', (AppStorage.get<number>('discoverFlipConfirmToken') ?? 0) + 1);
    } else {
      AppStorage.setOrCreate('discoverFlipCancelToken', (AppStorage.get<number>('discoverFlipCancelToken') ?? 0) + 1);
    }
  }

  /** 页头搜索入口：进入搜索模式（本地过滤小铺推荐） */
  private enterSearch(): void {
    this.searchActive = true;
  }

  /** 退出搜索模式：清空关键词，恢复全量列表 */
  private exitSearch(): void {
    this.searchActive = false;
    this.keyword = '';
  }

  /** 小铺卡「加入日程」：AI 推荐卡 → 新建私人卡片组（53）+ 加卡（56）→ 标记已加入（卡片保留在小铺，从日程删除后经 54 对账回归）；与列表卡同样先翻面确认 */
  private async handleJoinShop(act: Activity): Promise<void> {
    if (act.ended) {
      this.getUIContext().getPromptAction().showToast({ message: tr('活动已结束，无法加入 📁') });
      return;
    }
    if (!appStore.serverOnline) {
      this.getUIContext().getPromptAction().showToast({ message: tr('加入失败，请重试') });
      return;
    }
    const idx: number = Number(act.id.substring(5));
    const rec: ShopCardRecord | undefined = this.shopCards[idx];
    if (rec === undefined) {
      return;
    }
    const name: string = rec.event.length > 0 ? rec.event : (rec.purpose.length > 0 ? rec.purpose : tr('小铺卡片'));
    const created: GroupCreatedOutcome = await ServerGateway.groupsCreate(name, 'private');
    if (!created.ok) {
      this.getUIContext().getPromptAction().showToast({ message: created.message });
      return;
    }
    const fields: Record<string, Object> = {};
    fields['purpose'] = rec.purpose;
    fields['event'] = rec.event;
    fields['time'] = rec.time;
    fields['reminderTime'] = rec.reminderTime;
    fields['repeatTime'] = rec.repeatTime;
    fields['repeatUntil'] = rec.repeatUntil;
    fields['location'] = rec.location;
    fields['type'] = rec.type;
    fields['scene'] = rec.scene;
    fields['theme'] = rec.theme;
    fields['tags'] = rec.tags;
    const added: MessageOutcome = await ServerGateway.groupsAddCard(created.groupId, fields);
    if (!added.ok) {
      this.getUIContext().getPromptAction().showToast({ message: added.message });
      return;
    }
    shopStore.markJoined(appStore.getAccount(), rec.event, rec.time, created.groupId);
    this.shopCards = shopStore.listOf(appStore.getAccount());
    // 详情页加入小铺卡成功：重包装详情目标卡（joined 状态跟随最新小铺记录）
    if (this.detailActivity !== null && this.detailActivity.id.indexOf('shop-') === 0) {
      const detailIdx: number = Number(this.detailActivity.id.substring(5));
      this.detailActivity = detailIdx < this.shopCards.length
        ? this.shopActivityOf(this.shopCards[detailIdx], detailIdx) : null;
    }
    this.getUIContext().getPromptAction().showToast({ message: tr('已加入私人卡片库 🗂') });
  }

  /** 翻面等待确认的卡片若已不在当前展示列表（刷新移除/跨周清除），收起遮罩避免整页被遮罩卡死 */
  private collapseFlipGuardIfNeeded(): void {
    if (!this.flipGuardActive) {
      return;
    }
    const list: Activity[] = this.displayList();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === this.flipActId) {
        return;
      }
    }
    this.flipGuardActive = false;
    this.flipActId = '';
  }

  /** 点卡片空白区：打开卡片详情页 */
  private openDetail(act: Activity): void {
    this.detailActivity = act;
  }

  /** 关闭卡片详情页 */
  private closeDetail(): void {
    this.detailActivity = null;
  }

  /** 详情页底栏主按钮文案：镜像卡片正面的加入状态分支 */
  private detailJoinLabel(act: Activity): string {
    if (act.ended) {
      return tr('📁 已结束');
    }
    if (act.joined) {
      return tr('✓ 已加入日程');
    }
    return tr('加入日程');
  }

  /** 详情页底栏主按钮可点性：已结束/已加入置灰 */
  private detailJoinEnabled(act: Activity): boolean {
    return !act.ended && !act.joined;
  }

  /** 空态文案：优先提示关键词无匹配，其余按小铺生成状态提示 */
  private emptyListText(): string {
    if (this.keyword.trim().length > 0) {
      return trf('没有找到与「{0}」相关的卡片', this.keyword);
    }
    return this.shopEmptyText();
  }

  /** 小铺空态文案：生成中显示进度；失败提示下拉重试；末位兜底（历史推荐保留在小铺，正常不会为空） */
  private shopEmptyText(): string {
    if (this.shopGenerating) {
      return trf('AI 正在为你挑选卡片…（{0}/4）', this.shopProgress);
    }
    if (!appStore.serverOnline) {
      return tr('暂时无法加载，请稍后再试');
    }
    if (this.shopGenerateFailed) {
      return tr('AI 暂时无法生成卡片，下拉重试');
    }
    return tr('暂无推荐卡片，下拉刷新试试');
  }

  /** 卡片详情页（全屏覆盖层）：图片 / 事件 / 来源 / 标签，底栏返回 + 加入日程 */
  @Builder
  detailOverlay(act: Activity) {
    Column() {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.closeDetail();
          })

        Text(tr('卡片详情'))
          .fontSize(Theme.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 12, bottom: 10 })
      .backgroundColor($r('app.color.nav_bg'))
      .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })

      Scroll() {
        Column({ space: 12 }) {
          // 图片：渐变 + emoji 占位
          Stack() {
            Text(act.emoji)
              .fontSize(44)
          }
          .width('100%')
          .height(170)
          .linearGradient({
            angle: 135,
            colors: [[Theme.postcardGradientFrom(act.colorIndex), 0.0], [Theme.postcardGradientTo(act.colorIndex), 1.0]]
          })
          .borderRadius(Theme.radiusCard)

          // 事件：标题 + 标签 + 时间/地点
          Column({ space: 10 }) {
            Text(tr('事件'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))

            Row({ space: 12 }) {
              Text(act.emoji)
                .fontSize(34)
              Column({ space: 6 }) {
                Text(act.title)
                  .fontSize(Theme.fontBody)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Text(act.tag)
                  .fontSize(Theme.fontTag)
                  .fontColor(Theme.brandDeep())
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(Theme.brandSoft())
                  .borderRadius(Theme.radiusTag)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')

            Column({ space: 8 }) {
              Text(`⏰ ${act.timeText}`)
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(`📍 ${act.place}`)
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)

          // 来源：卡片小铺（AI 生成内容标识）
          Column({ space: 10 }) {
            Text(tr('来源'))
              .fontSize(Theme.fontCaption)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_secondary'))

            Row({ space: 12 }) {
              Column() {
                Text('🛍')
                  .fontSize(20)
              }
              .width(46)
              .height(46)
              .justifyContent(FlexAlign.Center)
              .backgroundColor(Theme.brandSoft())
              .borderRadius(23)

              Column({ space: 4 }) {
                Text(act.hostName)
                  .fontSize(Theme.fontBody)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Text(tr('由 AI 为你推荐'))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)

          if (act.tags.length > 0) {
            Column({ space: 8 }) {
              Text(tr('话题标签'))
                .fontSize(Theme.fontCaption)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_secondary'))
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(act.tags, (t: string) => {
                  Text(`#${t}`)
                    .fontSize(Theme.fontTag)
                    .fontColor(Theme.brandDeep())
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .backgroundColor(Theme.brandSoft())
                    .borderRadius(Theme.radiusTag)
                    .margin({ right: 6, bottom: 6 })
                }, (t: string) => t)
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(12)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
          }
        }
        .width('100%')
        .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 14, bottom: 16 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)

      Row({ space: 10 }) {
        Column() {
          Text(tr('返回'))
            .fontSize(Theme.fontBody)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
        }
        .height(46)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.chip_bg'))
        .borderRadius(Theme.radiusBtn)
        .onClick(() => {
          this.closeDetail();
        })

        Column() {
          Text(this.detailJoinLabel(act))
            .fontSize(Theme.fontBody)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.detailJoinEnabled(act) ? Color.White : $r('app.color.text_secondary'))
        }
        .height(46)
        .layoutWeight(2)
        .justifyContent(FlexAlign.Center)
        .linearGradient(this.detailJoinEnabled(act) ? {
          angle: 135,
          colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
        } : {
          angle: 135,
          colors: [[$r('app.color.chip_bg'), 0.0], [$r('app.color.chip_bg'), 1.0]]
        })
        .borderRadius(Theme.radiusBtn)
        .onClick(() => {
          if (this.detailJoinEnabled(act)) {
            this.handleJoinShop(act);
          }
        })
      }
      .width('100%')
      .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 10, bottom: 12 })
      .backgroundColor($r('app.color.nav_bg'))
      .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .transition(TransitionEffect.OPACITY)
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        PageHeader({
          title: tr('发现'),
          onSearchTap: () => {
            this.enterSearch();
          }
        })

        if (this.searchActive) {
          Row({ space: 8 }) {
            Image($r('app.media.icon_search'))
              .width(24)
              .height(24)

            TextInput({ placeholder: tr('搜索卡片 / #标签'), text: this.keyword })
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
                this.keyword = value;
              })

            if (this.keyword.length > 0) {
              Text('✕')
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_tertiary'))
                .padding({ left: 4, right: 4, top: 9, bottom: 9 })
                .onClick(() => {
                  this.keyword = '';
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
            Column({ space: 14 }) {
              if (this.displayList().length === 0) {
                Column({ space: 6 }) {
                  GlyphIcon({ emoji: '🛍', iconSize: 44 })
                  Text(this.emptyListText())
                    .fontSize(Theme.fontCaption)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .width('100%')
                .padding({ top: 36, bottom: 36 })
                .justifyContent(FlexAlign.Center)
              }

              ForEach(this.rowsOf(this.displayList()), (row: Activity[]) => {
                Row({ space: 12 }) {
                  ForEach(row, (a: Activity) => {
                    ActivityCard({
                      activity: a,
                      showCapacity: false,
                      onJoin: (act: Activity) => {
                        this.handleJoinShop(act);
                      },
                      onFlipChange: (actId: string, back: boolean, x: number, y: number, w: number, h: number) => {
                        this.handleFlipChange(actId, back, x, y, w, h);
                      },
                      onBodyTap: (act: Activity) => {
                        this.openDetail(act);
                      }
                    })
                      .layoutWeight(1)
                  }, (a: Activity) => `${a.id}|${a.joined ? 1 : 0}`)

                  if (row.length === 1) {
                    Column()
                      .layoutWeight(1)
                  }
                }
                .width('100%')
                .margin({ bottom: 2 })
                .alignItems(VerticalAlign.Top)
              }, (row: Activity[]) => {
                let k: string = `row-${row.length}`;
                row.forEach((a: Activity) => {
                  k += `-${a.id}_${a.joined ? 1 : 0}`;
                });
                return k;
              })

              if (this.shopCards.length > 0) {
                Row({ space: 8 }) {
                  if (this.shopGenerating) {
                    LoadingProgress()
                      .width(16)
                      .height(16)
                      .color(Theme.brand())
                    Text(tr('AI 正在为你挑选卡片…'))
                      .fontSize(Theme.fontCaption)
                      .fontColor($r('app.color.text_tertiary'))
                  } else {
                    Text(tr('每天上新一批 AI 推荐'))
                      .fontSize(Theme.fontCaption)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 2, bottom: 2 })
              }
            }
            .width('100%')
            .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 4, bottom: 90 })
          }
          .height('100%')
          .width('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
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

      if (this.detailActivity !== null) {
        this.detailOverlay(this.detailActivity)
      }
    }
    .width('100%')
    .height('100%')
  }
}
