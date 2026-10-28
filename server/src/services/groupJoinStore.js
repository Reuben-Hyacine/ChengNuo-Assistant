import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 组加入申请库（二期「组加入审核」）：卡片组开启「审核加入」后，他人加入整组须先向创建者提交申请。
// 持久化到服务器 data/group-join-requests.txt，一条申请即一行 JSON，文件剥离 BOM；
// 申请被处理（同意或拒绝）或撤回后即从申请库删除，不长期保留。
const FILE_PATH = path.join(config.dataDir, config.groupJoinRequestFile);

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
          && typeof parsed.fromAccount === 'string' && typeof parsed.toAccount === 'string') {
          cache.push({
            id: parsed.id,
            groupId: parsed.groupId,
            groupName: typeof parsed.groupName === 'string' ? parsed.groupName : '',
            fromAccount: parsed.fromAccount,
            fromUserId: Number.isInteger(parsed.fromUserId) ? parsed.fromUserId : null,
            toAccount: parsed.toAccount,
            toUserId: Number.isInteger(parsed.toUserId) ? parsed.toUserId : null,
            statement: typeof parsed.statement === 'string' ? parsed.statement : '',
            status: parsed.status === 'pending' ? 'pending' : 'pending',
            createdAt: typeof parsed.createdAt === 'string' ? parsed.createdAt : new Date().toISOString(),
            handledAt: null
          });
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

// 新建组加入申请：申请定位到「整个卡片组」（groupId）。
// 同一申请人对同一卡片组已有未处理申请时直接返回该申请，不重复入库。
// 返回 { request, created }：created=false 表示命中了已有申请（供调用方避免重复投递收件箱）。
export function createGroupJoinRequest({ groupId, groupName, fromAccount, fromUserId, toAccount, toUserId, statement }) {
  return serialized(async () => {
    await ensureLoaded();
    const existing = cache.find(
      entry => entry.status === 'pending' && entry.groupId === groupId && entry.fromAccount === fromAccount
    );
    if (existing) {
      return { request: view(existing), created: false };
    }
    const entry = {
      id: nextId++,
      groupId,
      groupName,
      fromAccount,
      fromUserId,
      toAccount,
      toUserId,
      statement,
      status: 'pending',
      createdAt: new Date().toISOString(),
      handledAt: null
    };
    cache.push(entry);
    await persist();
    return { request: view(entry), created: true };
  });
}

// 收件箱：别人向我（作为卡片组创建者）发来的、仍未处理的入组申请
export function listIncomingGroupJoins(account) {
  return serialized(async () => {
    await ensureLoaded();
    return cache
      .filter(entry => entry.toAccount === account && entry.status === 'pending')
      .map(view);
  });
}

// 某卡片组的全部未处理入组申请（106 切换为「自由加入」时批量自动通过用）
export function listGroupJoinRequestsByGroup(groupId) {
  return serialized(async () => {
    await ensureLoaded();
    return cache
      .filter(entry => entry.groupId === groupId && entry.status === 'pending')
      .map(view);
  });
}

// 我发出的入组申请（公开卡片组库标记「已申请入组」用）
export function listOutgoingGroupJoins(account) {
  return serialized(async () => {
    await ensureLoaded();
    return cache.filter(entry => entry.fromAccount === account).map(view);
  });
}

export function getGroupJoinRequest(id) {
  return serialized(async () => {
    await ensureLoaded();
    const entry = cache.find(item => item.id === id);
    return entry ? view(entry) : null;
  });
}

// 处理申请后删除：同意、拒绝或撤回都把该申请从申请库移除，避免申请记录长期堆积
export function removeGroupJoinRequest(id) {
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

// 注销账号时清除与该账号相关的全部入组申请（申请加入他人卡片组 / 他人申请加入其卡片组）
export function removeGroupJoinRequestsByAccount(account) {
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

// 改名级联：组加入申请里申请方/审批方为该账号的字段同步更新
export function renameGroupJoinRequestsByAccount(oldName, newName) {
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

// 卡片组被删除或转为私人时，一并清掉该组的全部未处理入组申请
export function removeGroupJoinRequestsByGroup(groupId) {
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
