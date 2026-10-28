import { CalendarDay } from '../model/Types';
import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';
import { holidayOf } from '../common/Holidays';
import { isBirthdayDay } from '../store/BirthdayStore';

/**
 * 自绘月历：月份头 + 周头 + 7×6 日期格
 * 今日渐变圆底；hasEvent 红点；右上角角标：有天气标志时显示天气（覆盖📮明信片角标），无天气标志时显示📮；
 * 数字下方居中节日名小标（黑色，无节日占位同高保证整行数字垂直对齐）；休息日（周六/周日）数字红色；
 * 用户生日格红色「生日」小标（优先于节日名，每年同月同日重复）；月份头右侧 🎂 为主页生日设置入口
 */
@Component
export struct MonthCalendar {
  @StorageProp('appLang') appLang: string = 'zh';
  /** 3 日预报真实天气标志（'YYYY-MM-DD' → emoji；天气块拉取后经 AppStorage 发布） */
  @StorageProp('weatherDailyMarks') weatherMarks: Record<string, string> = {};
  @Prop @Watch('onDatesChange') eventDates: string[] = [];
  @Prop @Watch('onDatesChange') postcardDates: string[] = [];
  @Prop selectedDate: string = '';
  onDayTap: (day: CalendarDay) => void = () => {};
  /** 用户生日（'YYYY-MM-DD'，个人空间记录镜像，空串未设置）：生日格红「生日」标 */
  @StorageProp('userBirthday') userBirthday: string = '';
  /** 月份头 🎂 点击：主页生日设置入口（日程页接 DatePicker 设置生日） */
  onBirthdayTap: () => void = () => {};
  /** 顶部块（月份头+周头）实测高度回报（vp）：日程页据此推算日历卡片/Swiper 需要的高度，
   *  保证 6 行日期格完整显示（否则 Swiper 定高会裁掉第 6 行，如 2027-01-31 不显示） */
  onTopMeasure: (heightVp: number) => void = () => {};

  @State dispYear: number = 2026;
  @State dispMonth: number = 9;
  @State cells: CalendarDay[] = [];
  private weekLabels: string[] = [tr('日'), tr('一'), tr('二'), tr('三'), tr('四'), tr('五'), tr('六')];

  aboutToAppear(): void {
    const now: Date = new Date();
    this.dispYear = now.getFullYear();
    this.dispMonth = now.getMonth() + 1;
    this.rebuild();
  }

  onDatesChange(): void {
    this.rebuild();
  }

  /** 指定日期的真实天气标志（无预报覆盖返回空串） */
  private markOf(dateText: string): string {
    const mark: string | undefined = this.weatherMarks[dateText];
    return mark !== undefined ? mark : '';
  }

  /** 休息日（周六/周日） */
  private isRestDay(dateText: string): boolean {
    const parts: string[] = dateText.split('-');
    if (parts.length !== 3) {
      return false;
    }
    const wd: number = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2])).getDay();
    return wd === 0 || wd === 6;
  }

  private fmt(y: number, m: number, d: number): string {
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const dd: string = d < 10 ? `0${d}` : `${d}`;
    return `${y}-${mm}-${dd}`;
  }

  private shiftMonth(delta: number): void {
    let y: number = this.dispYear;
    let m: number = this.dispMonth + delta;
    if (m < 1) {
      m = 12;
      y -= 1;
    } else if (m > 12) {
      m = 1;
      y += 1;
    }
    this.dispYear = y;
    this.dispMonth = m;
    this.rebuild();
  }

  private rebuild(): void {
    const list: CalendarDay[] = [];
    const firstWeekday: number = new Date(this.dispYear, this.dispMonth - 1, 1).getDay();
    const daysInMonth: number = new Date(this.dispYear, this.dispMonth, 0).getDate();
    const daysInPrev: number = new Date(this.dispYear, this.dispMonth - 1, 0).getDate();
    const now: Date = new Date();
    const todayText: string = this.fmt(now.getFullYear(), now.getMonth() + 1, now.getDate());
    let i: number = 0;
    const prevY: number = this.dispMonth === 1 ? this.dispYear - 1 : this.dispYear;
    const prevM: number = this.dispMonth === 1 ? 12 : this.dispMonth - 1;
    for (i = 0; i < firstWeekday; i++) {
      const d: number = daysInPrev - firstWeekday + 1 + i;
      list.push(CalendarDay.of(d, false, false, false, false, this.fmt(prevY, prevM, d)));
    }
    for (i = 1; i <= daysInMonth; i++) {
      const dt: string = this.fmt(this.dispYear, this.dispMonth, i);
      list.push(CalendarDay.of(i, true, dt === todayText,
        this.eventDates.indexOf(dt) >= 0, this.postcardDates.indexOf(dt) >= 0, dt));
    }
    const nextY: number = this.dispMonth === 12 ? this.dispYear + 1 : this.dispYear;
    const nextM: number = this.dispMonth === 12 ? 1 : this.dispMonth + 1;
    let nextDay: number = 1;
    while (list.length < 42) {
      list.push(CalendarDay.of(nextDay, false, false, false, false, this.fmt(nextY, nextM, nextDay)));
      nextDay += 1;
    }
    this.cells = list;
  }

  build() {
    Column() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(22)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 14, right: 14, top: 4, bottom: 4 })
            .onClick(() => {
              this.shiftMonth(-1);
            })
          Text(trf('{0}年{1}月', this.dispYear, this.dispMonth))
            .fontSize(Theme.fontSectionTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Text('›')
            .fontSize(22)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 10, right: 6, top: 4, bottom: 4 })
            .onClick(() => {
              this.shiftMonth(1);
            })
          Text('🎂')
            .fontSize(16)
            .padding({ left: 2, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              this.onBirthdayTap();
            })
        }
        .width('100%')

        Row() {
          ForEach(this.weekLabels, (w: string) => {
            Text(w)
              .fontSize(Theme.fontTag)
              .fontColor($r('app.color.text_tertiary'))
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
          }, (w: string) => w)
        }
        .width('100%')
        .margin({ top: 10, bottom: 4 })
      }
      .width('100%')
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const h: number = typeof newArea.height === 'number' ? newArea.height : 0;
        if (h > 0) {
          this.onTopMeasure(h);
        }
      })

      Grid() {
        ForEach(this.cells, (d: CalendarDay) => {
          GridItem() {
            this.dayCell(d)
          }
        }, (d: CalendarDay) => `${this.dispYear}-${this.dispMonth}|${d.dateText}|${d.hasEvent ? 1 : 0}${d.hasPostcard ? 1 : 0}${this.selectedDate === d.dateText ? 1 : 0}|${this.markOf(d.dateText)}|${isBirthdayDay(this.userBirthday, d.dateText) ? 1 : 0}`)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr')
      .width('100%')
      .height(354) // 6 行 × 59：显式定高，保证部分月份落在第 6 行的日期（如 2027-01-31）完整显示
    }
    .width('100%')
  }

  @Builder
  dayCell(d: CalendarDay) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack({ alignContent: Alignment.Center }) {
          if (d.isToday) {
            Column()
              .width(34)
              .height(34)
              .linearGradient({
                angle: 135,
                colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
              })
              .borderRadius(17)
          } else if (this.selectedDate === d.dateText) {
            Column()
              .width(34)
              .height(34)
              .backgroundColor(Theme.brandSoft())
              .borderRadius(17)
          }
          Text(`${d.day}`)
            .fontSize(Theme.fontBody)
            .fontWeight(d.isToday ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(d.isToday ? Color.White : (d.inMonth && this.isRestDay(d.dateText) ? $r('app.color.badge_red') : (d.inMonth ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))))
            .opacity(d.inMonth ? 1 : 0.4)
        }
        .width(36)
        .height(36)
        .offset({ x: -1 })

        if (d.hasPostcard && this.markOf(d.dateText).length === 0) {
          Text('📮')
            .fontSize(9)
            .translate({ x: 2, y: -2 })
        }
        if (this.markOf(d.dateText).length > 0) {
          Text(this.markOf(d.dateText))
            .fontSize(12)
            .padding(1)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(10)
            .shadow({ radius: 3, color: $r('app.color.shadow_soft') })
            .translate({ x: 2, y: -2 })
        }
      }
      .width(38)
      .height(36)

      if (d.inMonth && isBirthdayDay(this.userBirthday, d.dateText)) {
        Text(tr('生日'))
          .fontSize(10)
          .maxLines(1)
          .height(14)
          .fontColor($r('app.color.badge_red'))
      } else if (d.inMonth && holidayOf(d.dateText).length > 0) {
        Text(holidayOf(d.dateText))
          .fontSize(10)
          .maxLines(1)
          .height(14)
          .fontColor($r('app.color.text_primary'))
      } else {
        Column().height(14)
      }

      if (d.hasEvent) {
        Column()
          .width(4)
          .height(4)
          .borderRadius(2)
          .backgroundColor($r('app.color.badge_red'))
      } else {
        Column().width(4).height(4).opacity(0)
      }
    }
    .width('100%')
    .height(59)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.onDayTap(d);
    })
  }
}
