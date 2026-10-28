import { MODES, runAiJsonTask } from './index.js';
import { parseParticipants, hasValidReminderTime, missingCardTags } from '../cardStore.js';
import { createGroupForCard, groupCardEntriesOf, listPublicGroupsFor, getGroupView, appendGroupCardForConfirm, updateGroupCard, moveCardToLibrary } from '../cardGroupStore.js';
import { getProfile, appendUserTraits } from '../userProfileStore.js';
import { findAccount, findAccountByUserId } from '../accountStore.js';
import { areFriends, listInvitableAccounts } from '../friend.service.js';
import { getFlowState, setConfirmed, setLastReply, clearLastReply } from '../aiStatusStore.js';
import {
  getWorkingCard,
  updateWorkingCard,
  resetWorkingCard,
  setWorkingCardPublic,
  setWorkingCardFriendOnly,
  setWorkingCardCapacity,
  setWorkingCardNeedApproval,
  addWorkingCardParticipant,
  removeWorkingCardParticipant,
  isWorkingCardFilled,
  editWorkingCardFields,
  loadWorkingCardFromCard
} from '../workingCardStore.js';
import { findConflicts, describeConflicts } from '../conflictService.js';
import { readApiKey } from './apiKey.js';
import { syncClientWeather, syncCapturedWeather, currentWeatherForPrompt } from './weatherCapture.js';
import { clearAiWeather } from './aiWeatherStore.js';
import { checkText, MODERATION_ASK_REPLY } from '../moderation.service.js';
import { sendCardInviteToParticipant } from '../chat.service.js';
import { getCumulativeTagStats } from '../report.service.js';

function modeForState(state) {
  return state === 2 ? MODES.FINALIZE : (state === 1 ? MODES.CONFIRM : MODES.GATHER);
}

export async function deriveFlowStatus() {
  const [flowState, working] = await Promise.all([getFlowState(), getWorkingCard()]);
  const filled = isWorkingCardFilled(working.card);
  let confirmed = flowState.confirmed;
  if (confirmed && !filled) {
    confirmed = false;
    await setConfirmed(false);
  }
  return { state: confirmed ? 2 : (filled ? 1 : 0), filled, confirmed };
}

function isCardEmpty(card) {
  return !(card && (card.purpose || card.event || card.time || card.repeatTime || card.repeatUntil || card.location));
}

// 「确定」落库：按客户端看板当前居中的卡片组落位——
// 1) 未指定组（最右「新卡片组」列确定）：自动创建一个同名卡片组收纳该卡；
//    公开卡片 → 公开卡片组库（所有人可浏览，好友可加入组内卡片）；私人卡片 → 私人卡片组库（仅本人可见）
// 2) 指定组（groupId）：把工作卡追加进该组（仅创建者可加，组满报 409）；
//    卡片的公开/私人开关必须与该组库性一致，不一致时明确报错（不静默按组落库）
// 3) 指定组 + 卡（groupId + cardIndex）：选取已有卡片编辑后确定 → 原位更新该卡（创建者或发起者可改）；
//    开关与该组库性不一致 = 单卡转库：把该卡移出到按开关新建的同名组（公开 ↔ 私人）
async function writeByVisibility(working, account, options = {}) {
  const owner = typeof account === 'string' ? account.trim() : '';
  if (owner === '') {
    const err = new Error('需要账号身份才能保存卡片');
    err.status = 400;
    throw err;
  }
  const firstCard = { ...working.card };
  const targetGroupId = Number.isInteger(options.groupId) && options.groupId >= 1 ? options.groupId : null;
  const targetCardIndex = Number.isInteger(options.cardIndex) && options.cardIndex >= 1 ? options.cardIndex : null;
  const wantPrivate = working.public === false;
  if (targetGroupId !== null && targetCardIndex !== null) {
    const current = await getGroupView(targetGroupId, owner);
    if (wantPrivate !== (current.library === 'private')) {
      // 单卡转库：按「公开/私人」开关把该卡移出到目标库的新组（转私人 = 仅本人可见；转公开 = 进入公开卡片组库）
      if (!wantPrivate) {
        firstCard.friendOnly = working.friendOnly === true ? true : null;
        firstCard.needApproval = working.needApproval === true ? true : null;
      }
      const moved = await moveCardToLibrary(targetGroupId, targetCardIndex, owner, wantPrivate ? 'private' : 'public', firstCard);
      const g = moved.group;
      const card = (g.cards || []).find(c => c.index === moved.cardIndex);
      return {
        mode: 'moved',
        id: g.id,
        name: g.name,
        library: g.library,
        cardIndex: moved.cardIndex,
        cardCount: g.cardCount,
        removedFrom: moved.removedFrom,
        content: { ...(card ? card.content : firstCard), public: g.library === 'public' }
      };
    }
    const group = await updateGroupCard(targetGroupId, targetCardIndex, owner, firstCard);
    const card = (group.cards || []).find(c => c.index === targetCardIndex);
    return {
      mode: 'updated',
      id: group.id,
      name: group.name,
      library: group.library,
      cardIndex: targetCardIndex,
      cardCount: group.cardCount,
      content: { ...(card ? card.content : firstCard), public: group.library === 'public' }
    };
  }
  if (targetGroupId !== null) {
    const current = await getGroupView(targetGroupId, owner);
    if (wantPrivate !== (current.library === 'private')) {
      const cardLabel = wantPrivate ? '🔒 私人' : '🌐 公开';
      const groupLabel = wantPrivate ? '🌐 公开' : '🔒 私人';
      const err = new Error(`当前卡片是「${cardLabel}」，但卡片组「${current.name}」#${current.id} 是${groupLabel}卡片组：请先把卡片开关切为「${groupLabel}」再确定，或滑到最右侧「✨ 新卡片组」列确定`);
      err.status = 409;
      throw err;
    }
    const { group, cardIndex } = await appendGroupCardForConfirm(targetGroupId, owner, firstCard);
    const card = (group.cards || []).find(c => c.index === cardIndex);
    return {
      mode: 'appended',
      id: group.id,
      name: group.name,
      library: group.library,
      cardIndex,
      cardCount: group.cardCount,
      content: { ...(card ? card.content : firstCard), public: group.library === 'public' }
    };
  }
  // 「仅好友 / 需要申请」只在公开卡片组的卡片上生效，随卡片带入组内
  if (working.public !== false) {
    firstCard.friendOnly = working.friendOnly === true ? true : null;
    firstCard.needApproval = working.needApproval === true ? true : null;
  }
  const group = await createGroupForCard(owner, firstCard, { library: working.public === false ? 'private' : 'public' });
  return {
    mode: 'created',
    id: group.id,
    name: group.name,
    library: group.library,
    cardIndex: group.cards[0].index,
    cardCount: group.cardCount,
    content: { ...group.cards[0].content, public: group.library === 'public' }
  };
}

// 「确定」结果提示语：按落位方式（新建组 / 追加进组 / 原位更新 / 单卡转库）分别说明
function messageForWritten(written, isPublic, friendOnly) {
  if (!written) {
    return '确定完成';
  }
  if (written.mode === 'moved') {
    const label = written.library === 'private' ? '私人' : '公开';
    const from = written.removedFrom ? `（已从卡片组「${written.removedFrom.name}」#${written.removedFrom.id} 移出）` : '';
    return `确定完成：已把卡片转为${label}，移入${label}卡片组库${from}`;
  }
  if (written.mode === 'updated') {
    return `确定完成：已更新卡片组「${written.name}」#${written.id} 的卡片 #${written.cardIndex}`;
  }
  if (written.mode === 'appended') {
    return `确定完成：卡片已加入卡片组「${written.name}」#${written.id}（现有 ${written.cardCount} 张）`;
  }
  return isPublic
    ? `确定完成：已创建卡片组「${written.name}」#${written.id} 收纳该卡片，并写入公开卡片组库${friendOnly ? '（该卡片仅好友可见）' : ''}，可继续在组内添加卡片`
    : `确定完成：已创建卡片组「${written.name}」#${written.id} 收纳该卡片，并写入私人卡片组库（仅本人可见），可继续在组内添加卡片`;
}

// 某账号的用户资料（服务器用户资料库，按账号 -> userId 定位；用户本人也看不到，仅服务器内部与 AI 使用）
async function profileOfAccount(account) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    return null;
  }
  const found = await findAccount(name);
  if (!found) {
    return null;
  }
  const entry = await getProfile(found.userId);
  return entry?.profile ?? null;
}

// 某账号相关的全部组内卡片（其创建/加入的卡片组；已完成卡片不算日程，不参与冲突与上下文）
async function groupCardsOf(account) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    return [];
  }
  const entries = await groupCardEntriesOf(name);
  return entries.map(e => ({ owner: e.content.initiator ?? null, index: e.index, card: e.content }));
}

// 工作卡的参与人账号（可排除某个账号，通常是发起者本人）
async function workingParticipantAccounts(exclude = '') {
  const working = await getWorkingCard();
  const skip = typeof exclude === 'string' ? exclude.trim() : '';
  return parseParticipants(working.card.participant).filter(a => a !== skip);
}

// 冲突检测的比对来源（重做后全部来自卡片组库）：
// 1) 公开卡片组库中本人可见的卡片（「仅好友」卡片只对组创建者的好友可见）
// 2) 本人的组内卡片（创建/加入的组）
// 3) 当前卡片各参与人的组内卡片
// excludeKey（「组号:组内编号」）非空时排除该卡：原位更新时被选取的卡即是工作卡本身，不参与自冲突
async function collectConflictSources(selfAccount, excludeKey = null) {
  const [participants, myEntries, publicGroups] = await Promise.all([
    workingParticipantAccounts(selfAccount),
    groupCardEntriesOf(selfAccount),
    listPublicGroupsFor(selfAccount)
  ]);
  const mine = new Set(myEntries.map(e => `${e.groupId}:${e.cardIndex}`));
  const publicCards = [];
  for (const g of Array.isArray(publicGroups) ? publicGroups : []) {
    for (const card of Array.isArray(g.cards) ? g.cards : []) {
      if (mine.has(`${g.id}:${card.index}`)) {
        continue; // 自己的卡片已单独收录，避免重复
      }
      publicCards.push({ owner: g.owner, index: `${g.id}:${card.index}`, card: card.content });
    }
  }
  const own = myEntries.map(e => ({ owner: e.content.initiator ?? null, index: e.index, card: e.content }));
  const others = (await Promise.all(participants.map(async account => {
    const entries = await groupCardEntriesOf(account);
    return entries.map(e => ({ owner: account, index: e.index, card: e.content }));
  }))).flat();
  const all = [...publicCards, ...own, ...others];
  return excludeKey === null ? all : all.filter(e => e.index !== excludeKey);
}

// 校验当前工作卡是否与已有卡片时间冲突（确定卡片前的硬门槛，不依赖大模型判断）
export async function getWorkingCardConflicts({ account = null } = {}) {
  const working = await getWorkingCard();
  if (isCardEmpty(working.card)) {
    return { conflicts: [], descriptions: [], workingCard: working };
  }
  const sources = await collectConflictSources(account);
  const conflicts = findConflicts(working.card, sources);
  return { conflicts, descriptions: describeConflicts(conflicts), workingCard: working };
}

// 组装上下文：按账号呈现「本人」与「各参与人」的用户资料与卡片，供 AI 基于真实日程与资料推荐方案。
// 用户资料与卡片全部由服务器长期存储（用户资料库 + 公开卡片库 + 私人卡片库），不再依赖客户端上送。
export async function assembleContext(account) {
  const working = await getWorkingCard();
  const selfAccount = typeof account === 'string' ? account.trim() : '';

  // 本人的卡片：本人创建/加入的卡片组里的全部卡片（重做后卡片一律存放在卡片组里）
  const [selfCardsRaw, selfProfile] = await Promise.all([
    groupCardsOf(selfAccount),
    profileOfAccount(selfAccount)
  ]);
  const selfCards = selfCardsRaw.map(e => ({ index: e.index, ...e.card }));

  // 参与人：工作卡参与人字段中的账号，附上各自在服务器上的用户资料与组内卡片
  const participantAccounts = parseParticipants(working.card.participant);
  const participants = await Promise.all(participantAccounts.map(async acc => ({
    account: acc,
    profile: await profileOfAccount(acc),
    cards: (await groupCardsOf(acc)).map(e => ({ index: e.index, ...e.card }))
  })));

  const ctx = {
    selfAccount: selfAccount || null,
    selfProfile: selfProfile ?? null,
    selfCards: selfCards.length > 0 ? selfCards : null,
    participants: participants.length > 0 ? participants : null,
    // 用户列表：账号 / userId / 与本人关系，供 AI 把「邀请某人」映射到真实账号
    userList: selfAccount ? await listInvitableAccounts(selfAccount) : null,
    // 附带「公开/私人」当前值，便于 AI 判断用户是否要求改动公开状态
    currentCard: isCardEmpty(working.card) ? null : { ...working.card, public: working.public !== false },
    history: null
  };

  // 时间冲突：由服务器确定性算出（不依赖大模型判断），直接告知 AI 哪些已有卡片与本次安排重叠
  if (!isCardEmpty(working.card)) {
    const conflicts = findConflicts(working.card, await collectConflictSources(selfAccount));
    if (conflicts.length > 0) {
      ctx.conflicts = describeConflicts(conflicts);
    }
  }

  // 天气栏：对话中捕获的地区天气优先（当前卡片确定前一直生效），回退客户端记日程时上送的默认天气
  const weather = await currentWeatherForPrompt();
  if (weather !== null) {
    ctx.weather = weather;
  }

  // 周报累计信息：该用户全部相关卡片的标签/时段分布（与 reports.week 同源同口径），
  // 并入【用户信息】栏，供 AI 推断三维度标签、推荐「时间」时贴合用户长期习惯；无数据时不设该栏
  const weekStats = await getCumulativeTagStats({ account: selfAccount });
  if (weekStats !== null) {
    ctx.userInfo = weekStats;
  }

  return ctx;
}

// 历史对话：本地化改造后 AI 对话记录长期保存在客户端，服务器不再持久化；
// 客户端调用服务 0 时随请求上送 payload.history，这里只做净化（仅保留真实对话：direction ∈ {in, out} 且 content 非空）。
function withHistory(ctx, history) {
  const clean = (Array.isArray(history) ? history : [])
    .filter(m => m && (m.direction === 'in' || m.direction === 'out') && typeof m.content === 'string' && m.content.trim() !== '')
    .map(m => ({ direction: m.direction, content: m.content }));
  if (clean.length > 0) {
    ctx.history = clean;
  }
  return ctx;
}

// 把 AI 本轮发现的用户情况写入服务器「用户资料库」（按账号 -> userId 定位，去重追加）：
// account 为空时归到本人账号。用户资料只在服务器保存，不返回客户端。
async function saveTraits(traits, selfAccount) {
  const clean = (Array.isArray(traits) ? traits : [])
    .map(t => {
      if (typeof t === 'string') {
        return { account: null, content: t.trim() };
      }
      if (!t || typeof t !== 'object') {
        return null;
      }
      const content = typeof t.content === 'string' ? t.content.trim() : '';
      if (content === '') {
        return null;
      }
      return { account: typeof t.account === 'string' && t.account.trim() !== '' ? t.account.trim() : null, content };
    })
    .filter(t => t !== null);
  if (clean.length === 0) {
    return { saved: [] };
  }
  // 按目标账号归并，一个账号一次写入
  const byAccount = new Map();
  for (const { account, content } of clean) {
    const target = account ?? selfAccount;
    if (!target) {
      continue;
    }
    if (!byAccount.has(target)) {
      byAccount.set(target, []);
    }
    byAccount.get(target).push(content);
  }
  const saved = [];
  for (const [target, list] of byAccount) {
    const found = await findAccount(target);
    if (!found) {
      continue;
    }
    await appendUserTraits(found.userId, list);
    saved.push({ account: target, added: list.length });
  }
  return { saved };
}

// 完整 AI 对话流程：状态机 mode + 按账号的上下文 + AI 调用 + 工作卡更新 + finalize 落库
// 用户资料与卡片由服务器长期存储；AI 对话记录由客户端保存（历史随 payload.history 上送，本轮由客户端回写）
export async function runAiAsk(options = {}) {
  const {
    task, context = null, schemaHint = '', rules = [],
    account = null, history = null, targetGroupId = null, targetCardIndex = null,
    weather = null
  } = options;
  if (typeof task !== 'string' || task.trim() === '') {
    const err = new Error('task must be a non-empty string');
    err.status = 400;
    throw err;
  }

  // 智能审核（构建提示词之前）：用户输入未通过词库审核时不构建提示词、不调用 AI，
  // 按正常响应结构返回固定回复「请手动输入」（不落卡、不写用户资料，前端零改动）
  const moderation = checkText(task);
  if (!moderation.pass) {
    await setLastReply(MODERATION_ASK_REPLY);
    return {
      model: null,
      messages: null,
      raw: null,
      data: null,
      parts: { cards: [], users: [], reply: MODERATION_ASK_REPLY, status: {} },
      workingCard: await getWorkingCard(),
      written: null,
      invited: [],
      uninvited: [],
      traitsSaved: { saved: [] },
      flowStatus: await deriveFlowStatus(),
      moderation: { blocked: true, category: moderation.category }
    };
  }

  const flowStatus = await deriveFlowStatus();
  const mode = modeForState(flowStatus.state);
  const selfAccount = typeof account === 'string' ? account.trim() : '';

  // 天气：客户端随请求上送的本地天气作为默认；用户消息里出现省市时捕获该地区天气（和风天气）。
  // 捕获须在构建上下文之前完成，本轮【天气】栏即用捕获地区的天气；当前卡片确定前一直覆盖默认
  await syncClientWeather(weather);
  await syncCapturedWeather(task);

  const ctx = context ?? withHistory(await assembleContext(selfAccount), history);
  const result = await runAiJsonTask({ task, context: ctx, schemaHint, rules, mode });

  // 本轮 AI 发现的用户情况：直接写入服务器用户资料库（不返回客户端）
  const userTraits = Array.isArray(result.parts.users) ? result.parts.users : [];
  const traitsSaved = await saveTraits(userTraits, selfAccount);

  // 本轮对话由客户端写入其本地记录（服务器不再持久化）；这里只记住最近一次回复供状态查询
  const replyText = (result.parts && typeof result.parts.reply === 'string') ? result.parts.reply : null;
  await setLastReply(replyText);
  // AI 回复里提到的省市同样捕获，下一轮提示词【天气】栏生效
  await syncCapturedWeather(replyText);

  const aiCard = Array.isArray(result.parts.cards) && result.parts.cards.length > 0
    ? result.parts.cards[0]
    : null;
  await updateWorkingCard(aiCard);
  // 执行 AI 在卡片 invite / uninvite 字段里填写的邀请与取消邀请（服务器校验后写入/移出参与人）
  const invited = await applyAiInvites(selfAccount, aiCard ? aiCard.invite : null);
  const uninvited = await applyAiUninvites(selfAccount, aiCard ? aiCard.uninvite : null);

  let written = null;
  if (mode === MODES.FINALIZE) {
    const working = await getWorkingCard();
    // 「提醒时间」必须已由 AI 推荐并写入且格式正确（与「时间」同格式的绝对时间）、
    // 且三维度标签（类型 / 场景 / 主题）齐备才落库；
    // 任一缺失时保持工作卡不变，用户点「确定」也会被拒绝
    if (hasValidReminderTime(working.card) && missingCardTags(working.card).length === 0) {
      // 发起者：设置卡片的账号（仅一人）
      if (selfAccount) {
        working.card.initiator = selfAccount;
      }
      // FINALIZE 自动落库同样按客户端看板居中的卡片组落位（新建组 / 追加进组 / 原位更新）
      written = await writeByVisibility(working, selfAccount, { groupId: targetGroupId, cardIndex: targetCardIndex });
      await resetWorkingCard();
      await setConfirmed(false);
      // 卡片已确定：清空服务器存储的天气（客户端默认 + 捕获地区），下次记日程重新上送/捕获
      await clearAiWeather();
    }
  }

  return {
    ...result,
    workingCard: await getWorkingCard(),
    written,
    invited,
    uninvited,
    traitsSaved,
    flowStatus: await deriveFlowStatus()
  };
}

// 状态查询：AI 配置 + 流程状态 + 当前工作卡 + 最近一次 AI 回复
export async function getAiControlStatus() {
  const status = await getFlowState();
  return {
    configured: readApiKey() !== '',
    lastReply: status.lastReply ?? null,
    flowStatus: await deriveFlowStatus(),
    workingCard: await getWorkingCard()
  };
}

// 切换当前卡片的「公开/私人」：客户端在点「确定」前用按钮更改
export async function setCardVisibility(isPublic) {
  await setWorkingCardPublic(isPublic === true);
  return { workingCard: await getWorkingCard(), flowStatus: await deriveFlowStatus() };
}

// 切换当前卡片的「仅好友」：仅在「公开」卡片上生效，客户端在点「确定」前用按钮更改
export async function setCardFriendOnly(friendOnly) {
  await setWorkingCardFriendOnly(friendOnly === true);
  return { workingCard: await getWorkingCard(), flowStatus: await deriveFlowStatus() };
}

// 设置当前卡片的「人数上限」：包含发起者本人，最小为 1；客户端在点「确定」前用输入框修改
export async function setCardCapacity(capacity) {
  await setWorkingCardCapacity(capacity);
  return { workingCard: await getWorkingCard(), flowStatus: await deriveFlowStatus() };
}

// 切换当前卡片的「需要申请」：仅在「公开」卡片上生效，客户端在点「确定」前用按钮更改
export async function setCardNeedApproval(needApproval) {
  await setWorkingCardNeedApproval(needApproval);
  return { workingCard: await getWorkingCard(), flowStatus: await deriveFlowStatus() };
}

// 手动编辑当前卡片的文本字段：客户端「手动制作卡片」表单直接写入工作卡
// （空字符串 = 清空该字段，未出现在 fields 中 = 保持不变），写入后仍用「确定」落库；
// 与 AI 对话可混用：先手动打底再让 AI 完善，或反之
export async function editCardFields(fields) {
  const workingCard = await editWorkingCardFields(fields);
  return {
    workingCard,
    flowStatus: await deriveFlowStatus(),
    message: '已写入当前卡片：内容正确的话，点「确定」保存到卡片库；也可继续让 AI 完善'
  };
}

// 选取一张已有卡片成为「正在设置卡片」（服务 76）：把该卡片整份载入工作卡。
// 载入后「手动制作」（51 cards.edit）与 AI 对话（0 ai.ask）都作用于同一张工作卡，
// 因此该选取功能在两种输入方式间天然共用（不需要各自实现一遍）。
// 只允许选取调用者可见的卡片：私人组仅创建者/成员、公开组对所有人可见（与卡片组可见性一致）。
export async function pickCardAsWorking({ account = null, groupId = null, cardIndex = null } = {}) {
  const name = typeof account === 'string' ? account.trim() : '';
  if (name === '') {
    const err = new Error('需要账号身份才能选取卡片');
    err.status = 400;
    throw err;
  }
  const gid = Number(groupId);
  if (!Number.isInteger(gid) || gid < 1) {
    const err = new Error('groupId must be a positive integer');
    err.status = 400;
    throw err;
  }
  const cidx = Number(cardIndex);
  if (!Number.isInteger(cidx) || cidx < 1) {
    const err = new Error('cardIndex must be a positive integer');
    err.status = 400;
    throw err;
  }
  // getGroupView 内含可见性校验：不可见的组/卡片会以 403 拒绝
  const group = await getGroupView(gid, name);
  const card = (group.cards || []).find(c => c.index === cidx);
  if (!card) {
    const err = new Error('组内卡片不存在');
    err.status = 404;
    throw err;
  }
  const workingCard = await loadWorkingCardFromCard(card.content, group.library);
  return {
    workingCard,
    flowStatus: await deriveFlowStatus(),
    source: { groupId: group.id, groupName: group.name, cardIndex: card.index, library: group.library },
    message: `已选取卡片组「${group.name}」#${group.id} 的卡片 #${card.index} 作为「正在设置卡片」；可用「手动制作」继续修改，或让 AI 完善后点「确定」`
  };
}

// 邀请单个账号加入工作卡：校验好友关系与人数上限，通过后写入参与人。
// 返回 { account, ok, already?, reason? }，不抛错，便于「按钮邀请」与「AI 邀请」共用
async function inviteOneAccount(me, targetAccount) {
  const name = typeof targetAccount === 'string' ? targetAccount.trim() : '';
  if (name === '') {
    return { account: '', ok: false, reason: '账号为空' };
  }
  const target = await findAccount(name);
  if (!target) {
    return { account: name, ok: false, reason: '目标用户不存在' };
  }
  if (target.userId === me.userId) {
    return { account: name, ok: false, reason: '不能邀请自己' };
  }
  if (!(await areFriends(me.userId, target.userId))) {
    return { account: name, ok: false, reason: '不是好友，只能邀请好友' };
  }
  const working = await getWorkingCard();
  const already = parseParticipants(working.card.participant).includes(target.account);
  if (already) {
    return { account: target.account, ok: true, already: true };
  }
  // 「人数」含发起者本人：已达上限时拒绝
  if (working.card.count >= working.card.capacity) {
    return { account: target.account, ok: false, reason: `人数已达上限（${working.card.capacity} 人）` };
  }
  await addWorkingCardParticipant(target.account);
  return { account: target.account, ok: true };
}

// 执行 AI 在卡片元素 invite 字段里填写的邀请（逐个校验，失败不影响其他账号）
async function applyAiInvites(selfAccount, invite) {
  const list = Array.isArray(invite) ? invite : [];
  const names = [...new Set(list.filter(a => typeof a === 'string' && a.trim() !== '').map(a => a.trim()))];
  if (names.length === 0 || !selfAccount) {
    return [];
  }
  const me = await findAccount(selfAccount);
  if (!me) {
    return [];
  }
  const results = [];
  for (const name of names) {
    results.push(await inviteOneAccount(me, name));
  }
  return results;
}

// 执行 AI 在卡片元素 uninvite 字段里填写的「取消邀请」（逐个校验，失败不影响其他账号）
async function applyAiUninvites(selfAccount, uninvite) {
  const list = Array.isArray(uninvite) ? uninvite : [];
  const names = [...new Set(list.filter(a => typeof a === 'string' && a.trim() !== '').map(a => a.trim()))];
  if (names.length === 0) {
    return [];
  }
  const results = [];
  for (const raw of names) {
    const target = await findAccount(raw);
    const account = target ? target.account : raw;
    const working = await getWorkingCard();
    if (!parseParticipants(working.card.participant).includes(account)) {
      results.push({ account: raw, ok: false, reason: '不在当前卡片的参与人中' });
      continue;
    }
    await removeWorkingCardParticipant(account);
    results.push({ account, ok: true });
  }
  return results;
}

// 邀请好友加入「正在设置的卡片」：设置卡片阶段可用（空卡也可先邀请），仅限已是好友的账号；
// 邀请后把好友账号加入卡片参与人（去重），并受「人数上限」约束
export async function inviteToWorkingCard({ account, toAccount, toUserId }) {
  const me = await findAccount(account);
  if (!me) {
    const err = new Error('当前账号不存在，请重新登录');
    err.status = 400;
    throw err;
  }
  let name = typeof toAccount === 'string' ? toAccount.trim() : '';
  if (name === '' && Number.isInteger(toUserId)) {
    const found = await findAccountByUserId(toUserId);
    if (found) {
      name = found.account;
    }
  }
  if (name === '') {
    const err = new Error('目标用户不存在');
    err.status = 404;
    throw err;
  }
  const result = await inviteOneAccount(me, name);
  if (!result.ok) {
    const notFoundReasons = ['目标用户不存在'];
    const err = new Error(`${result.account} ${result.reason}`);
    err.status = notFoundReasons.includes(result.reason) ? 404 : (result.reason === '不能邀请自己' ? 400 : 409);
    throw err;
  }
  return {
    workingCard: await getWorkingCard(),
    flowStatus: await deriveFlowStatus(),
    invited: { account: result.account, already: result.already === true },
    message: result.already
      ? `${result.account} 已在当前卡片的参与人中`
      : `已邀请好友 ${result.account} 加入当前卡片（已写入参与人）`
  };
}

// 取消邀请：把账号从「正在设置的卡片」参与人字段移除（确定前参与者可增可减）
export async function uninviteFromWorkingCard({ account, toAccount }) {
  const me = await findAccount(account);
  if (!me) {
    const err = new Error('当前账号不存在，请重新登录');
    err.status = 400;
    throw err;
  }
  const name = typeof toAccount === 'string' ? toAccount.trim() : '';
  if (name === '') {
    const err = new Error('需要指定要移出的参与人账号');
    err.status = 400;
    throw err;
  }
  const working = await getWorkingCard();
  if (!parseParticipants(working.card.participant).includes(name)) {
    const err = new Error(`${name} 不在当前卡片的参与人中`);
    err.status = 409;
    throw err;
  }
  await removeWorkingCardParticipant(name);
  return {
    workingCard: await getWorkingCard(),
    flowStatus: await deriveFlowStatus(),
    removed: { account: name },
    message: `已把 ${name} 从当前卡片的参与人中移除`
  };
}

// 一键取消 / 还原：清空当前工作卡片，恢复空卡，并重置确认状态；
// 同时清空服务器存储的天气（默认 + 捕获）——被放弃的卡片不再占用捕获地区，客户端下次 ai.ask 会重新上送
export async function resetAiCard() {
  await resetWorkingCard();
  await setConfirmed(false);
  await clearLastReply();
  await clearAiWeather();
  return { workingCard: await getWorkingCard(), flowStatus: await deriveFlowStatus() };
}

// 一键清空 AI 对话记录：本地化改造后对话记录由客户端保存，服务器侧已无可清空内容
// （App 走客户端 :4000 时，服务 8 由客户端本地应答并清空其本地记录）
export async function clearAiContext() {
  return { cleared: { conversations: false }, message: 'AI 对话记录保存在客户端，服务器不再保存对话记录' };
}

// 确定：按客户端看板当前居中的卡片组落位（payload.groupId / payload.cardIndex 由客户端随请求携带）——
// 未指定 = 新建同名组收纳；指定组 = 追加进该组；指定组 + 卡 = 原位更新该卡。
// 设置卡片的账号记为「发起者」（仅一人，原位更新时保持原卡发起者不变）。
// 用户资料与卡片都长期保存在服务器，不回传客户端、不确定后清空。
export async function completeAiCard(options = {}) {
  const { userId = null, account = null, groupId = null, cardIndex = null } = options;
  const completeUserId = (Number.isInteger(userId) && userId >= 1) ? userId : 1;

  const working = await getWorkingCard();
  if (isCardEmpty(working.card)) {
    const err = new Error('还没有可确定的卡片');
    err.status = 400;
    throw err;
  }

  // 硬门槛一：必须有「提醒时间」，且格式与「时间」完全一致（绝对时间，如 2026-09-26 08:30）。
  // 缺失或格式不符一律不允许「确定」。
  if (!hasValidReminderTime(working.card)) {
    const err = new Error('缺少「提醒时间」或格式不正确：提醒时间必须与「时间」同格式（绝对时间 YYYY-MM-DD HH:mm），可在「手动制作卡片」里填写或让 AI 推荐提醒时间');
    err.status = 400;
    throw err;
  }

  // 硬门槛二：与任何已有卡片（公开卡片库中可见的卡片 + 本人与参与人的私人卡片）时间冲突时不允许确定；
  // 原位更新时排除被选取的那张卡本身（它就是工作卡的来源，不与自己冲突）
  const excludeKey = (Number.isInteger(groupId) && groupId >= 1 && Number.isInteger(cardIndex) && cardIndex >= 1)
    ? `${groupId}:${cardIndex}`
    : null;
  const conflicts = findConflicts(working.card, await collectConflictSources(account, excludeKey));
  if (conflicts.length > 0) {
    const err = new Error(`时间冲突，无法确定：${describeConflicts(conflicts).join('；')}`);
    err.status = 409;
    err.conflicts = describeConflicts(conflicts);
    throw err;
  }

  // 硬门槛三：三维度标签（类型 / 场景 / 主题）必须齐备——用于积分计算、周报统计、
  // 卡片小铺推荐、天气联动与发现页筛选；卡片上不展示，可在「手动制作卡片」里点选补齐
  const missingTags = missingCardTags(working.card);
  if (missingTags.length > 0) {
    const err = new Error(`卡片还缺少「${missingTags.join('」「')}」维度标签：可在「手动制作卡片」里点选，或让 AI 补充`);
    err.status = 400;
    throw err;
  }
  // 发起者：设置卡片的账号（仅一人）
  const initiator = typeof account === 'string' ? account.trim() : '';
  if (initiator) {
    working.card.initiator = initiator;
  }

  const written = await writeByVisibility(working, initiator, { groupId, cardIndex });
  const isPublic = working.public !== false;

  // 记日程时邀请的好友（已写入参与人文本）此时还看不到卡片：他们尚未加入卡片组。
  // 确定成功后自动补发一条可「接受邀请」的聊天消息，对方接受后即加入卡片组并看到卡片；
  // 非好友 / 私人组 / 已是组成员 / 卡片已完成等情况静默跳过，单个补发失败不影响确定结果
  if (initiator) {
    const invitedFriends = parseParticipants(working.card.participant)
      .filter(name => name !== initiator);
    for (const friend of invitedFriends) {
      try {
        await sendCardInviteToParticipant({
          account: initiator,
          toAccount: friend,
          groupId: written.id,
          cardIndex: written.cardIndex
        });
      } catch { /* 补发失败不影响确定 */ }
    }
  }

  // 清空工作卡等临时状态；对话记录与用户资料库长期保存在服务器
  await resetWorkingCard();
  await setConfirmed(false);
  await clearLastReply();
  // 卡片已确定：清空服务器存储的天气信息（客户端默认 + 对话捕获地区）
  await clearAiWeather();

  return {
    userId: completeUserId,
    written,
    public: isPublic,
    friendOnly: isPublic && working.friendOnly === true,
    message: messageForWritten(written, isPublic, working.friendOnly === true)
  };
}
