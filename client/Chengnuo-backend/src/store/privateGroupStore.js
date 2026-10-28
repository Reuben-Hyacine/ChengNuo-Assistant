import { statSync } from 'node:fs';
import { dataFilePath, readJsonl, writeJsonl, serializedChain, renameInParticipants } from './jsonl.js';

// 私人卡片组及卡片的客户端副本（与服务器双端存储）：
// 登录/连接服务器时全量上送本副本（服务器按 updatedAt 合并，较新者胜），再用服务器返回的合并结果覆盖本副本。
// 断网时可直接手动编辑本文件（每行一个卡片组的 JSON），联网登录后即同步到服务器。
const FILE_PATH = dataFilePath('private-groups.txt');

let cache = [];
let loaded = false;
let stamp = null; // 文件 mtime 标记：识别「客户端运行期间被手动编辑」，保证手改内容能被上传
const run = serializedChain();

function accountName(account) {
  return typeof account === 'string' ? account.trim() : '';
}

function fileStamp() {
  try {
    return statSync(FILE_PATH).mtimeMs;
  } catch {
    return null;
  }
}

function normalizeGroup(parsed) {
  const account = accountName(parsed?.account);
  const name = typeof parsed?.name === 'string' ? parsed.name.trim() : '';
  if (account === '' || name === '') {
    return null;
  }
  const id = Number(parsed?.id);
  const cards = Array.isArray(parsed?.cards) ? parsed.cards : [];
  const now = new Date().toISOString();
  return {
    id: Number.isInteger(id) && id >= 1 ? id : null,
    account,
    name,
    library: 'private',
    member: typeof parsed?.member === 'string' ? parsed.member : null,
    cards,
    createdAt: typeof parsed?.createdAt === 'string' ? parsed.createdAt : now,
    updatedAt: typeof parsed?.updatedAt === 'string' ? parsed.updatedAt : now
  };
}

async function ensureLoaded() {
  const current = fileStamp();
  if (loaded && current === stamp) {
    return;
  }
  const records = await readJsonl(FILE_PATH);
  cache = records.map(normalizeGroup).filter(g => g !== null);
  loaded = true;
  stamp = fileStamp();
}

async function persist() {
  await writeJsonl(FILE_PATH, cache);
  stamp = fileStamp();
}

// 某账号的私人卡片组副本（完整内部结构，含组内卡片）
export function listForAccount(account) {
  return run(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      return [];
    }
    return cache.filter(g => g.account === name).map(g => ({ ...g }));
  });
}

// 用服务器返回的私人卡片组覆盖本账号的副本（其他账号的记录保留）
export function replaceForAccount(account, groups) {
  return run(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      return { account: name, total: 0 };
    }
    const incoming = (Array.isArray(groups) ? groups : []).map(normalizeGroup).filter(g => g !== null && g.account === name);
    cache = cache.filter(g => g.account !== name).concat(incoming);
    await persist();
    return { account: name, total: incoming.length };
  });
}

// 删除某账号的一个私人卡片组副本（服务 38 双端删除、55 删组、50 转公开时由客户端同步调用）
export function removeForAccount(account, groupId) {
  return run(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const id = Number(groupId);
    if (name === '' || !Number.isInteger(id) || id < 1) {
      return { id: Number.isInteger(id) ? id : null, name: null, removedCards: 0, removed: false };
    }
    const hit = cache.find(g => g.account === name && g.id === id) ?? null;
    if (!hit) {
      return { id, name: null, removedCards: 0, removed: false };
    }
    cache = cache.filter(g => !(g.account === name && g.id === id));
    await persist();
    return { id, name: hit.name, removedCards: Array.isArray(hit.cards) ? hit.cards.length : 0, removed: true };
  });
}

// 删除某账号副本中一个私人卡片组内的一张卡（服务 57 转发成功后由客户端同步调用；副本无此组或此卡时空操作）。
// 不改副本的 updatedAt：让副本保持比服务器旧，63 合并时服务器版本（已删该卡）照旧胜出，不会反过来覆盖服务器
export function removeCardForAccount(account, groupId, cardIndex) {
  return run(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const gid = Number(groupId);
    const idx = Number(cardIndex);
    if (name === '' || !Number.isInteger(gid) || gid < 1 || !Number.isInteger(idx) || idx < 1) {
      return { groupId: gid, cardIndex: idx, removed: false };
    }
    const hit = cache.find(g => g.account === name && g.id === gid) ?? null;
    if (!hit || !Array.isArray(hit.cards)) {
      return { groupId: gid, cardIndex: idx, removed: false };
    }
    const before = hit.cards.length;
    hit.cards = hit.cards.filter(c => Number(c?.index) !== idx);
    const removed = hit.cards.length < before;
    if (removed) {
      await persist();
    }
    return { groupId: gid, cardIndex: idx, removed };
  });
}

// 注销账号：清除该账号的私人卡片组副本
export function clearByAccount(account) {
  return run(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      return { removed: 0 };
    }
    const before = cache.length;
    cache = cache.filter(g => g.account !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名（82）：副本的账号、成员表与卡内发起人/参与人/完成权限同步换名（与服务器 renameGroupsAccountOf 同构）；
// 不改 updatedAt：本地与服务器各自改好后内容一致，63 合并互不覆盖
export function renameAccountOf(account, newAccount) {
  return run(async () => {
    await ensureLoaded();
    const oldName = accountName(account);
    const newName = accountName(newAccount);
    if (oldName === '' || newName === '' || oldName === newName) {
      return { changed: 0 };
    }
    let changed = 0;
    for (const g of cache) {
      let touched = false;
      if (g.account === oldName) {
        g.account = newName;
        touched = true;
      }
      const member = renameInParticipants(g.member, oldName, newName);
      if (member !== null) {
        g.member = member;
        touched = true;
      }
      if (Array.isArray(g.cards)) {
        for (const card of g.cards) {
          if (!card || typeof card !== 'object') {
            continue;
          }
          if (card.content && typeof card.content === 'object') {
            if (card.content.initiator === oldName) {
              card.content.initiator = newName;
              touched = true;
            }
            const participant = renameInParticipants(card.content.participant, oldName, newName);
            if (participant !== null) {
              card.content.participant = participant;
              touched = true;
            }
          }
          if (card.completableBy === oldName) {
            card.completableBy = newName;
            touched = true;
          }
          if (card.completedBy === oldName) {
            card.completedBy = newName;
            touched = true;
          }
        }
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