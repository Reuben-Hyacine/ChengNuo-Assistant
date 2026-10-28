import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 提醒送达台账：记录「账号 × 卡片 × 某一次日程」的提醒是否已送达客户端，保证同一条提醒只弹一次。
// key 由 reminderService 生成（library#index#该次日程开始时间戳#卡片创建时间），台账只存 key 与送达时间。
// 超过保留期的记录在每次写入时顺手清理，避免台账无限增长。
const FILE_PATH = path.join(config.dataDir, config.reminderFile);

// 送达记录保留天数
const RETAIN_DAYS = 30;

let cache = new Map(); // account -> Set<key>
let times = new Map(); // key -> deliveredAt(ms)
let loaded = false;
let chain = Promise.resolve();

function serialized(task) {
  const run = chain.then(task, task);
  chain = run.then(() => {}, () => {});
  return run;
}

function accountName(account) {
  return typeof account === 'string' ? account.trim() : '';
}

function stripBom(text) {
  return text && text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
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
  const text = stripBom(await fs.readFile(FILE_PATH, 'utf8'));
  cache = new Map();
  times = new Map();
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() === '') {
      continue;
    }
    try {
      const parsed = JSON.parse(line);
      const account = accountName(parsed.account);
      const key = typeof parsed.key === 'string' ? parsed.key : '';
      const deliveredAt = Number(parsed.deliveredAt);
      if (account === '' || key === '' || !Number.isFinite(deliveredAt)) {
        continue;
      }
      if (!cache.has(account)) {
        cache.set(account, new Set());
      }
      cache.get(account).add(key);
      times.set(key, deliveredAt);
    } catch {
      // 跳过损坏行
    }
  }
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

async function persist() {
  const cutoff = Date.now() - RETAIN_DAYS * 24 * 3600 * 1000;
  for (const [key, deliveredAt] of [...times.entries()]) {
    if (deliveredAt < cutoff) {
      times.delete(key);
    }
  }
  const lines = [];
  for (const [account, keys] of cache.entries()) {
    for (const key of keys) {
      const deliveredAt = times.get(key);
      if (deliveredAt === undefined) {
        keys.delete(key);
        continue;
      }
      lines.push(JSON.stringify({ account, key, deliveredAt }));
    }
  }
  await fs.writeFile(FILE_PATH, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

// 过滤出尚未送达的 key：已送达的不返回（提醒不重复弹）
export function filterDelivered(account, keys) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const delivered = cache.get(name) ?? new Set();
    return (Array.isArray(keys) ? keys : []).filter(k => !delivered.has(k));
  });
}

// 记录一批 key 为已送达
export function markDelivered(account, keys) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const list = (Array.isArray(keys) ? keys : []).filter(k => typeof k === 'string' && k !== '');
    if (name === '' || list.length === 0) {
      return { marked: 0 };
    }
    if (!cache.has(name)) {
      cache.set(name, new Set());
    }
    const now = Date.now();
    let marked = 0;
    for (const key of list) {
      cache.get(name).add(key);
      times.set(key, now);
      marked += 1;
    }
    await persist();
    return { marked };
  });
}

// 组内某张卡片的「时间」被改动（延期）后，清掉该卡片在台账里的旧送达记录。
// 去重 key 含「该次日程开始时间戳」，改期后是新 key 会正常触发；但若时间被改回原值，
// 旧 key 仍在台账会让那一次永远不触发，故每次改期都把该卡片的旧 key 一并清掉。
// 只按该卡片前缀（group#组号:组内编号#）删除，不影响其他卡片。
export function clearRemindersByCard(groupId, cardIndex) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(groupId) || !Number.isInteger(cardIndex)) {
      return { removed: 0 };
    }
    const prefix = `group#${groupId}:${cardIndex}#`;
    let removed = 0;
    for (const [account, keys] of [...cache.entries()]) {
      for (const key of [...keys]) {
        if (key.startsWith(prefix)) {
          keys.delete(key);
          times.delete(key);
          removed += 1;
        }
      }
      if (keys.size === 0) {
        cache.delete(account);
      }
    }
    if (removed > 0) {
      await persist();
    }
    return { groupId, cardIndex, removed };
  });
}

// 注销账号时清空其送达台账
export function clearRemindersOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const keys = cache.get(name);
    if (!keys) {
      return { removed: 0 };
    }
    let removed = 0;
    for (const key of keys) {
      times.delete(key);
      removed += 1;
    }
    cache.delete(name);
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名级联：送达台账按账号名分桶，改名时整桶迁移（key 与送达时间不变）
export function renameRemindersOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    const keys = cache.get(oldName);
    if (!keys) {
      return { changed: 0 };
    }
    cache.delete(oldName);
    cache.set(newName, keys);
    await persist();
    return { changed: keys.size };
  });
}
