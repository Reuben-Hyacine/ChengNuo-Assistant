import { dataFilePath, readJsonl, writeJsonl, serializedChain } from './jsonl.js';

// 天气快照（客户端长期保存）：服务 97 调用和风天气得到 8 个产品的数据后，
// 由客户端写入本文件长期留存（服务器不持久化）。文件为 UTF-8 JSONL，可手动编辑。
const FILE_PATH = dataFilePath('weather.txt');

let cache = [];
let nextId = 1;
let loaded = false;
const run = serializedChain();

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function objectOrNull(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function normalize(parsed) {
  const id = Number(parsed?.id);
  if (!Number.isInteger(id) || id < 1) {
    return null;
  }
  const location = objectOrNull(parsed?.location);
  const weather = objectOrNull(parsed?.weather);
  if (!location || !weather) {
    return null;
  }
  return {
    id,
    account: textOf(parsed?.account) || null,
    userId: Number.isInteger(Number(parsed?.userId)) ? Number(parsed.userId) : null,
    location,
    weather,
    fetchedAt: typeof parsed?.fetchedAt === 'string' ? parsed.fetchedAt : new Date().toISOString()
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

// 追加一份天气快照：服务 97 返回成功后由客户端写入，返回落库后的完整记录
export function appendSnapshot({ account = null, userId = null, location = null, weather = null, fetchedAt = null }) {
  return run(async () => {
    await ensureLoaded();
    const loc = objectOrNull(location);
    const data = objectOrNull(weather);
    if (!loc || !data) {
      return null;
    }
    const rec = {
      id: nextId++,
      account: textOf(account) || null,
      userId: Number.isInteger(userId) ? userId : null,
      location: loc,
      weather: data,
      fetchedAt: typeof fetchedAt === 'string' && fetchedAt !== '' ? fetchedAt : new Date().toISOString()
    };
    cache.push(rec);
    await persist();
    return { ...rec };
  });
}

// 某账号的全部天气快照：最新的在前
export function listForAccount(account) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    if (name === '') {
      return [];
    }
    return cache.filter(rec => rec.account === name).reverse().map(rec => ({ ...rec }));
  });
}

// 某账号最近一份天气快照
export function latestForAccount(account) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    if (name === '') {
      return null;
    }
    for (let i = cache.length - 1; i >= 0; i -= 1) {
      if (cache[i].account === name) {
        return { ...cache[i] };
      }
    }
    return null;
  });
}

// 删除某账号的一份天气快照
export function removeSnapshot(account, id) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    const sid = Number(id);
    if (name === '' || !Number.isInteger(sid) || sid < 1) {
      return { id: Number.isInteger(sid) ? sid : null, removed: false };
    }
    const before = cache.length;
    cache = cache.filter(rec => !(rec.account === name && rec.id === sid));
    const removed = before !== cache.length;
    if (removed) {
      await persist();
    }
    return { id: sid, removed };
  });
}

// 注销账号：清除该账号在本客户端的天气快照
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

// 改名（82）：该账号的天气快照同步换名（userId 不变）
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