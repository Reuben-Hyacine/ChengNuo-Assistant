import { ServerGateway } from '../net/ServerGateway';
import { MessageOutcome, WeekReportOutcome } from '../net/ServerModels';
import { WeeklyReportBlocks } from '../components/WeeklyReportBlocks';
import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';

/**
 * 周报数据（个人信息进入）：查看本机周报库内容——本周窗口 + 五板块统计（复用「我的」页周报组件），
 * 底部「清除周报数据」按钮删除本机周报库（reports.txt，仅当前账号）。
 * 清除后本周设立数等由服务器快照在下次周报（74）时重新统计，打卡/完成/延时等客户端累计数从零开始。
 */
@Entry
@Component
struct WeekReportDataPage {
  @StorageProp('appLang') appLang: string = 'zh';
  @State report: WeekReportOutcome = new WeekReportOutcome();
  @State loading: boolean = true;
  @State clearing: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    const outcome: WeekReportOutcome = await ServerGateway.weekReport();
    this.loading = false;
    this.report = outcome.ok ? outcome : new WeekReportOutcome();
  }

  /** 周报日期区间（周一 - 周日，如「9月22日 - 9月28日」）：优先用后端返回的周窗口，未加载时本地推算本周一 */
  private weekRangeText(): string {
    let startMs: number = this.report.weekStartMs;
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

  /** 完成率展示文本：0-1 小数转百分比；null = 本周还没有到期卡片（显示 —） */
  private rateText(): string {
    if (this.report.rate === null) {
      return '—';
    }
    return `${Math.round(this.report.rate * 100)}%`;
  }

  /** 清除确认：本机周报数据删后由下次周报重新统计 */
  private confirmClear(): void {
    this.getUIContext().showAlertDialog({
      title: tr('清除周报数据'),
      message: tr('清除后无法恢复，确定清除吗？'),
      primaryButton: {
        value: tr('先留着'),
        action: (): void => {
        }
      },
      secondaryButton: {
        value: tr('清除'),
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
    const outcome: MessageOutcome = await ServerGateway.clearWeekReport();
    this.clearing = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    this.report = new WeekReportOutcome();
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
        Text(tr('周报数据'))
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
          } else {
            // 周报主体：标题 + 周区间 + 五板块（与「我的」页同款组件）
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

              WeeklyReportBlocks({
                setCount: this.report.setCount,
                doneCount: this.report.doneCount,
                extendCount: this.report.extendCount,
                tagCounts: this.report.tagCounts
              })
            }
            .width('100%')
            .padding(18)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

            // 本周明细
            Column() {
              this.statRow(tr('本周设立'), `${this.report.setCount}`)
              this.statRow(tr('本周打卡'), `${this.report.checkinCount}`)
              this.statRow(tr('本周完成'), `${this.report.doneCount}`)
              this.statRow(tr('本周延时'), `${this.report.extendCount}`)
              this.statRow(tr('完成率'), this.rateText())
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

            // 清除按钮：删除本机周报库（仅当前账号）
            Column() {
              Text(this.clearing ? tr('清除中…') : tr('清除周报数据'))
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

            Text(tr('周报数据仅保存在本机；清除后将从下一次统计开始重新累计'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ left: 12, right: 12, bottom: 8 })
          }
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

  /** 明细行：标签靠左、数值靠右 */
  @Builder
  private statRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(Theme.fontBody)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(value)
        .fontSize(Theme.fontBody)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 13, bottom: 13 })
  }
}
