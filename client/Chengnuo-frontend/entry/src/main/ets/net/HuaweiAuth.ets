import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** Account Kit 授权成功拿到的华为账号标识 */
export class HuaweiIdResult {
  unionId: string = '';
  openId: string = '';
}

/** requestHuaweiIdentity 调用结果：ok=false 时 message 为可直接展示的中文提示 */
export class HuaweiAuthOutcome {
  ok: boolean = false;
  message: string = '';
  id: HuaweiIdResult | null = null;
}

const LOG_DOMAIN: number = 0x0002;
const LOG_TAG: string = 'ChengNuoHuawei';

/** Account Kit 错误码 → 中文提示（用户取消单独识别，调用方静默处理） */
function describeAuthError(code: number): string {
  if (code === 1001502001) {
    return '尚未登录华为账号：请先在系统设置中登录华为账号';
  }
  if (code === 1001502012) {
    return '已取消华为账号授权';
  }
  if (code === 1001502002) {
    return '应用未获授权：请在华为账号授权页点击允许';
  }
  if (code === 1001500001) {
    return '应用签名校验失败：请在 AGC 控制台配置签名证书指纹';
  }
  if (code === 1001500002) {
    return '授权请求处理中，请稍候再试';
  }
  if (code === 1001502003) {
    return '授权参数无效：请检查 AGC 的 Client ID 配置';
  }
  if (code === 1001502005) {
    return '网络错误：请检查网络后重试';
  }
  if (code === 1001502009) {
    return '华为账号服务内部错误，请稍后重试';
  }
  if (code === 1001502014) {
    return '应用未申请该授权范围';
  }
  if (code === 12300001) {
    return '系统服务异常，请稍后重试';
  }
  if (code === 401) {
    return '缺少页面上下文，无法拉起华为账号授权';
  }
  return `华为账号授权失败（${code}）`;
}

/** 用户是否主动取消了授权（调用方静默返回、不弹提示） */
export function isHuaweiAuthCancelled(message: string): boolean {
  return message === '已取消华为账号授权';
}

/**
 * 拉起华为账号授权（scopes=['openid']，无需申请额外权限），成功返回 unionID / openID。
 * - context 传 UIAbility 的宿主上下文（getHostContext()），未登录华为账号时由系统拉起登录页
 * - state 用随机 UUID 一致性校验，防跨站攻击
 * - v1 简化：客户端直接使用 credential 里的 UnionID/OpenID（官方推荐无服务端交换场景），
 *   不上报 authorizationCode 做服务端交换
 */
export async function requestHuaweiIdentity(context: common.Context | undefined): Promise<HuaweiAuthOutcome> {
  const outcome: HuaweiAuthOutcome = new HuaweiAuthOutcome();
  if (context === undefined) {
    outcome.message = describeAuthError(401);
    return outcome;
  }
  const request: authentication.AuthorizationWithHuaweiIDRequest =
    new authentication.HuaweiIDProvider().createAuthorizationWithHuaweiIDRequest();
  request.scopes = ['openid'];
  request.forceAuthorization = true;
  request.state = util.generateRandomUUID();
  const controller: authentication.AuthenticationController = new authentication.AuthenticationController(context);
  try {
    const response: authentication.AuthenticationResponse = await controller.executeRequest(request);
    const authResponse: authentication.AuthorizationWithHuaweiIDResponse =
      response as authentication.AuthorizationWithHuaweiIDResponse;
    const responseState: string = authResponse.state ?? '';
    if (responseState.length === 0 || responseState !== request.state) {
      outcome.message = '授权校验失败（state 不一致），请重试';
      return outcome;
    }
    const credential: authentication.AuthorizationWithHuaweiIDCredential | undefined = authResponse.data;
    const unionId: string = credential?.unionID ?? '';
    const openId: string = credential?.openID ?? '';
    if (unionId.length === 0) {
      outcome.message = '未能获取华为账号标识（UnionID），请重试';
      return outcome;
    }
    const id: HuaweiIdResult = new HuaweiIdResult();
    id.unionId = unionId;
    id.openId = openId;
    outcome.ok = true;
    outcome.id = id;
    hilog.info(LOG_DOMAIN, LOG_TAG, `huawei identity ok, unionId length=${unionId.length}`);
    return outcome;
  } catch (e) {
    const err: BusinessError = e as BusinessError;
    hilog.error(LOG_DOMAIN, LOG_TAG, `huawei identity failed: ${err.code} ${err.message}`);
    outcome.message = describeAuthError(err.code);
    return outcome;
  }
}
