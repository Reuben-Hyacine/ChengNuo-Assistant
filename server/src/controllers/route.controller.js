import { ok, fail } from '../utils/response.js';
import { listServices, execute } from '../services/routeService.js';
import { listActivity, pushActivity } from '../services/activityStore.js';
import { resolveToken } from '../services/auth.service.js';

// 注册（10）、登录（11）、退出登录（12）、注销账号（13）由各自内部逻辑校验身份，无需 token；
// 华为账号登录（78）按 unionID 反查绑定关系并签发新 token，同样免 token；
// 游客登录（81）本身就是建号入口（自动创建 UID 名账号），同样免 token；
// 邮箱注册（85）/ 邮箱找回密码（86）/ 华为账号注册（88）免 token——验证码校验由 App 侧经 AGC 完成，
// 此三者为登录前的入口，与 78/81 同一信任模型
const AUTH_EXEMPT = new Set([10, 11, 12, 13, 78, 81, 85, 86, 88]);

export function listRouteServices(req, res) {
  ok(res, listServices());
}

// 路由入站调用日志（供服务器控制台回显客户端经路由发起的调用）
export function listRouteActivity(req, res) {
  ok(res, listActivity());
}

function summarizeResult(result) {
  if (!result || typeof result !== 'object') {
    return result == null ? null : String(result);
  }
  if (typeof result.message === 'string' && result.message !== '') {
    return result.message.slice(0, 120);
  }
  if (result.flowStatus && result.workingCard) {
    const card = (result.workingCard && result.workingCard.card) || {};
    const fields = ['purpose', 'event', 'time'].filter(k => card[k] != null).map(k => String(card[k])).join(' / ');
    return `state=${result.flowStatus.state} · ${fields || '空卡'}`;
  }
  const keys = Object.keys(result).slice(0, 5);
  return keys.join(', ') || '{}';
}

// 提交任务：执行服务后把结果**只**放在本次 HTTP 响应里返回给调用方。
// 不再做「服务器反向投递到客户端」——那要求服务器能访问客户端地址（客户端在 NAT 后不可达），
// 且调用方本来就在等这次响应，结果无需二次推送。
// 身份校验：调用方须携带登录时签发的 token；身份以 token 反解结果为准，并覆盖 payload 中自报的
// userId/account，避免客户端伪造他人身份。
export async function submitRouteTask(req, res) {
  const { service, serviceId, token = null, payload = {} } = req.body ?? {};
  const svcs = listServices();
  let num;
  if (serviceId !== undefined && serviceId !== null) {
    num = Number(serviceId);
    if (!Number.isInteger(num) || !svcs.some(s => s.id === num)) {
      return fail(res, 40002, `unknown service: ${num}`);
    }
  } else if (typeof service === 'string' && service.trim() !== '') {
    // 兼容旧 name 查找，转换为数字编号
    const found = svcs.find(s => s.name === service);
    if (!found) {
      return fail(res, 40002, `unknown service: ${service}`);
    }
    num = found.id;
  } else {
    return fail(res, 40001, 'serviceId (number) or service (name) is required');
  }

  const serverName = svcs.find(s => s.id === num)?.name ?? null;
  const body = (payload && typeof payload === 'object' && !Array.isArray(payload)) ? { ...payload } : {};

  if (!AUTH_EXEMPT.has(num)) {
    const me = resolveToken(token);
    if (!me) {
      return fail(res, 40101, '未登录：请先在客户端注册并登录账号', 401);
    }
    body.userId = me.userId;
    body.account = me.account;
  }

  const output = await execute(num, body);
  pushActivity({
    serviceId: num,
    service: serverName,
    summary: summarizeResult(output),
    ok: true
  });

  ok(res, { serviceId: num, service: serverName, result: output });
}