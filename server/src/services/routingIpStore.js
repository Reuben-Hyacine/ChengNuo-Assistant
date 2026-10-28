import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

const FILE_PATH = path.join(config.dataDir, config.routingIpFile);

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
    await fs.writeFile(FILE_PATH, '', 'utf8');
  }
}

async function load() {
  await ensureFile();
  const text = await fs.readFile(FILE_PATH, 'utf8');
  cache = text.split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .map(line => JSON.parse(line));
  nextId = cache.reduce((max, entry) => Math.max(max, entry.id), 0) + 1;
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

async function persist() {
  const text = cache.map(entry => JSON.stringify(entry)).join('\n');
  await fs.writeFile(FILE_PATH, text === '' ? '' : text + '\n', 'utf8');
}

export function listIps() {
  return serialized(async () => {
    await ensureLoaded();
    return cache.map(entry => ({ ...entry }));
  });
}

export function addIp({ ip, port, name, userId }) {
  return serialized(async () => {
    await ensureLoaded();
    const duplicate = cache.find(entry => entry.ip === ip && entry.port === port);
    if (duplicate) {
      const err = new Error('routing ip already exists');
      err.status = 409;
      throw err;
    }
    const entry = {
      id: nextId++,
      ip,
      port: port ?? null,
      name: name ?? null,
      userId: (Number.isInteger(userId) && userId >= 1) ? userId : null,
      createdAt: new Date().toISOString()
    };
    cache.push(entry);
    await persist();
    return { ...entry };
  });
}

// 登录后「账号与 IP 临时绑定」：同 ip+port 存在则更新 name/userId，否则新增条目
// 同一 userId 只保留最新一次绑定的条目，旧绑定清除
export function upsertIp({ ip, port, name, userId }) {
  return serialized(async () => {
    await ensureLoaded();
    const validUserId = Number.isInteger(userId) && userId >= 1 ? userId : null;
    const existing = cache.find(entry => entry.ip === ip && entry.port === port);
    if (existing) {
      if (typeof name === 'string' && name.trim() !== '') {
        existing.name = name.trim();
      }
      if (validUserId !== null) {
        existing.userId = validUserId;
      }
      if (validUserId !== null) {
        for (const entry of cache) {
          if (entry !== existing && entry.userId === validUserId) {
            entry.userId = null;
          }
        }
      }
      await persist();
      return { ...existing };
    }
    const entry = {
      id: nextId++,
      ip,
      port: port ?? null,
      name: name ?? null,
      userId: validUserId,
      createdAt: new Date().toISOString()
    };
    cache.push(entry);
    await persist();
    return { ...entry };
  });
}

// 注销账号时解除该 userId 的全部临时 IP 绑定
export function unbindUserId(userId) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1) {
      return null;
    }
    let changed = false;
    for (const entry of cache) {
      if (entry.userId === userId) {
        entry.userId = null;
        changed = true;
      }
    }
    if (changed) {
      await persist();
    }
    return { userId, unbound: changed };
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
    await persist();
    return { ...removed };
  });
}

// 改名级联：IP 临时绑定条目上的账号名同步更新（下次登录 upsert 也会自愈，此处保证改名后立即可用）
export function renameIpBindingsOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const entry of cache) {
      if (entry.name === oldName) {
        entry.name = newName;
        changed += 1;
      }
    }
    if (changed > 0) {
      await persist();
    }
    return { changed };
  });
}
