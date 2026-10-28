import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';
import { emptyCardContent, CARD_FIELDS, MIN_CAPACITY, participantCount, addParticipant, removeParticipant, parseParticipants, formatParticipants, isValidAbsoluteTime, CARD_TAG_FIELDS, cleanCardTagValue, cleanCardTags } from './cardStore.js';
import { parseUntil } from './conflictService.js';

const FILE_PATH = path.join(config.dataDir, 'working-card.json');

let cache = null;
let loaded = false;
let chain = Promise.resolve();

function serialized(task) {
  const run = chain.then(task, task);
  chain = run.then(() => {}, () => {});
  return run;
}

function cleanField(field, value) {
  // 「提醒时间」与「时间」同格式：都是绝对时间字符串（YYYY-MM-DD HH:mm，可带时段），走下面的字符串分支
  if (field === 'friendOnly') {
    return value === true ? true : null;
  }
  if (field === 'capacity') {
    return (Number.isInteger(value) && value >= MIN_CAPACITY) ? value : null;
  }
  if (field === 'needApproval') {
    return value === true ? true : null;
  }
  // 三维度标签：只收对应维度的合法枚举值（AI 偶发自创取值时忽略、不写入，保持该字段现状）
  if (CARD_TAG_FIELDS[field]) {
    return cleanCardTagValue(field, value);
  }
  // 话题标签（#标签）：数组或分隔字符串，清洗后非空才写入（AI 未提及 = 保持现状）
  if (field === 'tags') {
    const topicTags = cleanCardTags(value);
    return topicTags.length > 0 ? topicTags : null;
  }
  return (typeof value === 'string' && value.trim() !== '') ? value.trim() : null;
}

function normalizeCard(raw) {
  const out = emptyCardContent();
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const f of CARD_FIELDS) {
      const v = cleanField(f, raw[f]);
      if (v !== null) {
        out[f] = v;
      }
    }
  }
  return out;
}

// 卡片「公开/私人」字段：设置卡片时默认「私人」，只有显式 true 才视为公开
function normalizePublic(value) {
  return value === true;
}

// 卡片「仅好友」字段：默认关闭（false），仅在「公开」卡片上生效
function normalizeFriendOnly(value) {
  return value === true;
}

// 卡片「需要申请」字段：默认关闭（false），仅在「公开」卡片上生效
function normalizeNeedApproval(value) {
  return value === true;
}

// 「公开/私人」与「人数上限」绑定：上限 > 1 一定为公开；上限 = 1 一定为私人，且私人卡片只有发起者本人（清空参与人）
function enforceVisibilityCapacity() {
  const cap = (Number.isInteger(cache.card.capacity) && cache.card.capacity >= MIN_CAPACITY) ? cache.card.capacity : MIN_CAPACITY;
  if (cap > MIN_CAPACITY) {
    cache.card.capacity = cap;
    cache.public = true;
  } else {
    cache.card.capacity = MIN_CAPACITY;
    cache.public = false;
    cache.card.participant = null;
  }
}

// 用户切换「公开/私人」：切为公开时人数上限默认增加至 2；切为私人时上限还原为 1 并清空参与人
function applyPublicFlag(isPublic) {
  cache.public = normalizePublic(isPublic);
  if (cache.public) {
    if (cache.card.capacity <= MIN_CAPACITY) {
      cache.card.capacity = MIN_CAPACITY + 1;
    }
  } else {
    cache.card.capacity = MIN_CAPACITY;
    cache.card.participant = null;
  }
}

function snapshot() {
  const card = { ...cache.card };
  // 「人数」= 发起者本人 + 参与人总数，读取时实时算出
  card.count = participantCount(card);
  return { card, public: cache.public, friendOnly: cache.friendOnly, needApproval: cache.needApproval };
}

async function ensureFile() {
  await fs.mkdir(config.dataDir, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, JSON.stringify({ card: emptyCardContent(), public: false, friendOnly: false, needApproval: false }), 'utf8');
  }
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xFEFF ? text.slice(1) : text;
}

async function load() {
  await ensureFile();
  try {
    const data = JSON.parse(stripBom(await fs.readFile(FILE_PATH, 'utf8')));
    cache = { card: normalizeCard(data.card), public: normalizePublic(data.public), friendOnly: normalizeFriendOnly(data.friendOnly), needApproval: normalizeNeedApproval(data.needApproval) };
  } catch {
    cache = { card: emptyCardContent(), public: false, friendOnly: false, needApproval: false };
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

export function getWorkingCard() {
  return serialized(async () => {
    await ensureLoaded();
    return snapshot();
  });
}

export function updateWorkingCard(partial) {
  return serialized(async () => {
    await ensureLoaded();
    if (partial && typeof partial === 'object' && !Array.isArray(partial)) {
      for (const f of CARD_FIELDS) {
        if (f === 'initiator') {
          continue; // 「发起者」= 点「确定」的账号，由服务器在确定时写入，AI 不得修改
        }
        if (f === 'friendOnly' || f === 'needApproval') {
          // 这两个字段同时存在于「工作卡状态」与「卡片字段」，两处需保持同步；
          // AI 只有明确给出 true / false 才改动，null（未提及）表示保持现状
          if (partial[f] === true || partial[f] === false) {
            if (f === 'friendOnly') {
              cache.friendOnly = normalizeFriendOnly(partial[f]);
              cache.card.friendOnly = cache.friendOnly ? true : null;
            } else {
              cache.needApproval = normalizeNeedApproval(partial[f]);
              cache.card.needApproval = cache.needApproval ? true : null;
            }
          }
          continue;
        }
        const v = cleanField(f, partial[f]);
        if (v !== null) {
          // 「重复到何时」必须是单一绝对日期/日期时间（YYYY-MM-DD 或 YYYY-MM-DD HH:mm）：
          // AI 偶发把已有卡片的时间段（含 ~）搬运进该字段（用户并未输入），不合法取值一律不写入，
          // 保持该字段现状，从 AI 写入口挡住「未输入却被自动赋值」
          if (f === 'repeatUntil' && parseUntil(v) === null) {
            continue;
          }
          cache.card[f] = v;
        }
      }
      // 「公开/私人」存在工作卡状态上：明确给出 true / false 时按绑定规则联动人数上限与参与人
      if (partial.public === true || partial.public === false) {
        applyPublicFlag(partial.public);
      }
      enforceVisibilityCapacity();
    }
    await persist();
    return snapshot();
  });
}

export function resetWorkingCard() {
  return serialized(async () => {
    await ensureLoaded();
    cache = { card: emptyCardContent(), public: false, friendOnly: false, needApproval: false };
    await persist();
    return snapshot();
  });
}

// 选取一张已有卡片成为「正在设置卡片」（服务 76）：把该卡片的内容整份载入工作卡。
// 「发起者」不随选取带入（仍由「确定」时的账号写入）；公开/私人按来源卡片组决定，
// 私人状态下参与人清空、人数上限还原为 1（与 enforceVisibilityCapacity 规则一致）。
// 手动制作（51）与 AI 对话（0）都作用于同一张工作卡，故本选取功能两端天然共用。
export function loadWorkingCardFromCard(content, library) {
  return serialized(async () => {
    await ensureLoaded();
    const card = normalizeCard(content);
    card.initiator = null;
    cache.card = card;
    cache.public = normalizePublic(library === 'public');
    cache.friendOnly = normalizeFriendOnly(content?.friendOnly);
    cache.needApproval = normalizeNeedApproval(content?.needApproval);
    cache.card.friendOnly = cache.friendOnly ? true : null;
    cache.card.needApproval = cache.needApproval ? true : null;
    if (cache.public && cache.card.capacity <= MIN_CAPACITY) {
      cache.card.capacity = MIN_CAPACITY + 1;
    }
    enforceVisibilityCapacity();
    await persist();
    return snapshot();
  });
}

// 切换当前卡片的「公开/私人」：与人数上限绑定（公开 → 上限至少 2；私人 → 上限 1 且清空参与人）
export function setWorkingCardPublic(isPublic) {
  return serialized(async () => {
    await ensureLoaded();
    applyPublicFlag(isPublic);
    await persist();
    return snapshot();
  });
}

// 切换当前卡片的「仅好友」：仅在「公开」卡片上生效，客户端点「确定」前可用
export function setWorkingCardFriendOnly(friendOnly) {
  return serialized(async () => {
    await ensureLoaded();
    cache.friendOnly = normalizeFriendOnly(friendOnly);
    await persist();
    return snapshot();
  });
}

// 设置当前卡片的「人数上限」：与公开/私人绑定（> 1 → 公开；= 1 → 私人且清空参与人）
export function setWorkingCardCapacity(capacity) {
  return serialized(async () => {
    await ensureLoaded();
    cache.card.capacity = (Number.isInteger(capacity) && capacity >= MIN_CAPACITY) ? capacity : MIN_CAPACITY;
    enforceVisibilityCapacity();
    await persist();
    return snapshot();
  });
}

// 切换当前卡片的「需要申请」：仅在「公开」卡片上生效，客户端点「确定」前可用
export function setWorkingCardNeedApproval(needApproval) {
  return serialized(async () => {
    await ensureLoaded();
    cache.needApproval = normalizeNeedApproval(needApproval);
    await persist();
    return snapshot();
  });
}

// 邀请：把账号加入工作卡的参与人字段（同一账号只保留一次）
export function addWorkingCardParticipant(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    if (!name) {
      const err = new Error('需要账号才能邀请');
      err.status = 400;
      throw err;
    }
    cache.card.participant = addParticipant(cache.card.participant, name);
    enforceVisibilityCapacity();
    await persist();
    return snapshot();
  });
}

// 取消邀请：把账号从工作卡的参与人字段移除（确定卡片前参与者可增可减）
export function removeWorkingCardParticipant(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = typeof account === 'string' ? account.trim() : '';
    if (!name) {
      const err = new Error('需要账号才能移出');
      err.status = 400;
      throw err;
    }
    cache.card.participant = removeParticipant(cache.card.participant, name);
    await persist();
    return snapshot();
  });
}

// 改名级联：工作卡草稿的参与人列表同步更新
export function renameWorkingCardParticipant(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    const participants = parseParticipants(cache.card.participant);
    if (!participants.includes(oldName)) {
      return { changed: 0 };
    }
    cache.card.participant = formatParticipants(participants.map(p => p === oldName ? newName : p));
    await persist();
    return { changed: 1 };
  });
}

export function isWorkingCardFilled(card) {
  return !!(card && card.purpose && card.event && card.time);
}

// 手动编辑工作卡的文本字段（客户端「手动制作卡片」表单用）。
// 与 AI 的 updateWorkingCard（未提及保持不变、空值忽略）语义不同：
// 这里「字段出现在请求中」就写入：空字符串 / null = 清空该字段，未出现 = 保持不变。
// 「时间」「提醒时间」非空时必须为绝对时间（YYYY-MM-DD HH:mm，可带 ~ 时段），格式不符报 400。
// type / scene / theme 三维度标签非空时必须是对应维度的合法枚举值（选择器点选），否则报 400。
// tags 话题标签（#标签）接受字符串数组或「#、,，空白」分隔字符串：清洗（≤5 个、每个 ≤12 字符）
// 后写入，无有效标签 = 清空；与三维度标签相互独立，可 AI 自动生成也可用户自定义。
// capacity / friendOnly / needApproval / participant / initiator 不在此接受：
// 前四者有专用服务（24 / 22 / 29 / 31 / 32）并带联动规则，发起者由「确定」时的账号写入。
const MANUAL_EDIT_FIELDS = ['purpose', 'event', 'time', 'reminderTime', 'repeatTime', 'repeatUntil', 'location', 'type', 'scene', 'theme', 'tags'];

export function editWorkingCardFields(fields) {
  return serialized(async () => {
    await ensureLoaded();
    if (!fields || typeof fields !== 'object' || Array.isArray(fields)) {
      const err = new Error('fields 必须是包含卡片字段的对象');
      err.status = 400;
      throw err;
    }
    let touched = 0;
    for (const f of MANUAL_EDIT_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(fields, f)) {
        continue;
      }
      const raw = fields[f];
      if (raw === null || raw === undefined) {
        cache.card[f] = null;
        touched += 1;
        continue;
      }
      // 话题标签：接受数组或分隔字符串，清洗后写入；无有效标签视为清空
      if (f === 'tags') {
        const topicTags = cleanCardTags(raw);
        cache.card.tags = topicTags.length > 0 ? topicTags : null;
        touched += 1;
        continue;
      }
      if (typeof raw !== 'string') {
        const err = new Error(`字段 ${f} 必须是字符串`);
        err.status = 400;
        throw err;
      }
      const value = raw.trim();
      if (value === '') {
        cache.card[f] = null;
        touched += 1;
        continue;
      }
      if ((f === 'time' || f === 'reminderTime') && !isValidAbsoluteTime(value)) {
        const err = new Error(`「${f === 'time' ? '时间' : '提醒时间'}」必须为绝对时间（YYYY-MM-DD HH:mm，可带 ~ 时段），如 2026-10-02 10:00`);
        err.status = 400;
        throw err;
      }
      if (CARD_TAG_FIELDS[f] && !cleanCardTagValue(f, value)) {
        const err = new Error(`「${f}」标签取值无效：请从 ${CARD_TAG_FIELDS[f].join(' / ')} 中选择（客户端为点选，不接受自定义值）`);
        err.status = 400;
        throw err;
      }
      cache.card[f] = value;
      touched += 1;
    }
    if (touched === 0) {
      const err = new Error('没有要写入的字段：请在 fields 中给出 purpose / event / time 等卡片字段');
      err.status = 400;
      throw err;
    }
    await persist();
    return snapshot();
  });
}
