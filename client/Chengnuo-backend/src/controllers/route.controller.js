import { ok, fail } from '../utils/response.js';
import { listServerServices, submitToServer } from '../clientRouter.js';
import { handleRoute } from '../localRoute.js';

// 查询服务器上注册的服务（经路由 IP 连接到服务器）
export async function listRouteServices(req, res) {
  const out = await listServerServices();
  if (!out.ok) {
    return fail(res, 50301, `server unreachable: ${out.error ?? ('http ' + out.status)}`, 503);
  }
  ok(res, out.body?.data ?? out.body);
}

// 客户端提交任务：先按编号分流——本地化服务（AI 对话记录 / 好友对话 / 私人卡片组同步）由客户端直接应答，
// 其余服务照旧携带 serviceId + payload + 登录 token 转发给服务器，结果放在本次响应的 body 里返回。
// 服务器不需要反向连回客户端。
export async function submitRouteTask(req, res) {
  let { serviceId, token = null, payload = {} } = req.body ?? {};
  if (serviceId === undefined || serviceId === null || serviceId === '') {
    return fail(res, 40001, 'serviceId (number) is required; AI 调用编号为 0');
  }
  serviceId = Number(serviceId);

  try {
    const local = await handleRoute(serviceId, { token, payload });
    if (local.handled) {
      return ok(res, local.data);
    }
  } catch (err) {
    return fail(res, err.code ?? err.status ?? 500, err.message ?? '客户端处理失败', err.status ?? 500);
  }

  const out = await submitToServer({ serviceId, token, payload });

  if (!out.ok) {
    // 服务器有正常业务响应时，按其原始状态码与错误码透传（页面据此区分「登录失效 401」与「业务错误 409」等）；
    // 只有连不上服务器（无业务响应）时才用 502 表示链路故障。
    const code = out.body?.code;
    const message = out.body?.message;
    if (typeof code === 'number' && typeof message === 'string') {
      return fail(res, code, message, out.status || 502);
    }
    return fail(res, 50201, `server returned error: ${out.error ?? ('http ' + out.status)}`, 502);
  }
  ok(res, out.body?.data ?? out.body);
}