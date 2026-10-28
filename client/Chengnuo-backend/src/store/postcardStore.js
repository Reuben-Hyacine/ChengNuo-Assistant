import { dataFilePath, readJsonl, writeJsonl, serializedChain } from './jsonl.js';

// 明信片（客户端长期保存）：点击卡片「完成」后，服务器按该卡片生成一句明信片正文（服务 66），
// 由客户端写入本文件长期留存；服务器不做持久化。文件为 UTF-8 JSONL，可手动编辑。
const FILE_PATH = dataFilePath('postcards.txt');

let cache = [];
let nextId = 1;
let loaded = false;
const run = serializedChain();

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function normalize(parsed) {
  const id = Number(parsed?.id);
  const groupId = Number(parsed?.groupId);
  const cardIndex = Number(parsed?.cardIndex);
  const text = textOf(parsed?.text);
  if (!Number.isInteger(id) || id < 1 || text === '') {
    return null;
  }
  return {
    id,
    account: textOf(parsed?.account) || null,
    userId: Number.isInteger(Number(parsed?.userId)) ? Number(parsed.userId) : null,
    groupId: Number.isInteger(groupId) ? groupId : null,
    groupName: textOf(parsed?.groupName) || null,
    cardIndex: Number.isInteger(cardIndex) ? cardIndex : null,
    event: textOf(parsed?.event) || null,
    time: textOf(parsed?.time) || null,
    text,
    model: textOf(parsed?.model) || null,
    createdAt: typeof parsed?.createdAt === 'string' ? parsed.createdAt : new Date().toISOString()
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

// 追加一张明信片：服务 66 生成成功后由客户端写入，返回落库后的完整记录
export function appendPostcard({ account = null, userId = null, groupId = null, groupName = null, cardIndex = null, event = null, time = null, text, model = null, createdAt = null }) {
  return run(async () => {
    await ensureLoaded();
    const body = textOf(text);
    if (body === '') {
      return null;
    }
    const rec = {
      id: nextId++,
      account: textOf(account) || null,
      userId: Number.isInteger(userId) ? userId : null,
      groupId: Number.isInteger(groupId) ? groupId : null,
      groupName: textOf(groupName) || null,
      cardIndex: Number.isInteger(cardIndex) ? cardIndex : null,
      event: textOf(event) || null,
      time: textOf(time) || null,
      text: body,
      model: textOf(model) || null,
      createdAt: typeof createdAt === 'string' && createdAt !== '' ? createdAt : new Date().toISOString()
    };
    cache.push(rec);
    await persist();
    return { ...rec };
  });
}

// 某账号的全部明信片：最新的在前
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

// 删除某账号的一张明信片（控制台「明信片」库的删除按钮）
export function removePostcard(account, id) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    const pid = Number(id);
    if (name === '' || !Number.isInteger(pid) || pid < 1) {
      return { id: Number.isInteger(pid) ? pid : null, removed: false };
    }
    const before = cache.length;
    cache = cache.filter(rec => !(rec.account === name && rec.id === pid));
    const removed = before !== cache.length;
    if (removed) {
      await persist();
    }
    return { id: pid, removed };
  });
}

// 注销账号：清除该账号在本客户端的明信片
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

// 改名（82）：该账号的明信片记录同步换名（userId 不变）
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