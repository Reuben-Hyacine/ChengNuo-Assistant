import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

const FILE_PATH = path.join(config.dataDir, config.conversationFile);

// 对话记录长期保存在服务器，但每个账号只保留最近十条（超出即丢弃最早的）
export const MAX_MESSAGES_PER_USER = 10;

let records = [];
let nextId = 1;
let loaded = false;
let chain = Promise.resolve();

function serialized(task) {
  const run = chain.then(task, task);
  chain = run.then(() => {}, () => {});
  return run;
}

async function ensureFile() {
  await fs.mkdir(config.dataDir, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, '', 'utf8');
  }
}

function stripBom(text) {
  return text && text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

async function load() {
  await ensureFile();
  const text = stripBom(await fs.readFile(FILE_PATH, 'utf8'));
  records = text.split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .map(line => JSON.parse(line));
  nextId = records.reduce((max, rec) => Math.max(max, rec.id), 0) + 1;
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

async function persist() {
  const text = records.map(rec => JSON.stringify(rec)).join('\n');
  await fs.writeFile(FILE_PATH, text === '' ? '' : text + '\n', 'utf8');
}

// 只保留每个账号最近的 MAX_MESSAGES_PER_USER 条，过期的最早记录直接丢弃
function trimByUser(userId) {
  if (!Number.isInteger(userId) || userId < 1) {
    return 0;
  }
  const mine = records.filter(r => r.userId === userId);
  if (mine.length <= MAX_MESSAGES_PER_USER) {
    return 0;
  }
  const keep = new Set(mine.slice(-MAX_MESSAGES_PER_USER).map(r => r.id));
  const before = records.length;
  records = records.filter(r => r.userId !== userId || keep.has(r.id));
  return before - records.length;
}

// 返回某账号的对话流水，按时间顺序（旧 -> 新），最多最近十条
export function listMessages() {
  return serialized(async () => {
    await ensureLoaded();
    return [...records].reverse().map(rec => ({ ...rec }));
  });
}

export function getMessage(id) {
  return serialized(async () => {
    await ensureLoaded();
    const rec = records.find(r => r.id === id);
    return rec ? { ...rec } : null;
  });
}

export function addMessage({ peer = null, userId = null, direction = 'out', content = null } = {}) {
  return serialized(async () => {
    await ensureLoaded();
    const dir = (direction === 'in' || direction === 'out') ? direction : 'out';
    const uid = (Number.isInteger(userId) && userId >= 1) ? userId : null;
    const rec = {
      id: nextId++,
      peer: peer ?? null,
      userId: uid,
      direction: dir,
      time: new Date().toISOString(),
      content: content
    };
    records.push(rec);
    trimByUser(uid);
    await persist();
    return { ...rec };
  });
}

// 按 userId 查询某账号的对话记录：只返回最近十条（旧 -> 新）
export function getByUser(userId) {
  return serialized(async () => {
    await ensureLoaded();
    const mine = records.filter(r => r.userId === userId);
    return mine.slice(-MAX_MESSAGES_PER_USER).map(r => ({ ...r }));
  });
}

// 清空某用户的对话记录
export function clearByUser(userId) {
  return serialized(async () => {
    await ensureLoaded();
    const removed = records.filter(r => r.userId === userId);
    records = records.filter(r => r.userId !== userId);
    await persist();
    return removed.map(r => ({ ...r }));
  });
}

// 一键清空全部对话记录
export function clearAllConversations() {
  return serialized(async () => {
    await ensureLoaded();
    records = [];
    nextId = 1;
    await persist();
    return [];
  });
}

// 汇总每个对端最近一次交互
export function listPeers() {
  return serialized(async () => {
    await ensureLoaded();
    const latest = new Map();
    for (const rec of records) {
      if (rec.peer == null) {
        continue;
      }
      if (!latest.has(rec.peer) || latest.get(rec.peer).time < rec.time) {
        latest.set(rec.peer, { ...rec });
      }
    }
    return [...latest.values()];
  });
}