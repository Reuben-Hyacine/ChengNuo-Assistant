import { promises as fs } from 'node:fs';
import path from 'node:path';
import { config } from '../config.js';
import { normalizeContent, parseParticipants, formatParticipants, addParticipant, removeParticipant, isValidAbsoluteTime, MIN_CAPACITY, CARD_TAG_FIELDS, cleanCardTagValue, cleanCardTags } from './cardStore.js';
import { findAccount } from './accountStore.js';
import { areFriends } from './friend.service.js';
import { removeCardRequestsByGroupCard, removeCardRequestsByGroup, removeCardRequestsByAccount } from './cardRequestStore.js';
import { removeExtendRequestsByGroupCard, removeExtendRequestsByGroup, removeExtendRequestsByAccount } from './cardExtendStore.js';
import { removeGroupJoinRequestsByGroup } from './groupJoinStore.js';
import { recordTombstone, isStaleDeletedCopy } from './privateGroupTombstoneStore.js';
import { pushMail } from './mailboxStore.js';
import { parseDateTime, parseTimeRange, parseUntil, formatRange, formatDateTime } from './conflictService.js';
import { reminderOffsetMs } from './reminderService.js';
import { clearRemindersByCard } from './reminderStore.js';
import { checkContent, checkText, moderationPrefix } from './moderation.service.js';
import { enqueueClears } from './postcardOutbox.js';

// 卡片组库（统一卡片存储）：每张卡片都存放在某个卡片组里，组是唯一的卡片容器。
//   library='public'  → 公开卡片组库：所有人可浏览（组内「仅好友」卡片只对组创建者的好友可见），可加入组内卡片
//   library='private' → 私人卡片组库：仅创建者（及被邀请加入的成员）可见
// 卡片的创建路径（AI 对话确定 / 手动制作确定 / 组内添加）都会自动归入某个卡片组：
// AI 确定 / 手动确定时服务器自动创建一个同名卡片组收纳该卡（createGroupForCard）。
// 「完成权限」：创建者可指定组内一名成员获得某张卡片的「删除=完成」权限（completableBy）；
// 被指定的成员（或创建者本人）可把卡片标记为已完成（completedAt/completedBy）——
// 已完成的卡片不再提醒、归档展示，但记录保留可查看；创建者始终可真删卡片（removeGroupCard）。
const FILE_PATH = path.join(config.dataDir, config.cardGroupFile);

export const MAX_GROUPS_PER_ACCOUNT = 20; // 每个账号最多创建 20 个卡片组（公开 + 私人合计）
export const MAX_CARDS_PER_GROUP = 10;    // 每个卡片组最多 10 张卡片
export const MAX_GROUP_NAME_LEN = 60;     // 组名最长 60 字符
export const MAX_GROUP_INTRO_LEN = 200;   // 组简介（公开招募展示）最长 200 字
export const MAX_GROUP_AUDIENCE_LEN = 50; // 目标受众最长 50 字
export const MAX_GROUP_COVER_BASE64_LEN = 400000; // 组封面 base64 最长 40 万字符（约 300KB JPEG，客户端压缩到 640 边）
const MAX_GROUP_MEMBER_CAP = 99;          // 组人数上限（含创建者）最大值

// 组内卡片可手动填写的文本字段（与「手动制作卡片」一致）；
// capacity 单独接收（公开组内卡片至少 2、私人组内卡片至少 1）；friendOnly / needApproval 仅公开组的卡片生效
const GROUP_CARD_TEXT_FIELDS = ['purpose', 'event', 'location', 'time', 'reminderTime', 'repeatTime', 'repeatUntil'];

let cache = new Map(); // id -> group
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

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function notFound(message) {
  const err = new Error(message);
  err.status = 404;
  return err;
}

function forbidden(message) {
  const err = new Error(message);
  err.status = 403;
  return err;
}

function conflict(message) {
  const err = new Error(message);
  err.status = 409;
  return err;
}

async function ensureFile() {
  await fs.mkdir(config.dataDir, { recursive: true });
  try {
    await fs.access(FILE_PATH);
  } catch {
    await fs.writeFile(FILE_PATH, '', 'utf8');
  }
}

function normalizeLibrary(value) {
  return value === 'private' ? 'private' : 'public';
}

// 组加入模式（二期「组加入审核」）：open=自由加入 / review=审核加入（加入整组须创建者同意）
function normalizeJoinMode(value) {
  return value === 'review' ? 'review' : 'open';
}

// 组内卡片的 content 校验：event 必填；time / reminderTime 非空时必须是绝对时间；
// capacity：公开组内卡片至少 2（保证好友能加入），私人组内卡片至少 1；
// friendOnly / needApproval 仅公开组的卡片生效，私人组强制为 null；
// 三维度标签（类型 / 场景 / 主题）默认必须齐备且为合法枚举值，
// opts.requireTags=false 时宽松处理（延期等服务对历史无标签卡片放行，标签保持原状）
function normalizeGroupCardContent(fields, library, opts) {
  if (!fields || typeof fields !== 'object' || Array.isArray(fields)) {
    throw badRequest('卡片内容必须是包含目的/事件/时间等字段的对象');
  }
  const requireTags = !opts || opts.requireTags !== false;
  const minCapacity = library === 'private' ? MIN_CAPACITY : 2;
  const cleaned = {};
  for (const f of GROUP_CARD_TEXT_FIELDS) {
    if (!Object.prototype.hasOwnProperty.call(fields, f)) {
      cleaned[f] = null;
      continue;
    }
    const raw = fields[f];
    if (raw === null || raw === undefined) {
      cleaned[f] = null;
      continue;
    }
    if (typeof raw !== 'string') {
      throw badRequest(`字段 ${f} 必须是字符串`);
    }
    const value = raw.trim();
    if (value === '') {
      cleaned[f] = null;
      continue;
    }
    if ((f === 'time' || f === 'reminderTime') && !isValidAbsoluteTime(value)) {
      throw badRequest(`「${f === 'time' ? '时间' : '提醒时间'}」必须为绝对时间（YYYY-MM-DD HH:mm，可带 ~ 时段），如 2026-10-02 10:00`);
    }
    cleaned[f] = value;
  }
  if (!cleaned.event) {
    throw badRequest('「事件」不能为空');
  }
  // 三维度标签（类型 / 场景 / 主题）：每张卡片必须三维度齐备，且取值为对应维度的合法枚举值
  // （客户端为点选；AI 对话 / 手动制作的标签由工作卡带出，此处兜底校验；
  //   延期等对历史无标签卡片操作的场景传 requireTags=false 放行，标签保持原状）
  const tagLabels = { type: '类型', scene: '场景', theme: '主题' };
  const tags = {};
  for (const f of Object.keys(CARD_TAG_FIELDS)) {
    const v = cleanCardTagValue(f, fields[f]);
    if (!v && requireTags) {
      throw badRequest(`卡片缺少「${tagLabels[f]}」维度标签或取值无效：请从 ${CARD_TAG_FIELDS[f].join(' / ')} 中选择`);
    }
    tags[f] = v;
  }
  const capacity = (Number.isInteger(fields.capacity) && fields.capacity >= minCapacity) ? fields.capacity : minCapacity;
  // 话题标签（#标签）：随卡片内容透传（normalizeContent 内清洗，无有效标签存 null）
  return { ...normalizeContent({ ...cleaned, ...tags, tags: fields.tags ?? null }), capacity };
}

async function load() {
  await ensureFile();
  const text = stripBom(await fs.readFile(FILE_PATH, 'utf8'));
  cache = new Map();
  nextId = 1;
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() === '') {
      continue;
    }
    try {
      const parsed = JSON.parse(line);
      const id = Number(parsed.id);
      const owner = accountName(parsed.account);
      if (!Number.isInteger(id) || id < 1 || owner === '') {
        continue;
      }
      const name = typeof parsed.name === 'string' ? parsed.name.trim().slice(0, MAX_GROUP_NAME_LEN) : '';
      if (name === '') {
        continue;
      }
      const library = normalizeLibrary(parsed.library);
      // 组加入模式（106 设置）：open=自由加入 / review=审核加入；历史数据缺省回填 open
      const joinMode = normalizeJoinMode(parsed.joinMode);
      // 组简介 / 目标受众（服务 105 设置）：私人组可预先填好，转公开后展示；载入时夹紧长度
      const intro = typeof parsed.intro === 'string' ? parsed.intro.trim().slice(0, MAX_GROUP_INTRO_LEN) : null;
      const audience = typeof parsed.audience === 'string' ? parsed.audience.trim().slice(0, MAX_GROUP_AUDIENCE_LEN) : null;
      // 组人数上限（服务 98 设置）：组总人数上限（含创建者），2~99 整数，null = 不限；历史数据缺省回填 null
      const memberCap = Number.isInteger(parsed.memberCap) && parsed.memberCap >= 2 && parsed.memberCap <= MAX_GROUP_MEMBER_CAP ? parsed.memberCap : null;
      // 组封面（服务 105 上传 / 112 拉取）：base64 JPEG + 更新时间戳；缺失/超长/损坏数据按无封面兜底
      const cover = typeof parsed.cover === 'string' && parsed.cover.length > 0 && parsed.cover.length <= MAX_GROUP_COVER_BASE64_LEN ? parsed.cover : null;
      const coverUpdatedAt = cover !== null && typeof parsed.coverUpdatedAt === 'string' ? parsed.coverUpdatedAt : null;
      const cards = [];
      for (const card of Array.isArray(parsed.cards) ? parsed.cards : []) {
        const index = Number(card?.index);
        const content = normalizeContent(card?.content);
        if (!Number.isInteger(index) || index < 1 || index > MAX_CARDS_PER_GROUP || !content || !content.event) {
          continue;
        }
        if (library === 'private') {
          content.friendOnly = null;
          content.needApproval = null;
        }
        cards.push({
          index,
          content,
          // 私人卡片组的卡片固定由发起者（创建者）作为完成者，载入时一律拉齐
          completableBy: library === 'private'
            ? owner
            : (typeof card.completableBy === 'string' && card.completableBy.trim() !== '' ? card.completableBy.trim() : null),
          completedAt: typeof card.completedAt === 'string' ? card.completedAt : null,
          completedBy: typeof card.completedBy === 'string' ? card.completedBy : null,
          createdAt: typeof card.createdAt === 'string' ? card.createdAt : new Date().toISOString(),
          updatedAt: typeof card.updatedAt === 'string' ? card.updatedAt : new Date().toISOString()
        });
      }
      cards.sort((a, b) => a.index - b.index);
      cache.set(id, {
        id,
        account: owner,
        name,
        library,
        joinMode,
        intro,
        audience,
        memberCap,
        cover,
        coverUpdatedAt,
        member: typeof parsed.member === 'string' ? parsed.member : null,
        cards,
        createdAt: typeof parsed.createdAt === 'string' ? parsed.createdAt : new Date().toISOString(),
        updatedAt: typeof parsed.updatedAt === 'string' ? parsed.updatedAt : new Date().toISOString()
      });
      if (id >= nextId) {
        nextId = id + 1;
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
  const lines = [...cache.values()]
    .sort((a, b) => a.id - b.id)
    .map(group => JSON.stringify(group));
  await fs.writeFile(FILE_PATH, lines.length ? lines.join('\n') + '\n' : '', 'utf8');
}

// 读取视图：卡片附实时「人数」（发起者 + 参与人），role 为查看者视角（owner=创建者 / member=成员 / null=无关）
function view(group, viewer, options = {}) {
  const name = accountName(viewer);
  const members = parseParticipants(group.member);
  const isOwner = name === group.account;
  const isMember = members.includes(name);
  let cards = group.cards;
  // 公开卡片组库浏览者（非创建者/成员）：「仅好友」卡片只对创建者的好友可见
  if (!isOwner && !isMember && group.library === 'public' && Array.isArray(options.visibleCardIndexes)) {
    cards = group.cards.filter(c => options.visibleCardIndexes.includes(c.index));
  }
  return {
    id: group.id,
    name: group.name,
    owner: group.account,
    role: isOwner ? 'owner' : (isMember ? 'member' : null),
    library: group.library,
    // 组加入模式：open=自由加入 / review=审核加入（加入整组须创建者同意）
    joinMode: group.joinMode ?? 'open',
    // 组简介 / 目标受众：公开招募展示（发现页卡片摘要与「⋯ → 组简介」全文）
    intro: group.intro ?? null,
    audience: group.audience ?? null,
    // 组封面：hasCover + coverUpdatedAt 轻摘要（列表/详情不下发图片本体，原图走服务 112 按需拉取）
    hasCover: typeof group.cover === 'string' && group.cover.length > 0,
    coverUpdatedAt: group.coverUpdatedAt ?? null,
    members,
    memberCount: members.length,
    // 组人数上限（服务 98 设置）：组总人数上限（含创建者），null = 不限
    memberCap: group.memberCap ?? null,
    cardCount: group.cards.length,
    visibleCardCount: cards.length,
    cards: cards.map(card => ({
      index: card.index,
      content: { ...card.content, count: MIN_CAPACITY + parseParticipants(card.content.participant).length },
      // 私人卡片组的卡片固定由发起者（创建者）作为完成者：读取时一律派生，不依赖落库时的快照
      completableBy: group.library === 'private' ? group.account : card.completableBy,
      completedAt: card.completedAt,
      completedBy: card.completedBy,
      createdAt: card.createdAt,
      updatedAt: card.updatedAt
    })),
    createdAt: group.createdAt,
    updatedAt: group.updatedAt
  };
}

async function findGroup(id) {
  await ensureLoaded();
  if (!Number.isInteger(id) || id < 1) {
    throw badRequest('groupId must be a positive integer');
  }
  const group = cache.get(id) ?? null;
  if (!group) {
    throw notFound('卡片组不存在');
  }
  return group;
}

// 组内卡片定位（参与/审批/完成权限都以「组号 + 组内编号」定位一张卡片）
function findCard(group, cardIndex) {
  if (!Number.isInteger(cardIndex) || cardIndex < 1 || cardIndex > MAX_CARDS_PER_GROUP) {
    throw badRequest('cardIndex must be an integer 1-' + MAX_CARDS_PER_GROUP);
  }
  const card = group.cards.find(c => c.index === cardIndex);
  if (!card) {
    throw notFound('组内卡片不存在');
  }
  return card;
}

// 「仅好友」卡片的可见性：创建者与成员始终可见；其余查看者须与组创建者是好友
async function visibleCardIndexesFor(group, viewer) {
  const name = accountName(viewer);
  if (name === '' || name === group.account || parseParticipants(group.member).includes(name)) {
    return group.cards.map(c => c.index);
  }
  const owner = await findAccount(group.account);
  if (!owner) {
    return group.cards.filter(c => c.content.friendOnly !== true).map(c => c.index);
  }
  const me = await findAccount(name);
  const friends = !me ? false : await areFriends(me.userId, owner.userId);
  if (friends) {
    return group.cards.map(c => c.index);
  }
  return group.cards.filter(c => c.content.friendOnly !== true).map(c => c.index);
}

async function assertGroupCapacity(owner) {
  let owned = 0;
  for (const g of cache.values()) {
    if (g.account === owner) {
      owned += 1;
    }
  }
  if (owned >= MAX_GROUPS_PER_ACCOUNT) {
    throw conflict(`卡片组已满（每个账号最多创建 ${MAX_GROUPS_PER_ACCOUNT} 个）`);
  }
}

// 创建卡片组（可带首张卡片）：手动创建空组（服务 53）与「确定卡片自动建组」（aiAskService）共用
export function createGroup(account, name, options = {}) {
  return serialized(async () => {
    await ensureLoaded();
    const owner = accountName(account);
    if (owner === '') {
      throw badRequest('需要账号身份才能创建卡片组');
    }
    const groupName = typeof name === 'string' ? name.trim().slice(0, MAX_GROUP_NAME_LEN) : '';
    if (groupName === '') {
      throw badRequest('卡片组名称不能为空（最长 60 字符）');
    }
    await assertGroupCapacity(owner);
    const library = normalizeLibrary(options.library);
    // 智能审核：新组进入公开卡片组库前审核组名与首张卡片内容（手动建组与「确定」自动建组共用）
    if (library === 'public') {
      const moderation = checkContent({ name: groupName, firstCard: options.firstCard ?? null });
      if (!moderation.pass) {
        throw conflict(`${moderationPrefix(moderation)}，无法进入公开卡片组库`);
      }
    }
    const now = new Date().toISOString();
    const group = { id: nextId++, account: owner, name: groupName, library, joinMode: 'open', memberCap: null, member: null, cards: [], createdAt: now, updatedAt: now };
    if (options.firstCard) {
      const card = await buildCard(group, options.firstCard, owner);
      group.cards.push(card);
    }
    cache.set(group.id, group);
    await persist();
    return view(group, owner);
  });
}

// 「确定卡片」自动建组：AI 对话确定 / 手动制作确定时调用——创建一个与卡片同名（取事件名）的卡片组收纳该卡。
// 公开卡片 → 公开卡片组库（人数上限至少 2）；私人卡片 → 私人卡片组库（仅本人可见）
export function createGroupForCard(account, content, options = {}) {
  const event = typeof content?.event === 'string' ? content.event.trim() : '';
  const purpose = typeof content?.purpose === 'string' ? content.purpose.trim() : '';
  const name = (event || purpose || '未命名卡片').slice(0, MAX_GROUP_NAME_LEN);
  return createGroup(account, name, { library: options.library, firstCard: content });
}

// 组内新卡片：占用组内最小空闲编号，发起者 = 组创建者
async function buildCard(group, fields, owner) {
  if (group.cards.length >= MAX_CARDS_PER_GROUP) {
    throw conflict(`组内卡片已满（每个卡片组最多 ${MAX_CARDS_PER_GROUP} 张）`);
  }
  const content = normalizeGroupCardContent(fields, group.library);
  content.initiator = owner;
  // 「仅好友 / 需要申请」只在公开卡片组的卡片上生效（AI 工作卡与手动建卡可设置，随卡片带入组内）
  if (group.library === 'public') {
    content.friendOnly = fields.friendOnly === true ? true : null;
    content.needApproval = fields.needApproval === true ? true : null;
    // 参与人随卡带入（私人组人数上限为 1，不收参与人；与工作卡 enforceVisibilityCapacity 规则一致）
    if (typeof fields.participant === 'string' && fields.participant.trim() !== '') {
      content.participant = fields.participant.trim();
    }
  }
  let freeIndex = 0;
  for (let i = 1; i <= MAX_CARDS_PER_GROUP; i++) {
    if (!group.cards.some(c => c.index === i)) {
      freeIndex = i;
      break;
    }
  }
  const now = new Date().toISOString();
  // 私人卡片组：没有其他成员，发起者（创建者）默认即为完成者，且不允许修改
  const completableBy = group.library === 'private' ? owner : null;
  return { index: freeIndex, content, completableBy, completedAt: null, completedBy: null, createdAt: now, updatedAt: now };
}

// 我可见的卡片组：我创建的（公开 + 私人）+ 我已加入（成员）的
export function listGroupsVisibleTo(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能查看卡片组');
    }
    return [...cache.values()]
      .filter(g => g.account === name || parseParticipants(g.member).includes(name))
      .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1))
      .map(g => view(g, name));
  });
}

// 我的私人卡片组库：仅我创建、library='private' 的组（服务 37）
export function listPrivateGroupsOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能查看私人卡片组库');
    }
    return [...cache.values()]
      .filter(g => g.account === name && g.library === 'private')
      .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1))
      .map(g => view(g, name));
  });
}

// 周报统计（服务 74）：我「设置或参与」的全部卡片——我创建的组内卡片、我是参与人的卡片、我是卡片发起者的卡片。
// 只返回定位与内容，不做时间过滤（周交集由 report.service 用 conflictService 展开判断）。
export function listMyRelatedCards(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能统计周报');
    }
    const out = [];
    for (const group of [...cache.values()].sort((a, b) => a.id - b.id)) {
      for (const card of group.cards) {
        const related = group.account === name
          || card.content.initiator === name
          || parseParticipants(card.content.participant).includes(name);
        if (!related) {
          continue;
        }
        out.push({ groupId: group.id, cardIndex: card.index, content: { ...card.content } });
      }
    }
    return out;
  });
}

// 某账号当前拥有的卡片组数量（创建者视角）
function ownedGroupCount(owner) {
  let count = 0;
  for (const g of cache.values()) {
    if (g.account === owner) {
      count += 1;
    }
  }
  return count;
}

// 客户端上送的私人卡片组 → 内部结构（校验与载入时一致：组名必填、组内卡片要有事件、编号 1-10）
function normalizeUploadedPrivateGroup(parsed, owner) {
  const name = typeof parsed?.name === 'string' ? parsed.name.trim().slice(0, MAX_GROUP_NAME_LEN) : '';
  if (name === '') {
    return null;
  }
  const cards = [];
  for (const card of Array.isArray(parsed?.cards) ? parsed.cards : []) {
    const index = Number(card?.index);
    const content = normalizeContent(card?.content);
    if (!Number.isInteger(index) || index < 1 || index > MAX_CARDS_PER_GROUP || !content || !content.event) {
      continue;
    }
    content.friendOnly = null;
    content.needApproval = null;
    cards.push({
      index,
      content,
      // 私人卡片组的卡片固定由发起者（创建者）作为完成者，客户端上送的完成者一并忽略
      completableBy: owner,
      completedAt: typeof card.completedAt === 'string' ? card.completedAt : null,
      completedBy: typeof card.completedBy === 'string' ? card.completedBy : null,
      createdAt: typeof card.createdAt === 'string' ? card.createdAt : new Date().toISOString(),
      updatedAt: typeof card.updatedAt === 'string' ? card.updatedAt : new Date().toISOString()
    });
  }
  cards.sort((a, b) => a.index - b.index);
  const now = new Date().toISOString();
  const id = Number(parsed?.id);
  return {
    id: Number.isInteger(id) && id >= 1 ? id : null,
    account: owner,
    name,
    library: 'private',
    member: typeof parsed?.member === 'string' ? parsed.member : null,
    cards,
    createdAt: typeof parsed?.createdAt === 'string' ? parsed.createdAt : now,
    updatedAt: typeof parsed?.updatedAt === 'string' ? parsed.updatedAt : now
  };
}

// 私人卡片组同步（服务 63）：私人组在服务器与客户端双端存储。
// 客户端连接/登录时上送本地副本，此处按 updatedAt 合并（较新者胜），再把合并结果整体返回给客户端覆盖其副本。
// 组身份优先按 id 匹配（属于本账号且为私人组），其次按组名匹配；都不匹配则新建。
// 不传 groups 时只做拉取（返回服务器当前私人组），便于客户端刷新副本。
export function syncPrivateGroups(account, uploaded) {
  return serialized(async () => {
    await ensureLoaded();
    const owner = accountName(account);
    if (owner === '') {
      throw badRequest('需要账号身份才能同步私人卡片组');
    }
    if (Array.isArray(uploaded)) {
      let owned = ownedGroupCount(owner);
      for (const raw of uploaded) {
        const incoming = normalizeUploadedPrivateGroup(raw, owner);
        if (!incoming) {
          continue;
        }
        let existing = incoming.id !== null ? (cache.get(incoming.id) ?? null) : null;
        if (existing && (existing.account !== owner || existing.library !== 'private')) {
          existing = null;
        }
        if (!existing) {
          existing = [...cache.values()].find(g => g.account === owner && g.library === 'private' && g.name === incoming.name) ?? null;
        }
        if (!existing) {
          // 已删除 / 已转公开的组的陈旧副本（updatedAt 不晚于墓碑删除时间）：拒绝复活
          if (await isStaleDeletedCopy(owner, incoming)) {
            continue;
          }
          if (owned >= MAX_GROUPS_PER_ACCOUNT) {
            continue; // 超出账号卡片组上限的上送组直接忽略
          }
          cache.set(nextId, { ...incoming, id: nextId });
          nextId += 1;
          owned += 1;
          continue;
        }
        // 较新者胜：客户端本地改过的组（updatedAt 更新）覆盖服务器版本
        if (incoming.updatedAt > existing.updatedAt) {
          existing.name = incoming.name;
          existing.member = incoming.member;
          existing.cards = incoming.cards;
          existing.createdAt = incoming.createdAt;
          existing.updatedAt = incoming.updatedAt;
        }
      }
      await persist();
    }
    const groups = [...cache.values()]
      .filter(g => g.account === owner && g.library === 'private')
      .sort((a, b) => a.id - b.id)
      .map(g => ({ ...g, cards: g.cards.map(c => ({ ...c, content: { ...c.content } })) }));
    return { account: owner, total: groups.length, groups };
  });
}

// 公开卡片组库（服务 3）：所有 library='public' 的组；
// 组内「仅好友」卡片只对创建者本人、成员与创建者的好友可见（其余浏览者看不到这些卡片）
export function listPublicGroupsFor(viewer) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(viewer);
    const out = [];
    for (const g of [...cache.values()].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1))) {
      if (g.library !== 'public') {
        continue;
      }
      const visible = await visibleCardIndexesFor(g, name);
      out.push(view(g, name, { visibleCardIndexes: visible }));
    }
    return out;
  });
}

// 取单个卡片组：创建者与成员始终可见；公开组对所有人可见（公开卡片组库可浏览）；私人组仅创建者（及成员）可见
export async function getGroupView(id, viewer) {
  const group = await findGroup(id);
  const name = accountName(viewer);
  const isMember = parseParticipants(group.member).includes(name);
  if (name !== group.account && !isMember && group.library !== 'public') {
    throw forbidden('只有卡片组创建者与成员才能查看私人卡片组');
  }
  return view(group, name);
}

// 删除卡片组：仅创建者可删，组与其全部卡片一并删除（未处理的加入申请随之清除）。
// 私人组删除前记墓碑：客户端副本不随删除更新，登录同步（63）上送的旧副本凭墓碑识别，不再复活
export function deleteGroup(id, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能删除该卡片组');
    }
    if (group.library === 'private') {
      await recordTombstone({ account: group.account, id: group.id, name: group.name });
    }
    cache.delete(group.id);
    await persist();
    await removeCardRequestsByGroup(group.id);
    await removeExtendRequestsByGroup(group.id);
    await removeGroupJoinRequestsByGroup(group.id);
    return { id: group.id, name: group.name, removedCards: group.cards.length };
  });
}

// 从私人卡片组库删除：仅创建者可操作，且只能删除 library='private' 的组（服务 38）。
// 删除前记墓碑，防止客户端旧副本在登录同步（63）时复活该组
export function deletePrivateGroup(id, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能删除该卡片组');
    }
    if (group.library !== 'private') {
      throw conflict('该卡片组在公开卡片组库中，请到公开卡片组库或「我的卡片组」删除');
    }
    await recordTombstone({ account: group.account, id: group.id, name: group.name });
    cache.delete(group.id);
    await persist();
    await removeCardRequestsByGroup(group.id);
    await removeExtendRequestsByGroup(group.id);
    await removeGroupJoinRequestsByGroup(group.id);
    return { id: group.id, name: group.name, removedCards: group.cards.length };
  });
}

// 组内已无未完成卡片时自动删除整个卡片组（不允许存在空卡片组）：
// 「组内全部卡片完成」（62）与「最后一张卡被删除」（57）两条路径共用。
// 与手动删组一致：私人组记墓碑防登录同步复活、清理该组的加入/延期申请；
// 但不投「清理本地聊天记录」墓碑——已完成卡的聊天已冻结在明信片下（客户端剧本式记录仍可用），
// 57 路径里未完成卡的清理墓碑仍由调用方按原规则投递
async function autoDeleteEmptyGroup(group) {
  if (group.library === 'private') {
    await recordTombstone({ account: group.account, id: group.id, name: group.name });
  }
  cache.delete(group.id);
  await persist();
  await removeCardRequestsByGroup(group.id);
  await removeExtendRequestsByGroup(group.id);
  await removeGroupJoinRequestsByGroup(group.id);
}

// 组内添加卡片内核（不加锁，供两个加锁包装共用）：仅创建者可加，占用组内最小空闲编号；
// 组满 MAX_CARDS_PER_GROUP 张报 409。返回组视图 + 新卡编号（「确定」追加进指定组时回传定位）
async function appendCardCore(id, account, fields) {
  const group = await findGroup(id);
  const name = accountName(account);
  if (name !== group.account) {
    throw forbidden('只有卡片组创建者才能在组内添加卡片');
  }
  // 智能审核：向公开卡片组添加卡片前审核卡片内容（服务 56 与「确定」追加进组共用）
  if (group.library === 'public') {
    const moderation = checkContent(fields);
    if (!moderation.pass) {
      throw conflict(`${moderationPrefix(moderation)}，无法加入公开卡片组`);
    }
  }
  const card = await buildCard(group, fields, name);
  group.cards.push(card);
  group.cards.sort((a, b) => a.index - b.index);
  group.updatedAt = new Date().toISOString();
  await persist();
  return { group: view(group, name), cardIndex: card.index };
}

// 组内添加卡片（服务 56 groups.add-card）：返回组视图
export function addGroupCard(id, account, fields) {
  return serialized(async () => {
    return (await appendCardCore(id, account, fields)).group;
  });
}

// 「确定」追加进指定组（ai.complete 带 groupId）：同 addGroupCard，额外返回新卡编号
export function appendGroupCardForConfirm(id, account, fields) {
  return serialized(async () => appendCardCore(id, account, fields));
}

// 原位更新组内卡片（选取已有卡片编辑后「确定」，ai.complete 带 groupId + cardIndex）：
// 创建者或该卡发起者可改；已完成归档的卡不可改。编号 / 发起者 / 完成权限 / 完成信息保持不变，
// 仅更新内容；「仅好友 / 需要申请」只在公开组的卡片上生效（与 buildCard 规则一致）
export function updateGroupCard(id, cardIndex, account, fields) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    const card = findCard(group, cardIndex);
    const isOwner = name === group.account;
    const isInitiator = card.content.initiator === name;
    if (!isOwner && !isInitiator) {
      throw forbidden('只有卡片组创建者或该卡片的发起者才能修改组内卡片');
    }
    if (card.completedAt) {
      throw conflict('该卡片已完成并归档，不能修改');
    }
    // 智能审核：修改公开组内卡片前审核新内容，未通过则公开卡片保持未修改
    if (group.library === 'public') {
      const moderation = checkContent(fields);
      if (!moderation.pass) {
        throw conflict(`${moderationPrefix(moderation)}，公开卡片未修改`);
      }
    }
    const content = normalizeGroupCardContent(fields, group.library);
    if (group.library === 'public') {
      content.friendOnly = fields.friendOnly === true ? true : null;
      content.needApproval = fields.needApproval === true ? true : null;
      // 参与人随工作卡带入（编辑期间可邀人/退人）；私人组不收参与人
      if (typeof fields.participant === 'string' && fields.participant.trim() !== '') {
        content.participant = fields.participant.trim();
      }
    }
    // 发起者保持原卡登记人不变（确定者不抢占）
    content.initiator = card.content.initiator ?? name;
    card.content = content;
    card.updatedAt = new Date().toISOString();
    group.updatedAt = card.updatedAt;
    await persist();
    return view(group, name);
  });
}

// 删除组内卡片（真删）：创建者可删任意卡片；已完成卡片的「完成者」也可删（把已归档为明信片的卡片移除）。
// 该卡片上未处理的加入申请一并清除（服务 9 / 57）。
// 未完成的卡片被删除（结束方式=删除）时，向全部花名册投递「清理该群本地聊天记录」墓碑
// （postcardOutbox，各端经 103 拉取后删除本地线程）；已完成卡的删除不投（聊天已冻结在明信片下）
export function removeGroupCard(id, cardIndex, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    const card = findCard(group, cardIndex);
    const isOwner = name === group.account;
    const isCompleter = card.completedAt !== null && card.completedAt !== undefined && card.completedBy === name;
    if (!isOwner && !isCompleter) {
      throw forbidden('只有卡片组创建者或该卡片的完成者才能删除组内卡片');
    }
    const wasCompleted = card.completedAt !== null && card.completedAt !== undefined;
    const roster = [group.account, ...parseParticipants(group.member)]
      .filter((v, i, a) => v !== '' && a.indexOf(v) === i);
    const at = group.cards.findIndex(c => c.index === cardIndex);
    group.cards.splice(at, 1);
    group.updatedAt = new Date().toISOString();
    if (group.cards.length === 0) {
      // 组内最后一张卡被删：卡片组随即自动消失（不允许存在空卡片组）
      await autoDeleteEmptyGroup(group);
    } else {
      await persist();
      await removeCardRequestsByGroupCard(group.id, card.index);
      await removeExtendRequestsByGroupCard(group.id, card.index);
    }
    if (!wasCompleted && roster.length > 0) {
      await enqueueClears(group.id, roster);
    }
    return { id: group.id, removed: { index: card.index, content: card.content }, group: view(group, name) };
  });
}

// 加入组内单张卡片（服务 14）：写入该卡参与人，并同步成为卡片组成员（可见全组、收提醒）。
// 仅公开卡片组可直接加入；「需要申请」的卡片须先走申请流程（服务 25）；已完成/满员卡片不可加入
export function joinGroupCard(id, cardIndex, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能加入');
    }
    if (group.library !== 'public') {
      throw forbidden('私人卡片组不能直接加入，需由创建者通过聊天邀请');
    }
    // 审核加入（二期）：开启「审核加入」的卡片组，非成员不可直接加入组内卡片（须先提交入组申请，服务 107）
    if ((group.joinMode ?? 'open') === 'review'
      && name !== group.account
      && !parseParticipants(group.member).includes(name)) {
      throw conflict('该卡片组开启了审核加入，请先提交入组申请，等待创建者同意');
    }
    const card = findCard(group, cardIndex);
    if (card.completedAt) {
      throw conflict('该卡片已完成，无法加入');
    }
    if (card.content.initiator === name) {
      throw badRequest('发起者无需加入自己创建的卡片');
    }
    const already = parseParticipants(card.content.participant).includes(name);
    if (!already && MIN_CAPACITY + parseParticipants(card.content.participant).length >= card.content.capacity) {
      throw conflict(`人数已达上限（${card.content.capacity} 人），无法加入`);
    }
    if (!already && card.content.needApproval === true) {
      throw conflict('该卡片需要创建者同意，请先发送加入申请');
    }
    // 组人数上限（服务 98）：加入卡片会同时成为组成员，组满员时拦截
    const groupMembers = parseParticipants(group.member);
    if (!already && !groupMembers.includes(name)
      && group.memberCap !== null && group.memberCap !== undefined
      && 1 + groupMembers.length + 1 > group.memberCap) {
      throw conflict(`该卡片组人数已满（上限 ${group.memberCap} 人，含创建者），无法加入`);
    }
    card.content.participant = addParticipant(card.content.participant, name);
    card.updatedAt = new Date().toISOString();
    // 加入卡片的同时成为组成员（可见全组卡片并收提醒）
    const members = parseParticipants(group.member);
    if (!members.includes(name)) {
      group.member = formatParticipants([...members, name]);
    }
    group.updatedAt = new Date().toISOString();
    await persist();
    return view(group, name);
  });
}

// 审批通过后加入（服务 27 内部）：不再校验「需要申请」，但仍受人数上限约束
export function joinGroupCardByApproval(id, cardIndex, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能加入');
    }
    const card = findCard(group, cardIndex);
    if (card.completedAt) {
      throw conflict('该卡片已完成，无法加入');
    }
    const already = parseParticipants(card.content.participant).includes(name);
    if (!already && MIN_CAPACITY + parseParticipants(card.content.participant).length >= card.content.capacity) {
      throw conflict(`人数已达上限（${card.content.capacity} 人），无法加入`);
    }
    // 组人数上限（服务 98）：加入卡片会同时成为组成员，组满员时拦截
    const groupMembers = parseParticipants(group.member);
    if (!already && !groupMembers.includes(name)
      && group.memberCap !== null && group.memberCap !== undefined
      && 1 + groupMembers.length + 1 > group.memberCap) {
      throw conflict(`该卡片组人数已满（上限 ${group.memberCap} 人，含创建者），无法加入`);
    }
    card.content.participant = addParticipant(card.content.participant, name);
    card.updatedAt = new Date().toISOString();
    const members = parseParticipants(group.member);
    if (!members.includes(name)) {
      group.member = formatParticipants([...members, name]);
    }
    group.updatedAt = new Date().toISOString();
    await persist();
    return view(group, name);
  });
}

// 退出组内单张卡片（服务 15）：仅从该卡参与人中移除（组身份保留，仍可见全组）
export function leaveGroupCard(id, cardIndex, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能退出');
    }
    const card = findCard(group, cardIndex);
    if (card.content.initiator === name) {
      throw badRequest('发起者不可退出自己创建的卡片（可删除该卡片）');
    }
    if (!parseParticipants(card.content.participant).includes(name)) {
      throw notFound('你还不是该卡片的参与者');
    }
    card.content.participant = removeParticipant(card.content.participant, name);
    card.updatedAt = new Date().toISOString();
    group.updatedAt = new Date().toISOString();
    await persist();
    return view(group, name);
  });
}

// 创建者移除某张卡片的参与者（服务 30）：无需申请，直接从参与人字段删去
export function removeCardParticipantByOwner(id, cardIndex, account, targetAccount) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    const target = accountName(targetAccount);
    if (name === '' || target === '') {
      throw badRequest('需要创建者与参与者账号');
    }
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能删除参与者');
    }
    const card = findCard(group, cardIndex);
    if (!parseParticipants(card.content.participant).includes(target)) {
      throw conflict(`${target} 不是该卡片的参与者`);
    }
    card.content.participant = removeParticipant(card.content.participant, target);
    card.updatedAt = new Date().toISOString();
    group.updatedAt = new Date().toISOString();
    await persist();
    return view(group, name);
  });
}

// 加入卡片组（接受聊天组邀请 60 / 组号加入 65 / 入组申请审批 109 内部调用）：
// 写入成员名单并自动加入组内全部未满且未完成的卡片（写入参与人）。
// options.viaApproval=true 为入组申请审批路径，跳过「审核加入」闸（创建者已在 109 明确同意）
export function joinGroup(id, account, options = {}) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能加入卡片组');
    }
    if (name === group.account) {
      throw badRequest('不能加入自己创建的卡片组（你本来就是组内所有人）');
    }
    const members = parseParticipants(group.member);
    const already = members.includes(name);
    // 审核加入（二期）：开启「审核加入」的卡片组，非成员加入须先提交入组申请（服务 107），由创建者审批（109）
    if (!already && (group.joinMode ?? 'open') === 'review' && options.viaApproval !== true) {
      throw conflict('该卡片组开启了审核加入，请先提交入组申请，等待创建者同意');
    }
    // 组人数上限（服务 98）：加入后组内总人数（创建者 + 成员）不得超过上限
    if (!already && group.memberCap !== null && group.memberCap !== undefined
      && 1 + members.length + 1 > group.memberCap) {
      throw conflict(`该卡片组人数已满（上限 ${group.memberCap} 人，含创建者），无法加入`);
    }
    let joinedCards = 0;
    let skippedCards = 0;
    if (!already) {
      group.member = formatParticipants([...members, name]);
    }
    // 自动加入组内卡片：已是参与者、人数已满或已完成的卡片跳过（不因个别卡片满员而阻塞整个组的加入）
    for (const card of group.cards) {
      const participants = parseParticipants(card.content.participant);
      if (participants.includes(name)) {
        continue;
      }
      if (card.completedAt || MIN_CAPACITY + participants.length >= card.content.capacity) {
        skippedCards += 1;
        continue;
      }
      card.content.participant = addParticipant(card.content.participant, name);
      card.updatedAt = new Date().toISOString();
      joinedCards += 1;
    }
    group.updatedAt = new Date().toISOString();
    await persist();
    return { group: view(group, name), joined: !already, already, joinedCards, skippedCards };
  });
}

// 退出卡片组：仅成员可退（创建者不可退出自己创建的组，只能删除）；同时从组内卡片的参与人中移除
export function leaveGroup(id, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能退出卡片组');
    }
    if (name === group.account) {
      throw badRequest('创建者不能退出自己创建的卡片组，如不需要请直接删除');
    }
    const members = parseParticipants(group.member);
    if (!members.includes(name)) {
      throw notFound('你还不是该卡片组的成员');
    }
    group.member = formatParticipants(members.filter(m => m !== name));
    for (const card of group.cards) {
      const participants = parseParticipants(card.content.participant);
      if (participants.includes(name)) {
        card.content.participant = removeParticipant(card.content.participant, name);
        card.updatedAt = new Date().toISOString();
      }
      // 被指定「完成权限」的成员退出后，该权限自动收回
      if (card.completableBy === name) {
        card.completableBy = null;
        card.updatedAt = new Date().toISOString();
      }
    }
    group.updatedAt = new Date().toISOString();
    await persist();
    return { id: group.id, left: true };
  });
}

// 私人卡片组 → 公开卡片组（服务 50）：整组移动；组内卡片人数上限自动至少 2（保证好友能加入）
export function moveGroupToPublic(id, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能转换卡片组');
    }
    if (group.library === 'public') {
      throw conflict('该卡片组已在公开卡片组库中');
    }
    // 智能审核：整组进入公开卡片组库前审核组名、组简介与组内全部卡片内容；
    // 私人库不拦截（离开私人库那一刻才审），公转私再转公同样在此重审
    const moderation = checkContent({ name: group.name, intro: group.intro, audience: group.audience, cards: group.cards.map(c => c.content) });
    if (!moderation.pass) {
      throw conflict(`${moderationPrefix(moderation)}，无法进入公开卡片组库，已保持私密`);
    }
    // 离开私人库前记墓碑：客户端仍留着该组的私人副本，登录同步时不让其以「新私人组」复活出重复组
    await recordTombstone({ account: group.account, id: group.id, name: group.name });
    group.library = 'public';
    for (const card of group.cards) {
      if (!Number.isInteger(card.content.capacity) || card.content.capacity < 2) {
        card.content.capacity = 2;
        card.updatedAt = new Date().toISOString();
      }
    }
    group.updatedAt = new Date().toISOString();
    await persist();
    return view(group, name);
  });
}

// 公开卡片组 → 私人卡片组（服务 52）：仅创建者可操作。整组转为仅本人可见：
// 成员名单与各卡参与人一并清空（原成员与参与者在收件箱收到通知），未处理的加入申请清除，
// 各卡「完成权限」统一落到发起者（创建者）本人（私人状态下不允许再修改）
export function moveGroupToPrivate(id, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能转换卡片组');
    }
    if (group.library === 'private') {
      throw conflict('该卡片组已在私人卡片组库中');
    }
    // 转换前记下成员与参与人名单，转换后逐一投递通知
    const members = parseParticipants(group.member);
    const notified = new Set(members);
    for (const card of group.cards) {
      for (const p of parseParticipants(card.content.participant)) {
        notified.add(p);
      }
    }
    group.library = 'private';
    group.member = null;
    for (const card of group.cards) {
      card.content.participant = null;
      // 私人卡片组的卡片固定由发起者（创建者）作为完成者
      card.completableBy = name;
      card.content.friendOnly = null;
      card.content.needApproval = null;
      card.updatedAt = new Date().toISOString();
    }
    group.updatedAt = new Date().toISOString();
    await persist();
    await removeCardRequestsByGroup(group.id);
    await removeExtendRequestsByGroup(group.id);
    await removeGroupJoinRequestsByGroup(group.id);
    const title = `卡片组已转为私人：${group.name}`;
    const body = `${name} 已把卡片组「${group.name}」转为私人卡片组，你不再是该组的成员或卡片参与者，该组已从你的卡片组列表中移除。`;
    let sent = 0;
    for (const p of notified) {
      if (p === name) {
        continue;
      }
      const mail = await pushMail({ toAccount: p, fromAccount: name, title, body });
      if (mail) {
        sent += 1;
      }
    }
    return { group: view(group, name), notified: sent, notifiedAccounts: [...notified].filter(p => p !== name) };
  });
}

// 设置组简介 / 目标受众 / 组封面（服务 105 groups.set-profile）：仅创建者可改。
// 组简介 ≤200 字、目标受众 ≤50 字，均逐段过智能审核；两者都可清空（传空串即清除）。
// 组封面（coverOp）：keep=保持不变（缺省）/ remove=清除 / update=替换（coverBase64 必填，≤40 万字符）。
// 公开组在发现页展示（封面替换卡片顶部封面、简介进卡片详情页）；私人组可预先设置，转公开后即展示。
export function setGroupProfile(id, account, profile) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能修改组简介');
    }
    const intro = typeof profile?.intro === 'string' ? profile.intro.trim() : '';
    const audience = typeof profile?.audience === 'string' ? profile.audience.trim() : '';
    if (intro.length > MAX_GROUP_INTRO_LEN) {
      throw badRequest(`组简介最长 ${MAX_GROUP_INTRO_LEN} 字`);
    }
    if (audience.length > MAX_GROUP_AUDIENCE_LEN) {
      throw badRequest(`目标受众最长 ${MAX_GROUP_AUDIENCE_LEN} 字`);
    }
    const coverOp = profile?.coverOp === 'remove' || profile?.coverOp === 'update' ? profile.coverOp : 'keep';
    const coverBase64 = typeof profile?.coverBase64 === 'string' ? profile.coverBase64 : '';
    if (coverOp === 'update') {
      if (coverBase64 === '') {
        throw badRequest('缺少封面图片数据');
      }
      if (coverBase64.length > MAX_GROUP_COVER_BASE64_LEN) {
        throw badRequest(`封面图片过大（最长 ${MAX_GROUP_COVER_BASE64_LEN} 字符）`);
      }
    }
    for (const text of [intro, audience]) {
      if (text === '') {
        continue;
      }
      const moderation = checkText(text);
      if (!moderation.pass) {
        throw conflict(`${moderationPrefix(moderation)}，组简介未保存`);
      }
    }
    group.intro = intro === '' ? null : intro;
    group.audience = audience === '' ? null : audience;
    if (coverOp === 'remove') {
      group.cover = null;
      group.coverUpdatedAt = null;
    } else if (coverOp === 'update') {
      group.cover = coverBase64;
      group.coverUpdatedAt = new Date().toISOString();
    }
    group.updatedAt = new Date().toISOString();
    await persist();
    return view(group, name);
  });
}

// 取组封面原图（服务 112 groups.cover）：公开组任何人可拉；私人组仅创建者与成员可拉。
// 返回轻量结果：{ found, hasCover, coverUpdatedAt, cover }；组存在但未设封面时 hasCover=false、cover=null
export async function getGroupCover(id, viewer) {
  const group = await findGroup(id);
  const name = accountName(viewer);
  const isMember = parseParticipants(group.member).includes(name);
  if (name !== group.account && !isMember && group.library !== 'public') {
    throw forbidden('只有卡片组创建者与成员才能查看私人卡片组封面');
  }
  const hasCover = typeof group.cover === 'string' && group.cover.length > 0;
  return {
    found: true,
    hasCover,
    coverUpdatedAt: hasCover ? (group.coverUpdatedAt ?? null) : null,
    cover: hasCover ? group.cover : null
  };
}

// 设置组加入模式（106 groups.set-join-mode，二期「组加入审核」）：仅创建者可改。
// open=自由加入 / review=审核加入（加入整组须创建者同意）；私人组可预设，转公开后生效。
// 切换动作本身不处理存量申请（review→open 的批量自动通过由服务层 106 编排）。
export function setGroupJoinMode(id, account, joinMode) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能修改加入方式');
    }
    const mode = normalizeJoinMode(joinMode);
    group.joinMode = mode;
    group.updatedAt = new Date().toISOString();
    await persist();
    return view(group, name);
  });
}

// 设置组人数上限（服务 98 groups.set-member-cap）：仅创建者可改。
// memberCap = 组总人数上限（含创建者）：2~99 的整数，null = 不限；
// 不得低于当前组内总人数（创建者 + 成员）。加入整组（65/60/109）、加入组内卡片（14/49/27）
// 的成员名单增长点都按此上限拦截；审核通过（109）路径经 joinGroup 同样受限。
export function setGroupMemberCap(id, account, memberCap) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能修改组人数上限');
    }
    let cap = null;
    if (memberCap !== null && memberCap !== undefined && memberCap !== 0) {
      if (!Number.isInteger(memberCap) || memberCap < 2 || memberCap > MAX_GROUP_MEMBER_CAP) {
        throw badRequest(`组人数上限须为 2~${MAX_GROUP_MEMBER_CAP} 的整数（含创建者），或传 null 表示不限`);
      }
      cap = memberCap;
    }
    if (cap !== null) {
      const total = 1 + parseParticipants(group.member).length;
      if (cap < total) {
        throw conflict(`组人数上限不能低于当前组内人数（${total} 人，含创建者）`);
      }
    }
    group.memberCap = cap;
    group.updatedAt = new Date().toISOString();
    await persist();
    return view(group, name);
  });
}

// 单卡跨库移动（「确定」时公开/私人开关与该卡所在组的库性不一致）：把该卡从当前组移出，
// 按开关目标库新建一个同名卡片组收纳（公开→私人：原卡参与人清空并逐一收件箱通知；私人→公开：人数上限至少 2）。
// 仅创建者或该卡发起者可操作（与原位更新同一权限）；已完成归档的卡不可移动。
export function moveCardToLibrary(id, cardIndex, account, toLibrary, fields) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    const card = findCard(group, cardIndex);
    const isOwner = name === group.account;
    const isInitiator = card.content.initiator === name;
    if (!isOwner && !isInitiator) {
      throw forbidden('只有卡片组创建者或该卡片的发起者才能修改组内卡片');
    }
    if (card.completedAt) {
      throw conflict('该卡片已完成并归档，不能修改');
    }
    const target = toLibrary === 'private' ? 'private' : 'public';
    if (group.library === target) {
      throw conflict(`该卡片已在${target === 'private' ? '私人' : '公开'}卡片组内，无需转换`);
    }
    // 智能审核：单卡转入公开卡片组库前审核卡片内容（新组名取自事件/目的，随内容一并审核）
    if (target === 'public') {
      const moderation = checkContent(fields);
      if (!moderation.pass) {
        throw conflict(`${moderationPrefix(moderation)}，无法进入公开卡片组库`);
      }
    }
    await assertGroupCapacity(name);
    // 移动前记下原卡参与人与事件名：转私人后他们不再是参与者，逐一收件箱通知
    const participants = parseParticipants(card.content.participant);
    const eventName = card.content.event ?? card.content.purpose ?? '未命名卡片';
    // 新建同名卡片组收纳该卡（内容取「正在设置卡片」编辑后的 fields）
    const fieldsEvent = typeof fields?.event === 'string' ? fields.event.trim() : '';
    const fieldsPurpose = typeof fields?.purpose === 'string' ? fields.purpose.trim() : '';
    const newName = (fieldsEvent || fieldsPurpose || '未命名卡片').slice(0, MAX_GROUP_NAME_LEN);
    const now = new Date().toISOString();
    const newGroup = { id: nextId++, account: name, name: newName, library: target, member: null, cards: [], createdAt: now, updatedAt: now };
    const moved = await buildCard(newGroup, fields, name);
    newGroup.cards.push(moved);
    // 从原组移除该卡，并清理其未处理的加入/延时申请
    const at = group.cards.findIndex(c => c.index === card.index);
    group.cards.splice(at, 1);
    group.updatedAt = now;
    cache.set(newGroup.id, newGroup);
    await persist();
    await removeCardRequestsByGroupCard(group.id, card.index);
    await removeExtendRequestsByGroupCard(group.id, card.index);
    if (target === 'private') {
      const title = `卡片已转为私人：${eventName}`;
      const body = `${name} 已把卡片「${eventName}」转为私人卡片，你不再是该卡的参与者，该卡已从你的卡片列表中移除。`;
      for (const p of participants) {
        if (p === name) {
          continue;
        }
        await pushMail({ toAccount: p, fromAccount: name, title, body });
      }
      // 非创建者的发起者把卡移出他人的组时，原组创建者一并收到通知
      if (group.account !== name) {
        await pushMail({
          toAccount: group.account,
          fromAccount: name,
          title: `卡片已移出卡片组：${group.name}`,
          body: `${name} 已把卡片「${eventName}」从卡片组「${group.name}」移出并转为私人卡片。`
        });
      }
    }
    return { group: view(newGroup, name), cardIndex: moved.index, removedFrom: { id: group.id, name: group.name } };
  });
}

// 设置「完成权限」（服务 61）：创建者指定某张卡片的完成者（可以是组内成员，也可以是创建者本人）。
// memberAccount 传空表示收回权限（公开组下「收回」即回到只有创建者可完成）。
// 私人卡片组：完成者固定为发起者（创建者）本人，私人状态下不允许修改。
// 设置完成权限（服务 61）：已废弃——完成者固定为卡片发起者本人，无需（也不再）支持指定。
// 保留服务号返回明确拒绝，兼容旧客户端误调用
export function setCardCompleter(id, cardIndex, account, memberAccount) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name !== group.account) {
      throw forbidden('只有卡片组创建者才能设置完成权限');
    }
    throw conflict('完成者已固定为卡片发起者本人，无需再指定完成权限');
  });
}

// 标记卡片已完成（服务 62）：完成者固定为卡片发起者（content.initiator，即创建者本人），
// 只有发起者可以标记完成。已完成的卡片不再提醒、归档展示，但记录保留可查看；
// 该卡片未处理的加入申请一并清除。返回完成时刻的卡片快照（postcardSnapshot）——
// 62 响应不等待 AI 出稿，参与者明信片由路由层按快照后台生成投递（明信片已随快照定格，
// 之后卡片被归档删除也不影响出稿）
export function completeGroupCard(id, cardIndex, account) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能标记完成');
    }
    const card = findCard(group, cardIndex);
    if (card.completedAt) {
      throw conflict('该卡片已完成，无需重复标记');
    }
    const initiator = card.content.initiator ?? group.account;
    if (name !== initiator) {
      throw forbidden('完成者固定为卡片发起者：只有发起者本人可以标记卡片完成');
    }
    card.completedAt = new Date().toISOString();
    card.completedBy = name;
    card.updatedAt = card.completedAt;
    group.updatedAt = card.completedAt;
    // 组内全部卡片完成 = 已无未完成卡片：整个卡片组随即自动消失（不允许存在空卡片组）。
    // 各端本地聊天记录保留（明信片「上滑查看聊天记录」仍可用），不投清理墓碑
    const allDone = group.cards.every(c => c.completedAt !== null && c.completedAt !== undefined);
    if (allDone) {
      await autoDeleteEmptyGroup(group);
    } else {
      await persist();
      await removeCardRequestsByGroupCard(group.id, card.index);
      await removeExtendRequestsByGroupCard(group.id, card.index);
    }
    return {
      group: view(group, name),
      cardIndex: card.index,
      completedAt: card.completedAt,
      completedBy: card.completedBy,
      postcardSnapshot: {
        groupId: group.id,
        groupName: group.name,
        owner: group.account,
        members: parseParticipants(group.member),
        cardIndex: card.index,
        event: card.content?.event ?? null,
        time: card.content?.time ?? null,
        location: card.content?.location ?? null,
        purpose: card.content?.purpose ?? null,
        content: card.content,
        completedBy: card.completedBy,
        completedAt: card.completedAt
      },
      message: `卡片 #${card.index}「${card.content.event}」已标记为完成（由 ${name} 完成）`
    };
  });
}

// 延期时间的纯计算（不落库、可单独复用）：由新的开始时间与可选结束时间，
// 算出新的「时间」文本、按原提前量平移后的「提醒时间」、以及修正后的「重复到何时」。
// 供「发起者即时改期」与「参与者提交延期申请时的快照」共用，保证两条路径结果一致。
export function computeExtendedTime(cardContent, fields = {}) {
  const startText = typeof fields.time === 'string' ? fields.time.trim() : '';
  const newStart = parseDateTime(startText);
  if (!newStart) {
    throw badRequest('「时间」必须为绝对时间（YYYY-MM-DD HH:mm），如 2026-10-02 10:00');
  }
  // 结束时间：显式给出就用它，否则原时间含时段时保留原时段长度整体平移
  const oldRange = parseTimeRange(cardContent?.time);
  let endDate = null;
  const endRaw = typeof fields.endTime === 'string' ? fields.endTime.trim() : '';
  if (endRaw !== '') {
    endDate = parseDateTime(endRaw);
    if (!endDate) {
      throw badRequest('「结束时间」必须为绝对时间（YYYY-MM-DD HH:mm）');
    }
    if (endDate.getTime() <= newStart.getTime()) {
      throw badRequest('结束时间必须晚于开始时间');
    }
  } else if (oldRange && !oldRange.openEnded) {
    endDate = new Date(newStart.getTime() + (oldRange.end.getTime() - oldRange.start.getTime()));
  }
  const time = endDate ? formatRange(newStart, endDate) : formatDateTime(newStart);

  // 「提醒时间」按原提前量平移（原卡片没有可用时间时提前量为 0，即与开始时刻同时提醒）
  const offset = reminderOffsetMs(cardContent) ?? 0;
  const reminderTime = formatDateTime(new Date(newStart.getTime() - offset));

  // 「重复到何时」修正：未设重复、或原本就等于旧「时间」（normalizeContent 的缺省规则）时，
  // 同步为新「时间」；否则用户显式设过重复结束时间，延期不得越过它。
  const oldTime = cardContent?.time ?? null;
  const oldRepeatUntil = cardContent?.repeatUntil ?? null;
  const autoRepeatUntil = !cardContent?.repeatTime || oldRepeatUntil === null || oldRepeatUntil === oldTime;
  let repeatUntil = oldRepeatUntil;
  if (autoRepeatUntil) {
    repeatUntil = time;
  } else {
    const untilDate = parseUntil(oldRepeatUntil);
    if (untilDate && newStart.getTime() > untilDate.getTime()) {
      throw badRequest(`延期后的时间（${time}）已晚于「重复到何时」（${oldRepeatUntil}），请先调整重复设置`);
    }
  }

  return {
    start: formatDateTime(newStart),
    end: endDate ? formatDateTime(endDate) : null,
    time,
    reminderTime,
    repeatUntil
  };
}

// 修改组内卡片的「时间」= 延期（服务 67 发起者即时改期 / 服务 69 同意申请后改期）。
// 权限与「完成」一致：创建者本人或被指定「完成权限」的成员；已完成卡片不可延期。
// 入参 time 为新的开始时间（必须是绝对时间 "YYYY-MM-DD HH:mm"）；
// 原时间为时段时用 endTime 单独指定新的结束时间，未指定则沿用原时段长度整体平移。
export function extendGroupCardTime(id, cardIndex, account, fields = {}) {
  return serialized(async () => {
    const group = await findGroup(id);
    const name = accountName(account);
    if (name === '') {
      throw badRequest('需要账号身份才能延期');
    }
    const card = findCard(group, cardIndex);
    if (card.completedAt) {
      throw conflict('该卡片已完成，无法延期');
    }
    if (name !== group.account && card.completableBy !== name) {
      throw forbidden('只有卡片组创建者或被指定完成权限的成员才能延期该卡片');
    }

    const computed = computeExtendedTime(card.content, fields);
    const oldTime = card.content.time ?? null;
    const merged = {
      ...card.content,
      time: computed.time,
      reminderTime: computed.reminderTime,
      repeatUntil: computed.repeatUntil
    };
    // normalizeGroupCardContent 只处理文本字段与 capacity，其余字段需显式保留；
    // 延期不改内容，历史无标签卡片放行（requireTags=false），标签保持原状
    const content = normalizeGroupCardContent(merged, group.library, { requireTags: false });
    content.participant = card.content.participant ?? null;
    content.initiator = card.content.initiator ?? group.account;
    content.friendOnly = group.library === 'public' ? (card.content.friendOnly ?? null) : null;
    content.needApproval = group.library === 'public' ? (card.content.needApproval ?? null) : null;

    card.content = content;
    card.updatedAt = new Date().toISOString();
    group.updatedAt = card.updatedAt;
    await persist();
    // 清掉该卡片在提醒台账中的旧送达记录，避免「改回原时间」时该次提醒永不触发
    await clearRemindersByCard(group.id, card.index);
    return {
      group: view(group, name),
      cardIndex: card.index,
      time: content.time,
      reminderTime: content.reminderTime,
      previousTime: oldTime,
      message: `卡片 #${card.index}「${content.event}」的时间已调整至 ${content.time}`
    };
  });
}

// 收集某账号相关的全部组内卡片（提醒 / 冲突检测 / AI 上下文共用）：
// 该账号创建或加入的每个组的每张卡片；options.skipCompleted=true 时排除已完成卡片
export function groupCardEntriesOf(account, options = {}) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    if (name === '') {
      return [];
    }
    const skipCompleted = options.skipCompleted !== false;
    const out = [];
    for (const g of cache.values()) {
      const isOwner = g.account === name;
      const isMember = parseParticipants(g.member).includes(name);
      if (!isOwner && !isMember) {
        continue;
      }
      for (const card of g.cards) {
        if (skipCompleted && card.completedAt) {
          continue;
        }
        out.push({
          library: 'group',
          index: `${g.id}:${card.index}`,
          groupId: g.id,
          groupName: g.name,
          cardIndex: card.index,
          content: card.content,
          completedAt: card.completedAt,
          completedBy: card.completedBy,
          createdAt: card.createdAt,
          updatedAt: card.updatedAt
        });
      }
    }
    return out;
  });
}

// 注销账号时清理：删除其创建的全部卡片组，并把它从其他卡片组的成员、组内卡片参与人与「完成权限」中移除
export function clearGroupsOf(account) {
  return serialized(async () => {
    await ensureLoaded();
    const name = accountName(account);
    let removedGroups = 0;
    let removedMemberships = 0;
    for (const id of [...cache.keys()]) {
      const group = cache.get(id);
      if (group.account === name) {
        cache.delete(id);
        removedGroups += 1;
        continue;
      }
      let touched = false;
      const members = parseParticipants(group.member);
      if (members.includes(name)) {
        group.member = formatParticipants(members.filter(m => m !== name));
        touched = true;
        removedMemberships += 1;
      }
      for (const card of group.cards) {
        const participants = parseParticipants(card.content.participant);
        if (participants.includes(name)) {
          card.content.participant = removeParticipant(card.content.participant, name);
          card.updatedAt = new Date().toISOString();
          touched = true;
        }
        if (card.completableBy === name) {
          card.completableBy = null;
          card.updatedAt = new Date().toISOString();
          touched = true;
        }
      }
      if (touched) {
        group.updatedAt = new Date().toISOString();
      }
    }
    if (removedGroups > 0 || removedMemberships > 0) {
      await persist();
      await removeCardRequestsByAccount(name);
      await removeExtendRequestsByAccount(name);
    }
    return { removedGroups, removedMemberships };
  });
}

// 改名级联：该账号作为创建者/成员/参与人/完成人的字段同步更新（组记录、成员列表、卡片发起者与参与人、完成权限）
export function renameGroupsAccountOf(oldName, newName) {
  return serialized(async () => {
    await ensureLoaded();
    let changed = 0;
    for (const group of cache.values()) {
      let touched = false;
      if (group.account === oldName) {
        group.account = newName;
        touched = true;
      }
      const members = parseParticipants(group.member);
      if (members.includes(oldName)) {
        group.member = formatParticipants(members.map(m => m === oldName ? newName : m));
        touched = true;
      }
      for (const card of group.cards) {
        if (card.content && typeof card.content === 'object') {
          if (card.content.initiator === oldName) {
            card.content.initiator = newName;
            touched = true;
          }
          const participants = parseParticipants(card.content.participant);
          if (participants.includes(oldName)) {
            card.content.participant = formatParticipants(participants.map(p => p === oldName ? newName : p));
            touched = true;
          }
        }
        if (card.completableBy === oldName) {
          card.completableBy = newName;
          touched = true;
        }
        if (card.completedBy === oldName) {
          card.completedBy = newName;
          touched = true;
        }
      }
      if (touched) {
        changed += 1;
      }
    }
    if (changed > 0) {
      await persist();
    }
    return { changed };
  });
}
