import { MODES, runAiJsonTask, buildPostcardSchema, POSTCARD_TASK, POSTCARD_SYSTEM_PROMPT } from './ai/index.js';
import { getGroupView } from './cardGroupStore.js';
import { checkContent, MODERATION_POSTCARD_TEXT, MODERATION_POSTCARD_MODEL } from './moderation.service.js';
import { enqueuePostcards, takeOutboxFor } from './postcardOutbox.js';

// 明信片：点击「完成」后按该卡片生成一句明信片寄语（时间 + 事件 + 祝福）。
// 服务 66（postcard.make）：完成者本人视角——按组内现存卡片出稿，结果由客户端长期保存；
// 62 完成后的投递：按完成快照出稿——参与者后台出稿一次 fan-out 到外发中转库（postcardOutbox）；
// 完成者本人由 makeCompleterPostcard 同步出稿随 62 响应返回（postcard 字段）并中转投递一份，
// 各端经 103（postcards.pull）拉取（送达即删），客户端落本地库；
// 服务器只在 30 天中转期内暂存未送达的明信片，不做长期持久化。

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

function textOf(value) {
  return typeof value === 'string' ? value.trim() : '';
}

// AI 输出可能是 {postcard:"..."}；容错地从各种可能形状里取出正文
function extractPostcard(data) {
  const d = (data && typeof data === 'object' && !Array.isArray(data)) ? data : {};
  const candidates = [d.postcard, d.text, d.reply, d.content];
  for (const value of candidates) {
    if (typeof value === 'string' && value.trim() !== '') {
      return value.trim();
    }
  }
  if (Array.isArray(d.postcard) && typeof d.postcard[0] === 'string') {
    return d.postcard[0].trim();
  }
  return '';
}

export async function makePostcard({ account, groupId, cardIndex } = {}) {
  const name = textOf(account);
  if (name === '') {
    throw badRequest('需要账号身份才能制作明信片');
  }
  if (!Number.isInteger(cardIndex)) {
    throw badRequest('cardIndex must be an integer');
  }
  const group = await getGroupView(groupId, name);
  const card = (group.cards || []).find(c => c.index === cardIndex);
  if (!card) {
    throw badRequest('组内卡片不存在，无法制作明信片');
  }

  // 智能审核（构建提示词之前）：卡片内容未通过词库审核时不构建提示词、不调用 AI，
  // 返回预设寄语「祝你开心」（model 记为 moderation-preset，前端按正常结果保存展示）
  const moderation = checkContent({ group: group.name, content: card.content });
  if (!moderation.pass) {
    return {
      groupId: group.id,
      groupName: group.name,
      cardIndex: card.index,
      event: card.content?.event ?? null,
      time: card.content?.time ?? null,
      text: MODERATION_POSTCARD_TEXT,
      model: MODERATION_POSTCARD_MODEL,
      createdAt: new Date().toISOString(),
      moderation: { blocked: true, category: moderation.category }
    };
  }

  // 上下文只放这一张卡片：AI 无法看到其他卡片或用户资料
  const context = {
    currentCard: {
      groupId: group.id,
      groupName: group.name,
      cardIndex: card.index,
      event: card.content?.event ?? null,
      time: card.content?.time ?? null,
      location: card.content?.location ?? null,
      purpose: card.content?.purpose ?? null,
      completedBy: card.completedBy ?? null
    }
  };

  const result = await runAiJsonTask({
    task: POSTCARD_TASK,
    context,
    schemaHint: buildPostcardSchema(),
    system: POSTCARD_SYSTEM_PROMPT,
    mode: MODES.POSTCARD
  });

  const text = extractPostcard(result.data) || extractPostcard(result.parts);
  if (text === '') {
    const err = new Error('AI 未返回明信片正文');
    err.status = 502;
    throw err;
  }

  return {
    groupId: group.id,
    groupName: group.name,
    cardIndex: card.index,
    event: card.content?.event ?? null,
    time: card.content?.time ?? null,
    text,
    model: result.model,
    createdAt: new Date().toISOString()
  };
}

// 按完成时刻的卡片快照出稿（62 之后卡片随即被归档删除，不回读卡片库）。
// 快照由 completeGroupCard 在标记完成的同一事务里定格，供参与者明信片后台投递使用。
export async function makePostcardFromSnapshot(snapshot = {}) {
  const moderation = checkContent({ group: snapshot.groupName, content: snapshot.content });
  if (!moderation.pass) {
    return { text: MODERATION_POSTCARD_TEXT, model: MODERATION_POSTCARD_MODEL };
  }

  const context = {
    currentCard: {
      groupId: snapshot.groupId,
      groupName: snapshot.groupName,
      cardIndex: snapshot.cardIndex,
      event: snapshot.event ?? null,
      time: snapshot.time ?? null,
      location: snapshot.location ?? null,
      purpose: snapshot.purpose ?? null,
      completedBy: snapshot.completedBy ?? null
    }
  };

  const result = await runAiJsonTask({
    task: POSTCARD_TASK,
    context,
    schemaHint: buildPostcardSchema(),
    system: POSTCARD_SYSTEM_PROMPT,
    mode: MODES.POSTCARD
  });

  const text = extractPostcard(result.data) || extractPostcard(result.parts);
  if (text === '') {
    const err = new Error('AI 未返回明信片正文');
    err.status = 502;
    throw err;
  }
  return { text, model: result.model };
}

// 参与者明信片投递（62 完成后由路由层后台调用，不阻塞 62 响应）：
// 按快照出稿一次，fan-out 给除完成者（发起者）外的全部花名册成员——
// 完成者本人的明信片由 makeCompleterPostcard 同步出稿随 62 返回并另行中转投递，这里不重复。
// AI 出稿失败时退回预设寄语（完成这件事本身就是寄语），保证参与者总能收到明信片
const POSTCARD_FALLBACK_TEXT = '承诺已兑现，为你留存这一刻 ✨';
const POSTCARD_FALLBACK_MODEL = 'fallback-preset';

export async function deliverPostcardToParticipants(snapshot = {}) {
  const roster = [snapshot.owner, ...(Array.isArray(snapshot.members) ? snapshot.members : [])]
    .filter((name, idx, arr) => typeof name === 'string' && name.trim() !== '' && arr.indexOf(name) === idx);
  const targets = roster.filter(name => name !== snapshot.completedBy);
  if (targets.length === 0) {
    return { delivered: 0 };
  }
  let made;
  try {
    made = await makePostcardFromSnapshot(snapshot);
  } catch (err) {
    console.error('[postcard] 参与者明信片出稿失败，使用预设寄语:', err.message);
    made = { text: POSTCARD_FALLBACK_TEXT, model: POSTCARD_FALLBACK_MODEL };
  }
  const out = await enqueuePostcards({
    groupId: snapshot.groupId,
    groupName: snapshot.groupName ?? '',
    cardIndex: Number.isInteger(snapshot.cardIndex) ? snapshot.cardIndex : null,
    event: snapshot.event ?? '',
    time: snapshot.time ?? '',
    text: made.text,
    model: made.model,
    completedAt: snapshot.completedAt ?? ''
  }, targets);
  return { delivered: out.enqueued };
}

// 完成者本人的明信片（62 路由同步调用）：与参与者投递同一套快照出稿逻辑，
// AI 失败时同样退回预设寄语，保证完成者总能拿到明信片。
// 出稿结果一式两用：随 62 响应返回（postcard 字段——应用内完成弹窗与锁屏卡片
// 完成反馈展示 AI 寄语靠它），同时投一份到外发中转库（103），由应用端拉取后
// 落本地库长期保存（客户端 mergeMany 按 日期+标题+正文 去重，不会重复入库）
export async function makeCompleterPostcard(snapshot = {}, account = '') {
  const name = textOf(account);
  let made;
  try {
    made = await makePostcardFromSnapshot(snapshot);
  } catch (err) {
    console.error('[postcard] 完成者明信片出稿失败，使用预设寄语:', err.message);
    made = { text: POSTCARD_FALLBACK_TEXT, model: POSTCARD_FALLBACK_MODEL };
  }
  const postcard = {
    account: name,
    userId: 0,
    groupId: Number.isInteger(snapshot.groupId) ? snapshot.groupId : 0,
    groupName: snapshot.groupName ?? '',
    cardIndex: Number.isInteger(snapshot.cardIndex) ? snapshot.cardIndex : 0,
    event: snapshot.event ?? '',
    time: snapshot.time ?? '',
    text: made.text,
    model: made.model,
    createdAt: snapshot.completedAt ?? new Date().toISOString()
  };
  if (name !== '') {
    try {
      await enqueuePostcards({
        groupId: postcard.groupId,
        groupName: postcard.groupName,
        cardIndex: Number.isInteger(snapshot.cardIndex) ? snapshot.cardIndex : null,
        event: postcard.event,
        time: postcard.time,
        text: made.text,
        model: made.model,
        completedAt: postcard.createdAt
      }, [name]);
    } catch (err) {
      console.error('[postcard] 完成者明信片中转投递失败:', err.message);
    }
  }
  return postcard;
}

// 服务 103 postcards.pull：拉取发给我的明信片与「清理聊天记录」墓碑（拉取即删）。
// 明信片由客户端落本地库长期保存；clear 墓碑指明要删除本地聊天记录的群号
export async function pullPostcards({ account } = {}) {
  const name = textOf(account);
  if (name === '') {
    throw badRequest('需要账号身份才能拉取明信片');
  }
  const taken = await takeOutboxFor(name);
  return {
    account: name,
    postcards: taken.postcards,
    clears: taken.clears
  };
}