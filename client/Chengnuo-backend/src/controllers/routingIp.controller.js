import { ok, fail } from '../utils/response.js';
import { isValidIPv4, isValidPort } from '../utils/validate.js';
import { config } from '../config.js';
import { listIps, addIp, removeIp, setPrimary, selectServer } from '../services/ipStore.js';
import { detectOutwardAddr } from '../services/netAddress.js';
import { currentServer } from '../clientRouter.js';

// 服务器默认端口（服务器自身的默认监听端口）
const DEFAULT_SERVER_PORT = 3000;

export async function listRoutingIps(req, res) {
  ok(res, await listIps());
}

// 候选服务器列表：
//   默认第一条 =「服务器」（这台设备的服务器，填本机对外可达地址，其他设备上的客户端据此连上网外的它）
//   次选      =「本地服务器」（运行本软件的那台设备自己的服务器，127.0.0.1）
//   之后      = IP 库里保存过的其它地址
export async function suggestRoutingIps(req, res) {
  const current = await currentServer();
  const saved = await listIps();
  const outward = detectOutwardAddr();
  const suggestions = [];
  const seen = new Set();
  const add = (ip, port, label, source) => {
    const key = `${ip}:${port}`;
    if (ip === '' || seen.has(key)) {
      return;
    }
    seen.add(key);
    suggestions.push({ ip, port, label, source });
  };

  // 1) 默认：「服务器」的对外可达地址
  add(outward.ip, DEFAULT_SERVER_PORT, `服务器（本机对外地址 · ${outward.kind}）`, 'default');
  // 2) 次选：「本地服务器」本机回环地址
  add('127.0.0.1', DEFAULT_SERVER_PORT, '本地服务器（本机 127.0.0.1）', 'local');
  // 3) 库里已有记录
  for (const entry of saved) {
    add(entry.ip, entry.port ?? DEFAULT_SERVER_PORT, entry.primary ? '当前使用（来自 IP 库）' : 'IP 库中保存的服务器', 'saved');
  }

  ok(res, {
    current: { ip: current.ip, port: current.port },
    myIp: config.myIp,
    myPort: config.myPort,
    outward: { ip: outward.ip, kind: outward.kind },
    suggestions
  });
}

// 新增一条服务器地址；primary=true 表示把这条设为当前使用的服务器（其余条目自动取消 primary）
export async function addRoutingIp(req, res) {
  const { ip, port = null, name = null, primary = false } = req.body ?? {};
  if (!isValidIPv4(ip)) {
    return fail(res, 40001, 'valid IPv4 address is required');
  }
  if (port !== null && !isValidPort(port)) {
    return fail(res, 40002, 'port must be an integer between 1 and 65535');
  }
  const safeName = typeof name === 'string' && name.trim() !== '' ? name.trim() : null;
  try {
    const item = await addIp({ ip, port, name: safeName, primary: primary === true });
    res.status(201);
    ok(res, item);
  } catch (err) {
    if (err.status === 409) {
      return fail(res, 40901, err.message, 409);
    }
    throw err;
  }
}

// 切换当前使用的服务器：库里有这条就设为 primary，没有就新增一条并设为 primary。切换后立即生效。
export async function selectRoutingIp(req, res) {
  const { ip, port = DEFAULT_SERVER_PORT } = req.body ?? {};
  if (!isValidIPv4(ip)) {
    return fail(res, 40001, 'valid IPv4 address is required');
  }
  if (!isValidPort(port)) {
    return fail(res, 40002, 'port must be an integer between 1 and 65535');
  }
  const target = await selectServer({ ip: ip.trim(), port, name: 'server' });
  ok(res, { server: { ip: target.ip, port: target.port }, entry: target, message: `已切换到服务器 ${target.ip}:${target.port}，立即生效` });
}

// 兼容按 id 设置 primary
export async function setPrimaryRoutingIp(req, res) {
  const target = await setPrimary(Number(req.params.id));
  if (!target) {
    return fail(res, 40402, 'routing ip not found', 404);
  }
  ok(res, target);
}

export async function removeRoutingIp(req, res) {
  const removed = await removeIp(Number(req.params.id));
  if (!removed) {
    return fail(res, 40402, 'routing ip not found', 404);
  }
  ok(res, removed);
}
