import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';

const FILE_PATH = path.join(config.dataDir, config.cardFile);

export const MAX_CARDS = 20;

// 卡片参与人数量上限：包含发起者本人，默认与最小值为 1
export const MIN_CAPACITY = 1;

export const CARD_FIELDS = ['purpose', 'event', 'time', 'repeatTime', 'repeatUntil', 'location', 'participant', 'initiator', 'reminderTime', 'friendOnly', 'capacity', 'needApproval', 'type', 'scene', 'theme', 'tags'];

// 话题标签（#标签）：卡片的公开话题词，展示在卡片正面（#词 形式），用于发现页 #标签搜索与推荐参考；
// 与三维度标签（type/scene/theme，隐藏枚举元数据）相互独立，可由 AI 自动生成或用户自定义
export const MAX_CARD_TAGS = 5;      // 每张卡片最多 5 个话题标签
export const MAX_CARD_TAG_LEN = 12;  // 单个话题标签最长 12 字符

// 话题标签清洗：接受字符串数组或「#、,，空白」分隔的字符串 → 逐项去掉 # 前缀与首尾空白 →
// 过滤空项与超长项 → 按小写去重 → 截取前 MAX_CARD_TAGS 个；返回数组（无有效标签时为 []）
export function cleanCardTags(value) {
  const rawItems = Array.isArray(value)
    ? value
    : (typeof value === 'string' ? value.split(/[#、,，\s]+/) : []);
  const seen = new Set();
  const out = [];
  for (const item of rawItems) {
    if (typeof item !== 'string') {
      continue;
    }
    const tag = item.replace(/^#+/, '').trim();
    if (tag === '' || tag.length > MAX_CARD_TAG_LEN) {
      continue;
    }
    const key = tag.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(tag);
    if (out.length >= MAX_CARD_TAGS) {
      break;
    }
  }
  return out;
}

// 卡片三维度标签（每张卡片必须齐备才允许「确定」，卡片上不展示）：
//   type  类型——这是什么性质的事（积分计算、周报统计、卡片小铺推荐用）
//   scene 场景——在哪里发生（天气联动、发现页筛选用）
//   theme 主题——关于什么内容
export const CARD_TYPE_TAGS = ['work', 'task', 'activity', 'routine'];
export const CARD_SCENE_TAGS = ['indoor', 'outdoor', 'anywhere'];
export const CARD_THEME_TAGS = ['academic', 'sports', 'entertainment', 'social', 'creative', 'life'];
export const CARD_TAG_FIELDS = { type: CARD_TYPE_TAGS, scene: CARD_SCENE_TAGS, theme: CARD_THEME_TAGS };

// 标签字段的合法取值清洗：取值必须是对应维度的枚举值，否则返回 null（不写入）
export function cleanCardTagValue(field, value) {
  const allowed = CARD_TAG_FIELDS[field];
  if (!allowed || typeof value !== 'string') {
    return null;
  }
  const v = value.trim();
  return allowed.includes(v) ? v : null;
}

// 缺失/非法的维度标签中文名列表（三维度齐备时返回 []）：「确定」与组内加卡的硬门槛用
export function missingCardTags(card) {
  const labels = { type: '类型', scene: '场景', theme: '主题' };
  const missing = [];
  for (const f of Object.keys(CARD_TAG_FIELDS)) {
    if (!cleanCardTagValue(f, card ? card[f] : null)) {
      missing.push(labels[f]);
    }
  }
  return missing;
}

// 「时间」与「提醒时间」共用的绝对时间格式（与 AI 提示词要求一致）：
//   "YYYY-MM-DD HH:mm"，或时段 "YYYY-MM-DD HH:mm~HH:mm" / "YYYY-MM-DD HH:mm~YYYY-MM-DD HH:mm"
// 严禁「明天」「下周」等相对说法。
const ABSOLUTE_TIME_RE = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(~\d{2}:\d{2}|~\d{4}-\d{2}-\d{2} \d{2}:\d{2})?$/;

export function isValidAbsoluteTime(value) {
  return typeof value === 'string' && ABSOLUTE_TIME_RE.test(value.trim());
}

// 「提醒时间」是「确定」的前置条件：必须已由 AI 推荐写入，且格式与「时间」完全一致（绝对时间）
export function hasValidReminderTime(card) {
  return isValidAbsoluteTime(card ? card.reminderTime : null);
}

export function emptyCardContent() {
  return { purpose: null, event: null, time: null, repeatTime: null, repeatUntil: null, location: null, participant: null, initiator: null, reminderTime: null, friendOnly: null, capacity: MIN_CAPACITY, needApproval: null, type: null, scene: null, theme: null, tags: null };
}

export function normalizeContent(content) {
  if (typeof content === 'string') {
    return { ...emptyCardContent(), event: content.trim() || null };
  }
  if (content && typeof content === 'object' && !Array.isArray(content)) {
    const out = {};
    for (const f of CARD_FIELDS) {
      if (f === 'friendOnly') {
        // 卡片「仅好友」字段：true = 仅与发起者为好友关系的账号可见；null = 所有账号可见
        out[f] = content[f] === true ? true : null;
      } else if (f === 'capacity') {
        // 卡片「人数上限」：包含发起者本人，默认与最小值为 1
        out[f] = (Number.isInteger(content[f]) && content[f] >= MIN_CAPACITY) ? content[f] : MIN_CAPACITY;
      } else if (f === 'needApproval') {
        // 卡片「需要申请」字段：true = 他人加入前需发起者同意；null = 可直接加入
        out[f] = content[f] === true ? true : null;
      } else if (CARD_TAG_FIELDS[f]) {
        // 三维度标签（类型/场景/主题）：只收对应维度的合法枚举值，其余置 null
        // （旧数据没有标签时保持 null，由「确定」/组内加卡等创建门槛负责要求齐备）
        out[f] = cleanCardTagValue(f, content[f]);
      } else if (f === 'tags') {
        // 话题标签（#标签）：字符串数组，清洗后存数组，无有效标签存 null
        const topicTags = cleanCardTags(content[f]);
        out[f] = topicTags.length > 0 ? topicTags : null;
      } else {
        // 「时间」「提醒时间」等其余字段一律为字符串（提醒时间与时间同格式，均为绝对时间文本）
        out[f] = (typeof content[f] === 'string' && content[f].trim() !== '') ? content[f].trim() : null;
      }
    }
    // 「重复到何时」缺省规则：卡片未填写「重复到何时」时，默认取「时间」字段的值，保证每张卡片都有该字段
    if (out.repeatUntil === null && out.time !== null) {
      out.repeatUntil = out.time;
    }
    return out;
  }
  return null;
}

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

async function load() {
  await ensureFile();
  const text = await fs.readFile(FILE_PATH, 'utf8');
  cache = new Map();
  text.split(/\r?\n/)
    .filter(line => line.trim() !== '')
    .map(line => JSON.parse(line))
    .forEach(entry => cache.set(entry.index, entry));
}

async function ensureLoaded() {
  if (!loaded) {
    await load();
    loaded = true;
  }
}

async function persist() {
  const lines = [...cache.keys()]
    .sort((a, b) => a - b)
    .map(index => JSON.stringify(cache.get(index)));
  const text = lines.join('\n');
  await fs.writeFile(FILE_PATH, text === '' ? '' : text + '\n', 'utf8');
}

// 「人数」= 发起者本人 + 参与人总数（包含发起者，最小为 1）
export function participantCount(content) {
  if (!content || typeof content !== 'object') {
    return MIN_CAPACITY;
  }
  return MIN_CAPACITY + parseParticipants(content.participant).length;
}

function toSlot(index) {
  const entry = cache.get(index);
  const content = entry ? normalizeContent(entry.content) : null;
  if (content) {
    // 「人数」由发起者 + 参与人实时算出，不落库，避免与参与人字段不一致
    content.count = participantCount(content);
  }
  return {
    index,
    content,
    createdAt: entry?.createdAt ?? null,
    updatedAt: entry?.updatedAt ?? null
  };
}

function doSet(index, content) {
  const existing = cache.get(index);
  // count 是读取时算出的派生字段，落库前剔除，避免写入过期人数
  const stored = (content && typeof content === 'object' && !Array.isArray(content)) ? { ...content } : content;
  if (stored && typeof stored === 'object') {
    delete stored.count;
  }
  const entry = {
    index,
    content: stored,
    createdAt: existing?.createdAt ?? new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
  cache.set(index, entry);
  return persist().then(() => ({ ...entry }));
}

export function listCards() {
  return serialized(async () => {
    await ensureLoaded();
    const slots = [];
    for (let i = 1; i <= MAX_CARDS; i++) {
      slots.push(toSlot(i));
    }
    return slots;
  });
}

export function getCard(index) {
  return serialized(async () => {
    await ensureLoaded();
    return toSlot(index);
  });
}

export function setCard(index, content) {
  return serialized(() => ensureLoaded().then(() => doSet(index, content)));
}

export function addCard(content) {
  return serialized(async () => {
    await ensureLoaded();
    let freeIndex = 0;
    for (let i = 1; i <= MAX_CARDS; i++) {
      if (!cache.has(i)) {
        freeIndex = i;
        break;
      }
    }
    if (freeIndex === 0) {
      const err = new Error('card library is full');
      err.status = 409;
      throw err;
    }
    return doSet(freeIndex, content);
  });
}

export function clearCard(index) {
  return serialized(async () => {
    await ensureLoaded();
    const existing = cache.get(index);
    if (!existing) {
      return null;
    }
    cache.delete(index);
    await persist();
    return { ...existing };
  });
}

export function applyCards(cards) {
  return serialized(async () => {
    await ensureLoaded();
    if (!Array.isArray(cards)) {
      return [];
    }
    const saved = [];
    for (const card of cards) {
      if (!card || typeof card !== 'object') {
        continue;
      }
      const content = normalizeContent(card);
      if (content === null) {
        continue;
      }
      const idx = (Number.isInteger(card.index) && card.index >= 1 && card.index <= MAX_CARDS) ? card.index : null;
      let entry;
      if (idx !== null) {
        entry = await doSet(idx, content);
      } else {
        let freeIndex = 0;
        for (let i = 1; i <= MAX_CARDS; i++) {
          if (!cache.has(i)) {
            freeIndex = i;
            break;
          }
        }
        if (freeIndex === 0) {
          const err = new Error('card library is full');
          err.status = 409;
          throw err;
        }
        entry = await doSet(freeIndex, content);
      }
      saved.push(toSlot(entry.index));
    }
    return saved;
  });
}

// ---- 参与人字段（以 、/, 分隔的账号列表）解析与增删 ----
export function parseParticipants(participant) {
  if (typeof participant !== 'string' || participant.trim() === '') {
    return [];
  }
  return participant.split(/[、,，]/).map(s => s.trim()).filter(s => s !== '');
}

export function formatParticipants(list) {
  return list.length > 0 ? list.join('、') : null;
}

export function addParticipant(participant, account) {
  const list = parseParticipants(participant);
  if (!list.includes(account)) {
    list.push(account);
  }
  return formatParticipants(list);
}

export function removeParticipant(participant, account) {
  return formatParticipants(parseParticipants(participant).filter(a => a !== account));
}

// 改名级联：公开卡片库中该账号作为发起者/参与人的字段同步更新
export function renameAccountInPublicCards(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const entry of cache.values()) {
      let touched = false;
      if (entry.content && typeof entry.content === 'object') {
        if (entry.content.initiator === oldName) {
          entry.content.initiator = newName;
          touched = true;
        }
        const participants = parseParticipants(entry.content.participant);
        if (participants.includes(oldName)) {
          entry.content.participant = formatParticipants(participants.map(p => p === oldName ? newName : p));
          touched = true;
        }
      }
      if (touched) {
        entry.updatedAt = new Date().toISOString();
        changed += 1;
      }
    }
    if (changed > 0) {
      await persist();
    }
    return { changed };
  });
}

function accountName(account) {
  return typeof account === 'string' ? account.trim() : '';
}

// 加入卡片：把账号写入参与人字段（发起者/已参与者不可重复加入）
export function joinCard({ index, account }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (!name) {
      const err = new Error('需要账号身份才能加入');
      err.status = 400;
      throw err;
    }
    const slot = toSlot(index);
    if (!slot.content || !slot.content.event) {
      const err = new Error('卡片不存在');
      err.status = 404;
      throw err;
    }
    if (slot.content.initiator === name) {
      const err = new Error('发起者无需加入自己的卡片');
      err.status = 400;
      throw err;
    }
    // 人数已达上限时不允许再加入（「人数」含发起者本人）；已是参与者的重复加入不受限
    const already = parseParticipants(slot.content.participant).includes(name);
    if (!already && slot.content.count >= slot.content.capacity) {
      const err = new Error(`人数已达上限（${slot.content.capacity} 人），无法加入`);
      err.status = 409;
      throw err;
    }
    // 「需要申请」的卡片不能直接加入，必须先向发起者发起申请并获同意
    if (!already && slot.content.needApproval === true) {
      const err = new Error('该卡片需要发起者同意，请先发送加入申请');
      err.status = 409;
      throw err;
    }
    const next = { ...slot.content, participant: addParticipant(slot.content.participant, name) };
    const entry = await doSet(index, next);
    return toSlot(entry.index);
  });
}

// 审批通过后加入：发起者同意其申请，等同于直接加入（不再校验「需要申请」，但仍受人数上限约束）
export function joinCardByApproval({ index, account }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (!name) {
      const err = new Error('需要账号身份才能加入');
      err.status = 400;
      throw err;
    }
    const slot = toSlot(index);
    if (!slot.content || !slot.content.event) {
      const err = new Error('卡片不存在');
      err.status = 404;
      throw err;
    }
    if (slot.content.initiator === name) {
      const err = new Error('发起者无需加入自己的卡片');
      err.status = 400;
      throw err;
    }
    const already = parseParticipants(slot.content.participant).includes(name);
    if (!already && slot.content.count >= slot.content.capacity) {
      const err = new Error(`人数已达上限（${slot.content.capacity} 人），无法加入`);
      err.status = 409;
      throw err;
    }
    const next = { ...slot.content, participant: addParticipant(slot.content.participant, name) };
    const entry = await doSet(index, next);
    return toSlot(entry.index);
  });
}

// 退出卡片：把账号从参与人字段移除（发起者不可退出）
export function leaveCard({ index, account }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (!name) {
      const err = new Error('需要账号身份才能退出');
      err.status = 400;
      throw err;
    }
    const slot = toSlot(index);
    if (!slot.content || !slot.content.event) {
      const err = new Error('卡片不存在');
      err.status = 404;
      throw err;
    }
    if (slot.content.initiator === name) {
      const err = new Error('发起者不可退出自己的卡片');
      err.status = 400;
      throw err;
    }
    const next = { ...slot.content, participant: removeParticipant(slot.content.participant, name) };
    const entry = await doSet(index, next);
    return toSlot(entry.index);
  });
}

// 发起者移除参与者：无需申请，直接把该账号从参与人字段删去；
// 该账号的私人卡片库按「发起者=我 或 参与人含我」渲染，因此卡片会同时从对方卡片库消失
export function removeParticipantByOwner({ index, account, targetAccount }) {
  return serialized(async () => {
    await ensureLoaded();
    const owner = accountName(account);
    const target = accountName(targetAccount);
    if (!owner || !target) {
      const err = new Error('需要发起者与参与者账号');
      err.status = 400;
      throw err;
    }
    const slot = toSlot(index);
    if (!slot.content || !slot.content.event) {
      const err = new Error('卡片不存在');
      err.status = 404;
      throw err;
    }
    if (slot.content.initiator !== owner) {
      const err = new Error('只有卡片发起者才能删除参与者');
      err.status = 403;
      throw err;
    }
    if (!parseParticipants(slot.content.participant).includes(target)) {
      const err = new Error(`${target} 不是该卡片的参与者`);
      err.status = 409;
      throw err;
    }
    const next = { ...slot.content, participant: removeParticipant(slot.content.participant, target) };
    const entry = await doSet(index, next);
    return toSlot(entry.index);
  });
}

// 删除卡片：仅发起者可删除（发起者校验），其余账号无权删除
export function deleteOwnedCard({ index, account }) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (!name) {
      const err = new Error('需要账号身份（发起者）才能删除卡片');
      err.status = 400;
      throw err;
    }
    const existing = cache.get(index);
    if (!existing) {
      return null;
    }
    const slot = toSlot(index);
    if (slot.content && slot.content.initiator !== name) {
      const err = new Error('只有发起者才能删除该卡片');
      err.status = 403;
      throw err;
    }
    cache.delete(index);
    await persist();
    // 旧「公开卡片库」已由卡片组库取代：此函数仅为兼容保留，不再清理加入申请
    return { ...existing };
  });
}
