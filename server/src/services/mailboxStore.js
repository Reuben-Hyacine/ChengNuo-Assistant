import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 收件箱（站内邮件）：账号的日程提醒到点时，服务器在「弹窗提醒」之外把提醒邮件投递到该账号本人的收件箱，
// 用户登录客户端后经服务 42/43/44 查看、标记已读与删除。邮件只存服务器，客户端不落盘。
// 与提醒送达台账一致：超过保留期的邮件在每次写入时顺手清理，避免文件无限增长。
const FILE_PATH = path.join(config.dataDir, config.mailboxFile);

// 邮件保留天数（与提醒送达台账一致）
const RETAIN_DAYS = 30;

let cache = []; // [{id, toAccount, fromAccount, title, body, createdAt, readAt}]
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

function normalizeMail(parsed) {
  const id = Number(parsed.id);
  const toAccount = accountName(parsed.toAccount);
  const fromAccount = accountName(parsed.fromAccount);
  const createdAt = Number(parsed.createdAt);
  if (!Number.isInteger(id) || id < 1 || toAccount === '' || !Number.isFinite(createdAt)) {
    return null;
  }
  const readAt = Number(parsed.readAt);
  return {
    id,
    toAccount,
    fromAccount,
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
      const mail = normalizeMail(JSON.parse(line));
      if (!mail) {
        continue;
      }
      cache.push(mail);
      if (mail.id >= nextId) {
        nextId = mail.id + 1;
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
  cache = cache.filter(m => m.createdAt >= cutoff);
  const lines = cache.map(m => JSON.stringify(m));
  await fs.writeFile(FILE_PATH, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

function view(mail) {
  return { ...mail };
}

// 投递一封邮件（同一条提醒只投一次由调用方 reminderService 的送达台账保证）
export function pushMail({ toAccount, fromAccount, title, body }) {
  return serialized(async () => {
    await ensureLoaded();
    const to = accountName(toAccount);
    if (to === '') {
      return null;
    }
    const mail = {
      id: nextId++,
      toAccount: to,
      fromAccount: accountName(fromAccount),
      title: textOf(title, 120),
      body: textOf(body, 2000),
      createdAt: Date.now(),
      readAt: null
    };
    cache.push(mail);
    await persist();
    return view(mail);
  });
}

// 某账号的全部邮件（新邮件在前），附带未读数
export function listMailsOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const mails = cache
      .filter(m => m.toAccount === name)
      .sort((a, b) => b.createdAt - a.createdAt || b.id - a.id)
      .map(view);
    const unread = mails.filter(m => m.readAt === null).length;
    return { account: name, unread, total: mails.length, mails };
  });
}

// 标记已读：id 为空或 all=true 时全部标记
export function markMailRead(account, id, all = false) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const now = Date.now();
    let marked = 0;
    for (const m of cache) {
      if (m.toAccount !== name || m.readAt !== null) {
        continue;
      }
      if (all === true || !Number.isInteger(id) || m.id === id) {
        m.readAt = now;
        marked += 1;
      }
    }
    if (marked > 0) {
      await persist();
    }
    return { marked };
  });
}

// 删除邮件：id 为空或 all=true 时清空收件箱
export function removeMail(account, id, all = false) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const before = cache.length;
    if (all === true || !Number.isInteger(id)) {
      cache = cache.filter(m => m.toAccount !== name);
    } else {
      cache = cache.filter(m => !(m.toAccount === name && m.id === id));
    }
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 注销账号时清空其收件箱
export function clearMailboxOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const before = cache.length;
    cache = cache.filter(m => m.toAccount !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名级联：收件箱里收件人/发件人为该账号的字段同步更新
export function renameMailboxOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const m of cache) {
      let touched = false;
      if (m.toAccount === oldName) {
        m.toAccount = newName;
        touched = true;
      }
      if (m.fromAccount === oldName) {
        m.fromAccount = newName;
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
