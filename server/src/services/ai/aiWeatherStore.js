import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../../config.js';

// AI 对话天气存储（data/ai-weather.json）：
// - client：客户端记日程时随 ai.ask 上送的本地天气（默认天气，region + text 一句话摘要）
// - captured：对话中捕获的省市天气（服务器经和风天气拉取，30 分钟内复用）
// 卡片「确定」或「重置」时两者一并清空（clearAiWeather）；客户端下次 ai.ask 会重新上送默认天气。

const FILE_PATH = path.join(config.dataDir, 'ai-weather.json');

let cache = { client: null, captured: null };
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
    await fs.writeFile(FILE_PATH, JSON.stringify({ client: null, captured: null }), 'utf8');
  }
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

function validClient(entry) {
  if (!entry || typeof entry !== 'object') {
    return null;
  }
  const region = typeof entry.region === 'string' ? entry.region.trim() : '';
  const text = typeof entry.text === 'string' ? entry.text.trim() : '';
  if (region === '' || text === '') {
    return null;
  }
  return { region, text, sentAt: typeof entry.sentAt === 'string' ? entry.sentAt : '' };
}

function validCaptured(entry) {
  if (!entry || typeof entry !== 'object') {
    return null;
  }
  const region = typeof entry.region === 'string' ? entry.region.trim() : '';
  const text = typeof entry.text === 'string' ? entry.text.trim() : '';
  if (region === '' || text === '') {
    return null;
  }
  return {
    region,
    query: typeof entry.query === 'string' ? entry.query : region,
    detail: typeof entry.detail === 'string' ? entry.detail : '',
    text,
    locationId: typeof entry.locationId === 'string' ? entry.locationId : null,
    fetchedAt: typeof entry.fetchedAt === 'string' ? entry.fetchedAt : ''
  };
}

async function load() {
  await ensureFile();
  try {
    const data = JSON.parse(stripBom(await fs.readFile(FILE_PATH, 'utf8')));
    cache = {
      client: validClient(data.client),
      captured: validCaptured(data.captured)
    };
  } catch {
    cache = { client: null, captured: null };
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

export function getClientWeather() {
  return serialized(async () => {
    await ensureLoaded();
    return cache.client ? { ...cache.client } : null;
  });
}

export function setClientWeather(entry) {
  const valid = validClient(entry);
  if (!valid) {
    return null;
  }
  return serialized(async () => {
    await ensureLoaded();
    cache.client = { region: valid.region, text: valid.text, sentAt: new Date().toISOString() };
    await persist();
    return { ...cache.client };
  });
}

export function getCapturedWeather() {
  return serialized(async () => {
    await ensureLoaded();
    return cache.captured ? { ...cache.captured } : null;
  });
}

export function setCapturedWeather(entry) {
  const valid = validCaptured(entry);
  if (!valid) {
    return null;
  }
  return serialized(async () => {
    await ensureLoaded();
    cache.captured = {
      region: valid.region,
      query: valid.query,
      detail: valid.detail,
      text: valid.text,
      locationId: valid.locationId,
      fetchedAt: new Date().toISOString()
    };
    await persist();
    return { ...cache.captured };
  });
}

// 清空服务器存储的天气（客户端默认 + 捕获地区）：卡片确定/重置时调用
export function clearAiWeather() {
  return serialized(async () => {
    await ensureLoaded();
    cache = { client: null, captured: null };
    await persist();
    return { client: null, captured: null };
  });
}
