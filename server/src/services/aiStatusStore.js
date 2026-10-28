import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

const FILE_PATH = path.join(config.dataDir, 'ai-status.json');

let cache = null;
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
    await fs.writeFile(FILE_PATH, JSON.stringify({ confirmed: false }), 'utf8');
  }
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

async function load() {
  await ensureFile();
  try {
    const data = JSON.parse(stripBom(await fs.readFile(FILE_PATH, 'utf8')));
    cache = { confirmed: data.confirmed === true, lastReply: typeof data.lastReply === 'string' ? data.lastReply : null };
  } catch {
    cache = { confirmed: false, lastReply: null };
  }
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

async function persist() {
  await fs.writeFile(FILE_PATH, JSON.stringify(cache), 'utf8');
}

export function getFlowState() {
  return serialized(async () => {
    await ensureLoaded();
    return { ...cache };
  });
}

export function setConfirmed(confirmed) {
  return serialized(async () => {
    await ensureLoaded();
    cache.confirmed = confirmed === true;
    await persist();
    return { ...cache };
  });
}

// 记录最近一次 AI 回复（供服务器控制台轮询回显，来源含服务器控制台与客户端经路由的调用）
export function setLastReply(replyText) {
  return serialized(async () => {
    await ensureLoaded();
    cache.lastReply = (typeof replyText === 'string' && replyText !== '') ? replyText : null;
    await persist();
    return { ...cache };
  });
}

export function clearLastReply() {
  return setLastReply(null);
}
