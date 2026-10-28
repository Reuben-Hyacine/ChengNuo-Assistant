// 日程时间冲突检测：把卡片「时间 + 何时重复 + 重复到何时」展开成具体时间段，逐段比较是否重叠。
// 不依赖大模型判断，结果确定可复现，用于「提示词告知 AI」与「确定卡片前的硬门槛」。

// 未写结束时间时，按默认时长 60 分钟估算该次安排的长度
export const DEFAULT_DURATION_MIN = 60;

const WEEKDAYS = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 0, '天': 0 };

function pad(n) {
  return String(n).padStart(2, '0');
}

export function formatDateTime(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) {
    return null;
  }
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function formatRange(start, end) {
  const s = formatDateTime(start);
  if (!s) {
    return null;
  }
  const e = formatDateTime(end);
  if (!e) {
    return s;
  }
  // 同一天只显示一次日期
  if (formatDateTime(start).slice(0, 10) === formatDateTime(end).slice(0, 10)) {
    return `${s}~${e.slice(11)}`;
  }
  return `${s}~${e}`;
}

// 解析 "YYYY-MM-DD HH:mm"（允许 T 分隔、月日时分不补零）
export function parseDateTime(text) {
  const m = String(text ?? '').trim().match(/^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{1,2})$/);
  if (!m) {
    return null;
  }
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), 0, 0);
  return Number.isNaN(d.getTime()) ? null : d;
}

// "YYYY-MM-DD" → 当天 23:59:59（重复到何时含当天）
export function parseUntil(text) {
  const t = String(text ?? '').trim();
  if (t === '') {
    return null;
  }
  const full = parseDateTime(t);
  if (full) {
    return full;
  }
  const m = t.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/);
  if (!m) {
    return null;
  }
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 23, 59, 59, 0);
  return Number.isNaN(d.getTime()) ? null : d;
}

// 解析「时间」字段为一段：{ start, end, openEnded }
// 支持 "YYYY-MM-DD HH:mm"、"YYYY-MM-DD HH:mm~HH:mm"、"YYYY-MM-DD HH:mm~YYYY-MM-DD HH:mm"
export function parseTimeRange(timeText) {
  const text = String(timeText ?? '').trim();
  if (text === '') {
    return null;
  }
  const parts = text.split(/[~～]|至/).map(s => s.trim()).filter(s => s !== '');
  const start = parseDateTime(parts[0]);
  if (!start) {
    return null;
  }
  if (parts.length === 1) {
    return { start, end: new Date(start.getTime() + DEFAULT_DURATION_MIN * 60000), openEnded: true };
  }
  let end = parseDateTime(parts[1]);
  if (!end) {
    const hm = parts[1].match(/^(\d{1,2}):(\d{1,2})$/);
    if (hm) {
      end = new Date(start.getFullYear(), start.getMonth(), start.getDate(), Number(hm[1]), Number(hm[2]), 0, 0);
      if (end.getTime() <= start.getTime()) {
        end = new Date(end.getTime() + 24 * 3600 * 1000); // 跨天（如 23:00~01:00）
      }
    }
  }
  if (!end || end.getTime() <= start.getTime()) {
    return { start, end: new Date(start.getTime() + DEFAULT_DURATION_MIN * 60000), openEnded: true };
  }
  return { start, end, openEnded: false };
}

// 解析「何时重复」：每天 / 每周X / 每月N号
export function parseRepeat(repeatText, baseStart) {
  const t = String(repeatText ?? '').trim();
  if (t === '') {
    return null;
  }
  if (/每(天|日)/.test(t)) {
    return { kind: 'daily' };
  }
  const wk = t.match(/每(?:周|星期|礼拜)([一二三四五六日天])?/);
  if (wk) {
    const weekday = wk[1] ? WEEKDAYS[wk[1]] : baseStart.getDay();
    if (weekday === undefined) {
      return null;
    }
    return { kind: 'weekly', weekday };
  }
  const mo = t.match(/每(?:个)?月\s*(\d{1,2})\s*[号日]?/);
  if (mo) {
    const day = Number(mo[1]);
    if (day >= 1 && day <= 31) {
      return { kind: 'monthly', day };
    }
  }
  return null;
}

// 把起始时间对齐到「每周X」/「每月N号」
function alignWeekly(base, weekday) {
  const d = new Date(base.getTime());
  d.setDate(d.getDate() + ((weekday - d.getDay() + 7) % 7));
  return d;
}

function alignMonthly(base, day) {
  const d = new Date(base.getTime());
  d.setDate(day);
  if (d.getTime() < base.getTime()) {
    d.setMonth(d.getMonth() + 1);
    d.setDate(day);
  }
  return d;
}

function nextOccurrence(date, repeat) {
  if (repeat.kind === 'daily') {
    return new Date(date.getTime() + 24 * 3600 * 1000);
  }
  if (repeat.kind === 'weekly') {
    return new Date(date.getTime() + 7 * 24 * 3600 * 1000);
  }
  const d = new Date(date.getTime());
  d.setMonth(d.getMonth() + 1);
  d.setDate(repeat.day);
  return d;
}

// 把一张卡片在 [from, to] 窗口内展开为若干具体时间段
export function expandCardOccurrences(card, options = {}) {
  const base = parseTimeRange(card?.time);
  if (!base) {
    return [];
  }
  const limit = Number.isInteger(options.limit) ? options.limit : 200;
  const duration = base.end.getTime() - base.start.getTime();
  const winFrom = options.from instanceof Date ? options.from : new Date(0);
  const winTo = options.to instanceof Date && !Number.isNaN(options.to.getTime())
    ? options.to
    : new Date(base.start.getTime() + 365 * 24 * 3600 * 1000);
  const until = parseUntil(card?.repeatUntil);
  const stop = (until && until.getTime() < winTo.getTime()) ? until : winTo;
  const repeat = parseRepeat(card?.repeatTime, base.start);

  if (!repeat) {
    // 非重复卡：repeatUntil 缺省被规整为 time 本身，边界须为「含该次」（>），
    // 否则 stop=repeatUntil=起始时间 会把唯一一次发生判为空集（提醒/冲突检测全灭）
    if (base.end.getTime() <= winFrom.getTime() || base.start.getTime() > stop.getTime()) {
      return [];
    }
    return [{ start: base.start, end: base.end }];
  }

  let cursor = repeat.kind === 'weekly' ? alignWeekly(base.start, repeat.weekday)
    : repeat.kind === 'monthly' ? alignMonthly(base.start, repeat.day)
      : base.start;
  const out = [];
  let guard = 0;
  while (cursor.getTime() < stop.getTime() && out.length < limit && guard < 5000) {
    guard += 1;
    const end = new Date(cursor.getTime() + duration);
    if (end.getTime() > winFrom.getTime()) {
      out.push({ start: new Date(cursor.getTime()), end });
    }
    cursor = nextOccurrence(cursor, repeat);
  }
  return out;
}

// 候选卡片与「已有卡片」列表是否存在时间重叠
// otherEntries: [{ owner, index, card, local? }]
export function findConflicts(candidateCard, otherEntries) {
  const candOcc = expandCardOccurrences(candidateCard, {});
  if (candOcc.length === 0) {
    return [];
  }
  const from = candOcc[0].start;
  const lastEnd = candOcc.reduce((max, o) => (o.end.getTime() > max ? o.end.getTime() : max), 0);
  const to = new Date(Math.max(lastEnd, from.getTime() + 24 * 3600 * 1000));

  const conflicts = [];
  for (const entry of Array.isArray(otherEntries) ? otherEntries : []) {
    const other = entry?.card;
    if (!other) {
      continue;
    }
    const otherOcc = expandCardOccurrences(other, { from, to });
    if (otherOcc.length === 0) {
      continue;
    }
    let hit = null;
    for (const a of candOcc) {
      for (const b of otherOcc) {
        if (a.start.getTime() < b.end.getTime() && b.start.getTime() < a.end.getTime()) {
          hit = {
            start: new Date(Math.max(a.start.getTime(), b.start.getTime())),
            end: new Date(Math.min(a.end.getTime(), b.end.getTime()))
          };
          break;
        }
      }
      if (hit) {
        break;
      }
    }
    if (hit) {
      conflicts.push({
        owner: entry.owner ?? other.initiator ?? null,
        // index 既支持数字（旧卡片库槽位）也支持「组号:组内编号」字符串（卡片组库）
        index: (typeof entry.index === 'string' && entry.index !== '') || Number.isInteger(entry.index) ? entry.index : null,
        local: entry.local === true,
        event: other.event ?? null,
        time: other.time ?? null,
        repeatTime: other.repeatTime ?? null,
        repeatUntil: other.repeatUntil ?? null,
        overlap: formatRange(hit.start, hit.end)
      });
    }
  }
  return conflicts;
}

// 冲突的可读描述（用于提示词与报错信息）
export function describeConflict(conflict) {
  const who = conflict.owner ? `账号 ${conflict.owner}` : '未知账号';
  const where = conflict.index === null
    ? (conflict.local ? '客户端本地私人卡片' : '卡片')
    : `卡片 #${conflict.index}`;
  const when = conflict.repeatTime
    ? `${conflict.time}（${conflict.repeatTime}${conflict.repeatUntil ? `，重复到 ${conflict.repeatUntil}` : ''}）`
    : `${conflict.time}`;
  return `${where}（${who}：${conflict.event ?? '未命名'} ${when}）与本次安排重叠于 ${conflict.overlap}`;
}

export function describeConflicts(conflicts) {
  return (Array.isArray(conflicts) ? conflicts : []).map(describeConflict);
}
