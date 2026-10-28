import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';

/**
 * 关于我们页（关于程诺入口）：程诺介绍 / 团队与成员（Mygo企鹅研究中心）/ 我们关注 / 版本信息
 */
@Entry
@Component
struct AboutUsPage {
  /** 卡片小节标题：图标 + 标题 */
  @Builder
  private sectionTitle(icon: string, title: string) {
    Row({ space: 10 }) {
      Text(icon)
        .fontSize(18)
      Text(title)
        .fontSize(Theme.fontCardTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
  }

  /** 段落正文 */
  @Builder
  private para(text: string) {
    Text(text)
      .fontSize(Theme.fontBody)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
  }

  /** 分隔线 */
  @Builder
  private divider() {
    Column()
      .width('100%')
      .height(0.5)
      .backgroundColor($r('app.color.divider'))
  }

  /** 团队成员名胶囊（品牌浅底描边，样式同语言切换按钮） */
  @Builder
  private memberPill(name: string) {
    Text(name)
      .fontSize(Theme.fontBody)
      .fontColor(Theme.brandDeep())
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })
      .borderRadius(Theme.radiusBtn)
      .backgroundColor(Theme.brandSoft())
      .border({ width: 1, color: Theme.brand() })
  }

  /** 「我们关注」条目行：品牌色圆点 + 条目 */
  @Builder
  private focusRow(text: string) {
    Row({ space: 10 }) {
      Text('•')
        .fontSize(Theme.fontBody)
        .fontColor(Theme.brand())
      Text(text)
        .fontSize(Theme.fontBody)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
  }

  /** 版本信息键值行：左标签 + 右值（长链接省略号截断） */
  @Builder
  private infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(Theme.fontBody)
        .fontColor($r('app.color.text_secondary'))
      Text(value)
        .fontSize(Theme.fontBody)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
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
        Text(tr('关于我们'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 12 }) {
            this.sectionTitle('🍊', tr('关于程诺'))
            this.para(tr('程诺是一款需要联网使用的、基于 HarmonyOS 的 AI 日程应用，核心理念是"说到做到，一诺千金"——把每个承诺变成可见、可提醒、可回味的卡片。'))
            this.para(tr('你可以把它当成一个会聊天的日程助手。把作业、考试、社团、实习和临时安排告诉 AI，它就能帮你生成日程卡片，还可以整理进卡片组。到点后，程诺会通过应用内弹窗、系统通知和邮件提醒你。完成后，卡片以碎卡动画收起，AI 自动生成一张明信片作为回忆，并汇总到周报里，帮你回顾完成率、延时情况。如果时间有变，还可以调整日程时间。'))
            this.para(tr('日程之外还有更多伙伴功能：养一只小企鹅陪你打卡，用积分在装饰商城为它换装；在发现页逛 AI 推荐的小铺卡片，一键加入日程；用倒计时记下生日、纪念日和重要日子，每年重复的会自动数下一次，生日当天还有专属祝福和月历标记。'))
            this.para(tr('程诺还提供天气和锁屏卡片。锁屏卡片不解锁就能完成、延时或取消日程。明信片、周报等长期数据优先保存在本机，服务器只做短期中转，注重隐私。界面支持中英文切换，部分基础功能可离线应答。'))
            this.para(tr('程诺是鸿蒙应用大赛参赛作品，最终将以 Apache-2.0 许可证开源。'))
          }
          .width('100%')
          .padding(18)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Column({ space: 12 }) {
            this.sectionTitle('🐧', tr('关于我们'))
            this.para(tr('Mygo企鹅研究中心（由复旦大学 2025 级软件工程专业三名学生组成的兴趣团队）关注校园效率工具、HarmonyOS 应用开发和智能体应用。我们发起「程诺」，是因为我们相信校园日程不该只是课表。作业、考试、社团、实习和临时安排，都值得被更好地规划。我们希望「程诺」成为一款开源、尊重用户数据的日程规划应用，让安排日程更简单、更智能。'))
            Text(tr('团队成员目前有：'))
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Row({ space: 10 }) {
              this.memberPill('陈思翰')
              this.memberPill('沈宜其')
              this.memberPill('韦庆朗')
            }
            .width('100%')
          }
          .width('100%')
          .padding(18)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Column({ space: 12 }) {
            this.sectionTitle('💡', tr('我们关注'))
            this.focusRow(tr('校园场景下的效率工具'))
            this.focusRow(tr('HarmonyOS 应用开发'))
            this.focusRow(tr('智能体与日程规划结合'))
            this.focusRow(tr('开源协作与知识共享'))
            this.para(tr('欢迎通过 GitHub Issues 或邮箱联系我们。'))
          }
          .width('100%')
          .padding(18)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Column({ space: 12 }) {
            this.sectionTitle('📱', tr('版本信息'))
            this.infoRow(tr('版本'), 'v1.0.0')
            this.divider()
            this.infoRow(tr('开发者'), tr('Mygo企鹅研究中心'))
            this.divider()
            this.infoRow(tr('开源许可证'), tr('（拟定）Apache-2.0'))
          }
          .width('100%')
          .padding(18)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Text('© 2026 ' + tr('Mygo企鹅研究中心'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 12, bottom: 24 })
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
}
