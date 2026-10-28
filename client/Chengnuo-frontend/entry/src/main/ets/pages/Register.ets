import { appStore } from '../store/AppStore';
import { Theme } from '../common/Theme';
import { ServerGateway } from '../net/ServerGateway';
import { AccountOutcome } from '../net/ServerModels';
import { EmailUserOutcome, createEmailUser, requestRegisterCode } from '../net/EmailAuth';
import { HuaweiAuthOutcome, isHuaweiAuthCancelled, requestHuaweiIdentity } from '../net/HuaweiAuth';
import { AgreementCheckRow, AgreementDocDialog, DOC_KIND_AGREEMENT } from '../components/Agreement';
import { tr, trf } from '../common/I18n';

/**
 * 注册页（界面1）：邮箱验证码注册 + 华为账号注册两种方式。
 * - 邮箱注册：输入邮箱 → AGC 发验证码 → 输码注册（AGC createUser 校验验证码）
 *   → 服务器 85 自动建号（UIDxxxxx / 空密码 + 邮箱标识）→ 进入设置引导页（界面2）
 *   该邮箱已在 AGC 验证过时（alreadyExists）仍继续走 85 兜底：服务器已注册则提示去登录
 * - 华为注册：Account Kit 授权拿 unionID/openID → 服务器 88 自动建号并绑定（已绑定 409）→ 界面2
 * - 邮箱重复注册（服务器 409）提示直接登录；老账号请回登录页用账号名或邮箱登录
 * - 协议勾选：未勾选《用户协议》《隐私政策》时「注册/华为一键注册」置灰（获取验证码不受限）
 */
@Entry
@Component
struct Register {
  @StorageProp('appLang') appLang: string = 'zh';
  @State email: string = '';
  @State code: string = '';
  @State emailFocused: boolean = false;
  @State codeFocused: boolean = false;
  @State countdown: number = 0;
  @State loading: boolean = false;
  /** 协议勾选（与登录页通过 AppStorage 'agreementChecked' 共享） */
  @State agreementChecked: boolean = false;
  /** 协议/隐私文档弹窗 */
  @State docVisible: boolean = false;
  @State docKind: string = DOC_KIND_AGREEMENT;
  private timerId: number = -1;

  aboutToAppear(): void {
    this.agreementChecked = false;
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  onPageHide(): void {
    this.agreementChecked = false;
    AppStorage.setOrCreate('agreementChecked', false);
  }

  /** 验证码发送后 60 秒倒计时（期间「获取验证码」按钮置灰） */
  private startCountdown(): void {
    this.countdown = 60;
    this.timerId = setInterval(() => {
      this.countdown = this.countdown - 1;
      if (this.countdown <= 0) {
        clearInterval(this.timerId);
        this.timerId = -1;
        this.countdown = 0;
      }
    }, 1000);
  }

  private async ensureBackend(): Promise<boolean> {
    const reachable: boolean = await ServerGateway.ensureBase();
    if (!reachable) {
      appStore.markServerOffline();
    }
    return reachable;
  }

  /** 勾选/取消协议勾选（注册页与登录页通过 AppStorage 共享） */
  private toggleAgreement(checked: boolean): void {
    this.agreementChecked = checked;
    AppStorage.setOrCreate('agreementChecked', checked);
  }

  /** 打开《用户协议》/《隐私政策》文档弹窗 */
  private openDoc(kind: string): void {
    this.docKind = kind;
    this.docVisible = true;
  }

  /** 获取注册验证码（AGC 发送到邮箱，不受协议勾选限制） */
  private async handleSendCode(): Promise<void> {
    if (this.loading || this.countdown > 0) {
      return;
    }
    const email: string = this.email.trim();
    if (email.length === 0 || email.indexOf('@') < 0 || email.length > 254) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入正确的邮箱地址 ✉️') });
      return;
    }
    this.loading = true;
    const outcome = await requestRegisterCode(email);
    this.loading = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    this.startCountdown();
    this.getUIContext().getPromptAction().showToast({ message: outcome.message });
  }

  /** 邮箱验证码注册：AGC 校验验证码（createUser）→ 服务器 85 建号签发 → 设置引导页（界面2） */
  private async handleEmailRegister(): Promise<void> {
    if (this.loading) {
      return;
    }
    const email: string = this.email.trim();
    const code: string = this.code.trim();
    if (email.length === 0 || email.indexOf('@') < 0 || email.length > 254) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入正确的邮箱地址 ✉️') });
      return;
    }
    if (code.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入邮箱验证码 ✍️') });
      return;
    }
    this.loading = true;
    const user: EmailUserOutcome = await createEmailUser(email, code);
    if (!user.ok && !user.alreadyExists) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: user.message });
      return;
    }
    if (!(await this.ensureBackend())) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: tr('注册失败，请重试') });
      return;
    }
    const outcome: AccountOutcome = await ServerGateway.emailRegister(email);
    if (!outcome.ok) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    appStore.saveSession(outcome.token, outcome.userId, outcome.account, '');
    this.loading = false;
    this.getUIContext().getPromptAction().showToast({ message: trf('欢迎加入程诺，{0} ✨', outcome.account) });
    AppStorage.setOrCreate('setupMode', 'email');
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Setup' });
  }

  /** 华为账号注册（88）：Account Kit 授权 → 服务器自动建号并绑定 → 设置引导页（界面2，免密码） */
  private async handleHuaweiRegister(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    if (!(await this.ensureBackend())) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: tr('注册失败，请重试') });
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
    const outcome: AccountOutcome = await ServerGateway.huaweiRegister(auth.id.unionId, auth.id.openId);
    if (!outcome.ok) {
      this.loading = false;
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    appStore.saveSession(outcome.token, outcome.userId, outcome.account, '');
    this.loading = false;
    this.getUIContext().getPromptAction().showToast({ message: trf('欢迎加入程诺，{0} ✨', outcome.account) });
    AppStorage.setOrCreate('setupMode', 'huawei');
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Setup' });
  }

  build() {
    Stack() {
      Column({ space: 28 }) {
        Column({ space: 12 }) {
          Image($r('app.media.app_logo'))
            .width(64)
            .height(64)
            .borderRadius(20)
            .shadow({ radius: 20, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 8 })

          Text(tr('注册新账号'))
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

          Text(tr('对自己许下的每一个承诺'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
        }
        .margin({ top: 60 })

        Column({ space: 16 }) {
          TextInput({ placeholder: tr('注册邮箱'), text: this.email })
            .fontSize(Theme.fontBody)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .backgroundColor($r('app.color.input_bg'))
            .borderRadius(Theme.radiusInput)
            .border({
              width: 1.5,
              color: this.emailFocused ? Theme.brand() : Color.Transparent
            })
            .height(48)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.email = value;
            })
            .onFocus(() => {
              this.emailFocused = true;
            })
            .onBlur(() => {
              this.emailFocused = false;
            })

          Row({ space: 10 }) {
            TextInput({ placeholder: tr('邮箱验证码'), text: this.code })
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusInput)
              .border({
                width: 1.5,
                color: this.codeFocused ? Theme.brand() : Color.Transparent
              })
              .height(48)
              .padding({ left: 14, right: 14 })
              .layoutWeight(1)
              .onChange((value: string) => {
                this.code = value;
              })
              .onFocus(() => {
                this.codeFocused = true;
              })
              .onBlur(() => {
                this.codeFocused = false;
              })

            Column() {
              Text(this.countdown > 0 ? trf('{0}s 后重发', this.countdown)
                : (this.loading ? tr('发送中…') : tr('获取验证码')))
                .fontSize(Theme.fontCaption)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.countdown > 0 ? $r('app.color.text_tertiary') : Theme.brandDeep())
            }
            .height(48)
            .padding({ left: 14, right: 14 })
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.brandSoft())
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.handleSendCode();
            })
          }
          .width('100%')

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
            Text(this.loading ? tr('注册中…') : tr('注册'))
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
            this.handleEmailRegister();
          })

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
            Text(this.loading ? tr('处理中…') : tr('华为账号一键注册'))
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
            this.handleHuaweiRegister();
          })
        }
        .width('100%')
        .padding(Theme.spaceXxl)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(Theme.radiusModal)
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
        .margin({ left: Theme.spaceXxl, right: Theme.spaceXxl })

        Column() {
          Text(tr('已有账号？返回登录'))
            .fontSize(Theme.fontBody)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.brandDeep())
        }
        .padding({ top: 4, bottom: 4 })
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })

        Blank()
      }
      .width('100%')
      .height('100%')
      .padding({ left: Theme.spaceXxl, right: Theme.spaceXxl })
      .linearGradient({
        angle: 135,
        colors: [[Theme.brandSoft(), 0.0], [$r('app.color.bg_page'), 1.0]]
      })

      // 协议/隐私文档弹窗（勾选行蓝色标题打开）
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
