import { appStore } from '../store/AppStore';
import { Theme } from '../common/Theme';
import { ServerGateway } from '../net/ServerGateway';
import { AccountOutcome, MessageOutcome } from '../net/ServerModels';
import { tr } from '../common/I18n';

/**
 * 设置引导页（界面2）：邮箱 / 华为注册成功后的首次设置。
 * - 昵称：预填自动账号名（UIDxxxxx），修改则走 82 改名（服务器全库级联 + 本地同步）
 * - 密码（仅邮箱注册模式显示）：设置后走 83 落密码（程诺密码 = 邮箱密码，登录用），
 *   可留空跳过——之后可在「我的」页设置或走登录页「忘记密码」重置
 * - 华为注册模式不显示密码（Account Kit 流程无密码概念，登录走华为一键登录）
 * - 「完成」按已填内容设置；「跳过」直接进入主界面
 */
@Entry
@Component
struct Setup {
  @StorageProp('appLang') appLang: string = 'zh';
  @State nickname: string = '';
  @State password: string = '';
  @State confirm: string = '';
  @State nicknameFocused: boolean = false;
  @State passwordFocused: boolean = false;
  @State confirmFocused: boolean = false;
  @State loading: boolean = false;
  private huaweiMode: boolean = false;

  aboutToAppear(): void {
    appStore.initAppStorage();
    this.huaweiMode = (AppStorage.get<string>('setupMode') ?? 'email') === 'huawei';
    this.nickname = appStore.getAccount();
  }

  private async enterMain(): Promise<void> {
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Main' });
  }

  /** 完成：改名（有修改时，82）→ 设密码（邮箱模式且已填时，83）→ 进入主界面 */
  private async handleFinish(): Promise<void> {
    if (this.loading) {
      return;
    }
    const newName: string = this.nickname.trim();
    const pass: string = this.password.trim();
    const confirmPass: string = this.confirm.trim();
    if (newName.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入昵称 ✍️') });
      return;
    }
    if (!this.huaweiMode && pass.length > 0) {
      if (pass.length < 6) {
        this.getUIContext().getPromptAction().showToast({ message: tr('密码至少 6 位 ✍️') });
        return;
      }
      if (pass !== confirmPass) {
        this.getUIContext().getPromptAction().showToast({ message: tr('两次输入的密码不一致 ✍️') });
        return;
      }
    }
    this.loading = true;
    if (newName !== appStore.getAccount()) {
      const renameOutcome: AccountOutcome = await ServerGateway.renameAccount(newName);
      if (!renameOutcome.ok) {
        this.loading = false;
        this.getUIContext().getPromptAction().showToast({ message: renameOutcome.message });
        return;
      }
      const canonical: string = renameOutcome.account.length > 0 ? renameOutcome.account : newName;
      ServerGateway.setSession(ServerGateway.getToken(), canonical, appStore.getPassword());
      AppStorage.setOrCreate('serverAccount', canonical);
      appStore.setUserName(canonical);
    }
    if (!this.huaweiMode && pass.length > 0) {
      const passOutcome: MessageOutcome = await ServerGateway.setPassword('', pass);
      if (!passOutcome.ok) {
        this.loading = false;
        this.getUIContext().getPromptAction().showToast({ message: passOutcome.message });
        return;
      }
      ServerGateway.setSession(ServerGateway.getToken(), appStore.getAccount(), pass);
      AppStorage.setOrCreate('serverPassword', pass);
    }
    this.loading = false;
    this.getUIContext().getPromptAction().showToast({ message: tr('设置完成，欢迎开始程诺之旅 ✨') });
    await this.enterMain();
  }

  /** 跳过：不做任何设置直接进入主界面（昵称保留 UID 名，密码之后可设） */
  private async handleSkip(): Promise<void> {
    if (this.loading) {
      return;
    }
    await this.enterMain();
  }

  build() {
    Column({ space: 28 }) {
      Column({ space: 12 }) {
        Image($r('app.media.app_logo'))
          .width(64)
          .height(64)
          .borderRadius(20)
          .shadow({ radius: 20, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 8 })

        Text(tr('完成账号设置'))
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text(tr('设置昵称与密码，完成账号创建'))
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_secondary'))
      }
      .margin({ top: 60 })

      Column({ space: 16 }) {
        Text(tr('昵称'))
          .fontSize(Theme.fontCaption)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        TextInput({ placeholder: tr('昵称'), text: this.nickname })
          .fontSize(Theme.fontBody)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .backgroundColor($r('app.color.input_bg'))
          .borderRadius(Theme.radiusInput)
          .border({
            width: 1.5,
            color: this.nicknameFocused ? Theme.brand() : Color.Transparent
          })
          .height(48)
          .padding({ left: 14, right: 14 })
          .onChange((value: string) => {
            this.nickname = value;
          })
          .onFocus(() => {
            this.nicknameFocused = true;
          })
          .onBlur(() => {
            this.nicknameFocused = false;
          })

        if (!this.huaweiMode) {
          Text(tr('密码（选填，至少 6 位）'))
            .fontSize(Theme.fontCaption)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          TextInput({ placeholder: tr('设置密码'), text: this.password })
            .type(InputType.Password)
            .fontSize(Theme.fontBody)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .backgroundColor($r('app.color.input_bg'))
            .borderRadius(Theme.radiusInput)
            .border({
              width: 1.5,
              color: this.passwordFocused ? Theme.brand() : Color.Transparent
            })
            .height(48)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.password = value;
            })
            .onFocus(() => {
              this.passwordFocused = true;
            })
            .onBlur(() => {
              this.passwordFocused = false;
            })

          TextInput({ placeholder: tr('确认密码'), text: this.confirm })
            .type(InputType.Password)
            .fontSize(Theme.fontBody)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .backgroundColor($r('app.color.input_bg'))
            .borderRadius(Theme.radiusInput)
            .border({
              width: 1.5,
              color: this.confirmFocused ? Theme.brand() : Color.Transparent
            })
            .height(48)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.confirm = value;
            })
            .onFocus(() => {
              this.confirmFocused = true;
            })
            .onBlur(() => {
              this.confirmFocused = false;
            })
        }

        Column() {
          Text(this.loading ? tr('设置中…') : tr('完成'))
            .fontSize(Theme.fontBody)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.Center)
        .linearGradient({
          angle: 135,
          colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
        })
        .borderRadius(Theme.radiusBtn)
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
        .margin({ top: 8 })
        .onClick(() => {
          this.handleFinish();
        })

        Column() {
          Text(tr('跳过，直接进入'))
            .fontSize(Theme.fontCaption)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.brandDeep())
        }
        .width('100%')
        .height(44)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.brandSoft())
        .borderRadius(Theme.radiusBtn)
        .onClick(() => {
          this.handleSkip();
        })

        Row({ space: 6 }) {
          Text(this.huaweiMode ? '🧡' : '📮')
            .fontSize(Theme.fontCaption)
          Text(this.huaweiMode ? tr('华为账号注册：登录页可一键登录，密码不可设置')
            : tr('密码留空也可进入，之后可在「我的」页设置或用邮箱找回'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .padding(Theme.spaceXxl)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(Theme.radiusModal)
      .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
      .margin({ left: Theme.spaceXxl, right: Theme.spaceXxl })

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: Theme.spaceXxl, right: Theme.spaceXxl })
    .linearGradient({
      angle: 135,
      colors: [[Theme.brandSoft(), 0.0], [$r('app.color.bg_page'), 1.0]]
    })
  }
}
