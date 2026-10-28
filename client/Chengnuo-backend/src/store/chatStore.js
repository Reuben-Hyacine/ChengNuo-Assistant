import { dataFilePath, readJsonl, writeJsonl, serializedChain, renameInParticipants } from './jsonl.js';

// 好友对话（客户端长期保存完整聊天）：服务器只做「短期中转、送达即删」，
// 本库是消息的唯一长期存放处；对方经服务器中转发来的消息在拉取时合并进来（按内容去重）。
const FILE_PATH = dataFilePath('chats.txt');

let cache = []; // [{id, fromAccount, toAccount, kind, text, cardIndex, card, groupId, group, createdAt, readAt, acceptedAt}]
let nextId = 1;
let loaded = false;
const run = serializedChain();

function accountName(account) {
  return typeof account === 'string' ? account.trim() : '';
}

function textOf(value, max = 2000) {
  if (typeof value !== 'string') {
    return '';
  }
  const t = value.trim();
  return t.length > max ? t.slice(0, max) : t;
}

function objectOrNull(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
}

function normalizeKind(kind) {
  return kind === 'card' ? 'card' : (kind === 'group' ? 'group' : 'text');
}

function positiveIntOrNull(value) {
  const n = Number(value);
  return Number.isInteger(n) && n >= 1 ? n : null;
}

// 字段规范化（不校验编号）：编号为客户端本地编号，读取时校验、写入前统一分配
function normalize(parsed) {
  const fromAccount = accountName(parsed?.fromAccount);
  const toAccount = accountName(parsed?.toAccount);
  const createdAt = Number(parsed?.createdAt);
  if (fromAccount === '' || toAccount === '' || !Number.isFinite(createdAt) || createdAt <= 0) {
    return null;
  }
  const id = Number(parsed?.id);
  const readAt = Number(parsed?.readAt);
  const acceptedAt = Number(parsed?.acceptedAt);
  return {
    id: Number.isInteger(id) && id >= 1 ? id : null,
    fromAccount,
    toAccount,
    kind: normalizeKind(parsed?.kind),
    text: textOf(parsed?.text),
    cardIndex: positiveIntOrNull(parsed?.cardIndex),
    card: objectOrNull(parsed?.card),
    groupId: positiveIntOrNull(parsed?.groupId),
    group: objectOrNull(parsed?.group),
    createdAt,
    readAt: Number.isFinite(readAt) && readAt > 0 ? readAt : null,
    acceptedAt: Number.isFinite(acceptedAt) && acceptedAt > 0 ? acceptedAt : null
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
    const msg = normalize(raw);
    if (!msg || msg.id === null) {
      continue;
    }
    cache.push(msg);
    if (msg.id >= nextId) {
      nextId = msg.id + 1;
    }
  }
  loaded = true;
}

async function persist() {
  await writeJsonl(FILE_PATH, cache);
}

function view(msg) {
  return { ...msg };
}

// 内容指纹：中转消息不带可跨机器对齐的编号，合并时按「收发双方 + 时间 + 类型 + 内容」去重
function fingerprint(msg) {
  return [
    msg.fromAccount,
    msg.toAccount,
    msg.createdAt,
    msg.kind,
    msg.text,
    msg.cardIndex ?? '',
    msg.groupId ?? ''
  ].join('\u0001');
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

// 写入一条本地消息（自己发出的、经服务器校验后落地的消息，或合并进来的中转消息）
export function appendMessage(msg) {
  return run(async () => {
    await ensureLoaded();
    const normalized = normalize(msg);
    if (!normalized) {
      return null;
    }
    normalized.id = nextId++;
    cache.push(normalized);
    await persist();
    return view(normalized);
  });
}

// 合并服务器中转发来的消息：按内容指纹去重，编号由客户端本地重新分配
export function mergeIncoming(account, messages) {
  return run(async () => {
    await ensureLoaded();
    const me = accountName(account);
    if (me === '' || !Array.isArray(messages)) {
      return { added: 0, skipped: 0 };
    }
    const known = new Set(cache.map(fingerprint));
    let added = 0;
    let skipped = 0;
    for (const raw of messages) {
      const incoming = normalize(raw);
      if (!incoming || incoming.toAccount !== me) {
        skipped += 1;
        continue;
      }
      const key = fingerprint(incoming);
      if (known.has(key)) {
        skipped += 1;
        continue;
      }
      incoming.id = nextId++;
      cache.push(incoming);
      known.add(key);
      added += 1;
    }
    if (added > 0) {
      await persist();
    }
    return { added, skipped };
  });
}

// 与某好友的完整聊天记录（按时间正序），并把对方发来的未读标记为已读
export function listThread(account, peer) {
  return run(async () => {
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
      if (between && m.toAccount === me && m.readAt === null) {
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

// 会话总览：全部好友都在列（没聊过的也在），附最后一条消息摘要与未读数
export function listConversations(account, friends = []) {
  return run(async () => {
    await ensureLoaded();
    const me = accountName(account);
    if (me === '') {
      return { account: '', total: 0, unread: 0, conversations: [] };
    }
    const byPeer = new Map();
    for (const f of Array.isArray(friends) ? friends : []) {
      const name = accountName(f?.account);
      if (name === '') {
        continue;
      }
      byPeer.set(name, {
        peer: name,
        userId: Number.isInteger(f?.userId) ? f.userId : 0,
        unread: 0,
        total: 0,
        lastAt: null,
        lastId: 0,
        lastFromMe: null,
        lastKind: null,
        lastSummary: null
      });
    }
    for (const m of cache) {
      if (m.fromAccount !== me && m.toAccount !== me) {
        continue;
      }
      const peer = m.fromAccount === me ? m.toAccount : m.fromAccount;
      if (!byPeer.has(peer)) {
        byPeer.set(peer, { peer, userId: 0, unread: 0, total: 0, lastAt: null, lastId: 0, lastFromMe: null, lastKind: null, lastSummary: null });
      }
      const conv = byPeer.get(peer);
      conv.total += 1;
      if (m.toAccount === me && m.readAt === null) {
        conv.unread += 1;
      }
      if (conv.lastAt === null || m.createdAt > conv.lastAt || (m.createdAt === conv.lastAt && m.id > conv.lastId)) {
        conv.lastAt = m.createdAt;
        conv.lastId = m.id;
        conv.lastFromMe = m.fromAccount === me;
        conv.lastKind = m.kind;
        conv.lastSummary = summaryOf(m);
      }
    }
    const list = [...byPeer.values()]
      .sort((a, b) => (b.lastAt ?? 0) - (a.lastAt ?? 0) || a.peer.localeCompare(b.peer))
      .map(c => ({
        peer: c.peer,
        userId: c.userId,
        unread: c.unread,
        total: c.total,
        lastAt: c.lastAt ?? 0,
        lastFromMe: c.lastFromMe,
        lastKind: c.lastKind,
        lastSummary: c.lastSummary
      }));
    const unread = list.reduce((sum, c) => sum + c.unread, 0);
    return { account: me, total: list.length, unread, conversations: list };
  });
}

// 取一条本地消息（供「接受卡片/卡片组邀请」定位使用）
export function getMessage(account, id) {
  return run(async () => {
    await ensureLoaded();
    const me = accountName(account);
    if (me === '' || !Number.isInteger(id)) {
      return null;
    }
    const msg = cache.find(m => m.id === id && (m.fromAccount === me || m.toAccount === me)) ?? null;
    return msg ? view(msg) : null;
  });
}

// 标记一条邀请消息已被接受
export function markAccepted(account, id) {
  return run(async () => {
    await ensureLoaded();
    const me = accountName(account);
    if (me === '' || !Number.isInteger(id)) {
      return null;
    }
    const msg = cache.find(m => m.id === id && m.toAccount === me);
    if (!msg || msg.acceptedAt !== null) {
      return null;
    }
    msg.acceptedAt = Date.now();
    await persist();
    return view(msg);
  });
}

// 注销账号：清除该账号在本客户端的全部聊天记录
export function clearByAccount(account) {
  return run(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      return { removed: 0 };
    }
    const before = cache.length;
    cache = cache.filter(m => m.fromAccount !== name && m.toAccount !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名（82）：聊天收发双方与嵌套卡片/卡片组快照里的账号字段同步更新（与服务器 renameChatsOf 同构）
export function renameAccountOf(account, newAccount) {
  return run(async () => {
    await ensureLoaded();
    const oldName = accountName(account);
    const newName = accountName(newAccount);
    if (oldName === '' || newName === '' || oldName === newName) {
      return { changed: 0 };
    }
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
      if (m.card) {
        if (m.card.initiator === oldName) {
          m.card.initiator = newName;
          touched = true;
        }
        const participant = renameInParticipants(m.card.participant, oldName, newName);
        if (participant !== null) {
          m.card.participant = participant;
          touched = true;
        }
      }
      if (m.group && m.group.owner === oldName) {
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