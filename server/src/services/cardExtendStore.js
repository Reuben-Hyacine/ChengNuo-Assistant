import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 卡片延期申请库：持久化到服务器 data/card-extend-requests.txt
// 一条申请即一行 JSON，文件剥离 BOM；申请被处理（同意或拒绝）后即从申请库删除，不长期保留。
// 与「卡片加入申请」同构：申请定位到「卡片组内的一张卡片」（groupId + cardIndex），
// 由组内被指定「完成权限」的参与者发起，交给卡片组创建者（发起者）审批。
const FILE_PATH = path.join(config.dataDir, config.cardExtendRequestFile);

let cache = [];
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

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

async function ensureFile() {
  await fs.mkdir(config.dataDir, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, '', 'utf8');
  }
}

function normalizeEntry(parsed) {
  const id = Number(parsed?.id);
  const groupId = Number(parsed?.groupId);
  const cardIndex = Number(parsed?.cardIndex);
  const toAccount = accountName(parsed?.toAccount);
  const fromAccount = accountName(parsed?.fromAccount);
  if (!Number.isInteger(id) || id < 1 || !Number.isInteger(groupId) || !Number.isInteger(cardIndex)
    || toAccount === '' || fromAccount === '') {
    return null;
  }
  return {
    id,
    groupId,
    cardIndex,
    fromAccount,
    fromUserId: Number.isInteger(Number(parsed?.fromUserId)) ? Number(parsed.fromUserId) : null,
    toAccount,
    toUserId: Number.isInteger(Number(parsed?.toUserId)) ? Number(parsed.toUserId) : null,
    targetTime: textOf(parsed?.targetTime) || null,
    targetEndTime: textOf(parsed?.targetEndTime) || null,
    targetReminderTime: textOf(parsed?.targetReminderTime) || null,
    event: textOf(parsed?.event) || null,
    status: typeof parsed?.status === 'string' ? parsed.status : 'pending',
    createdAt: typeof parsed?.createdAt === 'string' ? parsed.createdAt : new Date().toISOString(),
    handledAt: typeof parsed?.handledAt === 'string' ? parsed.handledAt : null
  };
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
      const entry = normalizeEntry(JSON.parse(line));
      if (!entry) {
        continue;
      }
      cache.push(entry);
      if (entry.id >= nextId) {
        nextId = entry.id + 1;
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
  const text = cache.map(entry => JSON.stringify(entry)).join('\n');
  await fs.writeFile(FILE_PATH, text === '' ? '' : text + '\n', 'utf8');
}

function view(entry) {
  return { ...entry };
}

// 新建延期申请：同一申请人对同一张卡片已有未处理申请时直接返回该申请，不重复入库。
// targetTime / targetReminderTime 是提交时刻的快照，审批时按快照改期（不重新读申请者传参，避免篡改）。
// 返回 { request, created }：created=false 表示命中了已有申请（供调用方避免重复抄送收件箱）。
export function createExtendRequest({ groupId, cardIndex, fromAccount, fromUserId, toAccount, toUserId, targetTime, targetEndTime = null, targetReminderTime, event }) {
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
      fromUserId: Number.isInteger(fromUserId) ? fromUserId : null,
      toAccount,
      toUserId: Number.isInteger(toUserId) ? toUserId : null,
      targetTime,
      targetEndTime: targetEndTime ?? null,
      targetReminderTime: targetReminderTime ?? null,
      event: event ?? null,
      status: 'pending',
      createdAt: new Date().toISOString(),
      handledAt: null
    };
    cache.push(entry);
    await persist();
    return { request: view(entry), created: true };
  });
}

// 待办箱：别人向我（作为卡片组创建者）发来的、仍未处理的延期申请
export function listIncomingExtendRequests(account) {
  return serialized(async () => {
    await ensureLoaded();
    return cache
      .filter(entry => entry.toAccount === account && entry.status === 'pending')
      .map(view);
  });
}

export function getExtendRequest(id) {
  return serialized(async () => {
    await ensureLoaded();
    const entry = cache.find(item => item.id === id);
    return entry ? view(entry) : null;
  });
}

// 处理申请：校验「发给谁」与删除在同一个串行任务内完成，保证重复同意/拒绝只成功一次。
// 返回 { reason: null | 'not-found' | 'forbidden', request }，由调用方映射成 404 / 403。
export function consumeExtendRequest(id, toAccount) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(id)) {
      return { reason: 'not-found', request: null };
    }
    const index = cache.findIndex(item => item.id === id);
    if (index === -1) {
      return { reason: 'not-found', request: null };
    }
    const entry = cache[index];
    if (entry.toAccount !== accountName(toAccount)) {
      return { reason: 'forbidden', request: view(entry) };
    }
    const [removed] = cache.splice(index, 1);
    await persist();
    return { reason: null, request: view(removed) };
  });
}

// 组内某张卡片被删除或完成时，一并清掉该卡片上未处理的延期申请
export function removeExtendRequestsByGroupCard(groupId, cardIndex) {
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

// 卡片组被删除或转为私人时，一并清掉该组全部卡片上未处理的延期申请
export function removeExtendRequestsByGroup(groupId) {
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

// 注销账号时清除与该账号相关的全部延期申请（我发起的 / 发给我审批的）
export function removeExtendRequestsByAccount(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
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

// 改名级联：延期申请里申请方/审批方为该账号的字段同步更新
export function renameExtendRequestsByAccount(oldName, newName) {
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