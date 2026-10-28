import { runAiJsonTask, buildShopSchema, SHOP_SYSTEM_PROMPT, SHOP_TASK } from './index.js';
import { assembleContext } from './aiAskService.js';
import { cleanCardTagValue, cleanCardTags, isValidAbsoluteTime } from '../cardStore.js';
import { shopHolidayHint, todayText } from '../holidays.js';

// 卡片小铺主题轮换（index = 第几张）：服务端固定提示，避免客户端注入提示词；
// 超过 4 张后循环复用（无限追加流），exclude 名单保证不与前次重复
const SHOP_THEME_HINTS = [
  '（第 1 张：优先贴合「周报累计统计」里占比最高的主题与时段。）',
  '（第 2 张：侧重学习成长或创作类活动。）',
  '（第 3 张：侧重运动健康或生活整理类活动。）',
  '（第 4 张：侧重社交娱乐或放松身心类活动。）'
];

// 三维度标签非法/缺失时的兜底枚举：56 加卡硬性要求三维度齐备，兜底保证加入流程不失败
const TAG_FALLBACKS = { type: 'activity', scene: 'anywhere', theme: 'life' };

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function tagOrFallback(field, value) {
  return cleanCardTagValue(field, value) ?? TAG_FALLBACKS[field];
}

/**
 * 卡片小铺（服务 89）：AI 按「周报累计统计 + 用户资料 + 已有日程」直接推荐一张完整的
 * 私人日程卡片。与记日程对话流程（0）完全隔离：不读写工作卡、不改变 AI 状态机、
 * 不做内容审核（任务文案固定，产物经 53+56 只进入用户自己的私人卡片组）。
 * 卡片不落库：客户端按账号存本地小铺文件（无限追加、上拉加载更多），
 * 用户点「加入日程」时经 53 新建私人卡片组 + 56 加卡进入私人卡片库。
 * index = 第几张（1 起，主题提示按 4 循环）；exclude = 客户端上送的已推荐活动名清单（避免重复）。
 */
export async function runShopRecommend({ account = null, index = 1, exclude = null } = {}) {
  const name = textOf(account);
  if (name === '') {
    const err = new Error('需要账号身份才能获取卡片小铺推荐');
    err.status = 400;
    throw err;
  }
  const slot = Number.isInteger(index) && index >= 1 ? ((index - 1) % SHOP_THEME_HINTS.length) + 1 : 1;
  const excludeList = (Array.isArray(exclude) ? exclude : [])
    .filter(v => typeof v === 'string' && v.trim() !== '')
    .map(v => v.trim().slice(0, 40))
    .slice(0, 30);
  const excludeText = excludeList.length > 0
    ? `（不要与以下已推荐过的活动重复或高度相似：${excludeList.join('、')}。）`
    : '';
  const context = await assembleContext(name);
  const result = await runAiJsonTask({
    task: `${SHOP_TASK}${SHOP_THEME_HINTS[slot - 1]}${shopHolidayHint(todayText())}${excludeText}`,
    context,
    schemaHint: buildShopSchema(),
    system: SHOP_SYSTEM_PROMPT
  });
  const data = result.data;
  const rawCard = data && typeof data === 'object' && !Array.isArray(data) ? data.card : null;
  const src = rawCard && typeof rawCard === 'object' && !Array.isArray(rawCard) ? rawCard : {};
  const event = textOf(src.event);
  const time = textOf(src.time);
  if (event === '' || !isValidAbsoluteTime(time)) {
    const err = new Error('AI 未返回有效的小铺卡片（事件或时间缺失/格式不符）');
    err.status = 502;
    throw err;
  }
  const reminder = textOf(src.reminderTime);
  const topicTags = cleanCardTags(src.tags);
  const card = {
    purpose: textOf(src.purpose) || null,
    event,
    time,
    reminderTime: isValidAbsoluteTime(reminder) ? reminder : null,
    repeatTime: textOf(src.repeatTime) || null,
    repeatUntil: textOf(src.repeatUntil) || null,
    location: textOf(src.location) || null,
    type: tagOrFallback('type', src.type),
    scene: tagOrFallback('scene', src.scene),
    theme: tagOrFallback('theme', src.theme),
    tags: topicTags.length > 0 ? topicTags : null
  };
  return { card, model: result.model };
}
