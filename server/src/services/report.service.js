import { listMyRelatedCards } from './cardGroupStore.js';
import { expandCardOccurrences, parseTimeRange, parseRepeat } from './conflictService.js';
import { findAccount } from './accountStore.js';

// 周报统计（服务 74）：只做「计算」，不落库——周报数据按需求长期保存在转发台客户端。
// 统计口径（与需求一致）：
//   卡片数 = 我设置或参与、且「时间（含重复规则）展开后与本周周一时间段交集不为空」的卡片数；
//   打卡数 / 完成数 / 延时数由客户端在事件发生时自己累加（服务 75 / 62 / 67），服务器不参与。
// 这里返回：本周内命中的卡片 key 列表 + 本周内「已到期」的卡片 key 列表 + 我全部相关卡片 key 列表（供客户端累计去重）。
// 「已到期」= 本周内有开始时间不晚于当前时间的那次发生；客户端用它作完成率分母（并集 + 只算已到期）。

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function toDate(value) {
  const ms = Number(value);
  if (!Number.isFinite(ms)) {
    return null;
  }
  const d = new Date(ms);
  return Number.isNaN(d.getTime()) ? null : d;
}

// 「这张卡片的时间段是否与 [from, to) 有交集」
// 单次卡片直接比自身时段：卡片内容规范化会把空 repeatUntil 填成 time，
// 此时 expandCardOccurrences 会因 stop=repeatUntil=起始时间而判为空集，故单次卡片不走展开。
// 重复卡片仍用 expandCardOccurrences 展开（它按 repeatTime/repeatUntil 生成各次发生）。
function intersectsWeek(content, from, to) {
  const base = parseTimeRange(content?.time);
  if (!base) {
    return false;
  }
  const repeat = parseRepeat(content?.repeatTime, base.start);
  if (!repeat) {
    return base.start.getTime() < to.getTime() && from.getTime() < base.end.getTime();
  }
  return expandCardOccurrences(content, { from, to }).length > 0;
}

// 「本周内是否已到期」：与本周有交集，且已存在一次开始时间不晚于 now 的发生。
// 完成率的分子只看「已经该做」的卡片——本周尚未到开始时间的卡片不计入分母，
// 否则周一统计时完成率会被大量未来卡片拉低。
// 单次卡片与 intersectsWeek 同理不走展开（空 repeatUntil 会让展开判为空集）。
function dueInWeek(content, from, to, now) {
  const base = parseTimeRange(content?.time);
  if (!base) {
    return false;
  }
  const repeat = parseRepeat(content?.repeatTime, base.start);
  if (!repeat) {
    return base.start.getTime() < to.getTime()
      && from.getTime() < base.end.getTime()
      && base.start.getTime() <= now.getTime();
  }
  return expandCardOccurrences(content, { from, to }).some(o => o.start.getTime() <= now.getTime());
}

// 卡片「时段」归类（周报三维度标签计数用）：按「时间」开始时刻分上午 / 下午 / 夜晚；
// 开始时刻 05:00-12:00 = morning，12:00-18:00 = afternoon，18:00-次日05:00 = night（含深夜凌晨）；
// 卡片没有「时间」时返回 null（不归入任何时段）
function daySlotOf(content) {
  const base = parseTimeRange(content?.time);
  if (!base) {
    return null;
  }
  const hour = base.start.getHours();
  if (hour >= 5 && hour < 12) {
    return 'morning';
  }
  if (hour >= 12 && hour < 18) {
    return 'afternoon';
  }
  return 'night';
}

export async function getWeekCardReport({ account = null, startMs = null, endMs = null } = {}) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    throw badRequest('需要账号身份才能统计周报');
  }
  const me = await findAccount(name);
  if (!me) {
    throw badRequest('当前账号不存在，请重新登录');
  }
  const from = toDate(startMs);
  const to = toDate(endMs);
  if (!from || !to || to.getTime() <= from.getTime()) {
    throw badRequest('周报统计需要合法的周起止时间（startMs / endMs，结束需晚于开始）');
  }
  const cards = await listMyRelatedCards(name);
  const now = new Date();
  const allCardKeys = [];
  const weekCardKeys = [];
  const weekDueCardKeys = [];
  // 三维度标签 + 时段的卡片归类（周报计数用）：key = groupId:cardIndex，
  // type/scene/theme 为卡片隐藏标签（合法枚举或 null），day = 按开始时刻归的时段（无时间 = null）；
  // 客户端周报库按「维度:取值 → 卡片 key 去重集合」累计，卡片删除后计数不回退
  const tagCardOf = (card, key) => ({
    key,
    type: card.content?.type ?? null,
    scene: card.content?.scene ?? null,
    theme: card.content?.theme ?? null,
    day: daySlotOf(card.content)
  });
  const allTagCards = [];
  const weekTagCards = [];
  for (const card of cards) {
    const key = `${card.groupId}:${card.cardIndex}`;
    allCardKeys.push(key);
    allTagCards.push(tagCardOf(card, key));
    if (intersectsWeek(card.content, from, to)) {
      weekCardKeys.push(key);
      weekTagCards.push(tagCardOf(card, key));
      if (dueInWeek(card.content, from, to, now)) {
        weekDueCardKeys.push(key);
      }
    }
  }
  return {
    account: name,
    startMs: from.getTime(),
    endMs: to.getTime(),
    weekCardCount: weekCardKeys.length,
    weekDueCardCount: weekDueCardKeys.length,
    allCardCount: allCardKeys.length,
    weekCardKeys,
    weekDueCardKeys,
    allCardKeys,
    weekTagCards,
    allTagCards
  };
}

// 三维度标签 + 话题标签 + 时段的中文标签（周报累计信息 → AI 记日程【用户信息】栏渲染用）
const TAG_LABELS = {
  type: { work: '工作', task: '任务', activity: '活动', routine: '日常' },
  scene: { indoor: '室内', outdoor: '户外', anywhere: '不限地点' },
  theme: { academic: '学习', sports: '运动', entertainment: '娱乐', social: '社交', creative: '创作', life: '生活' },
  day: { morning: '上午', afternoon: '下午', night: '夜晚' },
  topic: {}
};

// 周报累计信息（AI 记日程【用户信息】栏用）：该用户全部相关卡片的
// 三维度标签 + 话题标签（#标签）+ 时段累计分布（与 getWeekCardReport 的 allTagCards 同源同口径）。
// 输出 { summary, totalCards, type: ['工作 12（48%）', ...], scene, theme, topic: ['健身 5（28%）', ...], day }：
// 各维度按数量降序、只列非零项、百分比为维度内占比（四舍五入）；topic = 话题标签（常用话题），
// 标签即展示词；账号为空 / 账号不存在 / 无任何卡片 / 各维度全空时返回 null（不设该栏）
export async function getCumulativeTagStats({ account = null } = {}) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    return null;
  }
  const me = await findAccount(name);
  if (!me) {
    return null;
  }
  const cards = await listMyRelatedCards(name);
  if (cards.length === 0) {
    return null;
  }
  const counts = { type: {}, scene: {}, theme: {}, topic: {}, day: {} };
  for (const card of cards) {
    const content = card.content ?? {};
    for (const dim of ['type', 'scene', 'theme']) {
      const value = content[dim];
      if (typeof value === 'string' && value !== '') {
        counts[dim][value] = (counts[dim][value] ?? 0) + 1;
      }
    }
    // 话题标签（#标签）：统计用户常用话题，供 AI 打标与小铺推荐参考
    for (const tag of Array.isArray(content.tags) ? content.tags : []) {
      if (typeof tag === 'string' && tag.trim() !== '') {
        const key = tag.trim();
        counts.topic[key] = (counts.topic[key] ?? 0) + 1;
      }
    }
    const day = daySlotOf(content);
    if (day !== null) {
      counts.day[day] = (counts.day[day] ?? 0) + 1;
    }
  }
  const out = {
    summary: '周报累计统计：该用户全部历史卡片的类型/场景/主题标签、常用话题与时段分布，反映长期习惯',
    totalCards: cards.length
  };
  let hasAny = false;
  for (const dim of ['type', 'scene', 'theme', 'topic', 'day']) {
    const dimCounts = counts[dim];
    const keys = Object.keys(dimCounts);
    let dimTotal = 0;
    for (const key of keys) {
      dimTotal += dimCounts[key];
    }
    if (dimTotal === 0) {
      continue;
    }
    keys.sort((a, b) => dimCounts[b] - dimCounts[a]);
    out[dim] = keys.map(key => {
      const label = TAG_LABELS[dim][key] ?? key;
      return dim === 'topic'
        ? `常用话题 #${label} ${dimCounts[key]}（${Math.round(dimCounts[key] * 100 / dimTotal)}%）`
        : `${label} ${dimCounts[key]}（${Math.round(dimCounts[key] * 100 / dimTotal)}%）`;
    });
    hasAny = true;
  }
  return hasAny ? out : null;
}