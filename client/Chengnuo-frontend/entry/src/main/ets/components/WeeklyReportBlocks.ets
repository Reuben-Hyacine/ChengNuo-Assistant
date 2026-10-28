import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';
import { TagOption, typeTagOptions, sceneTagOptions, themeTagOptions } from './TagPicker';
import { display } from '@kit.ArkUI';

/**
 * 周报五板块（「我的」页周报卡正文）：第 1 块 = 原周报正文（本周完成率 + 设立/完成/延时计数），
 * 第 2-5 块 = 累计统计块（时段分布横向柱状图 + 类型/场景/主题环状图）。
 * 五个等高板块上下滑动循环切换（参考日程页日历块 ↔ 天气块的 Swiper 切换与红点指示器，卡高不随切换跳变）。
 * 统计块数据 = 周报库累计计数 tagCounts（键 = day:morning / type:work 等，值 = 归入该类的累计卡片数，
 * 「一旦设置就 +1、累计不删除」）；百分比按维度内部占比换算（四舍五入，总和可能不为 100）
 */

/** 一个统计项：展示文案 + 累计数量 + 颜色 + 维度内百分比（0-100 整数） */
export class ChartSlice {
  label: string = '';
  count: number = 0;
  color: string = '';
  percent: number = 0;
}

/** 环状图的一段扇环（Path 命令 + 填充色） */
class RingSegment {
  cmd: string = '';
  color: string = '';
}

/** 时段三属性（key = 周报计数键 day:morning 等，label 经 tr() 渲染） */
export function daySlotOptions(): TagOption[] {
  const pairs: string[][] = [
    ['morning', '上午'],
    ['afternoon', '下午'],
    ['night', '夜晚']
  ];
  return pairs.map((p: string[]): TagOption => {
    const opt: TagOption = new TagOption();
    opt.key = p[0];
    opt.label = tr(p[1]);
    return opt;
  });
}

/** 各维度配色（与标签枚举顺序一一对应） */
const DAY_COLORS: string[] = ['#F5A623', '#FF7A59', '#5B8DEF'];
const TYPE_COLORS: string[] = ['#FF7A59', '#5B8DEF', '#F5A623', '#35B37D'];
const SCENE_COLORS: string[] = ['#FF7A59', '#35B37D', '#5B8DEF'];
const THEME_COLORS: string[] = ['#5B8DEF', '#35B37D', '#F5A623', '#FF7A59', '#9B59D0', '#E85A33'];
/** 环状图视觉直径（vp）：中心套住「N 张」总数，右侧留给图例（标签 + 百分比不截断） */
const RING_SIZE: number = 115;
const RING_STROKE: number = 16;
/** Swiper 定高：五个板块等高（取最高块的主题 6 项图例高度，内容垂直居中，滑动不跳变） */
const BLOCK_HEIGHT: number = 240;

/** Path 的 commands 坐标单位是物理 px（组件宽高默认 vp），按屏幕密度把 vp 视觉尺寸换算进命令坐标 */
function screenScale(): number {
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    return d.densityPixels > 0 ? d.densityPixels : 3;
  } catch (e) {
    return 3;
  }
}

/** 周报第 1 块：本周完成率 + 设立/完成/延时计数（原周报正文，现为五板块之首） */
@Component
struct OverviewBlock {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop setCount: number = 0;
  @Prop doneCount: number = 0;
  @Prop extendCount: number = 0;

  /** 本周完成率：完成数 / 设立数，四舍五入封顶 100；本周还没有设立卡片时为 0 */
  private completionRate(): number {
    if (this.setCount <= 0) {
      return 0;
    }
    const rate: number = Math.round(this.doneCount * 100 / this.setCount);
    return rate > 100 ? 100 : rate;
  }

  build() {
    Column({ space: 14 }) {
      // 本周完成率：完成数 / 设立数
      Column({ space: 4 }) {
        Text(`${this.completionRate()}%`)
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.brandDeep())
        Text(tr('完成率'))
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_secondary'))
      }
      .padding({ left: 30, right: 30, top: 14, bottom: 14 })
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(20)
      .border({ width: 1.5, color: Theme.brand() })

      // 本周三项计数：设立 / 完成 / 延期
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(`${this.setCount}`)
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(tr('设立'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .padding({ top: 12, bottom: 12 })
        .borderRadius(Theme.radiusTag)
        .backgroundColor($r('app.color.bg_card'))

        Column({ space: 4 }) {
          Text(`${this.doneCount}`)
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(tr('完成'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .padding({ top: 12, bottom: 12 })
        .borderRadius(Theme.radiusTag)
        .backgroundColor($r('app.color.bg_card'))

        Column({ space: 4 }) {
          Text(`${this.extendCount}`)
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(tr('延期'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .padding({ top: 12, bottom: 12 })
        .borderRadius(Theme.radiusTag)
        .backgroundColor($r('app.color.bg_card'))
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(14)
    .backgroundColor($r('app.color.bg_page'))
    .borderRadius(16)
  }
}

/** 环状图：按 ChartSlice 占比画扇环（Path commands 单位物理 px，按屏幕密度缩放到 115vp），
  * 中心显示累计总张数（套在环孔空白处），环与总数同心居中 */
@Component
struct DonutChart {
  @Prop slices: ChartSlice[] = [];

  private totalOf(): number {
    let total: number = 0;
    for (let i = 0; i < this.slices.length; i++) {
      total += this.slices[i].count;
    }
    return total;
  }

  /** 扇环 Path 命令：外弧 a0→a1 顺时针、内弧反向闭合（y 轴向下，-π/2 = 顶部；a1 > a0） */
  private segmentCmd(c: number, rOut: number, rIn: number, a0: number, a1: number): string {
    const large: number = (a1 - a0) > Math.PI ? 1 : 0;
    const x0o: number = c + rOut * Math.cos(a0);
    const y0o: number = c + rOut * Math.sin(a0);
    const x1o: number = c + rOut * Math.cos(a1);
    const y1o: number = c + rOut * Math.sin(a1);
    const x1i: number = c + rIn * Math.cos(a1);
    const y1i: number = c + rIn * Math.sin(a1);
    const x0i: number = c + rIn * Math.cos(a0);
    const y0i: number = c + rIn * Math.sin(a0);
    return `M ${x0o.toFixed(2)} ${y0o.toFixed(2)} `
      + `A ${rOut.toFixed(2)} ${rOut.toFixed(2)} 0 ${large} 1 ${x1o.toFixed(2)} ${y1o.toFixed(2)} `
      + `L ${x1i.toFixed(2)} ${y1i.toFixed(2)} `
      + `A ${rIn.toFixed(2)} ${rIn.toFixed(2)} 0 ${large} 0 ${x0i.toFixed(2)} ${y0i.toFixed(2)} Z`;
  }

  /** 全环底轨 Path 命令（外圈顺时针一整圈 + 内圈逆时针一整圈） */
  private trackCmd(c: number, rOut: number, rIn: number): string {
    return `M ${c - rOut} ${c} `
      + `A ${rOut} ${rOut} 0 0 1 ${c + rOut} ${c} `
      + `A ${rOut} ${rOut} 0 0 1 ${c - rOut} ${c} `
      + `L ${c - rIn} ${c} `
      + `A ${rIn} ${rIn} 0 0 0 ${c + rIn} ${c} `
      + `A ${rIn} ${rIn} 0 0 0 ${c - rIn} ${c} Z`;
  }

  /** 底轨命令（commands 单位 px、组件宽高 vp，按屏幕密度缩放坐标） */
  private trackCmdScaled(): string {
    const scale: number = screenScale();
    return this.trackCmd(RING_SIZE / 2 * scale, (RING_SIZE / 2 - 1) * scale,
      (RING_SIZE / 2 - 1 - RING_STROKE) * scale);
  }

  /** 全部扇环：多段时段间留 ≤1° 视觉缝隙；单一 100% 段拆两个半环（整圆弧命令会退化） */
  private segments(): RingSegment[] {
    const out: RingSegment[] = [];
    const total: number = this.totalOf();
    if (total <= 0) {
      return out;
    }
    const scale: number = screenScale();
    const c: number = RING_SIZE / 2 * scale;
    const rOut: number = (RING_SIZE / 2 - 1) * scale;
    const rIn: number = rOut - RING_STROKE * scale;
    const twoPi: number = Math.PI * 2;
    let active: number = 0;
    for (let i = 0; i < this.slices.length; i++) {
      if (this.slices[i].count > 0) {
        active += 1;
      }
    }
    if (active === 1) {
      for (let i = 0; i < this.slices.length; i++) {
        if (this.slices[i].count > 0) {
          const top: number = -Math.PI / 2;
          const s1: RingSegment = new RingSegment();
          s1.cmd = this.segmentCmd(c, rOut, rIn, top, top + Math.PI);
          s1.color = this.slices[i].color;
          out.push(s1);
          const s2: RingSegment = new RingSegment();
          s2.cmd = this.segmentCmd(c, rOut, rIn, top + Math.PI, top + twoPi);
          s2.color = this.slices[i].color;
          out.push(s2);
          break;
        }
      }
      return out;
    }
    let angle: number = -Math.PI / 2;
    for (let i = 0; i < this.slices.length; i++) {
      const count: number = this.slices[i].count;
      if (count <= 0) {
        continue;
      }
      const sweep: number = count / total * twoPi;
      const gap: number = Math.min(Math.PI / 180, sweep / 4);
      const seg: RingSegment = new RingSegment();
      seg.cmd = this.segmentCmd(c, rOut, rIn, angle + gap, angle + sweep - gap);
      seg.color = this.slices[i].color;
      out.push(seg);
      angle += sweep;
    }
    return out;
  }

  build() {
    Stack() {
      // 底轨/扇环 Path 必须显式定宽高：不设时 Path 按命令包围盒自适应，
      // 各扇环包围盒不同再被 Stack 居中会导致弧段错位（层次乱）
      Path()
        .commands(this.trackCmdScaled())
        .fill($r('app.color.bg_card'))
        .width(RING_SIZE)
        .height(RING_SIZE)
      ForEach(this.segments(), (seg: RingSegment) => {
        Path()
          .commands(seg.cmd)
          .fill(seg.color)
          .width(RING_SIZE)
          .height(RING_SIZE)
      }, (seg: RingSegment) => `${seg.color}-${seg.cmd}`)
      Column() {
        Text(`${this.totalOf()}`)
          .fontSize(Theme.fontSectionTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(tr('张'))
          .fontSize(Theme.fontTag)
          .fontColor($r('app.color.text_tertiary'))
      }
      .justifyContent(FlexAlign.Center)
    }
    .width(RING_SIZE)
    .height(RING_SIZE)
  }
}

/** 单个统计块（Swiper 一页，等高）：标题 + 「累计」角标 +（横向柱状图 | 环状图 + 图例）；维度内全为 0 时显示占位文案 */
@Component
struct ChartBlock {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop title: string = '';
  @Prop slices: ChartSlice[] = [];
  /** true = 横向柱状图（时段）；false = 环状图 + 图例（三维度） */
  @Prop bar: boolean = false;

  private totalOf(): number {
    let total: number = 0;
    for (let i = 0; i < this.slices.length; i++) {
      total += this.slices[i].count;
    }
    return total;
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.title)
          .fontSize(Theme.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(tr('累计'))
          .fontSize(Theme.fontTag)
          .fontColor(Theme.brandDeep())
          .backgroundColor(Theme.brandSoft())
          .borderRadius(Theme.radiusBtn)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      }
      .width('100%')

      if (this.totalOf() <= 0) {
        Column() {
          Text(tr('暂无统计数据'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.bar) {
        // 时段分布：横向柱状图（占比百分比条，内容垂直居中填满等高块）
        Column({ space: 10 }) {
          ForEach(this.slices, (s: ChartSlice) => {
            Row({ space: 10 }) {
              Text(s.label)
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_secondary'))
                .width(64)
                .maxLines(1)
              Stack({ alignContent: Alignment.Start }) {
                Column()
                  .width('100%')
                  .height(10)
                  .borderRadius(5)
                  .backgroundColor($r('app.color.bg_card'))
                Column()
                  .width(`${Math.min(100, Math.max(s.count > 0 ? 3 : 0, s.percent))}%`)
                  .height(10)
                  .borderRadius(5)
                  .backgroundColor(s.color)
              }
              .layoutWeight(1)
              Text(`${s.count} · ${s.percent}%`)
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_secondary'))
                .width(64)
                .textAlign(TextAlign.End)
            }
            .width('100%')
          }, (s: ChartSlice) => `${s.label}-${s.count}-${s.percent}-${this.appLang}`)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 类型 / 场景 / 主题分布：环状图（中心套总数）+ 图例（标签 + 维度内百分比，0 项置灰，不显示数量），
        // 图例 layoutWeight 占满环右侧剩余宽度（向左扩张不遮挡环），内容垂直居中填满等高块
        Row({ space: 12 }) {
          DonutChart({ slices: this.slices })
          Column({ space: 6 }) {
            ForEach(this.slices, (s: ChartSlice) => {
              Row({ space: 6 }) {
                Circle()
                  .width(10)
                  .height(10)
                  .fill(s.color)
                Text(s.label)
                  .fontSize(Theme.fontCaption)
                  .fontColor(s.count > 0 ? $r('app.color.text_secondary') : $r('app.color.text_tertiary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${s.percent}%`)
                  .fontSize(Theme.fontCaption)
                  .fontColor(s.count > 0 ? $r('app.color.text_secondary') : $r('app.color.text_tertiary'))
              }
              .width('100%')
            }, (s: ChartSlice) => `${s.label}-${s.count}-${s.percent}-${this.appLang}`)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor($r('app.color.bg_page'))
    .borderRadius(16)
  }
}

/**
 * 周报五板块：接收本周计数（setCount/doneCount/extendCount）与周报库累计计数 tagCounts
 * （键 = day:morning / type:work 等，值 = 累计卡片数），
 * 五个等高板块上下滑动循环切换（右侧竖排红点指示器高亮当前板块，样式同日程页日历块 ↔ 天气块）
 */
@Component
export struct WeeklyReportBlocks {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop setCount: number = 0;
  @Prop doneCount: number = 0;
  @Prop extendCount: number = 0;
  @Prop tagCounts: Record<string, number> = {};
  /** 当前板块页（0=完成率与本周计数 1=时段 2=类型 3=场景 4=主题；右侧竖排红点指示器高亮当前页） */
  @State pageIndex: number = 0;

  private countOf(key: string): number {
    const value: number | undefined = this.tagCounts[key];
    return value === undefined ? 0 : value;
  }

  private slicesOf(dim: string, options: TagOption[], colors: string[]): ChartSlice[] {
    let total: number = 0;
    const counts: number[] = [];
    for (let i = 0; i < options.length; i++) {
      const count: number = this.countOf(`${dim}:${options[i].key}`);
      counts.push(count);
      total += count;
    }
    const out: ChartSlice[] = [];
    for (let i = 0; i < options.length; i++) {
      const s: ChartSlice = new ChartSlice();
      s.label = options[i].label;
      s.count = counts[i];
      s.color = colors[i % colors.length];
      s.percent = total > 0 ? Math.round(counts[i] * 100 / total) : 0;
      out.push(s);
    }
    return out;
  }

  build() {
    Row({ space: 10 }) {
      Swiper() {
        OverviewBlock({ setCount: this.setCount, doneCount: this.doneCount, extendCount: this.extendCount })
        ChartBlock({ title: tr('时段分布'), slices: this.slicesOf('day', daySlotOptions(), DAY_COLORS), bar: true })
        ChartBlock({ title: tr('类型分布'), slices: this.slicesOf('type', typeTagOptions(), TYPE_COLORS), bar: false })
        ChartBlock({ title: tr('场景分布'), slices: this.slicesOf('scene', sceneTagOptions(), SCENE_COLORS), bar: false })
        ChartBlock({ title: tr('主题分布'), slices: this.slicesOf('theme', themeTagOptions(), THEME_COLORS), bar: false })
      }
      .vertical(true)
      .loop(true)
      .duration(300)
      .indicator(false)
      .height(BLOCK_HEIGHT)
      .layoutWeight(1)
      .onChange((index: number) => {
        this.pageIndex = index;
      })

      // 右侧红点指示器（竖排，样式同日历 ↔ 天气块红点）：五枚红点标示可上下滑动，当前板块红点竖向拉长高亮
      Column({ space: 6 }) {
        Column()
          .width(6)
          .height(this.pageIndex === 0 ? 16 : 6)
          .borderRadius(3)
          .backgroundColor(this.pageIndex === 0 ? '#E53935' : '#4DE53935')
          .animation({ duration: 200, curve: Curve.EaseInOut })
        Column()
          .width(6)
          .height(this.pageIndex === 1 ? 16 : 6)
          .borderRadius(3)
          .backgroundColor(this.pageIndex === 1 ? '#E53935' : '#4DE53935')
          .animation({ duration: 200, curve: Curve.EaseInOut })
        Column()
          .width(6)
          .height(this.pageIndex === 2 ? 16 : 6)
          .borderRadius(3)
          .backgroundColor(this.pageIndex === 2 ? '#E53935' : '#4DE53935')
          .animation({ duration: 200, curve: Curve.EaseInOut })
        Column()
          .width(6)
          .height(this.pageIndex === 3 ? 16 : 6)
          .borderRadius(3)
          .backgroundColor(this.pageIndex === 3 ? '#E53935' : '#4DE53935')
          .animation({ duration: 200, curve: Curve.EaseInOut })
        Column()
          .width(6)
          .height(this.pageIndex === 4 ? 16 : 6)
          .borderRadius(3)
          .backgroundColor(this.pageIndex === 4 ? '#E53935' : '#4DE53935')
          .animation({ duration: 200, curve: Curve.EaseInOut })
      }
      .height(BLOCK_HEIGHT)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
