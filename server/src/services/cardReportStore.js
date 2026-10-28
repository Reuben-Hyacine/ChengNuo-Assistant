import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

// 公开卡片举报库：持久化到服务器 data/card-reports.txt，一条举报即一行 JSON。
// 举报定位到「公开卡片组内的一张卡片」（groupId + cardIndex），提交时快照卡片内容与创建者，
// 之后卡片被改/删/转私人不影响举报记录本身与后续处理（管理台另行标注目标实时状态）。
// 状态机：pending（待处理）→ dismissed（驳回）/ actioned（已处理）。
// 举报是历史记录：不随账号注销/改名、卡片组删除做级联清理；同一举报人对同一张卡片未处理的举报去重。
const FILE_PATH = path.join(config.dataDir, config.cardReportFile);

// 举报理由（App 与管理台共用同一套枚举）
export const REPORT_REASONS = ['illegal', 'porn', 'attack', 'spam', 'other'];
export const MAX_REPORT_DETAIL_LEN = 200;
const REPORT_STATUSES = ['pending', 'dismissed', 'actioned'];

let cache = [];
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

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

async function ensureFile() {
  await fs.mkdir(config.dataDir, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, '', 'utf8');
  }
}

function normalizeEntry(parsed) {
  const id = Number(parsed?.id);
  const groupId = Number(parsed?.groupId);
  const cardIndex = Number(parsed?.cardIndex);
  const ownerAccount = accountName(parsed?.ownerAccount);
  const reporterAccount = accountName(parsed?.reporterAccount);
  const reason = textOf(parsed?.reason);
  const status = textOf(parsed?.status);
  if (!Number.isInteger(id) || id < 1 || !Number.isInteger(groupId) || groupId < 1
    || !Number.isInteger(cardIndex) || cardIndex < 1
    || ownerAccount === '' || reporterAccount === ''
    || !REPORT_REASONS.includes(reason) || !REPORT_STATUSES.includes(status)) {
    return null;
  }
  return {
    id,
    groupId,
    cardIndex,
    groupName: textOf(parsed?.groupName),
    ownerAccount,
    cardEvent: textOf(parsed?.cardEvent),
    cardPurpose: textOf(parsed?.cardPurpose),
    cardLocation: textOf(parsed?.cardLocation),
    cardTime: textOf(parsed?.cardTime),
    reporterAccount,
    reporterUserId: Number.isInteger(Number(parsed?.reporterUserId)) ? Number(parsed.reporterUserId) : null,
    reason,
    detail: textOf(parsed?.detail).slice(0, MAX_REPORT_DETAIL_LEN),
    status,
    createdAt: typeof parsed?.createdAt === 'string' ? parsed.createdAt : new Date().toISOString(),
    handledAt: typeof parsed?.handledAt === 'string' ? parsed.handledAt : null,
    action: textOf(parsed?.action) || null
  };
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
      const entry = normalizeEntry(JSON.parse(line));
      if (!entry) {
        continue;
      }
      cache.push(entry);
      if (entry.id >= nextId) {
        nextId = entry.id + 1;
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
  const text = cache.map(entry => JSON.stringify(entry)).join('\n');
  await fs.writeFile(FILE_PATH, text === '' ? '' : text + '\n', 'utf8');
}

function view(entry) {
  return { ...entry };
}

// 提交举报：同一举报人对同一张卡片已有 pending 举报时直接返回该举报，不重复入库。
// 返回 { report, created }：created=false 表示命中已有举报（幂等提交）。
export function createCardReport({ groupId, cardIndex, reporterAccount, reporterUserId, reason, detail, snapshot }) {
  return serialized(async () => {
    await ensureLoaded();
    const existing = cache.find(
      entry => entry.status === 'pending' && entry.groupId === groupId
        && entry.cardIndex === cardIndex && entry.reporterAccount === reporterAccount
    );
    if (existing) {
      return { report: view(existing), created: false };
    }
    const entry = {
      id: nextId++,
      groupId,
      cardIndex,
      groupName: snapshot.groupName,
      ownerAccount: snapshot.ownerAccount,
      cardEvent: snapshot.cardEvent,
      cardPurpose: snapshot.cardPurpose,
      cardLocation: snapshot.cardLocation,
      cardTime: snapshot.cardTime,
      reporterAccount,
      reporterUserId: Number.isInteger(reporterUserId) ? reporterUserId : null,
      reason,
      detail,
      status: 'pending',
      createdAt: new Date().toISOString(),
      handledAt: null,
      action: null
    };
    cache.push(entry);
    await persist();
    return { report: view(entry), created: true };
  });
}

// 管理台：全部举报（新→旧）
export function listCardReports() {
  return serialized(async () => {
    await ensureLoaded();
    return [...cache]
      .sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : b.id - a.id))
      .map(view);
  });
}

export function getCardReport(id) {
  return serialized(async () => {
    await ensureLoaded();
    const entry = cache.find(item => item.id === id);
    return entry ? view(entry) : null;
  });
}

// 处理举报：pending → dismissed / actioned（同一串行任务内校验并落库，重复处理只成功一次）。
// 返回更新后的举报，或 null（不存在 / 已处理）。
export function settleCardReport(id, status, action) {
  return serialized(async () => {
    await ensureLoaded();
    const entry = cache.find(item => item.id === id);
    if (!entry || entry.status !== 'pending') {
      return null;
    }
    entry.status = status;
    entry.action = action;
    entry.handledAt = new Date().toISOString();
    await persist();
    return view(entry);
  });
}
