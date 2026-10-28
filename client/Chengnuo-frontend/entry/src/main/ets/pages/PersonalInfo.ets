import { Backend, ProfileRecord } from '@chengnuo/backend';
import { appStore } from '../store/AppStore';
import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';
import { uidText } from '../common/Format';

/**
 * 个人信息（通用设置进入）：集中查看与管理保存在本机的个人信息。
 *  - 个人空间：只读摘要（头像/账号名/UID/性别/生日/地区/个性签名，读客户端本地副本），点击进个人空间修改；
 *  - 周报数据：进入独立页面查看本周统计与累计分布，可清除本机周报库（reports.txt）；
 *  - AI 对话记录：进入独立页面查看最近对话，可清空本机对话记录（conversations.txt）。
 *  周报与对话记录均只存本机；个人空间资料双端各存一份（本机 + 服务器），管理入口在个人空间页。
 */
@Entry
@Component
struct PersonalInfoPage {
  @StorageProp('userName') userName: string = tr('程诺用户');
  @StorageProp('serverUserId') serverUserId: number = 0;
  @StorageProp('appLang') appLang: string = 'zh';
  @State avatarUri: string = '';
  @State genderSel: string = '';
  @State birthdaySel: string = '';
  @State signText: string = '';
  @State provinceSel: string = '';
  @State citySel: string = '';

  aboutToAppear(): void {
    this.loadProfile();
  }

  /** 读本机个人空间副本（不拉服务器；摘要展示用，编辑在个人空间页） */
  private loadProfile(): void {
    const account: string = appStore.getAccount();
    this.avatarUri = Backend.profileAvatarUri(account);
    const record: ProfileRecord | null = Backend.getProfileRecord(account);
    this.genderSel = record !== null ? record.gender : '';
    this.birthdaySel = record !== null ? record.birthday : '';
    this.signText = record !== null ? record.signature : '';
    this.provinceSel = record !== null ? record.province : '';
    this.citySel = record !== null ? record.city : '';
  }

  private regionText(): string {
    if (this.provinceSel.length === 0) {
      return tr('未设置');
    }
    if (this.citySel.length === 0) {
      return this.provinceSel;
    }
    return `${this.provinceSel} ${this.citySel}`;
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
        Text(tr('个人信息'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 16 }) {
          // 个人空间：只读摘要，点击进个人空间修改
          Column() {
            Row({ space: 14 }) {
              if (this.avatarUri.length > 0) {
                Image(this.avatarUri)
                  .width(52)
                  .height(52)
                  .borderRadius(26)
                  .objectFit(ImageFit.Cover)
              } else {
                Image($r('app.media.penguin'))
                  .width(52)
                  .height(52)
                  .borderRadius(26)
                  .objectFit(ImageFit.Contain)
              }
              Column({ space: 3 }) {
                Text(this.userName)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.serverUserId > 0) {
                  Text(`UID：${uidText(this.serverUserId)}`)
                    .fontSize(Theme.fontCaption)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })

            this.infoRow(tr('性别'), this.genderSel.length > 0 ? tr(this.genderSel) : tr('未设置'),
              this.genderSel.length > 0)
            this.infoRow(tr('生日'), this.birthdaySel.length > 0 ? this.birthdaySel : tr('未设置'),
              this.birthdaySel.length > 0)
            this.infoRow(tr('地区'), this.regionText(), this.provinceSel.length > 0)
            this.infoRow(tr('个性签名'), this.signText.length > 0 ? this.signText : tr('未设置'),
              this.signText.length > 0)

            Text(tr('点击进入个人空间修改'))
              .fontSize(Theme.fontCaption)
              .fontColor(Theme.brandDeep())
              .width('100%')
              .textAlign(TextAlign.End)
              .padding({ left: 16, right: 16, top: 10, bottom: 14 })
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/PersonalSpace' });
          })

          // 本机数据管理：周报 / AI 对话记录
          Column() {
            this.dataEntryRow('📊', tr('周报数据'), tr('本机保存的每周统计与累计分布'), (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/WeekReportData' });
            })

            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor($r('app.color.divider'))

            this.dataEntryRow('💬', tr('AI 对话记录'), tr('本机保存的最近 10 条 AI 对话'), (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/ConversationsData' });
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Text(tr('周报与 AI 对话记录仅保存在本机；个人空间资料同时保存于本机与服务器'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ left: 12, right: 12 })
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

  /** 摘要信息行（只读）：标签 + 值（未设置显示占位灰色，多行值靠右对齐） */
  @Builder
  private infoRow(label: string, value: string, hasValue: boolean) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(Theme.fontBody)
        .fontColor($r('app.color.text_primary'))
        .width(72)
      Text(value)
        .fontSize(Theme.fontBody)
        .fontColor(hasValue ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /** 本机数据入口行：图标 + 标题/说明 + 箭头 */
  @Builder
  private dataEntryRow(icon: string, label: string, subtitle: string, onTap: () => void) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(18)
      Column({ space: 2 }) {
        Text(label)
          .fontSize(Theme.fontBody)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(subtitle)
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('›')
        .fontSize(18)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 15, bottom: 15 })
    .onClick(() => {
      onTap();
    })
  }
}
