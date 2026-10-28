import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';
import { parseParticipants, formatParticipants } from './cardStore.js';

// 卡片组群聊中转库：卡片组成员之间群聊消息（文字 / 卡片分享）的短期中转队列。
// 与好友聊天中转库（chatStore）同一约定：服务器只做「短期中转、送达即删」——
// 消息写入后等待各成员客户端拉取（拉取即从服务器删除），群聊记录的长期保存由各客户端自己负责。
// 一条逻辑消息向每个接收成员复制一份（fan-out），所有副本共用同一 id：发送者回执与接收者拉到的
// 消息 id 一致，客户端按 id 去重即可对齐。
// 超过保留期的消息在每次写入时顺手清理；每个「组 × 接收成员」只保留最近 MAX_PER_RECIPIENT 条。
const FILE_PATH = path.join(config.dataDir, config.groupChatFile);

const RETAIN_DAYS = 30;
const MAX_PER_RECIPIENT = 200;

let cache = []; // [{id, groupId, fromAccount, toAccount, kind:'text'|'card', text, cardIndex, cardGroupId, card, createdAt, acceptedAt}]
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
  const groupId = Number(parsed.groupId);
  const fromAccount = accountName(parsed.fromAccount);
  const toAccount = accountName(parsed.toAccount);
  const createdAt = Number(parsed.createdAt);
  if (!Number.isInteger(id) || id < 1 || !Number.isInteger(groupId) || groupId < 1 ||
    fromAccount === '' || toAccount === '' || !Number.isFinite(createdAt)) {
    return null;
  }
  const cardIndex = Number(parsed.cardIndex);
  const cardGroupId = Number(parsed.cardGroupId);
  const acceptedAt = Number(parsed.acceptedAt);
  return {
    id,
    groupId,
    fromAccount,
    toAccount,
    kind: parsed.kind === 'card' ? 'card' : 'text',
    text: textOf(parsed.text, 2000),
    cardIndex: Number.isInteger(cardIndex) && cardIndex >= 1 ? cardIndex : null,
    cardGroupId: Number.isInteger(cardGroupId) && cardGroupId >= 1 ? cardGroupId : null,
    card: (parsed.card && typeof parsed.card === 'object' && !Array.isArray(parsed.card)) ? parsed.card : null,
    createdAt,
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

async function persist() {
  const cutoff = Date.now() - RETAIN_DAYS * 24 * 3600 * 1000;
  cache = cache.filter(m => m.createdAt >= cutoff);
  // 每个「组 × 接收成员」只保留最近 MAX_PER_RECIPIENT 条
  const buckets = new Map();
  for (const m of cache) {
    const key = `${m.groupId}\n${m.toAccount}`;
    if (!buckets.has(key)) {
      buckets.set(key, []);
    }
    buckets.get(key).push(m);
  }
  const kept = [];
  for (const list of buckets.values()) {
    list.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id);
    kept.push(...(list.length > MAX_PER_RECIPIENT ? list.slice(list.length - MAX_PER_RECIPIENT) : list));
  }
  kept.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id);
  cache = kept;
  const lines = cache.map(m => JSON.stringify(m));
  await fs.writeFile(FILE_PATH, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

function view(msg) {
  return { ...msg };
}

/** 群消息核心（不含接收者）：发送者回执用 */
function coreView(msg) {
  return {
    id: msg.id,
    groupId: msg.groupId,
    fromAccount: msg.fromAccount,
    kind: msg.kind,
    text: msg.text,
    cardIndex: msg.cardIndex,
    cardGroupId: msg.cardGroupId,
    card: msg.card,
    createdAt: msg.createdAt,
    acceptedAt: msg.acceptedAt
  };
}

// 一条逻辑消息 fan-out 给全部接收成员：所有副本共用同一 id；返回消息核心供发送者回执。
// 接收列表为空（只有发送者自己在群里）也照样分配 id 落一份回执语义（不写中转）。
export function fanoutGroupMessage({ groupId, fromAccount, kind, text = '', cardIndex = null, cardGroupId = null, card = null }, toAccounts = []) {
  return serialized(async () => {
    await ensureLoaded();
    const from = accountName(fromAccount);
    const group = Number(groupId);
    if (from === '' || !Number.isInteger(group) || group < 1) {
      return null;
    }
    const id = nextId++;
    const createdAt = Date.now();
    for (const rawTo of toAccounts) {
      const to = accountName(rawTo);
      if (to === '' || to === from) {
        continue;
      }
      cache.push({
        id,
        groupId: group,
        fromAccount: from,
        toAccount: to,
        kind: kind === 'card' ? 'card' : 'text',
        text: textOf(text, 2000),
        cardIndex,
        cardGroupId,
        card: card && typeof card === 'object' && !Array.isArray(card) ? card : null,
        createdAt,
        acceptedAt: null
      });
    }
    await persist();
    return coreView({
      id,
      groupId: group,
      fromAccount: from,
      toAccount: '',
      kind: kind === 'card' ? 'card' : 'text',
      text: textOf(text, 2000),
      cardIndex,
      cardGroupId,
      card,
      createdAt,
      acceptedAt: null
    });
  });
}

// 拉取某成员在某群的中转消息：拉取即从服务器删除（送达即删，服务器不保存群聊记录）。
// 群聊记录的长期保存由各成员客户端负责。
export function takeGroupMessagesFor(account, groupId) {
  return serialized(async () => {
    await ensureLoaded();
    const me = accountName(account);
    const group = Number(groupId);
    if (me === '' || !Number.isInteger(group) || group < 1) {
      return { messages: [] };
    }
    const mine = cache.filter(m => m.toAccount === me && m.groupId === group);
    if (mine.length === 0) {
      return { messages: [] };
    }
    cache = cache.filter(m => !(m.toAccount === me && m.groupId === group));
    await persist();
    return {
      messages: mine.sort((a, b) => a.createdAt - b.createdAt || a.id - b.id).map(view)
    };
  });
}

// 注销账号时清空其在全部群聊中转箱里的消息
export function clearGroupChatsOf(account) {
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

// 改名级联：群聊中转消息的收发双方与嵌套卡片快照里的账号字段同步更新
export function renameGroupChatsOf(oldName, newName) {
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
