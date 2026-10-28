import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 明信片外发中转库：服务器按「短期中转、送达即删」投递两类记录——
// 1) postcard：卡片完成（62）后由服务器后台按快照出稿、发给除完成者外全体花名册成员的明信片；
// 2) clear：未完成卡片被删除（57）时投递的「清理该群本地聊天记录」墓碑。
// 各客户端经 103（postcards.pull）拉取，拉取即从服务器删除；明信片与聊天记录的
// 长期保存完全由客户端本地负责，服务器不存历史。与群聊中转库（groupChatStore）同一约定。
const FILE_PATH = path.join(config.dataDir, config.postcardOutboxFile);

const RETAIN_DAYS = 30;
const MAX_PER_ACCOUNT = 200;

let cache = []; // [{id, kind:'postcard'|'clear', toAccount, ...}]
let nextId = 1;
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

function textOf(value, max) {
  if (typeof value !== 'string') {
    return '';
  }
  const t = value.trim();
  return t.length > max ? t.slice(0, max) : t;
}

function normalizeRecord(parsed) {
  const id = Number(parsed.id);
  const toAccount = accountName(parsed.toAccount);
  const groupId = Number(parsed.groupId);
  const createdAt = Number(parsed.createdAt);
  if (!Number.isInteger(id) || id < 1 || toAccount === '' ||
    !Number.isInteger(groupId) || groupId < 1 || !Number.isFinite(createdAt)) {
    return null;
  }
  if (parsed.kind === 'clear') {
    return { id, kind: 'clear', toAccount, groupId, createdAt };
  }
  const cardIndex = Number(parsed.cardIndex);
  return {
    id,
    kind: 'postcard',
    toAccount,
    groupId,
    groupName: textOf(parsed.groupName, 120),
    cardIndex: Number.isInteger(cardIndex) && cardIndex >= 1 ? cardIndex : null,
    event: textOf(parsed.event, 200),
    time: textOf(parsed.time, 60),
    text: textOf(parsed.text, 2000),
    model: textOf(parsed.model, 120),
    completedAt: textOf(parsed.completedAt, 40),
    createdAt
  };
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
  cache = [];
  nextId = 1;
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() === '') {
      continue;
    }
    try {
      const rec = normalizeRecord(JSON.parse(line));
      if (!rec) {
        continue;
      }
      cache.push(rec);
      if (rec.id >= nextId) {
        nextId = rec.id + 1;
      }
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
  cache = cache.filter(r => r.createdAt >= cutoff);
  // 每个账号最多保留 MAX_PER_ACCOUNT 条（旧的先丢）
  const buckets = new Map();
  for (const r of cache) {
    if (!buckets.has(r.toAccount)) {
      buckets.set(r.toAccount, []);
    }
    buckets.get(r.toAccount).push(r);
  }
  const kept = [];
  for (const list of buckets.values()) {
    list.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id);
    kept.push(...(list.length > MAX_PER_ACCOUNT ? list.slice(list.length - MAX_PER_ACCOUNT) : list));
  }
  kept.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id);
  cache = kept;
  const lines = cache.map(r => JSON.stringify(r));
  await fs.writeFile(FILE_PATH, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

// 同一份明信片（同一次完成出稿的正文）fan-out 给多个接收账号
export function enqueuePostcards({ groupId, groupName = '', cardIndex = null, event = '', time = '',
  text = '', model = '', completedAt = '' }, toAccounts = []) {
  return serialized(async () => {
    await ensureLoaded();
    const group = Number(groupId);
    const body = textOf(text, 2000);
    if (!Number.isInteger(group) || group < 1 || body === '') {
      return { enqueued: 0 };
    }
    const createdAt = Date.now();
    let enqueued = 0;
    for (const rawTo of toAccounts) {
      const to = accountName(rawTo);
      if (to === '') {
        continue;
      }
      cache.push({
        id: nextId++,
        kind: 'postcard',
        toAccount: to,
        groupId: group,
        groupName: textOf(groupName, 120),
        cardIndex: Number.isInteger(cardIndex) && cardIndex >= 1 ? cardIndex : null,
        event: textOf(event, 200),
        time: textOf(time, 60),
        text: body,
        model: textOf(model, 120),
        completedAt: textOf(completedAt, 40),
        createdAt
      });
      enqueued += 1;
    }
    if (enqueued > 0) {
      await persist();
    }
    return { enqueued };
  });
}

// 「清理该群本地聊天记录」墓碑：未完成卡片被删除（57）时 fan-out 给全部花名册
export function enqueueClears(groupId, toAccounts = []) {
  return serialized(async () => {
    await ensureLoaded();
    const group = Number(groupId);
    if (!Number.isInteger(group) || group < 1) {
      return { enqueued: 0 };
    }
    const createdAt = Date.now();
    let enqueued = 0;
    for (const rawTo of toAccounts) {
      const to = accountName(rawTo);
      if (to === '') {
        continue;
      }
      cache.push({ id: nextId++, kind: 'clear', toAccount: to, groupId: group, createdAt });
      enqueued += 1;
    }
    if (enqueued > 0) {
      await persist();
    }
    return { enqueued };
  });
}

// 拉取某账号的全部待投递记录：拉取即从服务器删除（送达即删）。
// 返回 { postcards: [...], clears: [groupId, ...] }，由客户端落本地库 / 清本地线程
export function takeOutboxFor(account) {
  return serialized(async () => {
    await ensureLoaded();
    const me = accountName(account);
    if (me === '') {
      return { postcards: [], clears: [] };
    }
    const mine = cache.filter(r => r.toAccount === me);
    if (mine.length === 0) {
      return { postcards: [], clears: [] };
    }
    cache = cache.filter(r => r.toAccount !== me);
    await persist();
    mine.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id);
    const postcards = mine.filter(r => r.kind === 'postcard');
    const clears = [];
    for (const r of mine) {
      if (r.kind === 'clear' && !clears.includes(r.groupId)) {
        clears.push(r.groupId);
      }
    }
    return { postcards, clears };
  });
}

// 注销账号时清空其外发中转箱
export function clearOutboxOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const before = cache.length;
    cache = cache.filter(r => r.toAccount !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名级联：外发记录的接收账号同步更新
export function renameOutboxOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const r of cache) {
      if (r.toAccount === oldName) {
        r.toAccount = newName;
        changed += 1;
      }
    }
    if (changed > 0) {
      await persist();
    }
    return { changed };
  });
}
