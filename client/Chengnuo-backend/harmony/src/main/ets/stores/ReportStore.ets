import { JsonRec, Jsonl } from '../Jsonl';

export const WEEK_KEEP: number = 2;

/** 累计计数（totals） */
class WeekCounts {
  setCount: number = 0;
  checkinCount: number = 0;
  doneCount: number = 0;
  extendCount: number = 0;
  rate: number | null = null;
}

/** 一周的计数桶（key 为周一日期 YYYY-MM-DD；磁盘上 weeks 以数组落盘，靠 key/weekStartMs 关联） */
class WeekRec {
  key: string;
  weekStartMs: number;
  weekEndMs: number;
  setCount: number = 0;
  checkinCount: number = 0;
  doneCount: number = 0;
  extendCount: number = 0;
  dueKeys: string[] = [];
  rate: number | null = null;
  /** 本周三维度标签 + 时段计数（周快照）：键 = type:work / scene:indoor / theme:academic / day:morning 等，
   *  值 = 归入该类的卡片 key 去重集合；随周桶一起保留（WEEK_KEEP）与裁剪 */
  tagSeen: Record<string, string[]> = {};

  constructor(key: string, weekStartMs: number, weekEndMs: number) {
    this.key = key;
    this.weekStartMs = weekStartMs;
    this.weekEndMs = weekEndMs;
  }

  toRecord(): Record<string, Object> {
    const rec: Record<string, Object> =
      { 'key': this.key, 'weekStartMs': this.weekStartMs, 'weekEndMs': this.weekEndMs, 'setCount': this.setCount, 'checkinCount': this.checkinCount, 'doneCount': this.doneCount, 'extendCount': this.extendCount, 'dueKeys': this.dueKeys };
    JsonRec.put(rec, 'rate', this.rate);
    rec['tagSeen'] = stringMapToRecord(this.tagSeen);
    return rec;
  }
}

/** 三维度标签计数的四个维度名（type / scene / theme + 时段 day） */
const TAG_DIMENSIONS: string[] = ['type', 'scene', 'theme', 'day'];

/** Record<string, string[]> → Record<string, Object>（落盘用） */
function stringMapToRecord(map: Record<string, string[]>): Record<string, Object> {
  const out: Record<string, Object> = {};
  const keys: string[] = Object.keys(map);
  for (let i = 0; i < keys.length; i++) {
    out[keys[i]] = map[keys[i]];
  }
  return out;
}

/** 落盘的 tagSeen → 内存结构（旧数据无此字段返回空） */
function recordToStringMap(value: Object | undefined | null): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  const raw: Record<string, Object> | null = JsonRec.toRecord(value);
  if (raw === null) {
    return out;
  }
  const keys: string[] = Object.keys(raw);
  for (let i = 0; i < keys.length; i++) {
    const list: string[] = JsonRec.stringList(raw[keys[i]]);
    if (list.length > 0) {
      out[keys[i]] = list;
    }
  }
  return out;
}

/** 把一张卡片的归类并入「维度:取值 → 卡片 key 去重集合」（累计不删除：key 一旦并入不随卡片删除回退） */
function mergeTagCardInto(map: Record<string, string[]>, tagCard: Record<string, Object>): void {
  const key: string = JsonRec.trimText(tagCard['key']);
  if (key.length === 0) {
    return;
  }
  for (let i = 0; i < TAG_DIMENSIONS.length; i++) {
    const dim: string = TAG_DIMENSIONS[i];
    const val: string = JsonRec.trimText(tagCard[dim]);
    if (val.length === 0) {
      continue;
    }
    const slot: string = `${dim}:${val}`;
    const list: string[] | undefined = map[slot];
    if (list === undefined) {
      map[slot] = [key];
    } else if (list.indexOf(key) < 0) {
      list.push(key);
    }
  }
}

/** 「维度:取值」集合 → 计数视图（tagCounts：每个出现过的键 → 集合大小） */
function tagCountsOf(map: Record<string, string[]>): Record<string, Object> {
  const out: Record<string, Object> = {};
  const keys: string[] = Object.keys(map);
  for (let i = 0; i < keys.length; i++) {
    out[keys[i]] = map[keys[i]].length;
  }
  return out;
}

/** 一个账号的周报库记录 */
class ReportRec {
  account: string;
  userId: number | null;
  weeks: WeekRec[] = [];
  totals: WeekCounts = new WeekCounts();
  seenCards: string[] = [];
  dueSeenCards: string[] = [];
  checkins: string[] = [];
  /** 三维度标签 + 时段的累计计数（永不删除）：键 = type:work / scene:indoor / theme:academic / day:morning 等，
   *  值 = 归入该类的卡片 key 去重集合；prune 只裁周桶与打卡记录，这里永不裁剪（累计不删除） */
  tagSeen: Record<string, string[]> = {};

  constructor(account: string, userId: number | null) {
    this.account = account;
    this.userId = userId;
  }

  toRecord(): Record<string, Object> {
    const rec: Record<string, Object> =
      { 'account': this.account, 'seenCards': this.seenCards, 'dueSeenCards': this.dueSeenCards, 'checkins': this.checkins };
    JsonRec.put(rec, 'userId', this.userId);
    const weeks: Record<string, Object>[] = [];
    for (let i = 0; i < this.weeks.length; i++) {
      weeks.push(this.weeks[i].toRecord());
    }
    rec['weeks'] = weeks;
    const totals: Record<string, Object> =
      { 'setCount': this.totals.setCount, 'checkinCount': this.totals.checkinCount, 'doneCount': this.totals.doneCount, 'extendCount': this.totals.extendCount };
    JsonRec.put(totals, 'rate', this.totals.rate);
    rec['totals'] = totals;
    rec['tagSeen'] = stringMapToRecord(this.tagSeen);
    return rec;
  }
}

function intOr0(value: Object | undefined | null): number {
  const n: number = JsonRec.rawNum(value);
  return Number.isInteger(n) && n > 0 ? n : 0;
}

/** 时间入参归一：null/undefined/'' 一律按 fallback 处理 */
function resolveMs(value: Object | null, fallback: number): number {
  if (value === null || value === undefined || value === '') {
    return fallback;
  }
  const n: number = JsonRec.rawNum(value);
  return Number.isFinite(n) ? n : fallback;
}

/** resolveMs(value, null)：缺失/非法返回 null */
function resolveMsOrNull(value: Object | null): number | null {
  if (value === null || value === undefined || value === '') {
    return null;
  }
  const n: number = JsonRec.rawNum(value);
  return Number.isFinite(n) ? n : null;
}

function pad2(n: number): string {
  const s: string = `${n}`;
  return s.length < 2 ? `0${s}` : s;
}

/** "YYYY-MM-DD"（本地时区） */
export function dateKeyOf(ms: number): string {
  const d: Date = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** 所在周的周一 00:00（本地时区）毫秒时间戳 */
export function weekStartMsOf(ms: number): number {
  const d: Date = new Date(ms);
  d.setHours(0, 0, 0, 0);
  const offset: number = (d.getDay() + 6) % 7; // 周一=0
  d.setDate(d.getDate() - offset);
  return d.getTime();
}

/** 周标识直接用「周一那天的日期」 */
function weekKeyOf(ms: number): string {
  return dateKeyOf(weekStartMsOf(ms));
}

/** 完成率：分子=完成数，分母=max(已到期卡片并集, 完成数)；分母 0 时返回 null（界面显示「—」） */
function completionRate(dueCount: number, doneCount: number): number | null {
  const d: number = Math.max(intOr0(dueCount), intOr0(doneCount));
  return d > 0 ? Math.min(1, intOr0(doneCount) / d) : null;
}

/** 重算并写回完成率：每个周桶的 rate 与累计 rate（任何数字变化后调用一次） */
function refreshRates(rec: ReportRec): void {
  for (let i = 0; i < rec.weeks.length; i++) {
    const w: WeekRec = rec.weeks[i];
    w.rate = completionRate(w.dueKeys.length, w.doneCount);
  }
  rec.totals.rate = completionRate(rec.dueSeenCards.length, rec.totals.doneCount);
}

/** 记录视图：当前周 + 保留的周（新在前）+ 累计 + 今天已打卡的卡片 key */
function getReportOf(rec: ReportRec, atMs: Object | null): Record<string, Object> {
  const at: number = resolveMs(atMs, Date.now());
  const currentStart: number = weekStartMsOf(at);
  const today: string = dateKeyOf(at);
  const sorted: WeekRec[] = rec.weeks.slice().sort((a: WeekRec, b: WeekRec): number => b.weekStartMs - a.weekStartMs);
  const weeks: Record<string, Object>[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const w: WeekRec = sorted[i];
    const dueCount: number = w.dueKeys.length;
    const weekRec: Record<string, Object> =
      { 'key': dateKeyOf(w.weekStartMs), 'weekStartMs': w.weekStartMs, 'weekEndMs': w.weekEndMs, 'current': w.weekStartMs === currentStart, 'setCount': w.setCount, 'checkinCount': w.checkinCount, 'doneCount': w.doneCount, 'extendCount': w.extendCount, 'dueCount': dueCount, 'tagCounts': tagCountsOf(w.tagSeen) };
    JsonRec.put(weekRec, 'rate', w.rate !== null && Number.isFinite(w.rate) ? w.rate : completionRate(dueCount, w.doneCount));
    weeks.push(weekRec);
  }
  const totalsDue: number = rec.dueSeenCards.length;
  const totalsRec: Record<string, Object> =
    { 'setCount': rec.totals.setCount, 'checkinCount': rec.totals.checkinCount, 'doneCount': rec.totals.doneCount, 'extendCount': rec.totals.extendCount, 'dueCount': totalsDue, 'tagCounts': tagCountsOf(rec.tagSeen) };
  JsonRec.put(totalsRec, 'rate', rec.totals.rate !== null ? rec.totals.rate : completionRate(totalsDue, rec.totals.doneCount));
  const todayChecked: string[] = [];
  const suffix: string = `@${today}`;
  for (let i = 0; i < rec.checkins.length; i++) {
    const s: string = rec.checkins[i];
    if (s.endsWith(suffix)) {
      todayChecked.push(s.substring(0, s.lastIndexOf('@')));
    }
  }
  const currentWeek: Record<string, Object> =
    { 'key': dateKeyOf(currentStart), 'weekStartMs': currentStart, 'weekEndMs': currentStart + 7 * 86400000 };
  const out: Record<string, Object> =
    { 'account': rec.account, 'currentWeek': currentWeek, 'weeks': weeks, 'totals': totalsRec, 'todayChecked': todayChecked, 'seenCardCount': rec.seenCards.length };
  JsonRec.put(out, 'userId', rec.userId);
  return out;
}

/** reports.txt：周报库（每账号一条记录；周界按周一 00:00 本地时区划分，只保留最近两周） */
export class ReportStore {
  private cache: ReportRec[] = [];
  private loaded: boolean = false;

  private filePath(): string {
    return Jsonl.dataFilePath('reports.txt');
  }

  private normalize(parsed: Object | null): ReportRec | null {
    const rec: Record<string, Object> | null = JsonRec.toRecord(parsed);
    if (rec === null) {
      return null;
    }
    const account: string = JsonRec.trimText(rec['account']);
    if (account.length === 0) {
      return null;
    }
    const out: ReportRec = new ReportRec(account, JsonRec.coercedInt(rec['userId']));
    const rawWeeks: Object[] = JsonRec.arr(rec['weeks']) ?? [];
    for (let i = 0; i < rawWeeks.length; i++) {
      const wRec: Record<string, Object> | null = JsonRec.toRecord(rawWeeks[i]);
      if (wRec === null) {
        continue;
      }
      const weekStartMs: number = JsonRec.rawNum(wRec['weekStartMs']);
      if (!Number.isFinite(weekStartMs)) {
        continue;
      }
      const weekEndMs: number = JsonRec.rawNum(wRec['weekEndMs']);
      const key: string = JsonRec.strOrNull(wRec['key']) ?? dateKeyOf(weekStartMs);
      const w: WeekRec = new WeekRec(key, weekStartMs, Number.isFinite(weekEndMs) ? weekEndMs : weekStartMs + 7 * 86400000);
      w.setCount = intOr0(wRec['setCount']);
      w.checkinCount = intOr0(wRec['checkinCount']);
      w.doneCount = intOr0(wRec['doneCount']);
      w.extendCount = intOr0(wRec['extendCount']);
      w.dueKeys = JsonRec.stringList(wRec['dueKeys']);
      w.tagSeen = recordToStringMap(wRec['tagSeen']);
      out.weeks.push(w);
    }
    const tRec: Record<string, Object> = JsonRec.toRecord(rec['totals']) ?? {};
    out.totals.setCount = intOr0(tRec['setCount']);
    out.totals.checkinCount = intOr0(tRec['checkinCount']);
    out.totals.doneCount = intOr0(tRec['doneCount']);
    out.totals.extendCount = intOr0(tRec['extendCount']);
    out.seenCards = JsonRec.stringList(rec['seenCards']);
    out.dueSeenCards = JsonRec.stringList(rec['dueSeenCards']);
    out.checkins = JsonRec.stringList(rec['checkins']);
    out.tagSeen = recordToStringMap(rec['tagSeen']);
    // 载入即重算完成率：手动改过 reports.txt 里的数字后，落盘的 rate 也保持同步
    refreshRates(out);
    return out;
  }

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    const records: Object[] = Jsonl.readJsonl(this.filePath());
    this.cache = [];
    for (let i = 0; i < records.length; i++) {
      const rec: ReportRec | null = this.normalize(records[i]);
      if (rec !== null) {
        this.cache.push(rec);
      }
    }
    this.loaded = true;
  }

  private persist(): void {
    const out: Object[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      out.push(this.cache[i].toRecord());
    }
    Jsonl.writeJsonl(this.filePath(), out);
  }

  private findRecord(account: string): ReportRec | null {
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account === account) {
        return this.cache[i];
      }
    }
    return null;
  }

  private ensureRecord(account: string, userId: Object | null): ReportRec {
    const userIdNum: number | null = JsonRec.intOrNull(userId);
    const existing: ReportRec | null = this.findRecord(account);
    if (existing === null) {
      const rec: ReportRec = new ReportRec(account, userIdNum);
      this.cache.push(rec);
      return rec;
    }
    if (userIdNum !== null) {
      existing.userId = userIdNum;
    }
    return existing;
  }

  /** 取（或新建）某时刻所在周的桶 */
  private ensureWeek(rec: ReportRec, ms: number): WeekRec {
    const weekStartMs: number = weekStartMsOf(ms);
    const key: string = dateKeyOf(weekStartMs);
    for (let i = 0; i < rec.weeks.length; i++) {
      if (dateKeyOf(rec.weeks[i].weekStartMs) === key) {
        return rec.weeks[i];
      }
    }
    const w: WeekRec = new WeekRec(key, weekStartMs, weekStartMs + 7 * 86400000);
    rec.weeks.push(w);
    return w;
  }

  /** 只保留最近 WEEK_KEEP 周；打卡去重记录也裁到保留窗口内 */
  private prune(rec: ReportRec, nowMs: number): void {
    const sorted: WeekRec[] = rec.weeks.slice().sort((a: WeekRec, b: WeekRec): number => b.weekStartMs - a.weekStartMs);
    const kept: WeekRec[] = sorted.slice(0, WEEK_KEEP);
    const keptKeys: string[] = [];
    for (let i = 0; i < kept.length; i++) {
      keptKeys.push(dateKeyOf(kept[i].weekStartMs));
    }
    const earliest: number = kept.length > 0 ? kept[kept.length - 1].weekStartMs : weekStartMsOf(nowMs);
    const earliestDate: string = dateKeyOf(earliest);
    const keptWeeks: WeekRec[] = [];
    for (let i = 0; i < rec.weeks.length; i++) {
      if (keptKeys.indexOf(dateKeyOf(rec.weeks[i].weekStartMs)) >= 0) {
        keptWeeks.push(rec.weeks[i]);
      }
    }
    rec.weeks = keptWeeks;
    const keptCheckins: string[] = [];
    for (let i = 0; i < rec.checkins.length; i++) {
      const s: string = rec.checkins[i];
      const at: number = s.lastIndexOf('@');
      if (at >= 0 && s.substring(at + 1) >= earliestDate) {
        keptCheckins.push(s);
      }
    }
    rec.checkins = keptCheckins;
  }

  /**
   * 服务 74 快照：写入某一周的「卡片数」，把本次「已到期」卡片并入本周去重并集（完成率分母），
   * 并把本次看到的相关卡片并入累计去重集合（完成即删卡也不会让累计数缩水）。
   * 三维度标签 + 时段计数同口径：weekTagCards 并入本周桶（tagSeen，随周桶保留/裁剪）、
   * allTagCards 并入累计 tagSeen（永不删除——卡片删除后各维度计数不回退）。
   */
  applyWeekSnapshot(account: Object | null, userId: Object | null, startMs: Object | null, endMs: Object | null,
    weekCardKeys: Object | null, weekDueCardKeys: Object | null, allCardKeys: Object | null,
    weekTagCards: Object | null, allTagCards: Object | null): Record<string, Object> | null {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    const start: number | null = resolveMsOrNull(startMs);
    if (name.length === 0 || start === null) {
      return null;
    }
    const rec: ReportRec = this.ensureRecord(name, userId);
    const week: WeekRec = this.ensureWeek(rec, start);
    week.weekStartMs = weekStartMsOf(start);
    const endNum: number = JsonRec.rawNum(endMs);
    week.weekEndMs = Number.isFinite(endNum) ? endNum : week.weekStartMs + 7 * 86400000;
    week.setCount = (JsonRec.arr(weekCardKeys) ?? []).length;
    const dueKeys: Object[] = JsonRec.arr(weekDueCardKeys) ?? [];
    for (let i = 0; i < dueKeys.length; i++) {
      const key: string = JsonRec.text(dueKeys[i]);
      if (key.length > 0 && week.dueKeys.indexOf(key) < 0) {
        week.dueKeys.push(key);
      }
    }
    for (let i = 0; i < dueKeys.length; i++) {
      const key: string = JsonRec.text(dueKeys[i]);
      if (key.length > 0 && rec.dueSeenCards.indexOf(key) < 0) {
        rec.dueSeenCards.push(key);
      }
    }
    const allKeys: Object[] = JsonRec.arr(allCardKeys) ?? [];
    for (let i = 0; i < allKeys.length; i++) {
      const key: string = JsonRec.text(allKeys[i]);
      if (key.length > 0 && rec.seenCards.indexOf(key) < 0) {
        rec.seenCards.push(key);
      }
    }
    rec.totals.setCount = rec.seenCards.length;
    // 三维度标签 + 时段：本周命中卡并入本周桶，全部相关卡并入累计（并集去重，累计不删除）
    const weekTags: Object[] = JsonRec.arr(weekTagCards) ?? [];
    for (let i = 0; i < weekTags.length; i++) {
      const tagCard: Record<string, Object> | null = JsonRec.toRecord(weekTags[i]);
      if (tagCard !== null) {
        mergeTagCardInto(week.tagSeen, tagCard);
      }
    }
    const allTags: Object[] = JsonRec.arr(allTagCards) ?? [];
    for (let i = 0; i < allTags.length; i++) {
      const tagCard: Record<string, Object> | null = JsonRec.toRecord(allTags[i]);
      if (tagCard !== null) {
        mergeTagCardInto(rec.tagSeen, tagCard);
      }
    }
    this.prune(rec, start);
    refreshRates(rec);
    this.persist();
    return getReportOf(rec, start);
  }

  /** 打卡（服务 75）：每张卡片一天只能打一次；返回是否本次真正计数 */
  recordCheckin(account: Object | null, userId: Object | null, groupId: Object | null, cardIndex: Object | null,
    atMs: Object | null): Record<string, Object> | null {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    const gid: number = JsonRec.rawNum(groupId);
    const idx: number = JsonRec.rawNum(cardIndex);
    const at: number = resolveMs(atMs, Date.now());
    if (name.length === 0 || !Number.isInteger(gid) || !Number.isInteger(idx)) {
      return null;
    }
    const rec: ReportRec = this.ensureRecord(name, userId);
    const week: WeekRec = this.ensureWeek(rec, at);
    const ck: string = `${gid}:${idx}@${dateKeyOf(at)}`;
    const already: boolean = rec.checkins.indexOf(ck) >= 0;
    if (!already) {
      rec.checkins.push(ck);
      week.checkinCount += 1;
      rec.totals.checkinCount += 1;
    }
    this.prune(rec, at);
    refreshRates(rec);
    this.persist();
    const out: Record<string, Object> = getReportOf(rec, at);
    out['already'] = already;
    out['cardKey'] = `${gid}:${idx}`;
    return out;
  }

  /** 完成（服务 62）：完成数 +1，并同步给打卡数 +1（当天已打过卡则不重复计） */
  recordComplete(account: Object | null, userId: Object | null, groupId: Object | null, cardIndex: Object | null,
    atMs: Object | null): Record<string, Object> | null {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    const at: number = resolveMs(atMs, Date.now());
    if (name.length === 0) {
      return null;
    }
    const rec: ReportRec = this.ensureRecord(name, userId);
    const week: WeekRec = this.ensureWeek(rec, at);
    week.doneCount += 1;
    rec.totals.doneCount += 1;
    let checkinAdded: boolean = false;
    const gid: number = JsonRec.rawNum(groupId);
    const idx: number = JsonRec.rawNum(cardIndex);
    if (Number.isInteger(gid) && Number.isInteger(idx)) {
      const ck: string = `${gid}:${idx}@${dateKeyOf(at)}`;
      if (rec.checkins.indexOf(ck) < 0) {
        rec.checkins.push(ck);
        week.checkinCount += 1;
        rec.totals.checkinCount += 1;
        checkinAdded = true;
      }
    }
    this.prune(rec, at);
    refreshRates(rec);
    this.persist();
    const out: Record<string, Object> = getReportOf(rec, at);
    out['checkinAdded'] = checkinAdded;
    return out;
  }

  /** 延时（服务 67）：无论申请是否被同意都计一次 */
  recordExtend(account: Object | null, userId: Object | null, atMs: Object | null): Record<string, Object> | null {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    const at: number = resolveMs(atMs, Date.now());
    if (name.length === 0) {
      return null;
    }
    const rec: ReportRec = this.ensureRecord(name, userId);
    const week: WeekRec = this.ensureWeek(rec, at);
    week.extendCount += 1;
    rec.totals.extendCount += 1;
    this.prune(rec, at);
    refreshRates(rec);
    this.persist();
    return getReportOf(rec, at);
  }

  /** 读取某账号周报（读取时也做一次裁剪，保证只保留近两周） */
  getReport(account: Object | null, atMs: Object | null): Record<string, Object> {
    this.ensureLoaded();
    const at: number = resolveMs(atMs, Date.now());
    const accountName: string = JsonRec.trimText(account);
    const rec: ReportRec | null = this.findRecord(accountName);
    if (rec === null) {
      const emptyTotals: Record<string, Object> =
        { 'setCount': 0, 'checkinCount': 0, 'doneCount': 0, 'extendCount': 0, 'dueCount': 0, 'tagCounts': tagCountsOf({}) };
      const currentWeek: Record<string, Object> =
        { 'key': weekKeyOf(at), 'weekStartMs': weekStartMsOf(at), 'weekEndMs': weekStartMsOf(at) + 7 * 86400000 };
      const emptyWeeks: Object[] = [];
      const emptyToday: string[] = [];
      const out: Record<string, Object> =
        { 'currentWeek': currentWeek, 'weeks': emptyWeeks, 'totals': emptyTotals, 'todayChecked': emptyToday, 'seenCardCount': 0 };
      JsonRec.put(out, 'account', accountName.length > 0 ? accountName : null);
      return out;
    }
    this.prune(rec, at);
    this.persist();
    return getReportOf(rec, at);
  }

  /** 注销账号：清除该账号的周报库 */
  clearByAccount(account: Object | null): number {
    this.ensureLoaded();
    const name: string = JsonRec.trimText(account);
    if (name.length === 0) {
      return 0;
    }
    const before: number = this.cache.length;
    const kept: ReportRec[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account !== name) {
        kept.push(this.cache[i]);
      }
    }
    this.cache = kept;
    const removed: number = before - this.cache.length;
    if (removed > 0) {
      this.persist();
    }
    return removed;
  }

  /** 改名（82）：该账号的周报库记录同步换名（userId 不变） */
  renameAccountOf(account: Object | null, newAccount: Object | null): number {
    this.ensureLoaded();
    const oldName: string = JsonRec.trimText(account);
    const newName: string = JsonRec.trimText(newAccount);
    if (oldName.length === 0 || newName.length === 0 || oldName === newName) {
      return 0;
    }
    let renamed: number = 0;
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].account === oldName) {
        this.cache[i].account = newName;
        renamed += 1;
      }
    }
    if (renamed > 0) {
      this.persist();
    }
    return renamed;
  }
}

export const reportStore: ReportStore = new ReportStore();
