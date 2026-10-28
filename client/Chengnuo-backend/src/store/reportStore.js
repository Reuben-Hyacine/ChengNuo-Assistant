import { dataFilePath, readJsonl, writeJsonl, serializedChain } from './jsonl.js';

// 周报库（客户端长期保存，服务器不持久化）：每个账号一条记录。
//   weeks  = 近两周（今周 + 上一周）的周报：卡片数 / 打卡数 / 完成数 / 延时数 / 完成率
//   totals = 从注册起一直保留的累计数据（同样四项 + 完成率）
// 完成率 = 完成数 / max(「已到期」卡片去重并集大小, 完成数)，D 为 0 时显示「—」；
// 分母用「只增不减」的并集，避免「完成即删卡」让分母缩水、未到开始时间的卡片拉低完成率。
// 完成率以 rate 字段落盘（每个周桶一份 + totals 一份）：载入时重算一次，
// 之后每次「数字」变化（快照 / 打卡 / 完成 / 延时）都调 refreshRates 重算写回，保证与计数一致。
// 打卡去重：每张卡片每天只能打卡一次，去重键形如 "组号:卡号@YYYY-MM-DD"。
// 周界按「周一 00:00（本地时区）」划分；更早的周在每次读写时被裁掉，只留最近两周。
const FILE_PATH = dataFilePath('reports.txt');
export const WEEK_KEEP = 2;

let cache = [];
let loaded = false;
const run = serializedChain();

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function intOr0(value) {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : 0;
}

// 时间入参归一：null/undefined/'' 一律按「现在」处理（Number(null) 是 0，不能用 isFinite 直接判）
function resolveMs(value, fallback = Date.now()) {
  if (value === null || value === undefined || value === '') {
    return fallback;
  }
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function pad2(n) {
  return String(n).length < 2 ? `0${n}` : String(n);
}

// "YYYY-MM-DD"（本地时区）
export function dateKeyOf(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

// 所在周的周一 00:00（本地时区）毫秒时间戳
export function weekStartMsOf(ms) {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  const offset = (d.getDay() + 6) % 7; // 周一=0
  d.setDate(d.getDate() - offset);
  return d.getTime();
}

// 周标识直接用「周一那天的日期」，简单可读且与周界一一对应
export function weekKeyOf(ms) {
  return dateKeyOf(weekStartMsOf(ms));
}

function emptyCounts() {
  return { setCount: 0, checkinCount: 0, doneCount: 0, extendCount: 0 };
}

// 完成率（并集 + 只算已到期）：
//   分子 N = 完成数；分母 D = max(本周已到期卡片并集大小, 完成数)（保底分母不小于分子，避免完成即删卡导致率 > 100%）。
//   D 为 0 时返回 null，界面显示「—」。
function completionRate(dueCount, doneCount) {
  const d = Math.max(intOr0(dueCount), intOr0(doneCount));
  return d > 0 ? Math.min(1, intOr0(doneCount) / d) : null;
}

// 重算并写回完成率字段：每个周桶的 rate 与累计 rate。
// 任何「数字」变化（快照/打卡/完成/延时，或到期并集变化）之后都调用一次，保证落盘的 rate 与计数永远一致。
function refreshRates(rec) {
  for (const w of Object.values(rec.weeks)) {
    if (!Array.isArray(w.dueKeys)) {
      w.dueKeys = [];
    }
    w.rate = completionRate(w.dueKeys.length, w.doneCount);
  }
  const dueSeen = Array.isArray(rec.dueSeenCards) ? rec.dueSeenCards : [];
  rec.totals.rate = completionRate(dueSeen.length, rec.totals.doneCount);
}

function normalize(parsed) {
  const account = textOf(parsed?.account);
  if (account === '') {
    return null;
  }
  const weeks = {};
  const rawWeeks = parsed?.weeks && typeof parsed.weeks === 'object' && !Array.isArray(parsed.weeks) ? parsed.weeks : {};
  for (const [key, w] of Object.entries(rawWeeks)) {
    const weekStartMs = Number(w?.weekStartMs);
    if (!Number.isFinite(weekStartMs)) {
      continue;
    }
    weeks[key] = {
      weekStartMs,
      weekEndMs: Number.isFinite(Number(w?.weekEndMs)) ? Number(w.weekEndMs) : weekStartMs + 7 * 86400000,
      ...emptyCounts(),
      setCount: intOr0(w?.setCount),
      checkinCount: intOr0(w?.checkinCount),
      doneCount: intOr0(w?.doneCount),
      extendCount: intOr0(w?.extendCount),
      dueKeys: Array.isArray(w?.dueKeys) ? [...new Set(w.dueKeys.filter(k => typeof k === 'string' && k !== ''))] : []
    };
  }
  const t = parsed?.totals && typeof parsed.totals === 'object' ? parsed.totals : {};
  const seenCards = Array.isArray(parsed?.seenCards) ? parsed.seenCards.filter(k => typeof k === 'string' && k !== '') : [];
  const dueSeenCards = Array.isArray(parsed?.dueSeenCards) ? parsed.dueSeenCards.filter(k => typeof k === 'string' && k !== '') : [];
  const checkins = Array.isArray(parsed?.checkins) ? parsed.checkins.filter(s => typeof s === 'string' && s !== '') : [];
  const rec = {
    account,
    userId: Number.isInteger(Number(parsed?.userId)) ? Number(parsed.userId) : null,
    weeks,
    totals: {
      setCount: intOr0(t.setCount),
      checkinCount: intOr0(t.checkinCount),
      doneCount: intOr0(t.doneCount),
      extendCount: intOr0(t.extendCount)
    },
    seenCards: [...new Set(seenCards)],
    dueSeenCards: [...new Set(dueSeenCards)],
    checkins: [...new Set(checkins)]
  };
  // 载入即重算完成率：手动改过 reports.txt 里的数字后，落盘的 rate 也保持同步
  refreshRates(rec);
  return rec;
}

async function ensureLoaded() {
  if (loaded) {
    return;
  }
  const records = await readJsonl(FILE_PATH);
  cache = [];
  for (const raw of records) {
    const rec = normalize(raw);
    if (rec) {
      cache.push(rec);
    }
  }
  loaded = true;
}

async function persist() {
  await writeJsonl(FILE_PATH, cache);
}

function findRecord(account) {
  const name = textOf(account);
  return cache.find(rec => rec.account === name) ?? null;
}

function ensureRecord(account, userId = null) {
  const name = textOf(account);
  let rec = findRecord(name);
  if (!rec) {
    rec = { account: name, userId: Number.isInteger(userId) ? userId : null, weeks: {}, totals: emptyCounts(), seenCards: [], dueSeenCards: [], checkins: [] };
    cache.push(rec);
  } else if (Number.isInteger(userId)) {
    rec.userId = userId;
  }
  return rec;
}

// 取（或新建）某时刻所在周的桶
function ensureWeek(rec, ms) {
  const weekStartMs = weekStartMsOf(ms);
  const key = dateKeyOf(weekStartMs);
  if (!rec.weeks[key]) {
    rec.weeks[key] = { weekStartMs, weekEndMs: weekStartMs + 7 * 86400000, ...emptyCounts(), dueKeys: [] };
  }
  return rec.weeks[key];
}

// 只保留最近 WEEK_KEEP 周；打卡去重记录也裁到保留窗口内（更早的周不再需要去重）
function prune(rec, nowMs) {
  const kept = Object.values(rec.weeks).sort((a, b) => b.weekStartMs - a.weekStartMs).slice(0, WEEK_KEEP);
  const keptKeys = new Set(kept.map(w => dateKeyOf(w.weekStartMs)));
  const earliest = kept.length ? kept[kept.length - 1].weekStartMs : weekStartMsOf(nowMs);
  const earliestDate = dateKeyOf(earliest);
  for (const key of Object.keys(rec.weeks)) {
    if (!keptKeys.has(key)) {
      delete rec.weeks[key];
    }
  }
  rec.checkins = rec.checkins.filter(s => {
    const at = s.lastIndexOf('@');
    return at >= 0 && s.slice(at + 1) >= earliestDate;
  });
}

// 服务 74 快照：写入某一周的「卡片数」，把本次「已到期」卡片并入本周去重并集（完成率分母），
// 并把本次看到的相关卡片并入累计去重集合。
// 完成即删卡会让 weekCardKeys 缩水，所以完成率分母用「只增不减」的 dueKeys 并集，避免已完成的卡片从分母里消失。
export function applyWeekSnapshot({ account = null, userId = null, startMs = null, endMs = null, weekCardKeys = [], weekDueCardKeys = [], allCardKeys = [] } = {}) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    const start = resolveMs(startMs, null);
    if (name === '' || start === null) {
      return null;
    }
    const rec = ensureRecord(name, userId);
    const week = ensureWeek(rec, start);
    week.weekStartMs = weekStartMsOf(start);
    week.weekEndMs = Number.isFinite(Number(endMs)) ? Number(endMs) : week.weekStartMs + 7 * 86400000;
    week.setCount = Array.isArray(weekCardKeys) ? weekCardKeys.length : 0;
    if (!Array.isArray(week.dueKeys)) {
      week.dueKeys = [];
    }
    for (const key of Array.isArray(weekDueCardKeys) ? weekDueCardKeys : []) {
      if (typeof key === 'string' && key !== '' && !week.dueKeys.includes(key)) {
        week.dueKeys.push(key);
      }
    }
    if (!Array.isArray(rec.dueSeenCards)) {
      rec.dueSeenCards = [];
    }
    for (const key of Array.isArray(weekDueCardKeys) ? weekDueCardKeys : []) {
      if (typeof key === 'string' && key !== '' && !rec.dueSeenCards.includes(key)) {
        rec.dueSeenCards.push(key);
      }
    }
    for (const key of Array.isArray(allCardKeys) ? allCardKeys : []) {
      if (typeof key === 'string' && key !== '' && !rec.seenCards.includes(key)) {
        rec.seenCards.push(key);
      }
    }
    rec.totals.setCount = rec.seenCards.length;
    prune(rec, start);
    refreshRates(rec);
    await persist();
    return getReportOf(rec, start);
  });
}

// 打卡（服务 75）：每张卡片一天只能打一次；返回是否本次真正计数
export function recordCheckin({ account = null, userId = null, groupId = null, cardIndex = null, atMs = null } = {}) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    const gid = Number(groupId);
    const idx = Number(cardIndex);
    const at = resolveMs(atMs);
    if (name === '' || !Number.isInteger(gid) || !Number.isInteger(idx)) {
      return null;
    }
    const rec = ensureRecord(name, userId);
    const week = ensureWeek(rec, at);
    const ck = `${gid}:${idx}@${dateKeyOf(at)}`;
    const already = rec.checkins.includes(ck);
    if (!already) {
      rec.checkins.push(ck);
      week.checkinCount += 1;
      rec.totals.checkinCount += 1;
    }
    prune(rec, at);
    refreshRates(rec);
    await persist();
    return { ...getReportOf(rec, at), already, cardKey: `${gid}:${idx}` };
  });
}

// 完成（服务 62）：完成数 +1，并同步给打卡数 +1（当天已打过卡则不重复计）
export function recordComplete({ account = null, userId = null, groupId = null, cardIndex = null, atMs = null } = {}) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    const at = resolveMs(atMs);
    if (name === '') {
      return null;
    }
    const rec = ensureRecord(name, userId);
    const week = ensureWeek(rec, at);
    week.doneCount += 1;
    rec.totals.doneCount += 1;
    let checkinAdded = false;
    const gid = Number(groupId);
    const idx = Number(cardIndex);
    if (Number.isInteger(gid) && Number.isInteger(idx)) {
      const ck = `${gid}:${idx}@${dateKeyOf(at)}`;
      if (!rec.checkins.includes(ck)) {
        rec.checkins.push(ck);
        week.checkinCount += 1;
        rec.totals.checkinCount += 1;
        checkinAdded = true;
      }
    }
    prune(rec, at);
    refreshRates(rec);
    await persist();
    return { ...getReportOf(rec, at), checkinAdded };
  });
}

// 延时（服务 67）：无论申请是否被同意都计一次
export function recordExtend({ account = null, userId = null, atMs = null } = {}) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    const at = resolveMs(atMs);
    if (name === '') {
      return null;
    }
    const rec = ensureRecord(name, userId);
    const week = ensureWeek(rec, at);
    week.extendCount += 1;
    rec.totals.extendCount += 1;
    prune(rec, at);
    refreshRates(rec);
    await persist();
    return getReportOf(rec, at);
  });
}

// 记录视图：当前周 + 保留的周（新在前）+ 累计 + 今天已打卡的卡片 key
export function getReportOf(rec, atMs) {
  const at = resolveMs(atMs);
  const currentStart = weekStartMsOf(at);
  const currentKey = dateKeyOf(currentStart);
  const today = dateKeyOf(at);
  const weeks = Object.values(rec.weeks)
    .sort((a, b) => b.weekStartMs - a.weekStartMs)
    .map(w => {
      const dueCount = Array.isArray(w.dueKeys) ? w.dueKeys.length : 0;
      return {
        key: dateKeyOf(w.weekStartMs),
        weekStartMs: w.weekStartMs,
        weekEndMs: w.weekEndMs,
        current: w.weekStartMs === currentStart,
        setCount: w.setCount,
        checkinCount: w.checkinCount,
        doneCount: w.doneCount,
        extendCount: w.extendCount,
        dueCount,
        rate: Number.isFinite(w.rate) ? w.rate : completionRate(dueCount, w.doneCount)
      };
    });
  return {
    account: rec.account,
    userId: rec.userId,
    currentWeek: { key: currentKey, weekStartMs: currentStart, weekEndMs: currentStart + 7 * 86400000 },
    weeks,
    totals: (() => {
      const dueCount = Array.isArray(rec.dueSeenCards) ? rec.dueSeenCards.length : 0;
      return { ...rec.totals, dueCount, rate: rec.totals.rate ?? completionRate(dueCount, rec.totals.doneCount) };
    })(),
    todayChecked: rec.checkins.filter(s => s.endsWith(`@${today}`)).map(s => s.slice(0, s.lastIndexOf('@'))),
    seenCardCount: rec.seenCards.length
  };
}

// 读取某账号周报（读取时也做一次裁剪，保证只保留近两周）
export function getReport(account, atMs = null) {
  return run(async () => {
    await ensureLoaded();
    const at = resolveMs(atMs);
    const rec = findRecord(account);
    if (!rec) {
      return {
        account: textOf(account) || null,
        userId: null,
        currentWeek: { key: weekKeyOf(at), weekStartMs: weekStartMsOf(at), weekEndMs: weekStartMsOf(at) + 7 * 86400000 },
        weeks: [],
        totals: { ...emptyCounts(), dueCount: 0, rate: null },
        todayChecked: [],
        seenCardCount: 0
      };
    }
    prune(rec, at);
    await persist();
    return getReportOf(rec, at);
  });
}

// 注销账号：清除该账号的周报库
export function clearByAccount(account) {
  return run(async () => {
    await ensureLoaded();
    const name = textOf(account);
    if (name === '') {
      return { removed: 0 };
    }
    const before = cache.length;
    cache = cache.filter(rec => rec.account !== name);
    const removed = before - cache.length;
    if (removed > 0) {
      await persist();
    }
    return { removed };
  });
}

// 改名（82）：该账号的周报库记录同步换名（userId 不变）
export function renameAccountOf(account, newAccount) {
  return run(async () => {
    await ensureLoaded();
    const oldName = textOf(account);
    const newName = textOf(newAccount);
    if (oldName === '' || newName === '' || oldName === newName) {
      return { renamed: 0 };
    }
    let renamed = 0;
    for (const rec of cache) {
      if (rec.account === oldName) {
        rec.account = newName;
        renamed += 1;
      }
    }
    if (renamed > 0) {
      await persist();
    }
    return { renamed };
  });
}