import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 通知通道（新建）：延期申请被同意/拒绝后，服务器除投递到申请者的「收件箱」外，
// 还在本通道留一条通知，申请者登录后经服务 71/72/73 查看、标记已读与删除。
// 通知只存服务器，客户端不落盘；与收件箱、提醒台账一致，超过保留期的记录在写入时顺手清理。
const FILE_PATH = path.join(config.dataDir, config.noticeFile);

// 通知保留天数（与收件箱/提醒台账一致）
const RETAIN_DAYS = 30;

let cache = []; // [{id, toAccount, fromAccount, kind, groupId, cardIndex, event, title, body, createdAt, readAt}]
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

function normalizeNotice(parsed) {
  const id = Number(parsed.id);
  const toAccount = accountName(parsed.toAccount);
  const createdAt = Number(parsed.createdAt);
  if (!Number.isInteger(id) || id < 1 || toAccount === '' || !Number.isFinite(createdAt)) {
    return null;
  }
  const readAt = Number(parsed.readAt);
  const groupId = Number(parsed.groupId);
  const cardIndex = Number(parsed.cardIndex);
  return {
    id,
    toAccount,
    fromAccount: accountName(parsed.fromAccount),
    kind: textOf(parsed.kind, 40) || null,
    groupId: Number.isInteger(groupId) ? groupId : null,
    cardIndex: Number.isInteger(cardIndex) ? cardIndex : null,
    event: textOf(parsed.event, 200) || null,
    title: textOf(parsed.title, 120),
    body: textOf(parsed.body, 2000),
    createdAt,
    readAt: Number.isFinite(readAt) && readAt > 0 ? readAt : null
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
      const notice = normalizeNotice(JSON.parse(line));
      if (!notice) {
        continue;
      }
      cache.push(notice);
      if (notice.id >= nextId) {
        nextId = notice.id + 1;
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
  cache = cache.filter(n => n.createdAt >= cutoff);
  const lines = cache.map(n => JSON.stringify(n));
  await fs.writeFile(FILE_PATH, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

function view(notice) {
  return { ...notice };
}

// 推送一条通知到某账号的通知通道
export function pushNotice({ toAccount, fromAccount, kind, groupId = null, cardIndex = null, event = null, title, body }) {
  return serialized(async () => {
    await ensureLoaded();
    const to = accountName(toAccount);
    if (to === '') {
      return null;
    }
    const notice = {
      id: nextId++,
      toAccount: to,
      fromAccount: accountName(fromAccount),
      kind: textOf(kind, 40) || null,
      groupId: Number.isInteger(groupId) ? groupId : null,
      cardIndex: Number.isInteger(cardIndex) ? cardIndex : null,
      event: textOf(event, 200) || null,
      title: textOf(title, 120),
      body: textOf(body, 2000),
      createdAt: Date.now(),
      readAt: null
    };
    cache.push(notice);
    await persist();
    return view(notice);
  });
}

// 某账号的全部通知（最新的在前），附带未读数
export function listNoticesOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const notices = cache
      .filter(n => n.toAccount === name)
      .sort((a, b) => b.createdAt - a.createdAt || b.id - a.id)
      .map(view);
    const unread = notices.filter(n => n.readAt === null).length;
    return { account: name, unread, total: notices.length, notices };
  });
}

// 标记已读：id 为空或 all=true 时全部标记
export function markNoticeRead(account, id, all = false) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const now = Date.now();
    let marked = 0;
    for (const n of cache) {
      if (n.toAccount !== name || n.readAt !== null) {
        continue;
      }
      if (all === true || !Number.isInteger(id) || n.id === id) {
        n.readAt = now;
        marked += 1;
      }
    }
    if (marked > 0) {
      await persist();
    }
    return { marked };
  });
}

// 删除通知：id 为空或 all=true 时清空该账号的通知通道
export function removeNotice(account, id, all = false) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const before = cache.length;
    if (all === true || !Number.isInteger(id)) {
      cache = cache.filter(n => n.toAccount !== name);
    } else {
      cache = cache.filter(n => !(n.toAccount === name && n.id === id));
    }
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 注销账号时清空其通知通道
export function clearNoticesOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const before = cache.length;
    cache = cache.filter(n => n.toAccount !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名级联：通知通道里收件人/发件人为该账号的字段同步更新
export function renameNoticesOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const n of cache) {
      let touched = false;
      if (n.toAccount === oldName) {
        n.toAccount = newName;
        touched = true;
      }
      if (n.fromAccount === oldName) {
        n.fromAccount = newName;
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