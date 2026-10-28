import { parseTimeRange, expandCardOccurrences, formatDateTime } from './conflictService.js';
import { groupCardEntriesOf } from './cardGroupStore.js';
import { filterDelivered, markDelivered } from './reminderStore.js';
import { pushMail } from './mailboxStore.js';

// 日程提醒：卡片「确定」落库后，按卡片「提醒时间」在该时刻提醒用户。
// 受「服务器无反向投递」约束，提醒由客户端轮询拉取（服务 40 reminders.due），
// 服务器只负责：① 把卡片（含重复日程）展开成具体提醒时刻；② 判定哪些已经到点；③ 用送达台账保证同一条提醒只发一次。
// 提醒只在「到点」时产生，不做提前预告：服务 41 reminders.upcoming 已停用（固定返回空）。
// 「提醒时间」缺失/不合法/晚于日程开始/提前超过 30 天时，一律回退为「该次日程开始时刻」提醒。

// 到点提醒的领取窗口：超过 24 小时未领取的提醒视为过期，不再弹出（避免长时间离线后旧提醒刷屏）
const EXPIRE_MS = 24 * 3600 * 1000;

// 提醒时间最多提前量：超过视为非法，回退为日程开始时刻提醒
const MAX_LEAD_MS = 30 * 24 * 3600 * 1000;

function accountName(account) {
  return typeof account === 'string' ? account.trim() : '';
}

function badRequest(message) {
  const err = new Error(message);
  err.status = 400;
  return err;
}

// 提前量 = 日程开始 - 提醒时间；返回 null 表示卡片没有可用的「时间」字段。
// 延期改时间时复用该函数，保证「提醒时间」随新时间整体平移（保留原提前量）。
export function reminderOffsetMs(card) {
  const base = parseTimeRange(card?.time);
  if (!base) {
    return null;
  }
  const rem = parseTimeRange(card?.reminderTime);
  if (!rem) {
    return 0;
  }
  const offset = base.start.getTime() - rem.start.getTime();
  if (offset < 0 || offset > MAX_LEAD_MS) {
    return 0;
  }
  return offset;
}

// 把一张卡片在 [from, to] 内的提醒时刻全部展开（重复日程按每次展开，提醒时刻 = 该次开始 - 提前量）
function reminderMomentsBetween(card, from, to) {
  const offset = reminderOffsetMs(card);
  if (offset === null) {
    return [];
  }
  const occurrences = expandCardOccurrences(card, {
    from: new Date(from.getTime() + offset),
    to: new Date(to.getTime() + offset)
  });
  const out = [];
  for (const occ of occurrences) {
    const at = new Date(occ.start.getTime() - offset);
    if (at.getTime() >= from.getTime() && at.getTime() <= to.getTime()) {
      out.push({ at, occurrenceStart: occ.start, occurrenceEnd: occ.end });
    }
  }
  return out;
}

// 台账去重 key：组号 + 组内编号 + 该次日程开始时间戳 + 卡片创建时间（槽位复用也不误判）
function reminderKey(entry, moment) {
  return `${entry.library}#${entry.index}#${moment.occurrenceStart.getTime()}#${entry.createdAt ?? ''}`;
}

function describeReminder(entry, moment, now) {
  const card = entry.content ?? {};
  return {
    library: entry.library,
    index: entry.index,
    groupId: entry.groupId ?? null,
    groupName: entry.groupName ?? null,
    cardIndex: entry.cardIndex ?? null,
    purpose: card.purpose ?? null,
    event: card.event ?? null,
    time: card.time ?? null,
    repeatTime: card.repeatTime ?? null,
    repeatUntil: card.repeatUntil ?? null,
    location: card.location ?? null,
    participant: card.participant ?? null,
    initiator: card.initiator ?? null,
    reminderTime: card.reminderTime ?? null,
    remindAt: formatDateTime(moment.at),
    eventStart: formatDateTime(moment.occurrenceStart),
    eventEnd: formatDateTime(moment.occurrenceEnd),
    inMinutes: Math.round((moment.at.getTime() - now.getTime()) / 60000)
  };
}

// 收集本人全部需要提醒的卡片（重做后）：卡片一律存放在卡片组里——
// 本人创建的组 + 本人加入（成员）的组，组内每张未完成的卡片都按其「提醒时间」提醒；
// 已完成的卡片不再提醒。提醒跟随成员/参与关系而非公开库可见性。
async function loadMyReminderCards(account) {
  const entries = await groupCardEntriesOf(account);
  return entries.map(e => ({
    library: 'group',
    index: e.index,
    groupId: e.groupId,
    groupName: e.groupName,
    cardIndex: e.cardIndex,
    content: e.content,
    createdAt: e.createdAt ?? null,
    updatedAt: e.updatedAt ?? null
  }));
}

// 提醒邮件正文：与客户端弹窗内容保持一致，用户在自己的「收件箱」面板里看到同样的信息
function mailBody(entry, moment) {
  const card = entry.content ?? {};
  const parts = ['您有一条日程提醒到点了：'];
  parts.push(`「${card.event || '未命名日程'}」`);
  if (card.purpose) parts.push(`目的：${card.purpose}`);
  if (card.initiator) parts.push(`发起者：${card.initiator}`);
  parts.push(`日程时间：${formatDateTime(moment.occurrenceStart)}${moment.occurrenceEnd ? `~${formatDateTime(moment.occurrenceEnd)}` : ''}${card.repeatTime ? `（${card.repeatTime}${card.repeatUntil ? `，重复到 ${card.repeatUntil}` : ''}）` : ''}`);
  if (card.location) parts.push(`地点：${card.location}`);
  if (card.participant) parts.push(`参与人：${card.participant}`);
  parts.push(`提醒时刻：${formatDateTime(moment.at)}`);
  parts.push('（此邮件由日程编排系统自动投递到您的收件箱）');
  return parts.join('\n');
}

// 到点提醒的邮件投递：把每条已到点的提醒邮件投递到该账号本人的收件箱（弹窗提醒保持不变）。
// 投递失败不影响弹窗提醒的主流程；去重由提醒送达台账保证（同一条提醒只投一次）。
async function deliverReminderMails(account, due) {
  let sent = 0;
  for (const c of due) {
    const card = c.entry.content ?? {};
    const mail = await pushMail({
      toAccount: account,
      fromAccount: account,
      title: `日程提醒邮件：${card.event || '未命名日程'}`,
      body: mailBody(c.entry, c.moment)
    });
    if (mail) {
      sent += 1;
    }
  }
  return { sent };
}

// 服务 40 reminders.due：拉取已经到点、且尚未送达过的提醒。
// 拉取即视为送达（写入台账），同一条提醒对同一账号只返回一次；
// 返回的提醒仍由客户端弹窗展示（保持不变），服务器同时把提醒邮件投递到该账号本人的收件箱。
export async function collectDueReminders({ account = null } = {}) {
  const name = accountName(account);
  if (name === '') {
    throw badRequest('需要账号身份才能拉取提醒');
  }
  const now = new Date();
  const entries = await loadMyReminderCards(name);

  const candidates = [];
  for (const entry of entries) {
    for (const moment of reminderMomentsBetween(entry.content, new Date(now.getTime() - EXPIRE_MS), now)) {
      candidates.push({ entry, moment, key: reminderKey(entry, moment) });
    }
  }
  if (candidates.length === 0) {
    return { account: name, serverTime: now.toISOString(), reminders: [], mail: { sent: 0 } };
  }

  const freshKeys = new Set(await filterDelivered(name, candidates.map(c => c.key)));
  const due = candidates.filter(c => freshKeys.has(c.key));
  if (due.length === 0) {
    return { account: name, serverTime: now.toISOString(), reminders: [], mail: { sent: 0 } };
  }
  await markDelivered(name, due.map(c => c.key));
  const mail = await deliverReminderMails(name, due);
  return {
    account: name,
    serverTime: now.toISOString(),
    reminders: due.map(c => describeReminder(c.entry, c.moment, now)),
    mail
  };
}
