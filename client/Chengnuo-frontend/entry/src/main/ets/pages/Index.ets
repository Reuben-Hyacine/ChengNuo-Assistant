import { appStore } from '../store/AppStore';
import { Theme } from '../common/Theme';
import { ServerGateway } from '../net/ServerGateway';
import { AccountOutcome, LoginStateOutcome, MessageOutcome } from '../net/ServerModels';
import { EmailCodeOutcome, requestResetCode, resetEmailPassword } from '../net/EmailAuth';
import { HuaweiAuthOutcome, isHuaweiAuthCancelled, requestHuaweiIdentity } from '../net/HuaweiAuth';
import { loginAccountsStore, SavedLogin } from '../store/LoginAccountsStore';
import { AgreementCheckRow, AgreementDocDialog, DOC_KIND_AGREEMENT, DOC_KIND_PRIVACY } from '../components/Agreement';
import { tr, trf } from '../common/I18n';

/**
 * 登录页：邮箱（老账号可输账号名）+ 密码登录（11，仅登录、失败不自动注册）。
 * - 邮箱注册的账号输注册邮箱或账号名皆可（服务器双查）；空密码账号（跳过设密的）直接空密码登录
 * - 「忘记密码」：AGC 邮箱验证码校验（resetPassword）→ 服务器 86 重置程诺侧密码（仅邮箱注册账号适用）
 * - 「注册新账号」：进注册页（界面1：邮箱验证码注册 85 / 华为账号注册 88），完成后进设置引导页（界面2）
 * - 「华为账号一键登录」（78）：服务器按 unionID 反查已绑定账号（未注册引导到注册页）
 * - 自动登录：后端登录状态文件（login-state）为 1 时启动即用记录的凭据登录并直入主界面
 * - 后端不可达时不进入主界面，提示先启动 server :3000
 */
@Entry
@Component
struct Index {
  @StorageProp('appLang') appLang: string = 'zh';
  @State account: string = '';
  @State password: string = '';
  @State accountFocused: boolean = false;
  @State passwordFocused: boolean = false;
  @State loading: boolean = false;
  /** 启动时正在检查登录状态 / 自动登录：期间显示过渡界面，不闪登录表单 */
  @State autoChecking: boolean = true;
  /** 忘记密码弹窗（AGC 验证码 + 服务器 86 重置） */
  @State forgotVisible: boolean = false;
  @State forgotEmail: string = '';
  @State forgotCode: string = '';
  @State forgotNew: string = '';
  @State forgotCountdown: number = 0;
  @State forgotBusy: boolean = false;
  private forgotTimerId: number = -1;
  /** 协议勾选（与注册页通过 AppStorage 'agreementChecked' 共享） */
  @State agreementChecked: boolean = false;
  /** 协议/隐私文档弹窗 */
  @State docVisible: boolean = false;
  @State docKind: string = DOC_KIND_AGREEMENT;
  /** 最近登录账号表（邮箱框右侧倒三角展开；✕ 仅删本地记录，不涉及注销） */
  @State savedLogins: SavedLogin[] = [];
  @State loginsOpen: boolean = false;

  aboutToAppear(): void {
    appStore.initAppStorage();
    this.savedLogins = loginAccountsStore.list();
    this.agreementChecked = AppStorage.get<boolean>('agreementChecked') ?? false;
    appStore.restoreSession();
    this.tryAutoLogin();
  }

  onPageShow(): void {
    this.agreementChecked = false;
    AppStorage.setOrCreate('agreementChecked', false);
  }

  onPageHide(): void {
    this.agreementChecked = false;
    AppStorage.setOrCreate('agreementChecked', false);
  }

  aboutToDisappear(): void {
    if (this.forgotTimerId >= 0) {
      clearInterval(this.forgotTimerId);
      this.forgotTimerId = -1;
    }
  }

  /** 后端登录状态为 1：用记录的账号自动登录（密码可为空——跳过设密/自动建号账号空密码登录），
   *  仅登录不自动注册（账号已注销等情形回到登录页），成功直入主界面（不显示登录表单） */
  private async tryAutoLogin(): Promise<void> {
    if (!(await this.ensureBackend())) {
      this.autoChecking = false;
      return;
    }
    const state: LoginStateOutcome = await ServerGateway.loginState();
    if (state.ok && state.state === 1 && state.account.length > 0) {
      const outcome: AccountOutcome = await ServerGateway.login(state.account, state.password);
      if (outcome.ok) {
        appStore.saveSession(outcome.token, outcome.userId, outcome.account, state.password);
        this.autoChecking = false;
        this.getUIContext().getPromptAction().showToast({ message: trf('自动登录，欢迎回来，{0} ✨', outcome.account) });
        await this.enterMain();
        return;
      }
    }
    this.autoChecking = false;
  }

  private async enterMain(): Promise<void> {
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Main' });
  }

  /** 探测服务器（内置后端转发 server :3000），不可达则标记离线 */
  private async ensureBackend(): Promise<boolean> {
    const reachable: boolean = await ServerGateway.ensureBase();
    if (!reachable) {
      appStore.markServerOffline();
    }
    return reachable;
  }

  /** 登录（11）：账号名或注册邮箱 + 密码，失败不自动注册（未注册请走注册页） */
  private async handleLogin(): Promise<void> {
    if (this.loading) {
      return;
    }
    const username: string = this.account.trim();
    const password: string = this.password.trim();
    if (username.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入邮箱或账号名 ✍️') });
      return;
    }
    this.loading = true;
    await this.doLogin(username, password);
  }

  /** 登录公共流程：连服务器 → 登录（11）→ 记录最近登录表 → 保存会话 → 进主界面 */
  private async doLogin(username: string, password: string): Promise<void> {
    if (!(await this.ensureBackend())) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: tr('登录失败，请重试') });
      return;
    }
    const outcome: AccountOutcome = await ServerGateway.login(username, password);
    if (!outcome.ok) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    loginAccountsStore.record(username, password);
    this.savedLogins = loginAccountsStore.list();
    appStore.saveSession(outcome.token, outcome.userId, outcome.account, password);
    this.loading = false;
    this.getUIContext().getPromptAction().showToast({ message: trf('欢迎回来，{0} ✨', outcome.account) });
    await this.enterMain();
  }

  /** 下拉最近登录点击：已勾选协议 → 用记录的账号密码直接登录（密码不回显输入框，仅随登录请求提交）；
   *  未勾选 → 只把登录标识填入邮箱框，提示先勾选协议 */
  private async handleSavedLoginTap(rec: SavedLogin): Promise<void> {
    if (!this.agreementChecked) {
      this.account = rec.account;
      this.loginsOpen = false;
      this.getUIContext().getPromptAction().showToast({
        message: tr('请先勾选同意《用户协议》和《隐私政策》')
      });
      return;
    }
    if (this.loading) {
      return;
    }
    this.loginsOpen = false;
    this.loading = true;
    await this.doLogin(rec.account, rec.password);
  }

  /** 「✕」从最近登录表移除该账号（仅删本地记录，不是注销）；移除后列表为空自动收起下拉 */
  private removeSavedLogin(rec: SavedLogin): void {
    loginAccountsStore.remove(rec.account);
    this.savedLogins = loginAccountsStore.list();
    if (this.savedLogins.length === 0) {
      this.loginsOpen = false;
    }
  }

  /** 华为账号一键登录（78）：Account Kit 拉起授权拿 unionID/openID → 服务器按绑定关系反查程诺账号；
   *  该华为账号未绑定过程诺账号时服务器返回引导文案（去注册页完成注册）；用户取消授权静默返回 */
  private async handleHuaweiLogin(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    if (!(await this.ensureBackend())) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: tr('登录失败，请重试') });
      return;
    }
    const auth: HuaweiAuthOutcome = await requestHuaweiIdentity(this.getUIContext().getHostContext());
    if (!auth.ok || auth.id === null) {
      this.loading = false;
      if (!isHuaweiAuthCancelled(auth.message)) {
        this.getUIContext().getPromptAction().showToast({ message: auth.message });
      }
      return;
    }
    const outcome: AccountOutcome = await ServerGateway.huaweiLogin(auth.id.unionId, auth.id.openId);
    if (!outcome.ok) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    appStore.saveSession(outcome.token, outcome.userId, outcome.account, '');
    this.loading = false;
    this.getUIContext().getPromptAction().showToast({ message: trf('欢迎回来，{0} ✨', outcome.account) });
    await this.enterMain();
  }

  /** 打开忘记密码弹窗：清空上次输入 */
  private openForgotDialog(): void {
    this.forgotEmail = '';
    this.forgotCode = '';
    this.forgotNew = '';
    this.forgotBusy = false;
    this.forgotVisible = true;
  }

  /** 勾选/取消协议勾选（登录页与注册页通过 AppStorage 共享） */
  private toggleAgreement(checked: boolean): void {
    this.agreementChecked = checked;
    AppStorage.setOrCreate('agreementChecked', checked);
  }

  /** 打开《用户协议》/《隐私政策》文档弹窗 */
  private openDoc(kind: string): void {
    this.docKind = kind;
    this.docVisible = true;
  }

  /** 忘记密码：获取验证码（AGC 发送到注册邮箱，60 秒内不可重发） */
  private async handleForgotSend(): Promise<void> {
    if (this.forgotBusy || this.forgotCountdown > 0) {
      return;
    }
    const email: string = this.forgotEmail.trim();
    if (email.length === 0 || email.indexOf('@') < 0 || email.length > 254) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入正确的注册邮箱 ✉️') });
      return;
    }
    this.forgotBusy = true;
    const outcome: EmailCodeOutcome = await requestResetCode(email);
    this.forgotBusy = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    this.forgotCountdown = 60;
    this.forgotTimerId = setInterval(() => {
      this.forgotCountdown = this.forgotCountdown - 1;
      if (this.forgotCountdown <= 0) {
        clearInterval(this.forgotTimerId);
        this.forgotTimerId = -1;
        this.forgotCountdown = 0;
      }
    }, 1000);
    this.getUIContext().getPromptAction().showToast({ message: outcome.message });
  }

  /** 忘记密码：重置——AGC 验证码校验（resetPassword）→ 服务器 86 落程诺侧新密码；
   *  仅邮箱注册的账号适用（老账号无 AGC 用户，保留原密码登录） */
  private async handleForgotConfirm(): Promise<void> {
    if (this.forgotBusy) {
      return;
    }
    const email: string = this.forgotEmail.trim();
    const code: string = this.forgotCode.trim();
    const newPass: string = this.forgotNew.trim();
    if (email.length === 0 || email.indexOf('@') < 0 || email.length > 254) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入正确的注册邮箱 ✉️') });
      return;
    }
    if (code.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入邮箱验证码 ✍️') });
      return;
    }
    if (newPass.length < 6) {
      this.getUIContext().getPromptAction().showToast({ message: tr('新密码至少 6 位 ✍️') });
      return;
    }
    this.forgotBusy = true;
    const agc: EmailCodeOutcome = await resetEmailPassword(email, code, newPass);
    if (!agc.ok) {
      this.forgotBusy = false;
      this.getUIContext().getPromptAction().showToast({ message: agc.message });
      return;
    }
    if (!(await this.ensureBackend())) {
      this.forgotBusy = false;
      this.getUIContext().getPromptAction().showToast({ message: tr('重置失败，请重试') });
      return;
    }
    const outcome: MessageOutcome = await ServerGateway.emailResetPassword(email, newPass);
    this.forgotBusy = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    this.forgotVisible = false;
    this.getUIContext().getPromptAction().showToast({
      message: outcome.message.length > 0 ? outcome.message : tr('密码已重置，请使用新密码登录')
    });
  }

  build() {
    if (this.autoChecking) {
      // 启动过渡：检查登录状态 / 自动登录中，不显示登录表单
      Column({ space: 20 }) {
        Image($r('app.media.app_logo'))
          .width(72)
          .height(72)
          .borderRadius(22)
          .shadow({ radius: 20, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 8 })
          .margin({ top: 240 })

        Text(tr('正在检查登录状态…'))
          .fontSize(Theme.fontBody)
          .fontColor($r('app.color.text_secondary'))

        LoadingProgress()
          .width(28)
          .height(28)
          .color(Theme.brand())
      }
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 135,
        colors: [[Theme.brandSoft(), 0.0], [$r('app.color.bg_page'), 1.0]]
      })
    } else {
      Stack() {
        Column({ space: 28 }) {
          Column({ space: 12 }) {
            Image($r('app.media.app_logo'))
              .width(64)
              .height(64)
              .borderRadius(20)
              .shadow({ radius: 20, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 8 })

            Text(tr('程诺助手'))
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Text(tr('对自己许下的每一个承诺'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
          }
          .margin({ top: 60 })

          Column({ space: 16 }) {
            Stack({ alignContent: Alignment.TopStart }) {
              Stack({ alignContent: Alignment.TopEnd }) {
                TextInput({ placeholder: tr('邮箱'), text: this.account })
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_tertiary'))
                  .backgroundColor($r('app.color.input_bg'))
                  .borderRadius(Theme.radiusInput)
                  .border({
                    width: 1.5,
                    color: this.accountFocused ? Theme.brand() : Color.Transparent
                  })
                  .width('100%')
                  .height(48)
                  .padding({ left: 14, right: this.savedLogins.length > 0 ? 40 : 14 })
                  .onChange((value: string) => {
                    this.account = value;
                  })
                  .onFocus(() => {
                    this.accountFocused = true;
                    this.loginsOpen = false;
                  })
                  .onBlur(() => {
                    this.accountFocused = false;
                  })

                // 倒三角开关：展开/收起最近登录列表（无记录不显示；展开后转正三角）
                if (this.savedLogins.length > 0) {
                  Column() {
                    Text(this.loginsOpen ? '▴' : '▾')
                      .fontSize(12)
                      .fontColor(this.loginsOpen
                        ? Theme.brandDeep() : $r('app.color.text_secondary'))
                  }
                  .width(28)
                  .height(48)
                  .margin({ right: 6 })
                  .justifyContent(FlexAlign.Center)
                  .onClick(() => {
                    this.loginsOpen = !this.loginsOpen;
                  })
                }
              }
              .width('100%')

              // 最近登录下拉浮层（向下展开盖在密码框上）：点账号行=勾选协议后直接登录（密码不展示）；
              // 行尾「✕」=仅从最近登录表删除该记录（不是注销），点击不冒泡到行
              if (this.loginsOpen && this.savedLogins.length > 0) {
                Column() {
                  ForEach(this.savedLogins, (rec: SavedLogin) => {
                    Row() {
                      Text(rec.account)
                        .fontSize(Theme.fontBody)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Column() {
                        Text('✕')
                          .fontSize(Theme.fontCaption)
                          .fontColor($r('app.color.text_tertiary'))
                      }
                      .width(28)
                      .height(28)
                      .justifyContent(FlexAlign.Center)
                      .onClick(() => {
                        this.removeSavedLogin(rec);
                      })
                    }
                    .width('100%')
                    .height(44)
                    .padding({ left: 14, right: 6 })
                    .alignItems(VerticalAlign.Center)
                    .onClick(() => {
                      this.handleSavedLoginTap(rec);
                    })
                  }, (rec: SavedLogin) => rec.account)
                }
                .width('100%')
                .backgroundColor($r('app.color.bg_card'))
                .borderRadius(Theme.radiusInput)
                .border({ width: 1, color: $r('app.color.divider') })
                .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
                .offset({ y: 52 })
              }
            }
            .width('100%')
            // 展开时整层置顶：溢出容器的下拉浮层才会画在密码框等后续兄弟组件之上
            .zIndex(this.loginsOpen ? 9 : 0)

            TextInput({ placeholder: tr('密码'), text: this.password })
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

            AgreementCheckRow({
              checked: this.agreementChecked,
              onToggle: (checked: boolean) => {
                this.toggleAgreement(checked);
              },
              onOpenDoc: (kind: string) => {
                this.openDoc(kind);
              }
            })

            Column() {
              Text(this.loading ? tr('登录中…') : tr('登录'))
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
            .enabled(this.agreementChecked)
            .opacity(this.agreementChecked ? 1 : 0.5)
            .onClick(() => {
              this.handleLogin();
            })

            Row() {
              Column() {
                Text(tr('忘记密码'))
                  .fontSize(Theme.fontCaption)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_secondary'))
              }
              .padding({ top: 6, bottom: 6 })
              .onClick(() => {
                this.openForgotDialog();
              })

              Blank()

              Column() {
                Text(tr('注册新账号'))
                  .fontSize(Theme.fontCaption)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.brandDeep())
              }
              .padding({ top: 6, bottom: 6 })
              .onClick(() => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/Register' });
              })
            }
            .width('100%')

            Row({ space: 10 }) {
              Divider()
                .width(64)
                .strokeWidth(1)
                .color($r('app.color.divider'))
              Text(tr('或'))
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_tertiary'))
              Divider()
                .width(64)
                .strokeWidth(1)
                .color($r('app.color.divider'))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)

            Row({ space: 8 }) {
              Text('🧡')
                .fontSize(18)
              Text(this.loading ? tr('处理中…') : tr('华为账号一键登录'))
                .fontSize(Theme.fontBody)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.brandDeep())
            }
            .width('100%')
            .height(44)
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusBtn)
            .border({ width: 1.5, color: Theme.brand() })
            .enabled(this.agreementChecked)
            .opacity(this.agreementChecked ? 1 : 0.5)
            .onClick(() => {
              this.handleHuaweiLogin();
            })
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

        // 忘记密码弹窗：backdrop 点击关闭；卡片上的点击不冒泡（ArkUI onClick 不冒泡），再补一层空 onClick 兜底
        if (this.forgotVisible) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0, 0, 0, 0.45)')
            .onClick(() => {
              if (!this.forgotBusy) {
                this.forgotVisible = false;
              }
            })

          Column({ space: 16 }) {
            Text(tr('找回密码'))
              .fontSize(Theme.fontCardTitle)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Text(tr('输入注册邮箱，验证码将发送到该邮箱；仅邮箱注册的账号支持找回'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            TextInput({ placeholder: tr('注册邮箱'), text: this.forgotEmail })
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusInput)
              .height(48)
              .padding({ left: 14, right: 14 })
              .onChange((value: string) => {
                this.forgotEmail = value;
              })

            Row({ space: 10 }) {
              TextInput({ placeholder: tr('邮箱验证码'), text: this.forgotCode })
                .fontSize(Theme.fontBody)
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_tertiary'))
                .backgroundColor($r('app.color.input_bg'))
                .borderRadius(Theme.radiusInput)
                .height(48)
                .padding({ left: 14, right: 14 })
                .layoutWeight(1)
                .onChange((value: string) => {
                  this.forgotCode = value;
                })

              Column() {
                Text(this.forgotCountdown > 0 ? trf('{0}s 后重发', this.forgotCountdown)
                  : (this.forgotBusy ? tr('发送中…') : tr('获取验证码')))
                  .fontSize(Theme.fontCaption)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.forgotCountdown > 0 ? $r('app.color.text_tertiary') : Theme.brandDeep())
              }
              .height(48)
              .padding({ left: 14, right: 14 })
              .justifyContent(FlexAlign.Center)
              .backgroundColor(Theme.brandSoft())
              .borderRadius(Theme.radiusBtn)
              .onClick(() => {
                this.handleForgotSend();
              })
            }
            .width('100%')

            TextInput({ placeholder: tr('新密码（至少 6 位）'), text: this.forgotNew })
              .type(InputType.Password)
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusInput)
              .height(48)
              .padding({ left: 14, right: 14 })
              .onChange((value: string) => {
                this.forgotNew = value;
              })

            Row({ space: 12 }) {
              Column() {
                Text(tr('取消'))
                  .fontSize(Theme.fontBody)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_secondary'))
              }
              .layoutWeight(1)
              .height(44)
              .justifyContent(FlexAlign.Center)
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(Theme.radiusBtn)
              .onClick(() => {
                if (!this.forgotBusy) {
                  this.forgotVisible = false;
                }
              })

              Column() {
                Text(this.forgotBusy ? tr('重置中…') : tr('重置密码'))
                  .fontSize(Theme.fontBody)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
              }
              .layoutWeight(1)
              .height(44)
              .justifyContent(FlexAlign.Center)
              .linearGradient({
                angle: 135,
                colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
              })
              .borderRadius(Theme.radiusBtn)
              .onClick(() => {
                this.handleForgotConfirm();
              })
            }
            .width('100%')
          }
          .width('86%')
          .padding(22)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(Theme.radiusModal)
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
          .onClick(() => {
          })
        }

        // 协议/隐私文档弹窗（勾选行与隐私弹窗的蓝色标题共用，置于最顶层）
        if (this.docVisible) {
          AgreementDocDialog({
            kind: this.docKind,
            onClose: () => {
              this.docVisible = false;
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
  }
}
