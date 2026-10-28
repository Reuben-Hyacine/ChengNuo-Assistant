import { Theme } from '../common/Theme';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { tr } from '../common/I18n';
import { AGREEMENT_DOC, PRIVACY_DOC, DocBlock } from '../common/LegalDocs';
import { DocViewer } from './DocViewer';

/** 文档类型：用户协议 */
export const DOC_KIND_AGREEMENT: string = 'agreement';
/** 文档类型：隐私政策 */
export const DOC_KIND_PRIVACY: string = 'privacy';

/** 用户协议全文链接（官网，与 AGC 托管版本一致） */
export const AGREEMENT_DOC_URL: string = 'https://ourchengnuo.cn/agreement.html';
/** 隐私声明全文链接（官网，与 AGC 托管版本一致） */
export const PRIVACY_DOC_URL: string = 'https://ourchengnuo.cn/privacy.html';

/**
 * 协议勾选行：圆形勾选框 + 「我已阅读并同意《用户协议》和《隐私政策》」
 * - 勾选状态由父组件持有（checked + onToggle 回调）
 * - 《用户协议》《隐私政策》为蓝色可点标题（onOpenDoc 回调打开对应文档弹窗）
 * - 注意：Span 不支持触摸事件，蓝色标题用独立 Text 实现
 */
@Component
export struct AgreementCheckRow {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop checked: boolean = false;
  onToggle: (checked: boolean) => void = (checked: boolean) => {
  };
  onOpenDoc: (kind: string) => void = (kind: string) => {
  };

  build() {
    Row({ space: 4 }) {
      Checkbox()
        .shape(CheckBoxShape.CIRCLE)
        .select(this.checked)
        .selectedColor('#007DFF')
        .width(14)
        .height(14)
        .onChange((value: boolean) => {
          hilog.info(0x0, 'AgreementRow', 'onChange fired value=%{public}s', value ? 'true' : 'false');
          this.onToggle(value);
        })

      Text(tr('我已阅读并同意'))
        .fontSize(Theme.fontTag)
        .fontColor($r('app.color.text_secondary'))

      Text(tr('《用户协议》'))
        .fontSize(Theme.fontTag)
        .fontColor('#007DFF')
        .onClick(() => {
          this.onOpenDoc(DOC_KIND_AGREEMENT);
        })

      Text(tr('和'))
        .fontSize(Theme.fontTag)
        .fontColor($r('app.color.text_secondary'))

      Text(tr('《隐私政策》'))
        .fontSize(Theme.fontTag)
        .fontColor('#007DFF')
        .onClick(() => {
          this.onOpenDoc(DOC_KIND_PRIVACY);
        })
    }
    .width('100%')
    .height(30)
    .justifyContent(FlexAlign.Center)
  }
}

/**
 * 协议/隐私文档弹窗：全屏遮罩（点遮罩关闭）+ 居中卡片
 * - kind 取 DOC_KIND_AGREEMENT / DOC_KIND_PRIVACY
 * - 正文全文内嵌渲染（与官网/AGC 托管版本一致），底部附官网链接
 */
@Component
export struct AgreementDocDialog {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop kind: string = DOC_KIND_AGREEMENT;
  onClose: () => void = () => {
  };

  private titleOfKind(): string {
    return this.kind === DOC_KIND_PRIVACY ? tr('隐私政策') : tr('用户协议');
  }

  private urlOfKind(): string {
    return this.kind === DOC_KIND_PRIVACY ? PRIVACY_DOC_URL : AGREEMENT_DOC_URL;
  }

  private docOfKind(): DocBlock[] {
    return this.kind === DOC_KIND_PRIVACY ? PRIVACY_DOC : AGREEMENT_DOC;
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.45)')
        .onClick(() => {
          this.onClose();
        })

      Column() {
        Text(this.titleOfKind())
          .fontSize(Theme.fontCardTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 12 })

        Column() {
          DocViewer({ blocks: this.docOfKind() })
        }
        .layoutWeight(1)
        .width('100%')
        .backgroundColor($r('app.color.input_bg'))
        .borderRadius(Theme.radiusInput)
        .clip(true)

        Text(this.urlOfKind())
          .fontSize(Theme.fontTag)
          .fontColor(Theme.brandDeep())
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 10, bottom: 12 })

        Column() {
          Text(tr('我知道了'))
            .fontSize(Theme.fontBody)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
        }
        .width('100%')
        .height(44)
        .justifyContent(FlexAlign.Center)
        .linearGradient({
          angle: 135,
          colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
        })
        .borderRadius(Theme.radiusBtn)
        .onClick(() => {
          this.onClose();
        })
      }
      .width('88%')
      .height('78%')
      .padding(16)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(Theme.radiusModal)
      .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
  }
}
