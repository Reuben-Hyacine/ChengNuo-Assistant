import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { initialize, JsonTypeInfo } from '@hw-agconnect/hmcore';
import cloud, { Auth, AuthUser, EmailCredentialInfo, EmailVerifyCode, SignInResult, VerifyCodeAction, VerifyCodeParam } from '@hw-agconnect/cloud';
import { tr, trf } from '../common/I18n';

/**
 * AGC 邮箱验证码通道（AppGallery Connect 认证服务）：
 * - 只承担验证码的发送与校验（requestVerifyCode + createUser / resetPassword），
 *   程诺账号的建号、会话与密码存储一律走程诺服务器（85 / 86）
 * - AGC 侧注册不设密码；找回密码时 AGC 与服务器两侧同步落新密码（程诺密码 = 邮箱密码）
 * - 初始化读取 rawfile 的 agconnect-services.json，失败只禁用邮箱功能、不阻塞启动
 */

/** 验证码发送 / 密码重置结果：ok=false 时 message 为可直接展示的中文提示 */
export class EmailCodeOutcome {
  ok: boolean = false;
  message: string = '';
}

/** 邮箱验证码注册（AGC createUser）结果：uid 为 AGC 侧用户 id；
 *  alreadyExists=true 表示该邮箱已在 AGC 注册过（视为邮箱已验证，可继续走服务器 85 兜底） */
export class EmailUserOutcome {
  ok: boolean = false;
  message: string = '';
  uid: string = '';
  alreadyExists: boolean = false;
}

const LOG_DOMAIN: number = 0x0002;
const LOG_TAG: string = 'ChengNuoEmail';
const CONFIG_FILE: string = 'agconnect-services.json';

let agcReady: boolean = false;

/** AGC SDK 是否已初始化完成（失败时邮箱验证码功能不可用，其余功能不受影响） */
export function isAgcReady(): boolean {
  return agcReady;
}

/** AGC 错误 → 中文提示（识别不了的码带原始信息，便于排查） */
function describeAgcError(code: number, raw: string): string {
  const lower: string = raw.toLowerCase();
  if (lower.indexOf('not exist') >= 0) {
    return tr('该邮箱尚未注册程诺账号');
  }
  if (lower.indexOf('registered') >= 0 || lower.indexOf('exist') >= 0) {
    return tr('该邮箱已注册过，请直接登录或找回密码');
  }
  if (lower.indexOf('verify') >= 0) {
    return tr('验证码错误或已过期，请重试');
  }
  if (lower.indexOf('invalid') >= 0) {
    return tr('邮箱地址无效，请检查后重试');
  }
  if (lower.indexOf('frequent') >= 0 || lower.indexOf('interval') >= 0) {
    return tr('发送过于频繁，请稍后再试');
  }
  if (code === 1210005) {
    return tr('会话冲突，请重试');
  }
  const detail: string = raw.length > 0 && raw.length <= 60 ? `：${raw}` : '';
  return trf('邮箱验证服务错误（{0}）{1}', code, detail);
}

/** 初始化 AGC SDK：读取 rawfile 的 agconnect-services.json 注入（App 冷启动调用一次，失败不阻塞启动） */
export function initAgc(context: common.Context): void {
  if (agcReady) {
    return;
  }
  try {
    const raw: Uint8Array = context.resourceManager.getRawFileContentSync(CONFIG_FILE);
    const text: string = util.TextDecoder.create('utf-8').decodeToString(raw);
    const config: JsonTypeInfo = JSON.parse(text) as JsonTypeInfo;
    initialize(context, config);
    agcReady = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'agc sdk initialized');
  } catch (e) {
    agcReady = false;
    const err: BusinessError = e as BusinessError;
    hilog.error(LOG_DOMAIN, LOG_TAG, `agc init failed: ${err.code} ${err.message}`);
  }
}

/** AGC 侧静默登出（createUser 会把用户签入会话，注册前清一次保证可重复注册；失败忽略） */
async function signOutQuietly(auth: Auth): Promise<void> {
  try {
    await auth.signOut();
  } catch (e) {
    // 未登录时 signOut 可能报错，忽略即可
  }
}

/** 申请邮箱验证码（action 区分注册 / 找回密码场景，AGC 发送到邮箱） */
async function requestCode(email: string, action: VerifyCodeAction): Promise<EmailCodeOutcome> {
  const outcome: EmailCodeOutcome = new EmailCodeOutcome();
  if (!agcReady) {
    outcome.message = tr('邮箱验证服务未就绪，请重启应用');
    return outcome;
  }
  const emailCode: EmailVerifyCode = { kind: 'email', email: email };
  const param: VerifyCodeParam = {
    verifyCodeType: emailCode,
    action: action,
    lang: 'zh_CN'
  };
  try {
    await cloud.auth().requestVerifyCode(param);
    outcome.ok = true;
    outcome.message = tr('验证码已发送，请查收邮箱 📬');
    return outcome;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    hilog.error(LOG_DOMAIN, LOG_TAG, `request verify code failed: ${err.code} ${err.message}`);
    outcome.message = describeAgcError(err.code, err.message);
    return outcome;
  }
}

/** 申请注册验证码（注册页「获取验证码」，用于 AGC createUser 校验） */
export function requestRegisterCode(email: string): Promise<EmailCodeOutcome> {
  return requestCode(email, VerifyCodeAction.REGISTER_LOGIN);
}

/** 申请找回密码验证码（登录页「忘记密码」，用于 AGC resetPassword 校验） */
export function requestResetCode(email: string): Promise<EmailCodeOutcome> {
  return requestCode(email, VerifyCodeAction.RESET_PASSWORD);
}

/**
 * 邮箱验证码注册（AGC createUser，AGC 侧不设密码）：验证码校验通过即返回 AGC 用户 uid；
 * createUser 成功会把用户签入 AGC 会话，前后各 signOut 清理，避免残留会话卡住下次注册。
 * 该邮箱已在 AGC 注册过时（203818130），改用同一验证码 signIn 校验收码人身份，
 * 校验通过后 alreadyExists=true（调用方可继续走服务器 85 兜底），未通过则返回错误提示。
 */
export async function createEmailUser(email: string, verifyCode: string): Promise<EmailUserOutcome> {
  const outcome: EmailUserOutcome = new EmailUserOutcome();
  if (!agcReady) {
    outcome.message = tr('邮箱验证服务未就绪，请重启应用');
    return outcome;
  }
  const auth: Auth = cloud.auth();
  await signOutQuietly(auth);
  const credential: EmailCredentialInfo = {
    kind: 'email',
    email: email,
    verifyCode: verifyCode
  };
  try {
    const result: SignInResult = await auth.createUser(credential);
    const user: AuthUser = result.getUser();
    outcome.uid = user.getUid();
    outcome.ok = true;
    await signOutQuietly(auth);
    hilog.info(LOG_DOMAIN, LOG_TAG, `agc email user created, uid length=${outcome.uid.length}`);
    return outcome;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    const lower: string = err.message.toLowerCase();
    const alreadyRegistered: boolean = err.code === 203818130 || lower.indexOf('registered') >= 0 ||
      (lower.indexOf('exist') >= 0 && lower.indexOf('not exist') < 0);
    if (alreadyRegistered) {
      hilog.info(LOG_DOMAIN, LOG_TAG, `agc email user already registered (${err.code}), verify by sign-in`);
      await signOutQuietly(auth);
      try {
        const signedIn: SignInResult = await auth.signIn({ credentialInfo: credential });
        const existingUser: AuthUser = signedIn.getUser();
        outcome.uid = existingUser.getUid();
        outcome.ok = true;
        outcome.alreadyExists = true;
        await signOutQuietly(auth);
        hilog.info(LOG_DOMAIN, LOG_TAG, `agc email user verified by sign-in, uid length=${outcome.uid.length}`);
        return outcome;
      } catch (e2) {
        const err2: BusinessError = e2 as BusinessError;
        hilog.error(LOG_DOMAIN, LOG_TAG, `sign in existing email user failed: ${err2.code} ${err2.message}`);
        await signOutQuietly(auth);
        outcome.message = describeAgcError(err2.code, err2.message);
        return outcome;
      }
    }
    hilog.error(LOG_DOMAIN, LOG_TAG, `create email user failed: ${err.code} ${err.message}`);
    await signOutQuietly(auth);
    outcome.message = describeAgcError(err.code, err.message);
    return outcome;
  }
}

/**
 * 邮箱验证码重置密码（AGC resetPassword）：验证码校验通过后 AGC 侧同步落新密码
 * （程诺密码 = AGC 邮箱密码），随后由调用方再调服务器 86 落程诺侧密码；
 * 仅邮箱注册的账号适用（老账号无 AGC 用户，保留原密码登录）
 */
export async function resetEmailPassword(email: string, verifyCode: string,
  newPassword: string): Promise<EmailCodeOutcome> {
  const outcome: EmailCodeOutcome = new EmailCodeOutcome();
  if (!agcReady) {
    outcome.message = tr('邮箱验证服务未就绪，请重启应用');
    return outcome;
  }
  const credential: EmailCredentialInfo = {
    kind: 'email',
    email: email,
    password: newPassword,
    verifyCode: verifyCode
  };
  try {
    await cloud.auth().resetPassword(credential);
    outcome.ok = true;
    outcome.message = tr('密码已重置');
    return outcome;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    hilog.error(LOG_DOMAIN, LOG_TAG, `reset email password failed: ${err.code} ${err.message}`);
    outcome.message = describeAgcError(err.code, err.message);
    return outcome;
  }
}
