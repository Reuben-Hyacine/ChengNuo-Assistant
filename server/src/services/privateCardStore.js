import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';
import { normalizeContent, participantCount } from './cardStore.js';

// 私人卡片库：服务器长期存储，按账号分桶，每个账号最多 20 张。
// 与「公开卡片库」（cardStore.js，全局 20 槽）区分：私人卡片只属于发起它的账号，不对外可见。
const FILE_PATH = path.join(config.dataDir, config.privateCardFile);

export const MAX_PRIVATE_CARDS = 20;

// key = `${account}#${index}` -> { account, index, content, createdAt, updatedAt }
let cache = new Map();
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

function keyOf(account, index) {
  return `${account}#${index}`;
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
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() === '') {
      continue;
    }
    try {
      const parsed = JSON.parse(line);
      const account = accountName(parsed.account);
      const index = Number(parsed.index);
      if (account === '' || !Number.isInteger(index) || index < 1 || index > MAX_PRIVATE_CARDS) {
        continue;
      }
      const content = normalizeContent(parsed.content);
      if (content === null) {
        continue;
      }
      cache.set(keyOf(account, index), {
        account,
        index,
        content,
        createdAt: typeof parsed.createdAt === 'string' ? parsed.createdAt : new Date().toISOString(),
        updatedAt: typeof parsed.updatedAt === 'string' ? parsed.updatedAt : new Date().toISOString()
      });
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
  const lines = [...cache.values()]
    .sort((a, b) => (a.account === b.account ? a.index - b.index : a.account.localeCompare(b.account)))
    .map(entry => JSON.stringify(entry));
  await fs.writeFile(FILE_PATH, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

// 读取视图：附带实时算出的「人数」，统一把发起者记为所属账号
function view(entry) {
  const content = { ...entry.content, initiator: entry.account };
  content.count = participantCount(content);
  return { index: entry.index, content, createdAt: entry.createdAt, updatedAt: entry.updatedAt };
}

function doSet(account, index, content) {
  const key = keyOf(account, index);
  const existing = cache.get(key);
  const stored = (content && typeof content === 'object' && !Array.isArray(content)) ? { ...content } : content;
  if (stored && typeof stored === 'object') {
    delete stored.count;
  }
  const entry = {
    account,
    index,
    content: stored,
    createdAt: existing?.createdAt ?? new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  cache.set(key, entry);
  return persist().then(() => view(entry));
}

// 某账号的私人卡片库（按 index 升序）
export function listPrivateCards(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      return [];
    }
    return [...cache.values()]
      .filter(e => e.account === name)
      .sort((a, b) => a.index - b.index)
      .map(view);
  });
}

// 写入一张私人卡片：占用该账号最小的空闲 index；满 20 张报 409
export function addPrivateCard(account, content) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      const err = new Error('需要账号身份才能写入私人卡片');
      err.status = 400;
      throw err;
    }
    const normalized = normalizeContent(content);
    if (normalized === null) {
      const err = new Error('卡片内容不合法');
      err.status = 400;
      throw err;
    }
    let freeIndex = 0;
    for (let i = 1; i <= MAX_PRIVATE_CARDS; i++) {
      if (!cache.has(keyOf(name, i))) {
        freeIndex = i;
        break;
      }
    }
    if (freeIndex === 0) {
      const err = new Error(`私人卡片库已满（最多 ${MAX_PRIVATE_CARDS} 张）`);
      err.status = 409;
      throw err;
    }
    return doSet(name, freeIndex, { ...normalized, initiator: name });
  });
}

export function deletePrivateCard(account, index) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      const err = new Error('需要账号身份才能删除私人卡片');
      err.status = 400;
      throw err;
    }
    const key = keyOf(name, index);
    const existing = cache.get(key);
    if (!existing) {
      return null;
    }
    cache.delete(key);
    await persist();
    return view(existing);
  });
}

// 注销账号时清空其私人卡片库
export function clearPrivateCardsOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    let removed = 0;
    for (const key of [...cache.keys()]) {
      if (cache.get(key).account === name) {
        cache.delete(key);
        removed += 1;
      }
    }
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名级联：私人卡片库按账号名分桶，改名时整桶迁移（Map 键 + 记录 account + 卡片发起者快照）
export function renamePrivateCardsOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const key of [...cache.keys()]) {
      const entry = cache.get(key);
      if (entry.account !== oldName) {
        continue;
      }
      cache.delete(key);
      entry.account = newName;
      if (entry.content && typeof entry.content === 'object') {
        entry.content.initiator = newName;
      }
      cache.set(keyOf(newName, entry.index), entry);
      changed += 1;
    }
    if (changed > 0) {
      await persist();
    }
    return { changed };
  });
}
