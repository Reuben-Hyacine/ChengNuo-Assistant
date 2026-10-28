import { appStore } from '../store/AppStore';
import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';
import { ServerGateway } from '../net/ServerGateway';
import { AccountOutcome, EmailStateOutcome, HuaweiStateOutcome, MessageOutcome } from '../net/ServerModels';
import { EmailCodeOutcome, EmailUserOutcome, createEmailUser, requestRegisterCode,
  requestResetCode, resetEmailPassword } from '../net/EmailAuth';
import { HuaweiAuthOutcome, isHuaweiAuthCancelled, requestHuaweiIdentity } from '../net/HuaweiAuth';

/**
 * 账号安全（通用设置 → 账号安全进入）：绑定邮箱 / 设置密码 + 华为账号绑定。
 * - 绑定邮箱（auth.email-bind 96）：AGC 验证码校验通过后把邮箱绑到当前账号；未绑定邮箱不允许设置密码；
 *   绑定后该账号只能按邮箱登录（账号名退化为昵称），成功后刷新重登凭据与本地登录态
 * - 邮箱换绑（已绑定后的同一通道，96 换绑共用）：先验原邮箱验证码（createEmailUser 的 AGC signIn 校验），
 *   再输新邮箱验证码完成换绑
 * - 设置密码（auth.email-reset-password 86 重置流）：验证码发送到绑定邮箱，AGC 校验 + AGC 侧同步密码后
 *   服务器按邮箱落新密码（不验旧密码）；成功后刷新重登凭据与本地登录态
 * - 华为账号（79 状态 / 77 绑定 / 80 解绑）：未绑定 → 拉起 Account Kit 授权并绑定；
 *   已绑定 → 5 秒内两次点击确认解绑（解绑后登录页一键登录不可用）
 */
@Entry
@Component
struct AccountSecurityPage {
  /** 邮箱绑定态（95）：emailBound=true 行标题变「邮箱换绑」并展示掩码邮箱；
   *  hasPassword=是否已设置密码（设置密码行右侧「已设置/未设置」，未绑定邮箱不显示状态） */
  @State emailBound: boolean = false;
  @State boundEmail: string = '';
  @State hasPassword: boolean = false;
  /** 邮箱弹窗（96 绑定/换绑共用）：stage 0=输入新邮箱验证码；换绑先走 stage 1 验原邮箱 */
  @State emailVisible: boolean = false;
  @State emailStage: number = 0;
  @State emailInput: string = '';
  @State emailCode: string = '';
  @State emailCountdown: number = 0;
  @State emailBusy: boolean = false;
  private emailTimerId: number = -1;
  /** 设置密码弹窗（86 重置流）：绑定邮箱验证码 + 新密码 */
  @State passVisible: boolean = false;
  @State passCode: string = '';
  @State passNewInput: string = '';
  @State passBusy: boolean = false;
  @State passCountdown: number = 0;
  private passTimerId: number = -1;
  /** 华为账号绑定态（79）：true=已绑定，行标题变「解除华为账号绑定」 */
  @State huaweiBound: boolean = false;
  @State huaweiArmed: boolean = false;
  @State huaweiBusy: boolean = false;
  private huaweiArmedAt: number = 0;

  aboutToAppear(): void {
    this.loadEmailState();
    this.loadHuaweiState();
  }

  aboutToDisappear(): void {
    if (this.emailTimerId >= 0) {
      clearInterval(this.emailTimerId);
      this.emailTimerId = -1;
    }
    if (this.passTimerId >= 0) {
      clearInterval(this.passTimerId);
      this.passTimerId = -1;
    }
  }

  /** 邮箱展示掩码：保留前两字符 + *** + @域名 */
  private maskEmail(email: string): string {
    const at: number = email.indexOf('@');
    if (at <= 2) {
      return email;
    }
    return email.substring(0, 2) + '***' + email.substring(at);
  }

  /** 邮箱绑定状态（95）：进入页面时同步 */
  private async loadEmailState(): Promise<void> {
    if (!appStore.serverOnline) {
      return;
    }
    const outcome: EmailStateOutcome = await ServerGateway.emailState();
    if (outcome.ok) {
      this.emailBound = outcome.emailBound;
      this.boundEmail = outcome.email;
      this.hasPassword = outcome.hasPassword;
    }
  }

  /** 打开邮箱弹窗：已绑定走换绑两阶段（先验原邮箱），未绑定直接输新邮箱 */
  private openEmailDialog(): void {
    this.emailStage = this.emailBound ? 1 : 0;
    this.emailInput = '';
    this.emailCode = '';
    this.emailCountdown = 0;
    if (this.emailTimerId >= 0) {
      clearInterval(this.emailTimerId);
      this.emailTimerId = -1;
    }
    this.emailBusy = false;
    this.emailVisible = true;
  }

  private closeEmailDialog(): void {
    if (this.emailBusy) {
      return;
    }
    this.emailVisible = false;
    if (this.emailTimerId >= 0) {
      clearInterval(this.emailTimerId);
      this.emailTimerId = -1;
    }
    this.emailCountdown = 0;
  }

  /** 当前验证码收件目标：stage 1=原邮箱（换绑验身份），stage 0=新输入邮箱 */
  private emailCodeTarget(): string {
    return this.emailStage === 1 ? this.boundEmail : this.emailInput.trim();
  }

  private startEmailCountdown(): void {
    this.emailCountdown = 60;
    this.emailTimerId = setInterval(() => {
      this.emailCountdown = this.emailCountdown - 1;
      if (this.emailCountdown <= 0) {
        clearInterval(this.emailTimerId);
        this.emailTimerId = -1;
        this.emailCountdown = 0;
      }
    }, 1000);
  }

  /** 邮箱弹窗-获取验证码（AGC 发送到目标邮箱，60 秒内不可重发） */
  private async handleEmailSendCode(): Promise<void> {
    if (this.emailBusy || this.emailCountdown > 0) {
      return;
    }
    const target: string = this.emailCodeTarget();
    if (target.length === 0 || target.indexOf('@') < 0 || target.length > 254) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入正确的邮箱地址 ✉️') });
      return;
    }
    this.emailBusy = true;
    const outcome: EmailCodeOutcome = await requestRegisterCode(target);
    this.emailBusy = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    this.startEmailCountdown();
    this.getUIContext().getPromptAction().showToast({ message: outcome.message });
  }

  /** 邮箱弹窗-主按钮：stage 1 验原邮箱验证码后进入下一步；stage 0 校验新邮箱验证码并绑/换绑（96）。
   *  绑定成功后该账号只能按邮箱登录，随即用 邮箱+当前密码 重登刷新本地登录态与重登凭据 */
  private async handleEmailConfirm(): Promise<void> {
    if (this.emailBusy) {
      return;
    }
    const code: string = this.emailCode.trim();
    if (code.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入邮箱验证码 ✍️') });
      return;
    }
    if (this.emailStage === 1) {
      this.emailBusy = true;
      const verified: EmailUserOutcome = await createEmailUser(this.boundEmail, code);
      this.emailBusy = false;
      if (!verified.ok && !verified.alreadyExists) {
        this.getUIContext().getPromptAction().showToast({ message: verified.message });
        return;
      }
      this.emailStage = 0;
      this.emailInput = '';
      this.emailCode = '';
      this.emailCountdown = 0;
      if (this.emailTimerId >= 0) {
        clearInterval(this.emailTimerId);
        this.emailTimerId = -1;
      }
      return;
    }
    const email: string = this.emailInput.trim();
    if (email.length === 0 || email.indexOf('@') < 0 || email.length > 254) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入正确的邮箱地址 ✉️') });
      return;
    }
    this.emailBusy = true;
    const verified: EmailUserOutcome = await createEmailUser(email, code);
    if (!verified.ok && !verified.alreadyExists) {
      this.emailBusy = false;
      this.getUIContext().getPromptAction().showToast({ message: verified.message });
      return;
    }
    const bound: MessageOutcome = await ServerGateway.emailBind(email);
    if (!bound.ok) {
      this.emailBusy = false;
      this.getUIContext().getPromptAction().showToast({ message: bound.message });
      return;
    }
    const pass: string = appStore.getPassword();
    const relogin: AccountOutcome = await ServerGateway.login(email, pass);
    this.emailBusy = false;
    this.emailBound = true;
    this.boundEmail = email;
    this.emailVisible = false;
    if (this.emailTimerId >= 0) {
      clearInterval(this.emailTimerId);
      this.emailTimerId = -1;
    }
    this.emailCountdown = 0;
    if (relogin.ok) {
      appStore.saveSession(relogin.token, relogin.userId, appStore.getAccount(), pass);
      this.getUIContext().getPromptAction().showToast({
        message: bound.message.length > 0 ? bound.message : tr('邮箱绑定成功')
      });
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: tr('邮箱已绑定，请重新登录以刷新登录态') });
  }

  /** 打开设置密码弹窗：未绑定邮箱不允许设置密码（门槛在行点击处拦截） */
  private openPasswordDialog(): void {
    if (!this.emailBound) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请先绑定邮箱，再设置密码') });
      return;
    }
    this.passCode = '';
    this.passNewInput = '';
    this.passCountdown = 0;
    if (this.passTimerId >= 0) {
      clearInterval(this.passTimerId);
      this.passTimerId = -1;
    }
    this.passBusy = false;
    this.passVisible = true;
  }

  private closePasswordDialog(): void {
    if (this.passBusy) {
      return;
    }
    this.passVisible = false;
    if (this.passTimerId >= 0) {
      clearInterval(this.passTimerId);
      this.passTimerId = -1;
    }
    this.passCountdown = 0;
  }

  /** 设置密码弹窗-获取验证码（AGC 重置验证码发送到绑定邮箱） */
  private async handlePassSendCode(): Promise<void> {
    if (this.passBusy || this.passCountdown > 0) {
      return;
    }
    this.passBusy = true;
    const outcome: EmailCodeOutcome = await requestResetCode(this.boundEmail);
    this.passBusy = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    this.passCountdown = 60;
    this.passTimerId = setInterval(() => {
      this.passCountdown = this.passCountdown - 1;
      if (this.passCountdown <= 0) {
        clearInterval(this.passTimerId);
        this.passTimerId = -1;
        this.passCountdown = 0;
      }
    }, 1000);
    this.getUIContext().getPromptAction().showToast({ message: outcome.message });
  }

  /** 设置密码（86 重置流）：AGC 验证码校验并同步 AGC 密码 → 服务器按邮箱落新密码（不验旧密码）；
   *  成功后刷新本地登录态（重登凭据与自动登录改用 邮箱 + 新密码） */
  private async handlePasswordConfirm(): Promise<void> {
    if (this.passBusy) {
      return;
    }
    const code: string = this.passCode.trim();
    const newPass: string = this.passNewInput.trim();
    if (code.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入邮箱验证码 ✍️') });
      return;
    }
    if (newPass.length < 6) {
      this.getUIContext().getPromptAction().showToast({ message: tr('新密码至少 6 位 ✍️') });
      return;
    }
    this.passBusy = true;
    const agc: EmailCodeOutcome = await resetEmailPassword(this.boundEmail, code, newPass);
    if (!agc.ok) {
      this.passBusy = false;
      this.getUIContext().getPromptAction().showToast({ message: agc.message });
      return;
    }
    const outcome: MessageOutcome = await ServerGateway.emailResetPassword(this.boundEmail, newPass);
    if (!outcome.ok) {
      this.passBusy = false;
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    const relogin: AccountOutcome = await ServerGateway.login(this.boundEmail, newPass);
    this.passBusy = false;
    if (relogin.ok) {
      appStore.saveSession(relogin.token, relogin.userId, appStore.getAccount(), newPass);
    } else {
      ServerGateway.setSession(ServerGateway.getToken(), this.boundEmail, newPass);
      AppStorage.setOrCreate('serverPassword', newPass);
    }
    this.hasPassword = true;
    this.passVisible = false;
    if (this.passTimerId >= 0) {
      clearInterval(this.passTimerId);
      this.passTimerId = -1;
    }
    this.passCountdown = 0;
    this.getUIContext().getPromptAction().showToast({
      message: outcome.message.length > 0 ? outcome.message : tr('密码设置成功')
    });
  }

  /** 华为账号绑定状态（79）：进入页面时同步 */
  private async loadHuaweiState(): Promise<void> {
    if (!appStore.serverOnline) {
      return;
    }
    const outcome: HuaweiStateOutcome = await ServerGateway.huaweiState();
    if (outcome.ok) {
      this.huaweiBound = outcome.bound;
    }
    this.huaweiArmed = false;
  }

  /** 华为账号行标题：未绑定=绑定华为账号；已绑定=解除绑定（确认期提示再点一次） */
  private huaweiLabel(): string {
    if (!this.huaweiBound) {
      return tr('绑定华为账号');
    }
    return this.huaweiArmed ? tr('再点一次确认解绑 ⚠️') : tr('解除华为账号绑定');
  }

  /** 华为账号行：未绑定 → 拉起 Account Kit 授权并绑定（77）；
   *  已绑定 → 5 秒内两次点击确认解绑（80，解绑后登录页一键登录不可用） */
  private async handleHuaweiTap(): Promise<void> {
    if (this.huaweiBusy) {
      return;
    }
    if (this.huaweiBound) {
      const now: number = Date.now();
      if (!this.huaweiArmed || now - this.huaweiArmedAt > 5000) {
        this.huaweiArmed = true;
        this.huaweiArmedAt = now;
        this.getUIContext().getPromptAction().showToast({ message: tr('解绑后将不能用华为账号一键登录，再点一次确认 ⚠️') });
        return;
      }
      this.huaweiArmed = false;
      this.huaweiBusy = true;
      const outcome: MessageOutcome = await ServerGateway.huaweiUnbind();
      this.huaweiBusy = false;
      if (!outcome.ok) {
        this.getUIContext().getPromptAction().showToast({ message: outcome.message });
        return;
      }
      this.huaweiBound = false;
      this.getUIContext().getPromptAction().showToast({ message: outcome.message.length > 0 ? outcome.message : tr('已解除华为账号绑定') });
      return;
    }
    this.huaweiBusy = true;
    const auth: HuaweiAuthOutcome = await requestHuaweiIdentity(this.getUIContext().getHostContext());
    if (!auth.ok || auth.id === null) {
      this.huaweiBusy = false;
      if (!isHuaweiAuthCancelled(auth.message)) {
        this.getUIContext().getPromptAction().showToast({ message: auth.message });
      }
      return;
    }
    const bound: MessageOutcome = await ServerGateway.huaweiBind(auth.id.unionId, auth.id.openId);
    this.huaweiBusy = false;
    if (!bound.ok) {
      this.getUIContext().getPromptAction().showToast({ message: bound.message });
      return;
    }
    this.huaweiBound = true;
    this.getUIContext().getPromptAction().showToast({ message: bound.message.length > 0 ? bound.message : tr('华为账号绑定成功') });
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(24)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Text(tr('账号安全'))
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
              Row({ space: 12 }) {
                Text('📧')
                  .fontSize(18)
                Text(this.emailBound ? tr('邮箱换绑') : tr('绑定邮箱'))
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                if (this.emailBound) {
                  Text(this.maskEmail(this.boundEmail))
                    .fontSize(Theme.fontCaption)
                    .fontColor($r('app.color.text_tertiary'))
                    .maxLines(1)
                    .constraintSize({ maxWidth: 160 })
                }
                Text('›')
                  .fontSize(18)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 15, bottom: 15 })
              .onClick(() => {
                this.openEmailDialog();
              })

              Column()
                .width('100%')
                .height(0.5)
                .backgroundColor($r('app.color.divider'))

              Row({ space: 12 }) {
                Text('🔑')
                  .fontSize(18)
                Text(tr('设置密码'))
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                if (this.emailBound) {
                  Text(this.hasPassword ? tr('已设置') : tr('未设置'))
                    .fontSize(Theme.fontCaption)
                    .fontColor($r('app.color.text_tertiary'))
                }
                Text('›')
                  .fontSize(18)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 15, bottom: 15 })
              .onClick(() => {
                this.openPasswordDialog();
              })

              Column()
                .width('100%')
                .height(0.5)
                .backgroundColor($r('app.color.divider'))

              Row({ space: 12 }) {
                Text('🔗')
                  .fontSize(18)
                Text(this.huaweiLabel())
                  .fontSize(Theme.fontBody)
                  .fontColor(this.huaweiArmed ? $r('app.color.error') : $r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(this.huaweiBound ? tr('已设置') : tr('未设置'))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_tertiary'))
                Text('›')
                  .fontSize(18)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 15, bottom: 15 })
              .onClick(() => {
                this.handleHuaweiTap();
              })
            }
            .width('100%')
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

      // 绑定/换绑邮箱弹窗（96）：未绑定=单步输新邮箱验证码；换绑=先验原邮箱（stage 1）再输新邮箱（stage 0）
      if (this.emailVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.45)')
          .onClick(() => {
            this.closeEmailDialog();
          })

        Column({ space: 16 }) {
          Text(this.emailStage === 1 ? tr('验证原邮箱')
            : (this.emailBound ? tr('邮箱换绑') : tr('绑定邮箱')))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text(this.emailStage === 1
            ? trf('将向 {0} 发送验证码，验证身份', this.maskEmail(this.boundEmail))
            : (this.emailBound ? tr('输入新邮箱，验证后完成换绑') : tr('绑定后请使用该邮箱登录')))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          if (this.emailStage === 0) {
            TextInput({ placeholder: tr('新邮箱'), text: this.emailInput })
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusInput)
              .height(48)
              .padding({ left: 14, right: 14 })
              .onChange((value: string) => {
                this.emailInput = value;
              })
          }

          Row({ space: 10 }) {
            TextInput({ placeholder: tr('邮箱验证码'), text: this.emailCode })
              .type(InputType.Number)
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusInput)
              .height(48)
              .padding({ left: 14, right: 14 })
              .layoutWeight(1)
              .onChange((value: string) => {
                this.emailCode = value;
              })

            Column() {
              Text(this.emailCountdown > 0 ? trf('{0}s 后重发', this.emailCountdown)
                : (this.emailBusy ? tr('发送中…') : tr('获取验证码')))
                .fontSize(Theme.fontCaption)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.emailCountdown > 0 ? $r('app.color.text_tertiary') : Theme.brandDeep())
            }
            .height(48)
            .padding({ left: 14, right: 14 })
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.brandSoft())
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.handleEmailSendCode();
            })
          }
          .width('100%')

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
              this.closeEmailDialog();
            })

            Column() {
              Text(this.emailBusy ? tr('提交中…')
                : (this.emailStage === 1 ? tr('下一步')
                  : (this.emailBound ? tr('确认换绑') : tr('绑定'))))
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
              this.handleEmailConfirm();
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

      // 设置密码弹窗（86 重置流）：绑定邮箱验证码 + 新密码（不验旧密码）；backdrop 点击关闭
      if (this.passVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.45)')
          .onClick(() => {
            this.closePasswordDialog();
          })

        Column({ space: 16 }) {
          Text(tr('设置密码'))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text(trf('将向 {0} 发送验证码，验证身份', this.maskEmail(this.boundEmail)))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Row({ space: 10 }) {
            TextInput({ placeholder: tr('邮箱验证码'), text: this.passCode })
              .type(InputType.Number)
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.input_bg'))
              .borderRadius(Theme.radiusInput)
              .height(48)
              .padding({ left: 14, right: 14 })
              .layoutWeight(1)
              .onChange((value: string) => {
                this.passCode = value;
              })

            Column() {
              Text(this.passCountdown > 0 ? trf('{0}s 后重发', this.passCountdown)
                : (this.passBusy ? tr('发送中…') : tr('获取验证码')))
                .fontSize(Theme.fontCaption)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.passCountdown > 0 ? $r('app.color.text_tertiary') : Theme.brandDeep())
            }
            .height(48)
            .padding({ left: 14, right: 14 })
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.brandSoft())
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.handlePassSendCode();
            })
          }
          .width('100%')

          TextInput({ placeholder: tr('新密码（至少 6 位）'), text: this.passNewInput })
            .type(InputType.Password)
            .fontSize(Theme.fontBody)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .backgroundColor($r('app.color.input_bg'))
            .borderRadius(Theme.radiusInput)
            .height(48)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.passNewInput = value;
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
              this.closePasswordDialog();
            })

            Column() {
              Text(this.passBusy ? tr('提交中…') : tr('确认'))
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
              this.handlePasswordConfirm();
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
    }
    .width('100%')
    .height('100%')
  }
}
