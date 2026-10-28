import { InboxButton } from './InboxButton';
import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';

/**
 * 统一页头：企鹅吉祥物 + 标题 + 搜索胶囊 + 收件箱入口
 */
@Component
export struct PageHeader {
  @StorageProp('appLang') appLang: string = 'zh';
  @Prop title: string = '';
  @Prop showSearch: boolean = true;
  onSearchTap: (() => void) | undefined = undefined;

  build() {
    Row() {
      Image($r('app.media.penguin'))
        .width(40)
        .height(40)
        .objectFit(ImageFit.Contain)
        .margin({ right: 8 })

      Text(this.title)
        .fontSize(Theme.fontPageTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Blank()

      if (this.showSearch) {
        Row({ space: 6 }) {
          Image($r('app.media.icon_search'))
            .width(22)
            .height(22)
          Text(tr('搜索'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(20)
        .margin({ right: 12 })
        .onClick(() => {
          if (this.onSearchTap !== undefined) {
            this.onSearchTap();
          } else {
            this.getUIContext().getPromptAction().showToast({ message: tr('搜索是演示功能，随便看看～') });
          }
        })
      }

      InboxButton()
    }
    .width('100%')
    .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 14, bottom: 10 })
    .backgroundColor($r('app.color.nav_bg'))
    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
  }
}
