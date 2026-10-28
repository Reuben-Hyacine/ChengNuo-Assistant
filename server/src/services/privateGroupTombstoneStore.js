import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 私人卡片组删除墓碑：整组删除（55 / 38）或整组转公开（50）时记下 {account, id, name, deletedAt}。
// 私人组在服务器与客户端双端存储，但客户端副本不随服务器删除而更新——登录同步（63）上送的
// 旧副本会请求「重建」服务器上已删除的组（原实现直接新建，删除的内容就此复活）。
// 合并时用墓碑识别陈旧副本：副本的 updatedAt 不晚于删除时间，说明它只是删除前的快照，拒绝复活；
// 副本比删除时间新则视为删除后有意的离线重建，放行。
// 墓碑仅保留最近 90 天；同账号同 id / 同名的旧墓碑由新墓碑替换，防止无限增长。
const FILE_PATH = path.join(config.dataDir, config.privateGroupTombstoneFile);
const MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000;

let cache = [];
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

function normalizeTombstone(parsed) {
  const account = accountName(parsed?.account);
  const id = Number(parsed?.id);
  const name = typeof parsed?.name === 'string' ? parsed.name.trim() : '';
  const deletedAt = typeof parsed?.deletedAt === 'string' && parsed.deletedAt !== '' ? parsed.deletedAt : null;
  const validId = Number.isInteger(id) && id >= 1 ? id : null;
  if (account === '' || deletedAt === null || (name === '' && validId === null)) {
    return null;
  }
  return { account, id: validId, name, deletedAt };
}

function pruneExpired(now) {
  const horizon = new Date(now - MAX_AGE_MS).toISOString();
  cache = cache.filter(t => t.deletedAt >= horizon);
}

async function ensureFile() {
  await fs.mkdir(config.dataDir, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, '', 'utf8');
  }
}

async function ensureLoaded() {
  if (loaded) {
    return;
  }
  await ensureFile();
  const text = stripBom(await fs.readFile(FILE_PATH, 'utf8'));
  cache = text.split(/\r?\n/).map(line => line.trim()).filter(line => line !== '')
    .map(line => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .map(normalizeTombstone)
    .filter(t => t !== null);
  pruneExpired(Date.now());
  loaded = true;
}

async function persist() {
  const lines = cache.map(t => JSON.stringify(t));
  await fs.writeFile(FILE_PATH, lines.length > 0 ? `${lines.join('\n')}\n` : '', 'utf8');
}

// 记一条删除墓碑：同账号同 id / 同名的旧墓碑被替换（新删除时间更晚，语义覆盖旧的）
export function recordTombstone({ account = null, id = null, name = '' } = {}) {
  return serialized(async () => {
    await ensureLoaded();
    const entry = normalizeTombstone({ account, id, name, deletedAt: new Date().toISOString() });
    if (entry === null) {
      return;
    }
    cache = cache.filter(t => {
      if (t.account !== entry.account) {
        return true;
      }
      const sameId = entry.id !== null && t.id === entry.id;
      const sameName = entry.name !== '' && t.name === entry.name;
      return !(sameId || sameName);
    });
    cache.push(entry);
    pruneExpired(Date.now());
    await persist();
  });
}

// 上送副本是否为「已删除 / 已转公开的组的陈旧快照」：
// 存在同账号、删除时间不早于副本 updatedAt 的墓碑（id 相同或同名）即命中。
// 客户端应在删除/转公开时同步清理副本，此处是第二道防线（覆盖绕过客户端的删除、副本清理失败等情形）
export async function isStaleDeletedCopy(account, { id = null, name = '', updatedAt = '' } = {}) {
  await ensureLoaded();
  const owner = accountName(account);
  if (owner === '') {
    return false;
  }
  const copyId = Number(id);
  const copyName = typeof name === 'string' ? name.trim() : '';
  const copyUpdatedAt = typeof updatedAt === 'string' ? updatedAt : '';
  for (const t of cache) {
    if (t.account !== owner) {
      continue;
    }
    if (copyUpdatedAt !== '' && t.deletedAt < copyUpdatedAt) {
      continue; // 副本比删除时间新：删除后有意的离线重建，放行
    }
    const idHit = t.id !== null && Number.isInteger(copyId) && copyId >= 1 && t.id === copyId;
    const nameHit = t.name !== '' && copyName !== '' && t.name === copyName;
    if (idHit || nameHit) {
      return true;
    }
  }
  return false;
}

// 改名级联：墓碑按账号名归属，改名时同步迁移（防止旧名副本在改名后绕过陈旧判定复活）
export function renameTombstonesOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const t of cache) {
      if (t.account === oldName) {
        t.account = newName;
        changed += 1;
      }
    }
    if (changed > 0) {
      await persist();
    }
    return { changed };
  });
}
