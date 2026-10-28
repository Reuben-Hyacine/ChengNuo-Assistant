import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 卡片申请库：持久化到服务器 data/card-requests.txt
// 一条申请即一行 JSON，文件剥离 BOM；申请被处理（同意或拒绝）后即从申请库删除，不长期保留
const FILE_PATH = path.join(config.dataDir, config.cardRequestFile);

let cache = [];
let nextId = 1;
let loaded = false;
let chain = Promise.resolve();

function serialized(task) {
  const run = chain.then(task, task);
  chain = run.then(() => {}, () => {});
  return run;
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
  cache = [];
  text.split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .forEach(line => {
      try {
        const parsed = JSON.parse(line);
        if (parsed && Number.isInteger(parsed.id) && Number.isInteger(parsed.groupId)
          && Number.isInteger(parsed.cardIndex) && typeof parsed.toAccount === 'string') {
          cache.push(parsed);
        }
      } catch {
        // 跳过损坏行
      }
    });
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

function view(entry) {
  return { ...entry };
}

// 新建卡片加入申请：申请定位到「卡片组内的一张卡片」（groupId + cardIndex）；
// 同一申请人对同一张卡片已有未处理申请时直接返回该申请，不重复入库。
// 返回 { request, created }：created=false 表示命中了已有申请（供调用方避免重复抄送收件箱）。
export function createCardRequest({ groupId, cardIndex, fromAccount, fromUserId, toAccount, toUserId }) {
  return serialized(async () => {
    await ensureLoaded();
    const existing = cache.find(
      entry => entry.status === 'pending' && entry.groupId === groupId && entry.cardIndex === cardIndex && entry.fromAccount === fromAccount
    );
    if (existing) {
      return { request: view(existing), created: false };
    }
    const entry = {
      id: nextId++,
      groupId,
      cardIndex,
      fromAccount,
      fromUserId,
      toAccount,
      toUserId,
      status: 'pending',
      createdAt: new Date().toISOString(),
      handledAt: null
    };
    cache.push(entry);
    await persist();
    return { request: view(entry), created: true };
  });
}

// 收件箱：别人向我（作为卡片发起者）发来的、仍未处理的申请
export function listIncomingCardRequests(account) {
  return serialized(async () => {
    await ensureLoaded();
    return cache
      .filter(entry => entry.toAccount === account && entry.status === 'pending')
      .map(view);
  });
}

// 我发出的申请（用于卡片库标记「已申请」，避免重复申请）
export function listOutgoingCardRequests(account) {
  return serialized(async () => {
    await ensureLoaded();
    return cache.filter(entry => entry.fromAccount === account).map(view);
  });
}

export function getCardRequest(id) {
  return serialized(async () => {
    await ensureLoaded();
    const entry = cache.find(item => item.id === id);
    return entry ? view(entry) : null;
  });
}

// 处理申请后删除：同意或拒绝都把该申请从申请库移除，避免申请记录长期堆积
export function removeCardRequest(id) {
  return serialized(async () => {
    await ensureLoaded();
    const index = cache.findIndex(item => item.id === id);
    if (index === -1) {
      return null;
    }
    const [removed] = cache.splice(index, 1);
    await persist();
    return view(removed);
  });
}

// 注销账号时清除与该账号相关的全部申请（申请加入他人卡片 / 他人申请加入其卡片）
export function removeCardRequestsByAccount(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    if (name === '') {
      return { removed: 0 };
    }
    const before = cache.length;
    cache = cache.filter(entry => entry.fromAccount !== name && entry.toAccount !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名级联：卡片加入申请里申请方/审批方为该账号的字段同步更新
export function renameCardRequestsByAccount(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const entry of cache) {
      let touched = false;
      if (entry.fromAccount === oldName) {
        entry.fromAccount = newName;
        touched = true;
      }
      if (entry.toAccount === oldName) {
        entry.toAccount = newName;
        touched = true;
      }
      if (touched) {
        changed += 1;
      }
    }
    if (changed > 0) {
      await persist();
    }
    return { changed };
  });
}

// 组内某张卡片被删除或完成时，一并清掉该卡片上所有未处理的申请
export function removeCardRequestsByGroupCard(groupId, cardIndex) {
  return serialized(async () => {
    await ensureLoaded();
    const before = cache.length;
    cache = cache.filter(entry => !(entry.groupId === groupId && entry.cardIndex === cardIndex));
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { groupId, cardIndex, removed };
  });
}

// 卡片组被删除或转为私人时，一并清掉该组全部卡片上未处理的申请
export function removeCardRequestsByGroup(groupId) {
  return serialized(async () => {
    await ensureLoaded();
    const before = cache.length;
    cache = cache.filter(entry => entry.groupId !== groupId);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { groupId, removed };
  });
}
