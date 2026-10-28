import { dataFilePath, readJsonl, writeJsonl, serializedChain } from './jsonl.js';

// AI 对话记录（客户端长期保存）：服务器不再持久化对话，调用服务 0（ai.ask）时由本库上送历史。
// 每个账号只保留最近 MAX_MESSAGES_PER_USER 条，超出即丢弃最早的。
const FILE_PATH = dataFilePath('conversations.txt');
export const MAX_MESSAGES_PER_USER = 10;

let cache = [];
let nextId = 1;
let loaded = false;
const run = serializedChain();

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function normalize(parsed) {
  const id = Number(parsed?.id);
  const userId = Number(parsed?.userId);
  const direction = parsed?.direction === 'in' ? 'in' : (parsed?.direction === 'out' ? 'out' : null);
  const content = textOf(parsed?.content);
  if (!Number.isInteger(id) || id < 1 || !Number.isInteger(userId) || userId < 1 || !direction || content === '') {
    return null;
  }
  return {
    id,
    account: textOf(parsed?.account) || null,
    userId,
    direction,
    time: typeof parsed?.time === 'string' ? parsed.time : new Date().toISOString(),
    content
  };
}

async function ensureLoaded() {
  if (loaded) {
    return;
  }
  const records = await readJsonl(FILE_PATH);
  cache = [];
  nextId = 1;
  for (const raw of records) {
    const rec = normalize(raw);
    if (!rec) {
      continue;
    }
    cache.push(rec);
    if (rec.id >= nextId) {
      nextId = rec.id + 1;
    }
  }
  loaded = true;
}

async function persist() {
  await writeJsonl(FILE_PATH, cache);
}

function trimByUser(userId) {
  const mine = cache.filter(rec => rec.userId === userId);
  if (mine.length <= MAX_MESSAGES_PER_USER) {
    return;
  }
  const keep = new Set(mine.slice(-MAX_MESSAGES_PER_USER).map(rec => rec.id));
  cache = cache.filter(rec => rec.userId !== userId || keep.has(rec.id));
}

// 追加一轮对话（用户消息 + AI 回复）：服务 0 转发成功后由客户端写入
export function appendTurn({ account = null, userId, userText, replyText = null }) {
  return run(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1) {
      return [];
    }
    const time = new Date().toISOString();
    const written = [];
    const inText = textOf(userText);
    if (inText !== '') {
      const rec = { id: nextId++, account, userId, direction: 'in', time, content: inText };
      cache.push(rec);
      written.push({ ...rec });
    }
    const outText = textOf(replyText);
    if (outText !== '') {
      const rec = { id: nextId++, account, userId, direction: 'out', time, content: outText };
      cache.push(rec);
      written.push({ ...rec });
    }
    trimByUser(userId);
    if (written.length > 0) {
      await persist();
    }
    return written;
  });
}

// 服务 39：最近十条对话，最新的在前（与服务器旧实现一致，页面会自行倒序展示）
export function listByUser(userId) {
  return run(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1) {
      return [];
    }
    return cache.filter(rec => rec.userId === userId).slice(-MAX_MESSAGES_PER_USER).reverse().map(rec => ({ ...rec }));
  });
}

// 服务 0 上送的历史：最简单的 {direction, content} 列表，按时间正序（旧 -> 新）
export function historyFor(userId) {
  return run(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1) {
      return [];
    }
    return cache
      .filter(rec => rec.userId === userId)
      .slice(-MAX_MESSAGES_PER_USER)
      .map(rec => ({ direction: rec.direction, content: rec.content }));
  });
}

// 服务 8：清空某账号的 AI 对话记录
export function clearByUser(userId) {
  return run(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1) {
      return { removed: 0 };
    }
    const before = cache.length;
    cache = cache.filter(rec => rec.userId !== userId);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 注销账号：清除该账号在本客户端的 AI 对话记录
export function clearByAccount(account) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    if (name === '') {
      return { removed: 0 };
    }
    const before = cache.length;
    cache = cache.filter(rec => rec.account !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名（82）：该账号的对话记录同步换名（userId 不变，仅 account 字段迁移）
export function renameAccountOf(account, newAccount) {
  return run(async () => {
    await ensureLoaded();
    const oldName = textOf(account);
    const newName = textOf(newAccount);
    if (oldName === '' || newName === '' || oldName === newName) {
      return { renamed: 0 };
    }
    let renamed = 0;
    for (const rec of cache) {
      if (rec.account === oldName) {
        rec.account = newName;
        renamed += 1;
      }
    }
    if (renamed > 0) {
      await persist();
    }
    return { renamed };
  });
}