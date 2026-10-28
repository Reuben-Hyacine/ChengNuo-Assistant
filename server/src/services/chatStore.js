import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';
import { parseParticipants, formatParticipants } from './cardStore.js';

// 好友聊天库：两个好友账号之间的站内聊天消息（文字 / 卡片邀请），只存服务器，客户端不落盘。
// 与收件箱一致：超过保留期的消息在每次写入时顺手清理；每对账号只保留最近 MAX_PER_PAIR 条，避免文件无限增长。
const FILE_PATH = path.join(config.dataDir, config.chatFile);

const RETAIN_DAYS = 30;
const MAX_PER_PAIR = 200;

let cache = []; // [{id, fromAccount, toAccount, kind:'text'|'card'|'group', text, cardIndex, card, groupId, group, createdAt, readAt, acceptedAt}]
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

function normalizeMessage(parsed) {
  const id = Number(parsed.id);
  const fromAccount = accountName(parsed.fromAccount);
  const toAccount = accountName(parsed.toAccount);
  const createdAt = Number(parsed.createdAt);
  if (!Number.isInteger(id) || id < 1 || fromAccount === '' || toAccount === '' || !Number.isFinite(createdAt)) {
    return null;
  }
  const readAt = Number(parsed.readAt);
  const acceptedAt = Number(parsed.acceptedAt);
  const cardIndex = Number(parsed.cardIndex);
  const groupId = Number(parsed.groupId);
  return {
    id,
    fromAccount,
    toAccount,
    kind: parsed.kind === 'card' ? 'card' : (parsed.kind === 'group' ? 'group' : 'text'),
    text: textOf(parsed.text, 2000),
    cardIndex: Number.isInteger(cardIndex) && cardIndex >= 1 ? cardIndex : null,
    card: (parsed.card && typeof parsed.card === 'object' && !Array.isArray(parsed.card)) ? parsed.card : null,
    groupId: Number.isInteger(groupId) && groupId >= 1 ? groupId : null,
    group: (parsed.group && typeof parsed.group === 'object' && !Array.isArray(parsed.group)) ? parsed.group : null,
    createdAt,
    readAt: Number.isFinite(readAt) && readAt > 0 ? readAt : null,
    acceptedAt: Number.isFinite(acceptedAt) && acceptedAt > 0 ? acceptedAt : null
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
      const msg = normalizeMessage(JSON.parse(line));
      if (!msg) {
        continue;
      }
      cache.push(msg);
      if (msg.id >= nextId) {
        nextId = msg.id + 1;
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

function pairKeyOf(msg) {
  return [msg.fromAccount, msg.toAccount].sort().join('\n');
}

async function persist() {
  const cutoff = Date.now() - RETAIN_DAYS * 24 * 3600 * 1000;
  cache = cache.filter(m => m.createdAt >= cutoff);
  // 每对账号只保留最近 MAX_PER_PAIR 条
  const buckets = new Map();
  for (const m of cache) {
    const key = pairKeyOf(m);
    if (!buckets.has(key)) {
      buckets.set(key, []);
    }
    buckets.get(key).push(m);
  }
  const kept = [];
  for (const list of buckets.values()) {
    list.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id);
    kept.push(...(list.length > MAX_PER_PAIR ? list.slice(list.length - MAX_PER_PAIR) : list));
  }
  kept.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id);
  cache = kept;
  const lines = cache.map(m => JSON.stringify(m));
  await fs.writeFile(FILE_PATH, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

function view(msg) {
  return { ...msg };
}

function summaryOf(msg) {
  if (!msg) {
    return null;
  }
  if (msg.kind === 'card') {
    const c = msg.card || {};
    return `[卡片] ${c.purpose || '-'} / ${c.event || '-'} / ${c.time || '-'}`;
  }
  if (msg.kind === 'group') {
    const g = msg.group || {};
    return `[卡片组] ${g.name || '-'}（${g.cardCount ?? 0} 张卡片）`;
  }
  return msg.text;
}

// 写入一条消息（文字 / 卡片邀请 / 卡片组邀请），同时完成保留期与条数上限清理
export function pushMessage({ fromAccount, toAccount, kind, text = '', cardIndex = null, card = null, groupId = null, group = null }) {
  return serialized(async () => {
    await ensureLoaded();
    const from = accountName(fromAccount);
    const to = accountName(toAccount);
    if (from === '' || to === '') {
      return null;
    }
    const msg = {
      id: nextId++,
      fromAccount: from,
      toAccount: to,
      kind: kind === 'card' ? 'card' : (kind === 'group' ? 'group' : 'text'),
      text: textOf(text, 2000),
      cardIndex,
      card: card && typeof card === 'object' && !Array.isArray(card) ? card : null,
      groupId,
      group: group && typeof group === 'object' && !Array.isArray(group) ? group : null,
      createdAt: Date.now(),
      readAt: null,
      acceptedAt: null
    };
    cache.push(msg);
    await persist();
    return view(msg);
  });
}

// 两个账号之间的全部消息（按时间正序），并把我收到的未读消息标记为已读
export function listMessagesBetween(account, peer) {
  return serialized(async () => {
    await ensureLoaded();
    const me = accountName(account);
    const other = accountName(peer);
    if (me === '' || other === '') {
      return [];
    }
    const now = Date.now();
    let marked = 0;
    for (const m of cache) {
      const between = (m.fromAccount === me && m.toAccount === other) || (m.fromAccount === other && m.toAccount === me);
      if (!between) {
        continue;
      }
      if (m.toAccount === me && m.readAt === null) {
        m.readAt = now;
        marked += 1;
      }
    }
    if (marked > 0) {
      await persist();
    }
    return cache
      .filter(m => (m.fromAccount === me && m.toAccount === other) || (m.fromAccount === other && m.toAccount === me))
      .sort((a, b) => a.createdAt - b.createdAt || a.id - b.id)
      .map(view);
  });
}

// 某账号的会话总览：按对方账号聚合，附最后一条消息与未读数（按最后消息时间倒序）
export function listConversationsOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const me = accountName(account);
    const byPeer = new Map();
    for (const m of cache) {
      if (m.fromAccount !== me && m.toAccount !== me) {
        continue;
      }
      const peer = m.fromAccount === me ? m.toAccount : m.fromAccount;
      if (!byPeer.has(peer)) {
        byPeer.set(peer, { peer, last: null, unread: 0, total: 0 });
      }
      const conv = byPeer.get(peer);
      conv.total += 1;
      if (m.toAccount === me && m.readAt === null) {
        conv.unread += 1;
      }
      if (!conv.last || m.createdAt > conv.last.createdAt || (m.createdAt === conv.last.createdAt && m.id > conv.last.id)) {
        conv.last = m;
      }
    }
    return [...byPeer.values()]
      .sort((a, b) => b.last.createdAt - a.last.createdAt || b.last.id - a.last.id)
      .map(conv => ({
        peer: conv.peer,
        unread: conv.unread,
        total: conv.total,
        lastAt: conv.last.createdAt,
        lastFromMe: conv.last.fromAccount === me,
        lastKind: conv.last.kind,
        lastSummary: summaryOf(conv.last)
      }));
  });
}

// 取一条消息（供「接受卡片邀请」校验）
export function getMessage(id) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(id)) {
      return null;
    }
    const msg = cache.find(m => m.id === id) ?? null;
    return msg ? view(msg) : null;
  });
}

// 标记一条卡片邀请消息已被接受（记录接受时间，重复接受时返回 null）
export function markMessageAccepted(id) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(id)) {
      return null;
    }
    const msg = cache.find(m => m.id === id);
    if (!msg || msg.acceptedAt !== null) {
      return null;
    }
    msg.acceptedAt = Date.now();
    await persist();
    return view(msg);
  });
}

// 拉取中转发给某账号的消息：拉取即从服务器删除（服务器只做短期中转、送达即删）。
// 好友对话的长期保存由客户端负责，本库仅作为消息投递的临时队列。
export function takeMessagesFor(account) {
  return serialized(async () => {
    await ensureLoaded();
    const me = accountName(account);
    if (me === '') {
      return { messages: [] };
    }
    const mine = cache.filter(m => m.toAccount === me);
    if (mine.length === 0) {
      return { messages: [] };
    }
    cache = cache.filter(m => m.toAccount !== me);
    await persist();
    return {
      messages: mine.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id).map(view)
    };
  });
}

// 注销账号时清空其全部聊天记录
export function clearChatsOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    const before = cache.length;
    cache = cache.filter(m => m.fromAccount !== name && m.toAccount !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名级联：聊天消息的收发双方与嵌套卡片/卡片组快照里的账号字段同步更新
export function renameChatsOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const m of cache) {
      let touched = false;
      if (m.fromAccount === oldName) {
        m.fromAccount = newName;
        touched = true;
      }
      if (m.toAccount === oldName) {
        m.toAccount = newName;
        touched = true;
      }
      if (m.card && typeof m.card === 'object' && !Array.isArray(m.card)) {
        if (m.card.initiator === oldName) {
          m.card.initiator = newName;
          touched = true;
        }
        const participants = parseParticipants(m.card.participant);
        if (participants.includes(oldName)) {
          m.card.participant = formatParticipants(participants.map(p => p === oldName ? newName : p));
          touched = true;
        }
      }
      if (m.group && typeof m.group === 'object' && !Array.isArray(m.group) && m.group.owner === oldName) {
        m.group.owner = newName;
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
