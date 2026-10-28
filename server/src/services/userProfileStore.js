import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

const FILE_PATH = path.join(config.dataDir, config.userProfileFile);
export const MAX_USERS = 20;

let cache = [];
let loaded = false;
let chain = Promise.resolve();

function serialized(task) {
  const run = chain.then(task, task);
  chain = run.then(() => {}, () => {});
  return run;
}

function emptySlot(userId) {
  return { userId, profile: null };
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
  cache = [];
  for (let u = 1; u <= MAX_USERS; u++) {
    cache.push(emptySlot(u));
  }
  text.split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .forEach(line => {
      try {
        const parsed = JSON.parse(line);
        const userId = Number(parsed.userId);
        if (Number.isInteger(userId) && userId >= 1 && userId <= MAX_USERS) {
          const profile = parsed.profile && typeof parsed.profile === 'object' ? parsed.profile : null;
          cache[userId - 1] = { userId, profile };
        }
      } catch {
        // 跳过损坏行
      }
    });
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

async function persist() {
  const lines = cache
    .filter(s => s.profile !== null)
    .map(s => JSON.stringify(s));
  await fs.writeFile(FILE_PATH, (lines.length ? lines.join('\n') + '\n' : ''), 'utf8');
}

function view(slot) {
  return { userId: slot.userId, profile: slot.profile ? { ...slot.profile } : null };
}

export function listProfiles() {
  return serialized(async () => {
    await ensureLoaded();
    return cache.map(view);
  });
}

export function getProfile(userId) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1 || userId > MAX_USERS) {
      return null;
    }
    return view(cache[userId - 1]);
  });
}

export function setProfile(userId, profile) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1 || userId > MAX_USERS) {
      return null;
    }
    cache[userId - 1] = { userId, profile: profile ? { ...profile } : null };
    await persist();
    return view(cache[userId - 1]);
  });
}

// 把对话中发现的用户属性并入 profile.traits（去重、不覆盖已知信息）
export function appendUserTraits(userId, traits) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1 || userId > MAX_USERS) {
      return null;
    }
    const clean = (Array.isArray(traits) ? traits : [])
      .map(t => typeof t === 'string' ? t.trim() : (t && typeof t.content === 'string' ? t.content.trim() : ''))
      .filter(t => t !== '');
    if (clean.length === 0) {
      return view(cache[userId - 1]);
    }
    const slot = cache[userId - 1];
    const profile = slot.profile ? { ...slot.profile } : {};
    const existing = new Set(Array.isArray(profile.traits) ? profile.traits : []);
    const added = clean.filter(t => !existing.has(t));
    if (added.length === 0) {
      return view(slot);
    }
    profile.traits = [...existing, ...added];
    cache[userId - 1] = { userId, profile };
    await persist();
    return view(cache[userId - 1]);
  });
}

export function clearProfile(userId) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Number.isInteger(userId) || userId < 1 || userId > MAX_USERS) {
      return null;
    }
    const existing = view(cache[userId - 1]);
    cache[userId - 1] = emptySlot(userId);
    await persist();
    return existing;
  });
}

// 一键清空全部用户资料
export function clearAllProfiles() {
  return serialized(async () => {
    await ensureLoaded();
    cache = [];
    for (let u = 1; u <= MAX_USERS; u++) {
      cache.push(emptySlot(u));
    }
    await persist();
    return cache.map(view);
  });
}