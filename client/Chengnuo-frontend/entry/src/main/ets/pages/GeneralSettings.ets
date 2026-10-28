import { Backend, ProfileRecord } from '@chengnuo/backend';
import { appStore } from '../store/AppStore';
import { ServerGateway } from '../net/ServerGateway';
import { Theme } from '../common/Theme';
import { tr } from '../common/I18n';
import { langStore } from '../store/LangStore';
import { themeStore } from '../store/ThemeStore';

/** 主题色候选（首项为默认珊瑚橙） */
const THEME_COLOR_OPTIONS: string[] = [
  '#FF7A59', '#E5484D', '#F5A623', '#35B37D', '#14B8A6',
  '#5B8DEF', '#6366F1', '#9B59D0', '#EC4899', '#8D6E63'
];

/**
 * 通用设置：功能入口（个人空间 / 提醒设置 / 账号安全）+ 个性化（主题色）+ 个性化服务开关（默认开启）+ 界面语言（默认中文）。
 *  - 主题色：持久化到 preferences（app_theme），AppStorage('themeColor') 供 Theme.brand()/brandDeep()/brandSoft()
 *          全局读取；切换后清空路由栈回主页重建，保证已渲染页面按新主题色重绘。
 *  - 个性化开启：双向传输通道打开——对话记录仅保存在本机，历史随请求提供给 AI 提供个性化服务，
 *          并自动把个人空间信息写一份进用户信息（AI 上下文「本人用户资料」）；
 *  - 个性化关闭：切换的同时清空本机已存的对话记录与用户信息，并关闭储存通道——不再记录对话记录，
 *          此时传输给 AI 的对话记录与用户信息全部为空值；个人空间资料不受影响。
 *  AI 聊天、卡片、AI 明信片等全部 AI 服务不受开关影响，始终可用。
 *  - 语言切换只影响固定界面文案；卡片内容、用户名、聊天记录等用户数据保持原语言。
 */
@Entry
@Component
struct GeneralSettingsPage {
  @State personalizationOn: boolean = true;
  @StorageProp('appLang') appLang: string = 'zh';
  @State themeColor: string = Theme.DEFAULT_THEME;

  aboutToAppear(): void {
    this.personalizationOn = Backend.isPersonalizationEnabled();
    this.themeColor = AppStorage.get<string>('themeColor') ?? Theme.DEFAULT_THEME;
  }

  private handleToggle(isOn: boolean): void {
    if (isOn === this.personalizationOn) {
      return;
    }
    this.personalizationOn = isOn;
    Backend.setPersonalizationEnabled(isOn);
    if (!isOn) {
      // 关闭：清空用户信息（93 clear）；个人空间资料不动。失败静默——开关是本地状态，
      // 残留的用户信息会在下次开启时被重新覆盖
      ServerGateway.syncUserInfoClear().then((): void => {
      });
      this.getUIContext().getPromptAction().showToast({ message: tr('已关闭：本机对话记录与用户信息已清空') });
    } else {
      // 开启：自动把个人空间信息写一份进用户信息（93 put）
      this.syncProfileIntoUserInfo();
      this.getUIContext().getPromptAction().showToast({ message: tr('已开启个性化服务') });
    }
  }

  /** 把本机个人空间副本写进用户信息（个性化服务开启时调用；无资料或失败均静默） */
  private syncProfileIntoUserInfo(): void {
    const account: string = appStore.getAccount();
    if (account.length === 0) {
      return;
    }
    const record: ProfileRecord | null = Backend.getProfileRecord(account);
    if (record === null) {
      return;
    }
    const fields: Record<string, Object> = {
      'gender': record.gender,
      'birthday': record.birthday,
      'signature': record.signature,
      'province': record.province,
      'city': record.city
    };
    ServerGateway.syncUserInfoPut(fields).then((): void => {
    });
  }

  private handleLang(lang: string): void {
    if (this.appLang === lang) {
      return;
    }
    AppStorage.setOrCreate('appLang', lang);
    langStore.save(lang);
    this.getUIContext().getPromptAction().showToast({
      message: lang === 'en' ? 'Language switched to English' : tr('已切换为中文')
    });
    // ArkUI V1 按节点最小化刷新，tr() 内部读 AppStorage 不产生渲染依赖，
    // 已渲染页面不会随 appLang 变化刷新；清空路由栈回到主页，全部页面重建为新语言。
    this.getUIContext().getRouter().clear();
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Main' });
  }

  /** 切换主题色：写 AppStorage + 持久化，清路由栈回主页全量重绘（与语言切换同模式） */
  private handleTheme(hex: string): void {
    if (this.themeColor === hex) {
      return;
    }
    this.themeColor = hex;
    AppStorage.setOrCreate('themeColor', hex);
    themeStore.save(hex);
    this.getUIContext().getPromptAction().showToast({ message: tr('已切换主题色') });
    // Theme.brand() 内部读 AppStorage 不产生渲染依赖，已渲染页面不会自动刷新；
    // 清空路由栈回到主页，全部页面按新主题色重建。
    this.getUIContext().getRouter().clear();
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Main' });
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
        Text(tr('通用设置'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 16 }) {
          Column() {
            this.entryRow('🗂️', tr('个人信息'), (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/PersonalInfo' });
            })

            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor($r('app.color.divider'))

            this.entryRow('👤', tr('个人空间'), (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/PersonalSpace' });
            })

            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor($r('app.color.divider'))

            this.entryRow('🔔', tr('提醒设置'), (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/ReminderSettings' });
            })

            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor($r('app.color.divider'))

            this.entryRow('🛡️', tr('账号安全'), (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/AccountSecurity' });
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Column({ space: 12 }) {
            Row({ space: 12 }) {
              Text('🎨')
                .fontSize(18)
              Column({ space: 2 }) {
                Text(tr('个性化'))
                  .fontSize(Theme.fontBody)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text(tr('主题色：点选一款颜色，按钮与强调色即时跟随'))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_secondary'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(THEME_COLOR_OPTIONS, (hex: string) => {
                Stack() {
                  Column()
                    .width(30)
                    .height(30)
                    .borderRadius(15)
                    .backgroundColor(hex)
                  if (this.themeColor === hex) {
                    Text('✓')
                      .fontSize(15)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Color.White)
                  }
                }
                .width(38)
                .height(38)
                .borderRadius(19)
                .border({
                  width: 2,
                  color: this.themeColor === hex ? hex : Color.Transparent
                })
                .margin({ right: 10, bottom: 10 })
                .onClick(() => {
                  this.handleTheme(hex);
                })
              }, (hex: string) => hex)
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Column() {
            Row({ space: 12 }) {
              Text('🤖')
                .fontSize(18)
              Column({ space: 2 }) {
                Text(tr('个性化服务'))
                  .fontSize(Theme.fontBody)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text(this.personalizationOn ? tr('已开启：AI 记住你的对话与偏好') : tr('已关闭：AI 不记录任何个人信息'))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_secondary'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.personalizationOn })
                .selectedColor(Theme.brand())
                .switchPointColor(Color.White)
                .onChange((isOn: boolean) => {
                  this.handleToggle(isOn);
                })
            }
            .width('100%')
            .padding(16)
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

          Column({ space: 12 }) {
            Row({ space: 12 }) {
              Text('🌐')
                .fontSize(18)
              Column({ space: 2 }) {
                Text(tr('语言设置'))
                  .fontSize(Theme.fontBody)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Text(tr('界面文案语言；卡片与用户名保持原样'))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_secondary'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            Row({ space: 12 }) {
              Text('中文')
                .fontSize(Theme.fontBody)
                .fontColor(this.appLang === 'zh' ? Theme.brandDeep() : $r('app.color.text_secondary'))
                .padding({ left: 24, right: 24, top: 8, bottom: 8 })
                .borderRadius(Theme.radiusBtn)
                .backgroundColor(this.appLang === 'zh' ? Theme.brandSoft() : Color.Transparent)
                .border({
                  width: 1,
                  color: this.appLang === 'zh' ? Theme.brand() : $r('app.color.divider')
                })
                .onClick(() => {
                  this.handleLang('zh');
                })
              Text('English')
                .fontSize(Theme.fontBody)
                .fontColor(this.appLang === 'en' ? Theme.brandDeep() : $r('app.color.text_secondary'))
                .padding({ left: 24, right: 24, top: 8, bottom: 8 })
                .borderRadius(Theme.radiusBtn)
                .backgroundColor(this.appLang === 'en' ? Theme.brandSoft() : Color.Transparent)
                .border({
                  width: 1,
                  color: this.appLang === 'en' ? Theme.brand() : $r('app.color.divider')
                })
                .onClick(() => {
                  this.handleLang('en');
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusCard)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
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

  /** 功能入口行：图标 + 标题 + 箭头（与设置列表行样式一致） */
  @Builder
  private entryRow(icon: string, label: string, onTap: () => void) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(18)
      Text(label)
        .fontSize(Theme.fontBody)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
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
