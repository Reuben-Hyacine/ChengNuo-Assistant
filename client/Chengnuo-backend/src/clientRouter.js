import { config } from './config.js';
import { primaryIp } from './services/ipStore.js';

// 客户端绝不 import 服务器代码。所有对服务器的调用都通过 HTTP 路由 IP 完成。
const ROUTE_SERVICES_PATH = '/api/route/services';
const ROUTE_TASK_PATH = '/api/route/task';
const SUBMIT_TIMEOUT_MS = 60000;

// 当前要连接的服务器：实时读取客户端持有的「服务器 IP 库」中的 primary 条目，
// 因此在控制台切换服务器后立即生效，无需重启客户端；库里没有记录时回退到配置默认值。
export async function currentServer() {
  const entry = await primaryIp();
  if (entry) {
    return { ip: entry.ip, port: entry.port ?? 3000, source: 'ip-library' };
  }
  return { ip: config.serverIp, port: config.serverPort, source: 'default' };
}

async function serverBase() {
  const { ip, port } = await currentServer();
  return `http://${ip}:${port}`;
}

// 查询服务器上当前注册的服务（列表返回 [{id,name}])
export async function listServerServices() {
  const url = `${await serverBase()}${ROUTE_SERVICES_PATH}`;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), SUBMIT_TIMEOUT_MS);
    const resp = await fetch(url, { method: 'GET', signal: controller.signal });
    clearTimeout(timer);
    const text = await resp.text();
    let parsed = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = { raw: text };
    }
    return { ok: resp.ok, status: resp.status, body: parsed };
  } catch (err) {
    return { ok: false, status: 0, error: err.message };
  }
}

// 提交任务到服务器：客户端只发 serviceId + payload + 登录 token，服务器执行后把结果放在本次 HTTP 响应里返回。
// 不再上报「结果回传地址」——服务器不需要反向连回客户端，客户端在 NAT 后也能正常工作。
export async function submitToServer({ serviceId, token = null, payload = {} }) {
  const url = `${await serverBase()}${ROUTE_TASK_PATH}`;
  const body = {
    serviceId,
    payload: payload ?? {}
  };
  if (typeof token === 'string' && token.trim() !== '') {
    // 登录凭据：服务器据此反解调用者身份（注册/登录/退出/注销无需携带）
    body.token = token.trim();
  }
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), SUBMIT_TIMEOUT_MS);
    const resp = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: controller.signal
    });
    clearTimeout(timer);
    const text = await resp.text();
    let parsed = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = { raw: text };
    }
    return { ok: resp.ok, status: resp.status, body: parsed };
  } catch (err) {
    return { ok: false, status: 0, error: err.message };
  }
}