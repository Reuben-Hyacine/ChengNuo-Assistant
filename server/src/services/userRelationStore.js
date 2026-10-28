import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

const FILE_PATH = path.join(config.dataDir, config.userRelationFile);

export const MAX_USERS = 20;

let cache = new Map();
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

function emptyRelations() {
  const relations = new Map();
  for (let t = 1; t <= MAX_USERS; t++) {
    relations.set(t, null);
  }
  return relations;
}

async function persist() {
  const lines = [];
  for (let u = 1; u <= MAX_USERS; u++) {
    const relMap = cache.get(u) ?? emptyRelations();
    const relations = {};
    for (let t = 1; t <= MAX_USERS; t++) {
      relations[String(t)] = relMap.get(t) ?? null;
    }
    lines.push(JSON.stringify({ userId: u, relations }));
  }
  await fs.writeFile(FILE_PATH, lines.join('\n') + '\n', 'utf8');
}

async function load() {
  await ensureFile();
  const text = await fs.readFile(FILE_PATH, 'utf8');
  const lines = text.split(/\r?\n/).filter(line => line.trim() !== '');
  cache = new Map();
  for (const line of lines) {
    const parsed = JSON.parse(line);
    if (!Number.isInteger(parsed.userId) || parsed.userId < 1 || parsed.userId > MAX_USERS) {
      continue;
    }
    const relations = emptyRelations();
    const entries = parsed.relations ?? {};
    for (let t = 1; t <= MAX_USERS; t++) {
      const rel = entries[String(t)];
      if (rel !== null && rel !== undefined && typeof rel.content === 'string') {
        relations.set(t, { content: rel.content, updatedAt: rel.updatedAt ?? null });
      }
    }
    cache.set(parsed.userId, relations);
  }
  let dirty = lines.length !== MAX_USERS;
  for (let u = 1; u <= MAX_USERS; u++) {
    if (!cache.has(u)) {
      cache.set(u, emptyRelations());
      dirty = true;
    }
  }
  if (dirty) {
    await persist();
  }
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

function toRelationSlot(userId, targetId) {
  const rel = cache.get(userId)?.get(targetId) ?? null;
  return {
    userId,
    targetId,
    content: rel?.content ?? null,
    updatedAt: rel?.updatedAt ?? null
  };
}

function toUserSlots(userId) {
  const relations = [];
  for (let t = 1; t <= MAX_USERS; t++) {
    relations.push(toRelationSlot(userId, t));
  }
  return { userId, relations };
}

export function listAllUsers() {
  return serialized(async () => {
    await ensureLoaded();
    const users = [];
    for (let u = 1; u <= MAX_USERS; u++) {
      users.push(toUserSlots(u));
    }
    return users;
  });
}

export function getUserRelations(userId) {
  return serialized(async () => {
    await ensureLoaded();
    return toUserSlots(userId);
  });
}

export function getRelation(userId, targetId) {
  return serialized(async () => {
    await ensureLoaded();
    return toRelationSlot(userId, targetId);
  });
}

export function setRelation(userId, targetId, content) {
  return serialized(async () => {
    await ensureLoaded();
    const relations = cache.get(userId);
    relations.set(targetId, { content, updatedAt: new Date().toISOString() });
    await persist();
    return toRelationSlot(userId, targetId);
  });
}

// 注销账号时清空该 userId 的全部关系：既清掉它指向别人的槽位，也清掉别人指向它的槽位，
// 避免 userId 回收复用后新账号继承已注销账号的好友关系
export function clearAllRelationsOf(userId) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1 || userId > MAX_USERS) {
      return null;
    }
    let changed = 0;
    const own = cache.get(userId);
    if (own) {
      for (let t = 1; t <= MAX_USERS; t++) {
        if (own.get(t)) {
          own.set(t, null);
          changed += 1;
        }
      }
    }
    for (let u = 1; u <= MAX_USERS; u++) {
      if (u === userId) {
        continue;
      }
      const rels = cache.get(u);
      if (rels && rels.get(userId)) {
        rels.set(userId, null);
        changed += 1;
      }
    }
    if (changed > 0) {
      await persist();
    }
    return { userId, cleared: changed };
  });
}

export function clearRelation(userId, targetId) {
  return serialized(async () => {
    await ensureLoaded();
    const relations = cache.get(userId);
    const existing = relations.get(targetId);
    if (!existing) {
      return null;
    }
    relations.set(targetId, null);
    await persist();
    return { userId, targetId, content: existing.content, updatedAt: existing.updatedAt };
  });
}
