import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';
import { WeatherMark } from '../common/WeatherMark';
import { GeoCoord, coordOf } from '../common/CityCoords';
import { LocationResult, LocationService } from '../common/LocationService';
import { regionProvinceNames, regionProvinceOf } from '../common/RegionData';
import { weatherPrefStore } from '../store/WeatherPrefStore';
import { ServerGateway } from '../net/ServerGateway';
import { WeatherAirInfo, WeatherAlertInfo, WeatherDayInfo, WeatherHourInfo, WeatherIndexInfo,
  WeatherNowInfo, WeatherOutcome } from '../net/ServerModels';

/**
 * 天气块（日程页日历块循环滑动的另一屏，与日历块互为左右邻居）：
 * - 左上角省市城市（📍 省 市 ▾）：点击弹省市两级滚轮（与个人空间「地区」一致）手动调整；「🎯 定位」自动定位调整
 * - 数据：weather.fetch（97，和风天气 8 产品聚合）；内置后端拦截落库快照（每次新结果清空旧数据，只留一份）
 * - 正文：气象预警横幅 → 当前实况 → 分钟降水 → 3 日预报 → 24 小时横滑 → 空气与生活指数 → 日出日落月相 → 昨日实况
 * - 逐小时时间线：随时间推进删除过去时段，当前时段恒居最左；用户可横滑查看，3 秒无操作自动回归最左默认位
 * - 降级：拉取失败保留快照并标「离线」；无任何数据时正文显示原因
 * - 3 日预报同步发布到 AppStorage('weatherDailyMarks')，日历格子右下角展示真实天气标志（仅预报覆盖日期）
 * - 刷新时机：手动「刷新」/ 切城市 / 定位成功 / 冷启动且快照超过 60 分钟 / 跨 00:00 与 12:00 半日边界 / 距上次更新超 12 小时（自动刷新带 30 分钟尝试冷却，保护配额无高频轮询）
 * 城市经 weatherPrefStore 落盘（app_weather），重启保留。
 */
@Component
export struct WeatherCard {
  @StorageProp('weatherProvince') province: string = '北京市';
  @StorageProp('weatherCity') city: string = '市辖区';
  @State locating: boolean = false;
  @State loading: boolean = false;
  @State weather: WeatherOutcome | null = null;
  /** true = 当前展示的是内置后端快照（服务器不可达或本次未刷新成功） */
  @State offline: boolean = false;
  @State errorMsg: string = '';
  /** 最近一次成功数据对应的省市（同一城市且未过期时不重复拉取，保护配额） */
  private lastFetchedKey: string = '';
  /** 拉取进行中收到的新请求（如切城市）暂存于此，当前拉取结束后立即补拉，避免静默丢弃导致正文停留旧城市 */
  private pendingProvince: string = '';
  private pendingCity: string = '';
  private pendingForce: boolean = false;
  private hasPending: boolean = false;
  /** 逐小时时间线：当前小时起点（now 按小时取整）；周期检测跨小时 → 删除过去时段，当前时段居首 */
  @State hourStartMs: number = Math.floor(Date.now() / 3600000) * 3600000;
  private hourScroller: Scroller = new Scroller();
  private hourTimerId: number = -1;
  private hourReturnId: number = -1;
  /** 自动刷新：最近跨过的 00:00/12:00 半日边界（防重复触发） */
  private lastHalfDayMs: number = -1;
  /** 自动刷新：最近一次自动刷新尝试时刻（成功失败都计，30 分钟冷却防失败重试风暴） */
  private lastAutoRefreshMs: number = -1;

  aboutToAppear(): void {
    const snapshot: WeatherOutcome | null = ServerGateway.weatherSnapshot();
    if (snapshot !== null) {
      this.applyWeather(snapshot, true);
    }
    this.refresh(false);
    this.lastHalfDayMs = this.latestHalfDayMs(Date.now());
    this.lastAutoRefreshMs = Date.now();
    this.hourTimerId = setInterval(() => {
      this.checkHourRollover();
      this.checkAutoRefresh();
    }, 10000);
  }

  aboutToDisappear(): void {
    if (this.hourTimerId >= 0) {
      clearInterval(this.hourTimerId);
      this.hourTimerId = -1;
    }
    if (this.hourReturnId >= 0) {
      clearTimeout(this.hourReturnId);
      this.hourReturnId = -1;
    }
  }

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Row({ space: 4 }) {
            Text('📍')
              .fontSize(Theme.fontTag)
            Text(this.regionText())
              .fontSize(Theme.fontBody)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('▾')
              .fontSize(Theme.fontTag)
              .fontColor($r('app.color.text_tertiary'))
          }
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => {
          this.openProvincePicker();
        })

        if (this.locating) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(Theme.brand())
        } else {
          Text(tr('🎯 定位'))
            .fontSize(Theme.fontTag)
            .fontColor(Theme.brand())
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(Theme.radiusTag)
            .onClick(() => {
              this.handleLocate();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 状态行：更新时间 / 离线角标 / 手动刷新
      Row({ space: 6 }) {
        if (this.weather !== null) {
          Text(trf('更新于 {0}', this.fetchedTimeText()))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
          if (this.offline) {
            Text(tr('离线'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(Theme.radiusTag)
          }
        }
        Blank()
        if (this.loading) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(Theme.brand())
        } else {
          Text(tr('刷新'))
            .fontSize(Theme.fontTag)
            .fontColor(Theme.brand())
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(Theme.radiusTag)
            .onClick(() => {
              this.refresh(true);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })

      Scroll() {
        Column({ space: 10 }) {
          if (this.weather === null) {
            this.emptyBody()
          } else {
            this.weatherBody()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 4 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 14, bottom: 14, left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Theme.radiusCard)
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
  }

  /** 无任何数据时的正文（显示失败原因或引导刷新） */
  @Builder
  emptyBody() {
    Column({ space: 8 }) {
      if (this.loading) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(Theme.brand())
      } else {
        Text('🌤️')
          .fontSize(40)
        Text(this.errorMsg.length > 0 ? this.errorMsg : tr('暂无天气数据'))
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding({ top: 24, bottom: 8 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 天气正文（八段按数据有无逐段展示）：直读 this.weather 状态变量——@Builder 按值传参不会随状态变化刷新，正文会冻结在首次渲染 */
  @Builder
  weatherBody() {
    if (this.weather !== null) {
      this.alertBanners()
      this.nowSection()
      this.minutelySection()
      this.dailySection()
      this.hourlySection()
      this.chipsSection()
      this.astroSection()
      this.yesterdaySection()
    }
  }

  /** 气象预警横幅（severityColor 为 #RRGGBB 时用预警色，否则红色兜底） */
  @Builder
  alertBanners() {
    if (this.weather !== null) {
      ForEach(this.weather.alerts, (alert: WeatherAlertInfo) => {
        Row({ space: 6 }) {
          Text('⚠️')
            .fontSize(Theme.fontCaption)
          Text(alert.title)
            .fontSize(Theme.fontCaption)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(Theme.radiusTag)
        .backgroundColor(alert.severityColor.startsWith('#') ? alert.severityColor : $r('app.color.badge_red'))
      }, (alert: WeatherAlertInfo) => `${alert.title}|${alert.startTime}`)
    }
  }

  /** 当前实况：大图标 + 温度/现象 + 体感/湿度/风 */
  @Builder
  nowSection() {
    if (this.weather !== null && this.weather.now !== null) {
      Row({ space: 12 }) {
        Text(WeatherMark.emojiOfIconOr(this.weather.now.icon, '🌤️'))
          .fontSize(38)
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(`${this.weather.now.temp}°`)
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text(this.weather.now.text)
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(VerticalAlign.Bottom)

          Text(this.nowDetailText(this.weather))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 分钟级降水摘要（如「未来两小时无降水」） */
  @Builder
  minutelySection() {
    if (this.weather !== null && this.weather.minutelySummary.length > 0) {
      Text(`☔ ${this.weather.minutelySummary}`)
        .fontSize(Theme.fontCaption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
    }
  }

  /** 3 日预报：今天/明天/后天 三等分 */
  @Builder
  dailySection() {
    if (this.weather !== null && this.weather.days.length > 0) {
      Row() {
        ForEach(this.weather.days, (day: WeatherDayInfo, index: number) => {
          Column({ space: 3 }) {
            Text(this.dayLabel(index))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
            Text(WeatherMark.emojiOfIconOr(day.iconDay, '🌤️'))
              .fontSize(20)
            Text(`${day.tempMax}° / ${day.tempMin}°`)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }, (day: WeatherDayInfo) => `${day.fxDate}|${day.iconDay}|${day.tempMax}|${day.tempMin}`)
      }
      .width('100%')
    }
  }

  /** 24 小时预报（横向滑动）：随时间推进删除过去时段，当前时段居最左；3 秒无操作自动回归最左 */
  @Builder
  hourlySection() {
    if (this.weather !== null && this.visibleHours().length > 0) {
      Scroll(this.hourScroller) {
        Row({ space: 12 }) {
          ForEach(this.visibleHours(), (hour: WeatherHourInfo) => {
            Column({ space: 3 }) {
              Text(this.hourText(hour.fxTime))
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_tertiary'))
              Text(WeatherMark.emojiOfIconOr(hour.icon, '🌤️'))
                .fontSize(16)
              Text(`${hour.temp}°`)
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Center)
          }, (hour: WeatherHourInfo) => `${hour.fxTime}|${hour.temp}|${hour.icon}`)
        }
        .padding({ left: 2, right: 2 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .onTouch(() => {
        this.scheduleHourReturn();
      })
    }
  }

  /** 空气质量 + 生活指数 chips（运动/洗车/穿衣/紫外线） */
  @Builder
  chipsSection() {
    if (this.weather !== null && (this.weather.air !== null || this.weather.indices.length > 0)) {
      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.weather.air !== null) {
          Text(`🍃 ${this.weather.air.aqi} ${this.weather.air.category}`)
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(Theme.radiusTag)
            .margin({ right: 6, bottom: 6 })
        }
        ForEach(this.weather.indices, (item: WeatherIndexInfo) => {
          Text(`${item.name} ${item.category}`)
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(Theme.radiusTag)
            .margin({ right: 6, bottom: 6 })
        }, (item: WeatherIndexInfo) => `${item.type}|${item.category}`)
      }
      .width('100%')
    }
  }

  /** 日出日落月相（取 3 日预报首日） */
  @Builder
  astroSection() {
    if (this.weather !== null && this.weather.days.length > 0) {
      if (this.weather.days[0].sunrise.length > 0 || this.weather.days[0].sunset.length > 0 ||
        this.weather.days[0].moonPhase.length > 0) {
        Row({ space: 12 }) {
          if (this.weather.days[0].sunrise.length > 0) {
            Text(`🌅 ${this.clockText(this.weather.days[0].sunrise)}`)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
          if (this.weather.days[0].sunset.length > 0) {
            Text(`🌇 ${this.clockText(this.weather.days[0].sunset)}`)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
          if (this.weather.days[0].moonPhase.length > 0) {
            Text(`🌙 ${this.weather.days[0].moonPhase}`)
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
  }

  /** 昨日实况（timeMachine） */
  @Builder
  yesterdaySection() {
    if (this.weather !== null && this.weather.yesterdayMax.length > 0 && this.weather.yesterdayMin.length > 0) {
      Text(trf('昨天 {0}° ~ {1}°', this.weather.yesterdayMin, this.weather.yesterdayMax))
        .fontSize(Theme.fontCaption)
        .fontColor($r('app.color.text_tertiary'))
    }
  }

  private regionText(): string {
    if (this.province.length === 0) {
      return tr('未设置');
    }
    if (this.city.length === 0) {
      return this.province;
    }
    return `${this.province} ${this.city}`;
  }

  /** 手动调整：省市两级滚轮（先省后市，与个人空间「地区」一致） */
  private openProvincePicker(): void {
    const names: string[] = regionProvinceNames();
    const current: number = names.indexOf(this.province);
    const selected: number = current >= 0 ? current : 0;
    this.getUIContext().showTextPickerDialog({
      range: names,
      selected: selected,
      onAccept: (value: TextPickerResult) => {
        const index: number = typeof value.index === 'number' ? value.index : selected;
        const name: string = index >= 0 && index < names.length ? names[index] : names[selected];
        this.openCityPicker(name);
      }
    });
  }

  private openCityPicker(provinceName: string): void {
    const province = regionProvinceOf(provinceName);
    if (province === null) {
      return;
    }
    const names: string[] = province.cities;
    const current: number = names.indexOf(this.city);
    const selected: number = current >= 0 ? current : 0;
    this.getUIContext().showTextPickerDialog({
      range: names,
      selected: selected,
      onAccept: (value: TextPickerResult) => {
        const index: number = typeof value.index === 'number' ? value.index : selected;
        const city: string = index >= 0 && index < names.length ? names[index] : names[selected];
        weatherPrefStore.setRegion(provinceName, city);
        this.refreshAt(provinceName, city, true);
      }
    });
  }

  /** 自动调整：定位当前城市（失败提示已本地化的原因） */
  private async handleLocate(): Promise<void> {
    if (this.locating) {
      return;
    }
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    this.locating = true;
    const result: LocationResult = await LocationService.locate(ctx);
    this.locating = false;
    if (result.ok) {
      weatherPrefStore.setRegion(result.province, result.city);
      this.refreshAt(result.province, result.city, true);
      this.getUIContext().getPromptAction().showToast({
        message: trf('已定位到 {0} {1}', result.province, result.city)
      });
    } else {
      this.getUIContext().getPromptAction().showToast({ message: result.message });
    }
  }

  /** 拉取天气：force=true 立即拉取；false 仅当无数据/切城市/超过 60 分钟时拉取 */
  private async refresh(force: boolean): Promise<void> {
    await this.refreshAt(this.province, this.city, force);
  }

  private async refreshAt(province: string, city: string, force: boolean): Promise<void> {
    if (this.loading) {
      // 已有拉取在飞行中（如进入页面触发的补拉未完成时用户切了城市）：
      // 排队最新请求而非丢弃，避免正文永远停留在旧城市
      this.pendingProvince = province;
      this.pendingCity = city;
      this.pendingForce = force;
      this.hasPending = true;
      return;
    }
    const key: string = `${province}|${city}`;
    if (!force && this.weather !== null && this.lastFetchedKey === key && !this.isStale()) {
      return;
    }
    const coord: GeoCoord | null = coordOf(province, city);
    this.loading = true;
    const outcome: WeatherOutcome = await ServerGateway.weatherFetch(
      coord !== null ? coord.lat : Number.NaN,
      coord !== null ? coord.lng : Number.NaN,
      city);
    this.loading = false;
    if (outcome.ok) {
      this.applyWeather(outcome, false);
    } else if (this.weather === null) {
      // 没有任何数据：正文显示失败原因
      this.errorMsg = outcome.message;
    } else {
      // 已有快照数据：保留展示，toast 提示本次刷新失败
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
    }
    if (this.hasPending) {
      // 飞行期间收到过新请求（通常是切城市）：立即补拉最新的一次
      const nextProvince: string = this.pendingProvince;
      const nextCity: string = this.pendingCity;
      const nextForce: boolean = this.pendingForce;
      this.hasPending = false;
      this.refreshAt(nextProvince, nextCity, nextForce);
    }
  }

  private applyWeather(weather: WeatherOutcome, fromSnapshot: boolean): void {
    this.weather = weather;
    this.offline = fromSnapshot;
    this.errorMsg = '';
    if (this.selectionMatches(weather)) {
      this.lastFetchedKey = this.currentKey();
    }
    this.publishMarks(weather);
    if (!fromSnapshot) {
      // 拉取成功：天气话术/日历标志可能变化，广播日程页重推锁屏卡片；
      // 启动时的快照载入不广播（卡片库尚未就绪，启动流程本就会按快照推一次）
      AppStorage.setOrCreate('weatherStamp', (AppStorage.get<number>('weatherStamp') ?? 0) + 1);
    }
  }

  private currentKey(): string {
    return `${this.province}|${this.city}`;
  }

  /** 快照/拉取结果是否就是当前选择的城市（按解析坐标与城市坐标表比对，0.5° ≈ 55km） */
  private selectionMatches(weather: WeatherOutcome): boolean {
    const coord: GeoCoord | null = coordOf(this.province, this.city);
    if (coord === null) {
      return false;
    }
    const lat: number = Number(weather.lat);
    const lon: number = Number(weather.lon);
    if (Number.isNaN(lat) || Number.isNaN(lon)) {
      return false;
    }
    return Math.abs(lat - coord.lat) < 0.5 && Math.abs(lon - coord.lng) < 0.5;
  }

  /** 快照是否超过 60 分钟（无法解析视为过期） */
  private isStale(): boolean {
    if (this.weather === null) {
      return true;
    }
    const ms: number = Date.parse(this.weather.fetchedAt);
    if (Number.isNaN(ms)) {
      return true;
    }
    return Date.now() - ms > 60 * 60 * 1000;
  }

  /** 3 日预报 → 日历格子右上角真实天气标志（仅预报覆盖日期，其余空白） */
  private publishMarks(weather: WeatherOutcome): void {
    const marks: Record<string, string> = {};
    for (let i = 0; i < weather.days.length; i++) {
      const day: WeatherDayInfo = weather.days[i];
      const emoji: string = WeatherMark.emojiOfIcon(day.iconDay);
      if (day.fxDate.length > 0 && emoji.length > 0) {
        marks[day.fxDate] = emoji;
      }
    }
    AppStorage.setOrCreate('weatherDailyMarks', marks);
  }

  /** 实况小字：体感 x° · 湿度 x% · xx风x级 */
  private nowDetailText(w: WeatherOutcome): string {
    if (w.now === null) {
      return '';
    }
    const now: WeatherNowInfo = w.now;
    const parts: string[] = [];
    if (now.feelsLike.length > 0) {
      parts.push(trf('体感 {0}°', now.feelsLike));
    }
    if (now.humidity.length > 0) {
      parts.push(trf('湿度 {0}%', now.humidity));
    }
    if (now.windDir.length > 0 || now.windScale.length > 0) {
      parts.push(`${now.windDir}${trf('风{0}级', now.windScale)}`);
    }
    return parts.join(' · ');
  }

  /** 3 日预报日期标签：今天/明天/后天 */
  private dayLabel(index: number): string {
    if (index === 0) {
      return tr('今天');
    }
    if (index === 1) {
      return tr('明天');
    }
    if (index === 2) {
      return tr('后天');
    }
    if (this.weather === null || index >= this.weather.days.length) {
      return '';
    }
    const date: string = this.weather.days[index].fxDate;
    return date.length >= 10 ? date.substring(5) : date;
  }

  /** 逐小时列表实际展示：删除早于当前小时的时段（无法解析时刻的保守保留） */
  private visibleHours(): WeatherHourInfo[] {
    if (this.weather === null) {
      return [];
    }
    const list: WeatherHourInfo[] = [];
    for (let i = 0; i < this.weather.hours.length; i++) {
      const hour: WeatherHourInfo = this.weather.hours[i];
      const ms: number = Date.parse(hour.fxTime);
      if (Number.isNaN(ms) || ms >= this.hourStartMs) {
        list.push(hour);
      }
    }
    return list;
  }

  /** 周期检测跨小时：过去时段删除、当前时段居首并回归最左 */
  private checkHourRollover(): void {
    const hs: number = Math.floor(Date.now() / 3600000) * 3600000;
    if (hs !== this.hourStartMs) {
      this.hourStartMs = hs;
      this.returnHourScroll(true);
    }
  }

  /** 最近一个已过去的 00:00/12:00 半日边界（本地时区） */
  private latestHalfDayMs(now: number): number {
    const d: Date = new Date(now);
    const dayStart: number = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    return now - dayStart >= 12 * 3600 * 1000 ? dayStart + 12 * 3600 * 1000 : dayStart;
  }

  /** 自动刷新：跨 00:00/12:00 边界强制刷新；距上次成功更新超 12 小时补刷（30 分钟尝试冷却） */
  private checkAutoRefresh(): void {
    const now: number = Date.now();
    const boundary: number = this.latestHalfDayMs(now);
    if (boundary !== this.lastHalfDayMs) {
      this.lastHalfDayMs = boundary;
      this.lastAutoRefreshMs = now;
      this.refresh(true);
      return;
    }
    if (this.weather !== null && now - this.lastAutoRefreshMs > 30 * 60 * 1000) {
      const fetched: number = Date.parse(this.weather.fetchedAt);
      if (!Number.isNaN(fetched) && now - fetched > 12 * 3600 * 1000) {
        this.lastAutoRefreshMs = now;
        this.refresh(false);
      }
    }
  }

  /** 用户操作逐小时块：重置 3 秒无操作回归计时 */
  private scheduleHourReturn(): void {
    if (this.hourReturnId >= 0) {
      clearTimeout(this.hourReturnId);
    }
    this.hourReturnId = setTimeout(() => {
      this.hourReturnId = -1;
      this.returnHourScroll(true);
    }, 3000);
  }

  /** 逐小时横滑回到最左端（已在最左端时跳过，避免动画事件自循环） */
  private returnHourScroll(animated: boolean): void {
    if (this.weather === null || this.visibleHours().length === 0) {
      return;
    }
    if (Number(this.hourScroller.currentOffset().xOffset) <= 0.5) {
      return;
    }
    if (animated) {
      this.hourScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 300 } });
    } else {
      this.hourScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    }
  }

  /** 逐小时 fxTime（ISO 含时区）→ 'HH:mm' 本地时刻 */
  private hourText(fxTime: string): string {
    const ms: number = Date.parse(fxTime);
    if (Number.isNaN(ms)) {
      return fxTime.length >= 16 ? fxTime.substring(11, 16) : fxTime;
    }
    const d: Date = new Date(ms);
    const h: number = d.getHours();
    const m: number = d.getMinutes();
    return `${h < 10 ? '0' + h : h}:${m < 10 ? '0' + m : m}`;
  }

  /** HH:mm 直接展示；意外拿到 ISO 时截取时刻段 */
  private clockText(text: string): string {
    return text.length >= 16 ? text.substring(11, 16) : text;
  }

  /** fetchedAt（ISO）→ 'HH:mm' 本地时刻 */
  private fetchedTimeText(): string {
    if (this.weather === null) {
      return '';
    }
    const ms: number = Date.parse(this.weather.fetchedAt);
    if (Number.isNaN(ms)) {
      return this.weather.fetchedAt.length >= 16 ? this.weather.fetchedAt.substring(11, 16) : this.weather.fetchedAt;
    }
    const d: Date = new Date(ms);
    const h: number = d.getHours();
    const m: number = d.getMinutes();
    return `${h < 10 ? '0' + h : h}:${m < 10 ? '0' + m : m}`;
  }
}
