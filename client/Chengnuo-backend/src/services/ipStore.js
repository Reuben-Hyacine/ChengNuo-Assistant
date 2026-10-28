import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 服务器 IP 库：本文件由客户端持有，记录「本客户端要连接的服务器地址」。
// 默认连「服务器」（对外可达地址，其他设备也能连上），次选是「本地服务器」（本机 127.0.0.1）。
// 启动器按 命令行 --server > primary 条目 > 第一条有效条目 > 默认（本机对外地址）的顺序选服务器。
// 文件可手动编辑：以 # 开头的行是说明，读取时跳过；每次写回都会重新写入下面的说明头，不会被清掉。
const FILE_PATH = path.join(config.dataDir, config.routingIpFile);

const FILE_HEADER = [
  '# ===== 服务器 IP 库（可手动编辑）=====',
  '# 用途：记录本客户端要连接的服务器地址。',
  '#   默认（primary: true）：「服务器」—— 对外提供服务的这台设备，ip 填它的对外可达地址，',
  '#                        这样其他设备上的客户端也能连上它（跨局域网/VPN 均可）。',
  '#   次选：「本地服务器」—— 运行本软件的那台设备自己的服务器，ip 填 127.0.0.1。',
  '# 客户端启动时按以下优先级决定连哪台服务器：',
  '#   1) 命令行参数  node launcher.js --server=IP:PORT   （最高优先级；会写回本文件）',
  '#   2) 本文件中 primary 为 true 的那一条',
  '#   3) 本文件中第一条有效记录',
  '#   4) 以上都没有时：本机对外可达地址 : 3000',
  '# 改法：把目标服务器写成一行 JSON，并把它设为 "primary": true（其余行设 false 或删除），',
  '#      保存后重启客户端（node launcher.js）即可生效。',
  '# 提示：若服务器所在设备换了网络，ip 要跟着改成它新的对外地址；同机测试也可以直接用 127.0.0.1。',
  '# 示例：{"id":1,"ip":"26.103.5.180","port":3000,"name":"server","primary":true}',
  ''
].join('\n');

let cache = [];
let nextId = 1;
let loaded = false;
let chain = Promise.resolve();

function serialized(task) {
  const run = chain.then(task, task);
  chain = run.then(() => {}, () => {});
  return run;
}

async function ensureFile() {
  await fs.mkdir(config.dataDir, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, FILE_HEADER, 'utf8');
  }
}

// 读取时跳过空行与 # 开头的说明行，保证手动编辑友好
async function load() {
  await ensureFile();
  const text = await fs.readFile(FILE_PATH, 'utf8');
  cache = [];
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) {
      continue;
    }
    try {
      const entry = JSON.parse(trimmed);
      if (typeof entry?.ip !== 'string' || entry.ip.trim() === '') {
        continue;
      }
      cache.push({
        id: Number.isInteger(entry.id) ? entry.id : cache.length + 1,
        ip: entry.ip.trim(),
        port: Number.isInteger(entry.port) ? entry.port : null,
        name: typeof entry.name === 'string' && entry.name.trim() !== '' ? entry.name.trim() : null,
        primary: entry.primary === true,
        createdAt: typeof entry.createdAt === 'string' ? entry.createdAt : new Date().toISOString()
      });
    } catch {
      // 跳过损坏行（手动编辑出错时不影响其它记录）
    }
  }
  nextId = cache.reduce((max, entry) => Math.max(max, entry.id), 0) + 1;
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

// 写回时始终带上说明头，避免手动加的说明被覆盖丢失
async function persist() {
  const lines = cache.map(entry => JSON.stringify(entry));
  const body = lines.length ? lines.join('\n') + '\n' : '';
  await fs.writeFile(FILE_PATH, FILE_HEADER + body, 'utf8');
}

export function listIps() {
  return serialized(async () => {
    await ensureLoaded();
    return cache.map(entry => ({ ...entry }));
  });
}

// 写入一条服务器地址；primary 为 true 时把其它条目的 primary 清掉
export function addIp({ ip, port = null, name = null, primary = false }) {
  return serialized(async () => {
    await ensureLoaded();
    const address = typeof ip === 'string' ? ip.trim() : '';
    const duplicate = cache.find(entry => entry.ip === address && entry.port === port);
    if (duplicate) {
      const err = new Error('routing ip already exists');
      err.status = 409;
      throw err;
    }
    if (primary) {
      for (const entry of cache) {
        entry.primary = false;
      }
    }
    const entry = {
      id: nextId++,
      ip: address,
      port: port ?? null,
      name: name ?? null,
      primary: primary === true,
      createdAt: new Date().toISOString()
    };
    cache.push(entry);
    await persist();
    return { ...entry };
  });
}

// 把某条记录设为当前使用的服务器（primary），其余条目自动取消 primary
export function setPrimary(id) {
  return serialized(async () => {
    await ensureLoaded();
    const target = cache.find(entry => entry.id === id);
    if (!target) {
      return null;
    }
    for (const entry of cache) {
      entry.primary = entry === target;
    }
    await persist();
    return { ...target };
  });
}

// 选择要连接的服务器：库里有这条就设为 primary，没有就新增一条并设为 primary
export function selectServer({ ip, port = null, name = null }) {
  return serialized(async () => {
    await ensureLoaded();
    const address = typeof ip === 'string' ? ip.trim() : '';
    if (address === '') {
      const err = new Error('ip is required');
      err.status = 400;
      throw err;
    }
    let target = cache.find(entry => entry.ip === address && entry.port === port) ?? null;
    if (!target) {
      target = {
        id: nextId++,
        ip: address,
        port: port ?? null,
        name: name ?? null,
        primary: true,
        createdAt: new Date().toISOString()
      };
      cache.push(target);
    }
    for (const entry of cache) {
      entry.primary = entry === target;
    }
    await persist();
    return { ...target };
  });
}

// 当前使用的服务器（primary 优先，其次第一条）
export function primaryIp() {
  return serialized(async () => {
    await ensureLoaded();
    const target = cache.find(entry => entry.primary) ?? cache[0] ?? null;
    return target ? { ...target } : null;
  });
}

export function removeIp(id) {
  return serialized(async () => {
    await ensureLoaded();
    const index = cache.findIndex(entry => entry.id === id);
    if (index === -1) {
      return null;
    }
    const [removed] = cache.splice(index, 1);
    // 删掉的若是当前服务器，则把剩下的第一条顶上，避免库里没有 primary
    if (removed.primary && cache.length > 0 && !cache.some(e => e.primary)) {
      cache[0].primary = true;
    }
    await persist();
    return { ...removed };
  });
}

export { FILE_PATH as routingIpFilePath };
