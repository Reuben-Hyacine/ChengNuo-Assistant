import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';

/**
 * 卡片三维度标签（类型 / 场景 / 主题）的单选项
 */
export class TagOption {
  key: string = '';
  label: string = '';
}

/**
 * 卡片三维度标签选项（key = 服务器存储的英文枚举值，label 经 tr() 渲染展示文案）。
 * 三维度标签是隐藏元数据：卡片上不展示，用于积分计算、周报统计、卡片小铺推荐、
 * 天气联动与发现页筛选；每张卡片「确定」前三维度必须齐备（客户端为点选，非打字）。
 */
export function typeTagOptions(): TagOption[] {
  const pairs: string[][] = [
    ['work', '工作'],
    ['task', '任务'],
    ['activity', '活动'],
    ['routine', '日常']
  ];
  return pairs.map((p: string[]): TagOption => {
    const opt: TagOption = new TagOption();
    opt.key = p[0];
    opt.label = tr(p[1]);
    return opt;
  });
}

export function sceneTagOptions(): TagOption[] {
  const pairs: string[][] = [
    ['indoor', '室内'],
    ['outdoor', '户外'],
    ['anywhere', '不限地点']
  ];
  return pairs.map((p: string[]): TagOption => {
    const opt: TagOption = new TagOption();
    opt.key = p[0];
    opt.label = tr(p[1]);
    return opt;
  });
}

export function themeTagOptions(): TagOption[] {
  const pairs: string[][] = [
    ['academic', '学习'],
    ['sports', '运动'],
    ['entertainment', '娱乐'],
    ['social', '社交'],
    ['creative', '创作'],
    ['life', '生活']
  ];
  return pairs.map((p: string[]): TagOption => {
    const opt: TagOption = new TagOption();
    opt.key = p[0];
    opt.label = tr(p[1]);
    return opt;
  });
}

/**
 * 三维度标签单选选择器：一行标签 + 可换行 chips（点选而非打字）；
 * 选中 chip 反色高亮（brand 底白字），再点已选项不取消（三维度必选，无清空入口）
 */
@Component
export struct TagPicker {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop label: string = '';
  @Prop options: TagOption[] = [];
  @Prop selected: string = '';
  onPick: (key: string) => void = (_key: string) => {};

  build() {
    Column({ space: 6 }) {
      Text(this.label)
        .fontSize(Theme.fontTag)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_secondary'))
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.options, (opt: TagOption) => {
          Text(opt.label)
            .fontSize(Theme.fontTag)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.selected === opt.key ? Color.White : $r('app.color.text_secondary'))
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .backgroundColor(this.selected === opt.key ? Theme.brand() : $r('app.color.chip_bg'))
            .borderRadius(Theme.radiusBtn)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.onPick(opt.key);
            })
        }, (opt: TagOption) => `${opt.key}-${this.selected === opt.key}-${this.appLang}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
